import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/catalog/adapters/forge_catalog_adapter.dart';
import 'package:obtainium/catalog/catalog_provider.dart';
import 'package:obtainium/catalog/data/catalog_database.dart';
import 'package:obtainium/catalog/adapters/github_catalog_adapter.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/catalog/data/catalog_repository.dart';
import 'package:obtainium/pages/catalog_detail.dart';
import 'package:provider/provider.dart';
import 'package:obtainium/catalog/scoring.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late CatalogDatabase database;
  setUp(() {
    database = CatalogDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
  });
  tearDown(() => database.close());

  test(
    'facets are exact and private and unknown filters are explicit',
    () async {
      final now = DateTime.utc(2026, 1, 15);
      await database.upsertForgeRepository(
        _repository(
          id: 'utility',
          name: 'Alpha Utility',
          categories: const {'Utility'},
          stars: 50,
          observedAt: now,
        ),
      );
      await database.upsertForgeRepository(
        _repository(
          id: 'utilities',
          name: 'Beta Utilities',
          categories: const {'Utilities'},
          stars: 100,
          observedAt: now,
        ),
      );
      await database.upsertForgeRepository(
        _repository(
          id: 'private',
          name: 'Private Utility',
          categories: const {'Utility'},
          stars: 1,
          isPrivate: true,
          apkAvailability: AvailabilityState.unknown,
          observedAt: now,
        ),
      );

      final exact = await database.queryCatalog(
        const CatalogQuery(
          text: '',
          filters: CatalogFilters(categories: {'Utility'}),
        ),
      );
      expect(
        exact.map((entry) => entry.name),
        containsAll(<String>['Alpha Utility', 'Private Utility']),
      );
      expect(
        exact.map((entry) => entry.name),
        isNot(contains('Beta Utilities')),
      );

      final privateOnly = await database.queryCatalog(
        const CatalogQuery(text: '', filters: CatalogFilters(isPrivate: true)),
      );
      expect(privateOnly.map((entry) => entry.name), ['Private Utility']);

      final availableOnly = await database.queryCatalog(
        const CatalogQuery(
          text: '',
          filters: CatalogFilters(apkAvailable: true),
        ),
      );
      expect(
        availableOnly.map((entry) => entry.name),
        isNot(contains('Private Utility')),
      );
      final includeUnknown = await database.queryCatalog(
        const CatalogQuery(
          text: '',
          filters: CatalogFilters(apkAvailable: true, includeUnknown: true),
        ),
      );
      expect(
        includeUnknown.map((entry) => entry.name),
        contains('Private Utility'),
      );
    },
  );
  test(
    'catalog filters and lightweight sorts apply exact predicates',
    () async {
      final now = DateTime.utc(2026, 1, 15);
      await database.upsertForgeRepository(
        _repository(
          id: 'alpha',
          name: 'Alpha',
          categories: const {'Utility'},
          topics: const {'privacy'},
          license: 'MIT',
          stars: 100,
          accountId: 'account-a',
          observedAt: now.subtract(const Duration(days: 2)),
        ),
      );
      await database.upsertForgeRepository(
        _repository(
          id: 'beta',
          name: 'Beta',
          categories: const {'Game'},
          topics: const {'offline'},
          stars: 5,
          archived: true,
          fork: true,
          deviceCompatibility: AvailabilityState.unavailable,
          observedAt: now,
        ),
      );

      Future<List<String>> names(CatalogQuery query) async =>
          (await database.queryCatalog(
            query,
          )).map((entry) => entry.name).toList();

      expect(
        await names(
          const CatalogQuery(
            text: '',
            filters: CatalogFilters(
              accountIds: {'account-a'},
              categories: {'Utility'},
              licenses: {'MIT'},
              topics: {'privacy'},
              minimumStars: 50,
            ),
          ),
        ),
        ['Alpha'],
      );
      expect(
        await names(
          const CatalogQuery(
            text: '',
            filters: CatalogFilters(
              includeArchived: true,
              includeForks: true,
              deviceCompatible: false,
            ),
          ),
        ),
        ['Beta'],
      );
      expect(
        await names(const CatalogQuery(text: '', sort: CatalogSort.name)),
        ['Alpha'],
      );
      expect(
        await names(
          const CatalogQuery(
            text: '',
            sort: CatalogSort.stars,
            filters: CatalogFilters(includeArchived: true, includeForks: true),
          ),
        ),
        ['Alpha', 'Beta'],
      );
      expect(
        await names(
          const CatalogQuery(
            text: '',
            sort: CatalogSort.activity,
            filters: CatalogFilters(includeArchived: true, includeForks: true),
          ),
        ),
        ['Beta', 'Alpha'],
      );
    },
  );

  test(
    'score sort is stable and full-text search handles quoted input',
    () async {
      final now = DateTime.utc(2026, 1, 15);
      await database.upsertForgeRepository(
        _repository(
          id: 'low',
          name: 'Quoted Android Client',
          categories: const {'Utility'},
          stars: 5,
          score: 40,
          observedAt: now,
        ),
      );
      await database.upsertForgeRepository(
        _repository(
          id: 'high',
          name: 'Quoted Android Manager',
          categories: const {'Utility'},
          stars: 2,
          score: 90,
          observedAt: now,
        ),
      );

      final sorted = await database.queryCatalog(
        const CatalogQuery(
          text: 'Quoted "Android',
          sort: CatalogSort.emporionScore,
        ),
      );
      expect(
        sorted.map((entry) => entry.forgeRepository!.providerRepositoryId),
        ['high', 'low'],
      );
    },
  );

  test('F-Droid repository updates preserve in-progress generations', () async {
    const repositoryId = 'fdroid-official';
    const generation = 'generation-before-repository-update';
    final accepted = DateTime.utc(2026, 1, 15, 12);
    await database.beginFdroidGeneration(repositoryId, generation);
    await database.stageFdroidBatch(repositoryId, generation, [
      _fdroidPackage(generation, versionCode: 10),
    ]);

    await database.upsertFdroidRepository(
      FdroidRepository.official().copyWith(label: 'Updated F-Droid'),
    );
    await database.publishFdroidGeneration(
      repositoryId: repositoryId,
      generation: generation,
      acceptedTimestamp: accepted,
    );

    final repositories = await database.fdroidRepositories();
    final packages = await database.fdroidPackagesForRepository(repositoryId);
    expect(repositories.single.label, 'Updated F-Droid');
    expect(packages.single.generation, generation);
  });

  test(
    'F-Droid publication is atomic and rejects timestamp rollback',
    () async {
      const repositoryId = 'fdroid-official';
      final accepted = DateTime.utc(2026, 1, 15, 12);
      await database.beginFdroidGeneration(repositoryId, 'generation-1');
      await database.stageFdroidBatch(repositoryId, 'generation-1', [
        _fdroidPackage('generation-1', versionCode: 10),
      ]);
      await database.publishFdroidGeneration(
        repositoryId: repositoryId,
        generation: 'generation-1',
        acceptedTimestamp: accepted,
      );

      var visible = await database.fdroidPackagesForRepository(repositoryId);
      expect(visible.single.versions.single.versionCode, 10);

      await database.beginFdroidGeneration(repositoryId, 'generation-2');
      await database.stageFdroidBatch(repositoryId, 'generation-2', [
        _fdroidPackage('generation-2', versionCode: 11),
      ]);
      await expectLater(
        database.publishFdroidGeneration(
          repositoryId: repositoryId,
          generation: 'generation-2',
          acceptedTimestamp: accepted.subtract(const Duration(seconds: 1)),
        ),
        throwsA(isA<FormatException>()),
      );

      visible = await database.fdroidPackagesForRepository(repositoryId);
      expect(visible.single.generation, 'generation-1');
      expect(visible.single.versions.single.versionCode, 10);
    },
  );

  test(
    'F-Droid identities preserve signer variants and merge linked sources',
    () async {
      const signerA =
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      const signerB =
          'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
      const repositoryId = 'fdroid-official';
      const generation = 'dedupe-generation';
      final now = DateTime.utc(2026, 1, 15);
      final forge =
          _repository(
            id: 'linked',
            name: 'Linked App',
            categories: const {'Utility'},
            stars: 100,
            observedAt: now,
          ).copyWith(
            releases: [
              ReleaseSummary(
                id: 'release-1',
                version: '1.0',
                assets: [
                  ReleaseAsset(
                    name: 'app.apk',
                    downloadUrl: Uri.parse(
                      'https://github.com/example/linked/app.apk',
                    ),
                    contentType: 'application/vnd.android.package-archive',
                  ),
                ],
              ),
            ],
          );
      await database.upsertForgeRepository(forge);
      await database.beginFdroidGeneration(repositoryId, generation);
      final packageA = _fdroidPackage(
        generation,
        versionCode: 10,
        signer: signerA,
        sourceCodeUrl: forge.webUrl,
      );
      final packageB = _fdroidPackage(
        generation,
        versionCode: 10,
        signer: signerB,
        antiFeatures: const {'Tracking'},
        sourceCodeUrl: forge.webUrl,
      );
      await database.stageFdroidBatch(repositoryId, generation, [
        packageA,
        packageB,
      ]);
      await database.publishFdroidGeneration(
        repositoryId: repositoryId,
        generation: generation,
        acceptedTimestamp: now,
      );
      await database.linkPackageSource(package: packageA, repository: forge);
      final entries = await database.queryCatalog(const CatalogQuery(text: ''));

      expect(entries, hasLength(2));
      expect(entries.map((entry) => entry.catalogKey).toSet(), hasLength(2));
      final antiFeatureMatches = await database.queryCatalog(
        const CatalogQuery(
          text: '',
          filters: CatalogFilters(antiFeatures: {'Tracking'}),
        ),
      );
      expect(antiFeatureMatches.single.fdroidPackage!.signerSha256, signerB);
      final linked = entries.singleWhere(
        (entry) => entry.fdroidPackage!.signerSha256 == signerA,
      );
      expect(linked.forgeRepository?.catalogKey, forge.catalogKey);
      expect(
        linked.installOrigins.map((origin) => origin.sourceUrl).toSet(),
        hasLength(linked.installOrigins.length),
      );
    },
  );

  test('provider failure preserves the stale cached result', () async {
    final old = DateTime.now().toUtc().subtract(const Duration(days: 2));
    await database.upsertForgeRepository(
      _repository(
        id: 'cached',
        name: 'Cached Client',
        categories: const {'Utility'},
        stars: 10,
        observedAt: old,
      ),
    );
    final repository = CatalogRepository(
      database: database,
      adapters: [GitHubCatalogAdapter(_FailingTransport())],
    );

    final results = await repository
        .search(
          const CatalogQuery(
            text: 'Cached Client',
            filters: CatalogFilters(sources: {ProviderKind.github}),
          ),
        )
        .toList();

    expect(results, hasLength(2));
    expect(results.last.entries.single.name, 'Cached Client');
    expect(results.last.stale, isTrue);
    expect(results.last.partial, isTrue);
    expect(results.last.message, isNotEmpty);
  });

  test('provider refresh retains matching F-Droid results', () async {
    const repositoryId = 'fdroid-official';
    const generation = 'unified-search-generation';
    await database.beginFdroidGeneration(repositoryId, generation);
    await database.stageFdroidBatch(repositoryId, generation, [
      _fdroidPackage(generation, versionCode: 10),
    ]);
    await database.publishFdroidGeneration(
      repositoryId: repositoryId,
      generation: generation,
      acceptedTimestamp: DateTime.utc(2026, 1, 15),
    );
    final repository = CatalogRepository(
      database: database,
      adapters: [GitHubCatalogAdapter(_SuccessfulSearchTransport())],
    );

    final results = await repository
        .search(const CatalogQuery(text: 'Example'))
        .toList();

    expect(results, hasLength(2));
    expect(results.last.entries.map((entry) => entry.originKind).toSet(), {
      CatalogOriginKind.forgeRelease,
      CatalogOriginKind.fdroidPackage,
    });
  });

  testWidgets('F-Droid detail lays out complete provenance fingerprints', (
    tester,
  ) async {
    final package = _fdroidPackage(
      'detail-provenance-generation',
      versionCode: 10,
    );
    final entry = CatalogEntry(
      catalogKey: 'fdroid:fdroid-official:org.example.app',
      originKind: CatalogOriginKind.fdroidPackage,
      name: 'Example',
      sourceLabel: 'F-Droid',
      host: 'f-droid.org',
      packageName: package.packageName,
      categories: package.categories,
      topics: const {},
      antiFeatures: package.antiFeatures,
      isPrivate: false,
      archived: false,
      fork: false,
      apkAvailability: AvailabilityState.available,
      deviceCompatibility: AvailabilityState.unknown,
      freshness: FreshnessState.fresh,
      observedAt: package.observedAt,
      installOrigins: const [],
      fdroidPackage: package,
    );
    final catalogProvider = _StaticCatalogProvider(entry);

    await tester.pumpWidget(
      ChangeNotifierProvider<CatalogProvider>.value(
        value: catalogProvider,
        child: MaterialApp(
          home: CatalogDetailPage(catalogKey: entry.catalogKey),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -1800));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text(FdroidRepository.officialFingerprint), findsOneWidget);
    expect(tester.takeException(), isNull);
    catalogProvider.dispose();
  });

  test('score requires adequate coverage and penalizes stale projects', () {
    final now = DateTime.utc(2026, 1, 15);
    final saturated = EmporionScorer.score(
      MetricSnapshot(
        observedAt: now,
        stars: 10000,
        commits90d: 90,
        activeContributors90d: 50,
        allTimeContributors: 100,
        releases365d: 12,
        daysSinceCommit: 0,
        daysSinceRelease: 0,
        issueSampleSize: 10,
        responseRate: 1,
        actionRate: 1,
        closeRate: 1,
        medianFirstResponseHours: 0,
      ),
    );
    expect(saturated.score, 100);
    expect(saturated.confidence, 100);

    final unknownReweighted = EmporionScorer.score(
      MetricSnapshot(
        observedAt: now,
        commits90d: 90,
        activeContributors90d: 50,
        releases365d: 12,
        daysSinceCommit: 0,
        daysSinceRelease: 0,
        issueSampleSize: 10,
        responseRate: 1,
        actionRate: 1,
        closeRate: 1,
        medianFirstResponseHours: 0,
      ),
    );
    expect(unknownReweighted.score, 100);
    expect(unknownReweighted.confidence, lessThan(100));

    final estimated = EmporionScorer.score(
      MetricSnapshot(
        observedAt: now,
        stars: 10000,
        commits90d: 90,
        activeContributors90d: 50,
        releases365d: 12,
        daysSinceCommit: 0,
        daysSinceRelease: 0,
        issueSampleSize: 10,
        responseRate: 1,
        actionRate: 1,
        closeRate: 1,
        medianFirstResponseHours: 0,
        estimatedFields: const {'stars'},
      ),
    );
    expect(estimated.score, 100);
    expect(estimated.confidence, lessThan(saturated.confidence));
    final sparse = EmporionScorer.score(
      MetricSnapshot(observedAt: now, stars: 500, commits90d: 40),
    );
    expect(sparse.score, isNull);
    expect(sparse.confidence, lessThan(50));

    final active = EmporionScorer.score(_completeMetrics(now, stale: false));
    final stale = EmporionScorer.score(_completeMetrics(now, stale: true));
    expect(active.confidence, 100);
    expect(active.score, isNotNull);
    expect(active.score!, greaterThan(stale.score!));
  });
}

class _StaticCatalogProvider extends CatalogProvider {
  final CatalogEntry entry;

  _StaticCatalogProvider(this.entry)
    : super(
        repository: CatalogRepository(
          database: CatalogDatabase(
            factory: databaseFactoryFfi,
            path: inMemoryDatabasePath,
          ),
          adapters: const [],
        ),
      );

  @override
  List<CatalogEntry> get entries => [entry];

  @override
  List<FdroidRepository> get fdroidRepositories => [
    FdroidRepository.official(),
  ];

  @override
  Future<void> enrichEntry(String catalogKey) async {}
}

class _FailingTransport implements CatalogTransport {
  @override
  Future<CatalogResponse> get(
    Uri uri, {
    required ProviderKind provider,
    ProviderAccount? account,
    String? credentialOverride,
    Map<String, String> headers = const {},
  }) async {
    throw CatalogHttpException('offline', uri: uri);
  }
}

class _SuccessfulSearchTransport implements CatalogTransport {
  @override
  Future<CatalogResponse> get(
    Uri uri, {
    required ProviderKind provider,
    ProviderAccount? account,
    String? credentialOverride,
    Map<String, String> headers = const {},
  }) async {
    final body = jsonEncode({
      'total_count': 1,
      'incomplete_results': false,
      'items': [
        {
          'id': 42,
          'name': 'Example Forge',
          'full_name': 'example/forge',
          'html_url': 'https://github.com/example/forge',
          'url': 'https://api.github.com/repos/example/forge',
          'owner': {'login': 'example'},
          'description': 'Example Android app',
          'topics': ['android'],
          'private': false,
          'archived': false,
          'fork': false,
          'stargazers_count': 10,
          'forks_count': 1,
          'open_issues_count': 0,
          'pushed_at': '2026-01-15T00:00:00Z',
        },
      ],
    });
    return CatalogResponse(
      statusCode: 200,
      headers: const {},
      bodyBytes: utf8.encode(body),
      requestUri: uri,
    );
  }
}

ForgeRepository _repository({
  required String id,
  required String name,
  required Set<String> categories,
  required int stars,
  required DateTime observedAt,
  int? score,
  bool isPrivate = false,
  AvailabilityState apkAvailability = AvailabilityState.available,
  Set<String> topics = const {'android'},
  String license = 'GPL-3.0-only',
  String? accountId,
  bool archived = false,
  bool fork = false,
  AvailabilityState deviceCompatibility = AvailabilityState.available,
}) {
  final metrics = MetricSnapshot(
    observedAt: observedAt,
    stars: stars,
    score: score,
    confidence: score == null ? 0 : 100,
  );
  return ForgeRepository(
    catalogKey: ForgeRepository.identity(ProviderKind.github, 'github.com', id),
    provider: ProviderKind.github,
    host: 'github.com',
    providerRepositoryId: id,
    webUrl: Uri.parse('https://github.com/example/$id'),
    apiUrl: Uri.parse('https://api.github.com/repos/example/$id'),
    owner: 'example',
    path: 'example/$id',
    name: name,
    topics: topics,
    categories: categories,
    license: license,
    isPrivate: isPrivate,
    accountId: accountId,
    archived: archived,
    fork: fork,
    apkAvailability: apkAvailability,
    deviceCompatibility: deviceCompatibility,
    observedAt: observedAt,
    lastActivity: observedAt,
    metrics: metrics,
  );
}

FdroidPackage _fdroidPackage(
  String generation, {
  required int versionCode,
  String repositoryId = 'fdroid-official',
  String signer =
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  Set<String> antiFeatures = const {},
  Uri? sourceCodeUrl,
}) {
  return FdroidPackage(
    repositoryId: repositoryId,
    packageName: 'org.example.app',
    signerSha256: signer,
    name: 'Example',
    categories: const {'Utility'},
    antiFeatures: antiFeatures,
    sourceCodeUrl: sourceCodeUrl,
    screenshots: const [],
    observedAt: DateTime.utc(2026, 1, 15),
    generation: generation,
    versions: [
      FdroidVersion(
        repositoryId: repositoryId,
        packageName: 'org.example.app',
        versionName: '1.$versionCode',
        versionCode: versionCode,
        apkUrl: Uri.parse(
          'https://f-droid.org/repo/org.example.app_$versionCode.apk',
        ),
        sha256:
            'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        size: 1024,
        signerSha256: signer,
      ),
    ],
  );
}

MetricSnapshot _completeMetrics(DateTime now, {required bool stale}) =>
    MetricSnapshot(
      observedAt: now,
      stars: 1000,
      commits90d: stale ? 0 : 80,
      activeContributors90d: stale ? 1 : 20,
      allTimeContributors: 50,
      releases365d: stale ? 0 : 10,
      daysSinceCommit: stale ? 720 : 1,
      daysSinceRelease: stale ? 720 : 5,
      issueSampleSize: 10,
      responseRate: stale ? 0.1 : 0.9,
      actionRate: stale ? 0.1 : 0.9,
      closeRate: stale ? 0.1 : 0.8,
      medianFirstResponseHours: stale ? 500 : 8,
    );
