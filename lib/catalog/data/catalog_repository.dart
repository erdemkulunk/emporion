import 'dart:async';

import 'package:obtainium/catalog/adapters/forge_catalog_adapter.dart';
import 'package:obtainium/catalog/data/catalog_database.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/catalog/scoring.dart';

class CatalogSearchResult {
  final List<CatalogEntry> entries;
  final bool stale;
  final bool partial;
  final bool incomplete;
  final int evaluated;
  final String? message;

  const CatalogSearchResult({
    required this.entries,
    this.stale = false,
    this.partial = false,
    this.incomplete = false,
    this.evaluated = 0,
    this.message,
  });
}

class CatalogRepository {
  static const searchTtl = Duration(minutes: 30);
  static const repositoryTtl = Duration(hours: 6);
  static const metricTtl = Duration(hours: 24);
  static const heavyBatchSize = 10;
  static const heavyMatchTarget = 50;
  static const providerCandidateLimit = 300;

  final CatalogDatabase database;
  final List<ForgeCatalogAdapter> adapters;

  const CatalogRepository({required this.database, required this.adapters});

  ForgeCatalogAdapter adapterFor(ProviderKind kind, String host) {
    return adapters.firstWhere(
      (adapter) =>
          adapter.kind == kind &&
          (kind != ProviderKind.forgejo ||
              canonicalHost(adapter.defaultWebBaseUrl) == canonicalHost(host)),
      orElse: () => adapters.firstWhere((adapter) => adapter.kind == kind),
    );
  }

  Future<List<CatalogEntry>> searchCached(
    CatalogQuery query, {
    int offset = 0,
  }) => database.queryCatalog(query, offset: offset);

  Stream<CatalogSearchResult> search(CatalogQuery query) async* {
    final cached = await searchCached(query);
    if (cached.isNotEmpty) {
      yield CatalogSearchResult(
        entries: cached,
        stale: cached.any((e) => e.freshness != FreshnessState.fresh),
      );
    }

    final accounts = await database.accounts();
    final work = <({ForgeCatalogAdapter adapter, ProviderAccount? account})>[];
    for (final adapter in adapters) {
      if (query.filters.sources.isNotEmpty &&
          !query.filters.sources.contains(adapter.kind)) {
        continue;
      }
      work.add((adapter: adapter, account: null));
      for (final account in accounts.where(
        (a) =>
            a.provider == adapter.kind &&
            !a.reconnectRequired &&
            (query.filters.accountIds.isEmpty ||
                query.filters.accountIds.contains(a.id)),
      )) {
        work.add((adapter: adapter, account: account));
      }
    }

    final providerResults = await Future.wait(
      work.map((target) async {
        try {
          final page = await target.adapter.search(
            query,
            account: target.account,
          );
          for (final repository in page.repositories) {
            await database.upsertForgeRepository(repository);
          }
          final host =
              target.account?.webBaseUrl ?? target.adapter.defaultWebBaseUrl;
          final cacheKey = query.cacheKey(
            target.adapter.kind,
            host,
            target.account?.id,
          );
          await database.saveSearchPage(
            cacheKey: cacheKey,
            provider: target.adapter.kind,
            host: host,
            accountId: target.account?.id,
            query: query,
            catalogKeys: page.repositories.map((e) => e.catalogKey).toList(),
            next: page.next,
            incomplete: page.incomplete,
            ttl: searchTtl,
          );
          return (target: target, page: page, error: null as Object?);
        } catch (error) {
          return (
            target: target,
            page: null as CatalogPage?,
            error: error as Object?,
          );
        }
      }),
    );

    final stableKeys = <String>[];
    final seen = <String>{};
    var partial = false;
    var incomplete = false;
    final errors = <String>[];
    for (final result in providerResults) {
      final page = result.page;
      if (page == null) {
        errors.add('${result.target.adapter.adapterName}: ${result.error}');
        continue;
      }
      partial = partial || page.partial;
      incomplete = incomplete || page.incomplete;
      for (final repository in page.repositories) {
        if (seen.add(repository.catalogKey)) {
          stableKeys.add(repository.catalogKey);
        }
      }
    }
    final unified = await database.queryCatalog(
      CatalogQuery(
        text: query.text,
        filters: query.filters,
        sort: query.sort,
        pageSize: query.pageSize,
      ),
    );
    final byKey = {for (final entry in unified) entry.catalogKey: entry};
    final refreshed = <CatalogEntry>[
      for (final key in stableKeys) ?byKey.remove(key),
      ...byKey.values,
    ];
    if (refreshed.isNotEmpty || cached.isEmpty) {
      yield CatalogSearchResult(
        entries: refreshed,
        stale: refreshed.any(
          (entry) => entry.freshness != FreshnessState.fresh,
        ),
        partial: partial || errors.isNotEmpty,
        incomplete: incomplete,
        message: errors.isEmpty ? null : errors.join('\n'),
      );
    }
  }

  Future<CatalogEntry> enrich(
    CatalogEntry entry, {
    bool includeMetrics = true,
  }) async {
    final repository = entry.forgeRepository;
    if (repository == null) return entry;
    final accounts = await database.accounts();
    final account = repository.accountId == null
        ? null
        : accounts.where((e) => e.id == repository.accountId).firstOrNull;
    final adapter = adapterFor(repository.provider, repository.host);
    final now = DateTime.now().toUtc();
    final releases =
        repository.releases.isNotEmpty &&
            now.difference(repository.observedAt) <= const Duration(hours: 6)
        ? repository.releases
        : await adapter.fetchReleases(
            repository,
            account: account,
            maxPages: 3,
          );
    var enriched = repository.copyWith(
      releases: releases,
      apkAvailability: releases.any((e) => e.hasInstallableAsset)
          ? AvailabilityState.available
          : AvailabilityState.unavailable,
      observedAt: now,
    );
    if (includeMetrics) {
      final cached = repository.metrics;
      final metrics =
          cached != null && cached.isFreshAt(now, const Duration(hours: 24))
          ? cached
          : await adapter.fetchMetrics(enriched, account: account, now: now);
      enriched = enriched.copyWith(metrics: EmporionScorer.score(metrics));
    }
    await database.upsertForgeRepository(enriched);
    final rows = await database.queryCatalog(
      const CatalogQuery(text: '', pageSize: 1),
      restrictToKeys: [enriched.catalogKey],
    );
    if (rows.isEmpty) throw StateError('Enriched catalog entry disappeared');
    return rows.single;
  }

  Future<CatalogSearchResult> evaluateHeavyFilters(
    CatalogQuery query, {
    int alreadyEvaluated = 0,
    int requestBudget = 200,
  }) async {
    if (!query.filters.requiresHeavyMetrics &&
        query.sort != CatalogSort.emporionScore) {
      final entries = await searchCached(query);
      return CatalogSearchResult(entries: entries, evaluated: entries.length);
    }
    final candidates = await database.queryCatalog(
      CatalogQuery(
        text: query.text,
        filters: CatalogFilters(
          sources: query.filters.sources,
          accountIds: query.filters.accountIds,
          categories: query.filters.categories,
          licenses: query.filters.licenses,
          antiFeatures: query.filters.antiFeatures,
          topics: query.filters.topics,
          isPrivate: query.filters.isPrivate,
          apkAvailable: query.filters.apkAvailable,
          deviceCompatible: query.filters.deviceCompatible,
          includeArchived: query.filters.includeArchived,
          includeForks: query.filters.includeForks,
          includeUnknown: true,
          minimumStars: query.filters.minimumStars,
        ),
        sort: CatalogSort.relevance,
        pageSize: providerCandidateLimit,
      ),
    );
    var evaluated = alreadyEvaluated;
    var requests = 0;
    final providerCounts = <ProviderKind, int>{};
    while (evaluated < candidates.length && requests < requestBudget) {
      final batch = candidates.skip(evaluated).take(heavyBatchSize).where((
        entry,
      ) {
        final kind = entry.forgeRepository?.provider;
        if (kind == null) return false;
        final used = providerCounts[kind] ?? 0;
        if (used >= providerCandidateLimit) return false;
        providerCounts[kind] = used + 1;
        return true;
      }).toList();
      if (batch.isEmpty) break;
      for (final entry in batch) {
        try {
          await enrich(entry);
        } on CatalogHttpException {
          // Unavailable metrics remain unknown and are handled by includeUnknown.
        }
        requests++;
        if (requests >= requestBudget) break;
      }
      evaluated += batch.length;
      final matches = await database.queryCatalog(query);
      if (matches.length >= heavyMatchTarget) {
        return CatalogSearchResult(
          entries: matches,
          evaluated: evaluated,
          partial: true,
        );
      }
    }
    final matches = await database.queryCatalog(query);
    return CatalogSearchResult(
      entries: matches,
      evaluated: evaluated,
      partial: evaluated < candidates.length,
      message: '${matches.length} matches from $evaluated evaluated',
    );
  }

  Future<ProviderAccount> addAccount({
    required ForgeCatalogAdapter adapter,
    required String apiBaseUrl,
    required String webBaseUrl,
    required String token,
    required String label,
    required Future<void> Function(ProviderAccount account, String token)
    storeCredential,
  }) async {
    final validation = await adapter.validateAccount(
      apiBaseUrl: apiBaseUrl,
      webBaseUrl: webBaseUrl,
      token: token,
    );
    final account = ProviderAccount.validated(
      provider: adapter.kind,
      apiBaseUrl: apiBaseUrl,
      webBaseUrl: webBaseUrl,
      label: label,
      username: validation.username,
      validatedAt: DateTime.now().toUtc(),
      effectiveScopes: validation.effectiveScopes,
    );
    await storeCredential(account, token);
    await database.upsertAccount(account);
    return account;
  }

  Future<void> deleteAccount(
    ProviderAccount account, {
    required Future<void> Function(String accountId) deleteCredential,
  }) async {
    await deleteCredential(account.id);
    await database.deleteAccountData(account.id);
  }
}
