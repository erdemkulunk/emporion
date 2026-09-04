import 'package:obtainium/catalog/data/catalog_repository.dart';
import 'package:obtainium/catalog/fdroid/verified_fdroid_catalog_source.dart';
import 'package:obtainium/catalog/models.dart';

class CatalogRefreshReport {
  final int fdroidRepositories;
  final int forgeRepositories;
  final int enrichedSubscriptions;
  final List<String> errors;

  const CatalogRefreshReport({
    required this.fdroidRepositories,
    required this.forgeRepositories,
    required this.enrichedSubscriptions,
    required this.errors,
  });

  bool get hasActionableError => errors.any((error) {
    final value = error.toLowerCase();
    return value.contains('credential') ||
        value.contains('authorization') ||
        value.contains('fingerprint') ||
        value.contains('trust');
  });
}

class CatalogBackgroundRefresher {
  final CatalogRepository repository;
  final VerifiedFdroidCatalogSource fdroid;

  const CatalogBackgroundRefresher({
    required this.repository,
    required this.fdroid,
  });

  Future<CatalogRefreshReport> run({
    required Set<String> subscribedUrls,
    String locale = 'en-US',
  }) async {
    var fdroidCount = 0;
    var forgeCount = 0;
    var enrichedCount = 0;
    final errors = <String>[];

    for (final fdroidRepository
        in await repository.database.fdroidRepositories()) {
      if (!fdroidRepository.enabled ||
          fdroidRepository.trustState != RepositoryTrustState.trusted) {
        continue;
      }
      try {
        await fdroid.sync(fdroidRepository, locale: locale);
        fdroidCount++;
      } catch (error) {
        errors.add('${fdroidRepository.label}: $error');
      }
    }

    final accounts = await repository.database.accounts();
    for (final adapter in repository.adapters) {
      final targets = <ProviderAccount?>[
        null,
        ...accounts.where((account) => account.provider == adapter.kind),
      ];
      for (final account in targets) {
        try {
          for (final query in _shelfQueries(adapter.kind)) {
            final page = await adapter.search(query, account: account);
            for (final forgeRepository in page.repositories) {
              await repository.database.upsertForgeRepository(forgeRepository);
              forgeCount++;
            }
          }
          if (account != null) {
            PageCursor? cursor;
            do {
              final page = await adapter.listAccessibleRepositories(
                account: account,
                cursor: cursor,
              );
              for (final forgeRepository in page.repositories) {
                await repository.database.upsertForgeRepository(
                  forgeRepository,
                );
                forgeCount++;
              }
              cursor = page.next;
            } while (cursor != null);
          }
        } catch (error) {
          errors.add(
            '${adapter.kind.name}/${account?.label ?? 'public'}: $error',
          );
        }
      }
    }

    final normalizedSubscriptions = subscribedUrls.map(_canonicalUrl).toSet();
    final candidates = await repository.database.queryCatalog(
      const CatalogQuery(text: '', pageSize: 300),
    );
    for (final entry in candidates) {
      final forgeRepository = entry.forgeRepository;
      if (forgeRepository == null) continue;
      final subscribed = normalizedSubscriptions.contains(
        _canonicalUrl(forgeRepository.webUrl.toString()),
      );
      if (!subscribed && !forgeRepository.isPrivate) continue;
      try {
        await repository.enrich(entry, includeMetrics: subscribed);
        if (subscribed) enrichedCount++;
      } catch (error) {
        errors.add('${forgeRepository.path}: $error');
      }
    }

    return CatalogRefreshReport(
      fdroidRepositories: fdroidCount,
      forgeRepositories: forgeCount,
      enrichedSubscriptions: enrichedCount,
      errors: errors,
    );
  }

  List<CatalogQuery> _shelfQueries(ProviderKind kind) => switch (kind) {
    ProviderKind.github => const [
      CatalogQuery(
        text: 'topic:android archived:false',
        sort: CatalogSort.stars,
        pageSize: 100,
      ),
      CatalogQuery(
        text: 'topic:android-app archived:false',
        sort: CatalogSort.stars,
        pageSize: 100,
      ),
    ],
    ProviderKind.gitlab => const [
      CatalogQuery(
        text: '',
        filters: CatalogFilters(topics: {'android'}),
        sort: CatalogSort.stars,
        pageSize: 100,
      ),
    ],
    ProviderKind.forgejo => const [
      CatalogQuery(text: 'android', sort: CatalogSort.stars, pageSize: 50),
    ],
    ProviderKind.fdroid => const [],
  };

  static String _canonicalUrl(String value) {
    final uri = Uri.parse(value);
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          query: null,
          fragment: null,
          path: uri.path.replaceFirst(RegExp(r'/$'), ''),
        )
        .toString();
  }
}
