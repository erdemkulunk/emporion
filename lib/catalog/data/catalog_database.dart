import 'dart:convert';

import 'package:obtainium/catalog/models.dart';
import 'package:sqflite/sqflite.dart';

class CachedSearchPage {
  final String cacheKey;
  final List<String> catalogKeys;
  final PageCursor? next;
  final DateTime observedAt;
  final DateTime expiresAt;
  final bool incomplete;

  const CachedSearchPage({
    required this.cacheKey,
    required this.catalogKeys,
    required this.observedAt,
    required this.expiresAt,
    this.next,
    this.incomplete = false,
  });

  bool isFreshAt(DateTime now) => !expiresAt.isBefore(now.toUtc());
}

class CatalogDatabase {
  static const schemaVersion = 1;
  static const defaultFileName = 'emporion_catalog.db';

  final DatabaseFactory factory;
  final String? path;
  Database? _database;
  String _ftsRowIdColumn = 'docid';

  CatalogDatabase({DatabaseFactory? factory, this.path})
    : factory = factory ?? databaseFactory;

  Future<Database> get database async => _database ??= await _open();

  Future<Database> _open() async {
    final dbPath = path ?? '${await getDatabasesPath()}/$defaultFileName';
    final opened = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: _create,
      ),
    );
    final ftsDefinition = await opened.query(
      'sqlite_master',
      columns: ['sql'],
      where: "type = 'table' AND name = 'catalog_fts'",
      limit: 1,
    );
    if (ftsDefinition.firstOrNull?['sql']?.toString().toLowerCase().contains(
          'fts5',
        ) ==
        true) {
      _ftsRowIdColumn = 'rowid';
    }
    return opened;
  }

  Future<void> _create(Database db, int version) async {
    await db.execute('''
CREATE TABLE provider_accounts (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  api_base_url TEXT NOT NULL,
  web_base_url TEXT NOT NULL,
  label TEXT NOT NULL,
  username TEXT NOT NULL,
  validated_at INTEGER NOT NULL,
  reconnect_required INTEGER NOT NULL DEFAULT 0,
  effective_scopes TEXT
)''');
    await db.execute('''
CREATE TABLE forge_repositories (
  catalog_key TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  host TEXT NOT NULL,
  provider_repository_id TEXT NOT NULL,
  account_id TEXT,
  web_url TEXT NOT NULL,
  api_url TEXT NOT NULL,
  owner TEXT NOT NULL,
  path TEXT NOT NULL,
  name TEXT NOT NULL,
  summary TEXT,
  description TEXT,
  topics TEXT NOT NULL,
  categories TEXT NOT NULL,
  license TEXT,
  is_private INTEGER NOT NULL,
  archived INTEGER NOT NULL,
  is_fork INTEGER NOT NULL,
  apk_availability TEXT NOT NULL,
  device_compatibility TEXT NOT NULL,
  last_activity INTEGER,
  observed_at INTEGER NOT NULL,
  metrics_json TEXT,
  UNIQUE(provider, host, provider_repository_id, account_id)
)''');
    await db.execute('''
CREATE TABLE fdroid_repositories (
  id TEXT PRIMARY KEY,
  canonical_url TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  mirrors TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  signing_certificate TEXT,
  trust_state TEXT NOT NULL,
  enabled INTEGER NOT NULL,
  last_accepted_timestamp INTEGER,
  last_generation TEXT,
  sync_error TEXT
)''');
    await db.execute('''
CREATE TABLE sync_generations (
  repository_id TEXT NOT NULL,
  generation TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  completed_at INTEGER,
  package_count INTEGER NOT NULL DEFAULT 0,
  verified INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(repository_id, generation),
  FOREIGN KEY(repository_id) REFERENCES fdroid_repositories(id) ON DELETE CASCADE
)''');
    await db.execute('''
CREATE TABLE fdroid_packages (
  repository_id TEXT NOT NULL,
  package_name TEXT NOT NULL,
  signer_sha256 TEXT NOT NULL,
  generation TEXT NOT NULL,
  name TEXT NOT NULL,
  summary TEXT,
  description TEXT,
  categories TEXT NOT NULL,
  license TEXT,
  anti_features TEXT NOT NULL,
  source_code_url TEXT,
  issue_tracker_url TEXT,
  icon_url TEXT,
  screenshots TEXT NOT NULL,
  observed_at INTEGER NOT NULL,
  PRIMARY KEY(repository_id, package_name, signer_sha256, generation),
  FOREIGN KEY(repository_id, generation) REFERENCES sync_generations(repository_id, generation) ON DELETE CASCADE
)''');
    await db.execute('''
CREATE TABLE fdroid_versions (
  repository_id TEXT NOT NULL,
  package_name TEXT NOT NULL,
  signer_sha256 TEXT NOT NULL,
  generation TEXT NOT NULL,
  version_code INTEGER NOT NULL,
  version_name TEXT NOT NULL,
  apk_url TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  size INTEGER NOT NULL,
  min_sdk INTEGER,
  max_sdk INTEGER,
  abis TEXT NOT NULL,
  densities TEXT NOT NULL,
  languages TEXT NOT NULL,
  release_channel TEXT NOT NULL,
  added_at INTEGER,
  PRIMARY KEY(repository_id, package_name, version_code, signer_sha256, generation),
  FOREIGN KEY(repository_id, package_name, signer_sha256, generation)
    REFERENCES fdroid_packages(repository_id, package_name, signer_sha256, generation) ON DELETE CASCADE
)''');
    await db.execute('''
CREATE TABLE package_source_links (
  repository_id TEXT NOT NULL,
  package_name TEXT NOT NULL,
  signer_sha256 TEXT NOT NULL,
  forge_catalog_key TEXT NOT NULL,
  source_url TEXT NOT NULL,
  observed_at INTEGER NOT NULL,
  PRIMARY KEY(repository_id, package_name, signer_sha256),
  FOREIGN KEY(forge_catalog_key) REFERENCES forge_repositories(catalog_key) ON DELETE CASCADE
)''');
    await db.execute('''
CREATE TABLE metric_snapshots (
  entity_key TEXT NOT NULL,
  observed_at INTEGER NOT NULL,
  window_days INTEGER NOT NULL,
  sample_size INTEGER NOT NULL,
  exact INTEGER NOT NULL,
  estimated_fields TEXT NOT NULL,
  unavailable_fields TEXT NOT NULL,
  adapter_version INTEGER NOT NULL,
  values_json TEXT NOT NULL,
  PRIMARY KEY(entity_key, observed_at)
)''');
    await db.execute('''
CREATE TABLE release_summaries (
  entity_key TEXT NOT NULL,
  release_id TEXT NOT NULL,
  published_at INTEGER,
  data_json TEXT NOT NULL,
  observed_at INTEGER NOT NULL,
  PRIMARY KEY(entity_key, release_id)
)''');
    await db.execute('''
CREATE TABLE search_pages (
  cache_key TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  host TEXT NOT NULL,
  account_id TEXT NOT NULL,
  query_json TEXT NOT NULL,
  cursor_json TEXT,
  catalog_keys TEXT NOT NULL,
  next_cursor_json TEXT,
  incomplete INTEGER NOT NULL,
  observed_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
)''');
    await db.execute('''
CREATE TABLE catalog_documents (
  docId INTEGER PRIMARY KEY AUTOINCREMENT,
  catalog_key TEXT NOT NULL UNIQUE,
  entity_key TEXT NOT NULL,
  origin_kind TEXT NOT NULL,
  localized_name TEXT NOT NULL,
  summary TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  package_id TEXT NOT NULL DEFAULT '',
  owner_path TEXT NOT NULL DEFAULT '',
  categories TEXT NOT NULL DEFAULT '',
  topics TEXT NOT NULL DEFAULT '',
  license TEXT,
  anti_features TEXT NOT NULL DEFAULT '',
  provider TEXT NOT NULL,
  account_id TEXT,
  host TEXT NOT NULL,
  is_private INTEGER NOT NULL,
  archived INTEGER NOT NULL,
  is_fork INTEGER NOT NULL,
  apk_available INTEGER,
  device_compatible INTEGER,
  stars INTEGER,
  active_contributors_90d INTEGER,
  all_time_contributors INTEGER,
  commits_90d INTEGER,
  releases_365d INTEGER,
  score INTEGER,
  confidence INTEGER,
  response_rate REAL,
  action_rate REAL,
  close_rate REAL,
  days_since_commit INTEGER,
  days_since_release INTEGER,
  first_response_hours REAL,
  last_activity INTEGER,
  observed_at INTEGER NOT NULL
)''');
    try {
      await _createFts4(db);
    } on DatabaseException catch (error) {
      if (!error.toString().contains('no such module: fts4')) rethrow;
      _ftsRowIdColumn = 'rowid';
      await _createFts5(db);
    }
    await db.execute(
      'CREATE INDEX forge_host_account_idx ON forge_repositories(provider, host, account_id)',
    );
    await db.execute(
      'CREATE INDEX fdroid_active_idx ON fdroid_packages(repository_id, generation)',
    );
    await db.execute(
      'CREATE INDEX metrics_entity_time_idx ON metric_snapshots(entity_key, observed_at DESC)',
    );
    await db.execute(
      'CREATE INDEX documents_sort_idx ON catalog_documents(score DESC, stars DESC, last_activity DESC)',
    );
    await _insertFdroidRepository(db, FdroidRepository.official());
  }

  Future<void> _createFts4(Database db) async {
    await db.execute('''
CREATE VIRTUAL TABLE catalog_fts USING fts4(
  localized_name,
  summary,
  description,
  package_id,
  owner_path,
  categories,
  topics,
  content='catalog_documents',
  tokenize=unicode61
)''');
    await db.execute('''
CREATE TRIGGER catalog_documents_ai AFTER INSERT ON catalog_documents BEGIN
  INSERT INTO catalog_fts(docid, localized_name, summary, description, package_id, owner_path, categories, topics)
  VALUES (new.docId, new.localized_name, new.summary, new.description, new.package_id, new.owner_path, new.categories, new.topics);
END''');
    await db.execute('''
CREATE TRIGGER catalog_documents_ad AFTER DELETE ON catalog_documents BEGIN
  DELETE FROM catalog_fts WHERE docid = old.docId;
END''');
    await db.execute('''
CREATE TRIGGER catalog_documents_au AFTER UPDATE ON catalog_documents BEGIN
  DELETE FROM catalog_fts WHERE docid = old.docId;
  INSERT INTO catalog_fts(docid, localized_name, summary, description, package_id, owner_path, categories, topics)
  VALUES (new.docId, new.localized_name, new.summary, new.description, new.package_id, new.owner_path, new.categories, new.topics);
END''');
  }

  Future<void> _createFts5(Database db) async {
    await db.execute('''
CREATE VIRTUAL TABLE catalog_fts USING fts5(
  localized_name,
  summary,
  description,
  package_id,
  owner_path,
  categories,
  topics,
  content='catalog_documents',
  content_rowid='docId',
  tokenize='unicode61'
)''');
    await db.execute('''
CREATE TRIGGER catalog_documents_ai AFTER INSERT ON catalog_documents BEGIN
  INSERT INTO catalog_fts(rowid, localized_name, summary, description, package_id, owner_path, categories, topics)
  VALUES (new.docId, new.localized_name, new.summary, new.description, new.package_id, new.owner_path, new.categories, new.topics);
END''');
    await db.execute('''
CREATE TRIGGER catalog_documents_ad AFTER DELETE ON catalog_documents BEGIN
  INSERT INTO catalog_fts(catalog_fts, rowid, localized_name, summary, description, package_id, owner_path, categories, topics)
  VALUES ('delete', old.docId, old.localized_name, old.summary, old.description, old.package_id, old.owner_path, old.categories, old.topics);
END''');
    await db.execute('''
CREATE TRIGGER catalog_documents_au AFTER UPDATE ON catalog_documents BEGIN
  INSERT INTO catalog_fts(catalog_fts, rowid, localized_name, summary, description, package_id, owner_path, categories, topics)
  VALUES ('delete', old.docId, old.localized_name, old.summary, old.description, old.package_id, old.owner_path, old.categories, old.topics);
  INSERT INTO catalog_fts(rowid, localized_name, summary, description, package_id, owner_path, categories, topics)
  VALUES (new.docId, new.localized_name, new.summary, new.description, new.package_id, new.owner_path, new.categories, new.topics);
END''');
  }

  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async =>
      (await database).transaction(action);

  Future<void> upsertAccount(ProviderAccount account) async {
    await (await database).insert(
      'provider_accounts',
      _accountRow(account),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ProviderAccount>> accounts() async =>
      (await (await database).query(
        'provider_accounts',
        orderBy: 'label COLLATE NOCASE',
      )).map(_accountFromRow).toList();

  Future<void> deleteAccountData(String accountId) async {
    await transaction((txn) async {
      await txn.delete(
        'search_pages',
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      final privateRows = await txn.query(
        'forge_repositories',
        columns: ['catalog_key'],
        where: 'account_id = ? AND is_private = 1',
        whereArgs: [accountId],
      );
      for (final row in privateRows) {
        await txn.delete(
          'catalog_documents',
          where: 'entity_key = ?',
          whereArgs: [row['catalog_key']],
        );
      }
      await txn.delete(
        'forge_repositories',
        where: 'account_id = ? AND is_private = 1',
        whereArgs: [accountId],
      );
      await txn.delete(
        'provider_accounts',
        where: 'id = ?',
        whereArgs: [accountId],
      );
    });
  }

  Future<void> upsertFdroidRepository(FdroidRepository repository) async {
    await _insertFdroidRepository(await database, repository);
  }

  static Future<void> _insertFdroidRepository(
    DatabaseExecutor db,
    FdroidRepository repository,
  ) async {
    final row = _fdroidRepositoryRow(repository);
    final updated = await db.update(
      'fdroid_repositories',
      row,
      where: 'id = ?',
      whereArgs: [repository.id],
    );
    if (updated == 0) {
      await db.insert(
        'fdroid_repositories',
        row,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    }
  }

  Future<List<FdroidRepository>> fdroidRepositories() async =>
      (await (await database).query(
        'fdroid_repositories',
        orderBy: 'label COLLATE NOCASE',
      )).map(_fdroidRepositoryFromRow).toList();

  Future<FdroidRepository?> fdroidRepositoryByUrl(String canonicalUrl) async {
    final rows = await (await database).query(
      'fdroid_repositories',
      where: 'canonical_url = ?',
      whereArgs: [canonicalUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : _fdroidRepositoryFromRow(rows.single);
  }

  Future<List<FdroidPackage>> fdroidPackagesForRepository(
    String repositoryId, {
    String? packageName,
  }) async {
    final db = await database;
    final repositoryRows = await db.query(
      'fdroid_repositories',
      columns: ['last_generation'],
      where: 'id = ?',
      whereArgs: [repositoryId],
      limit: 1,
    );
    final generation =
        repositoryRows.firstOrNull?['last_generation'] as String?;
    if (generation == null) return const [];
    final packages = await db.query(
      'fdroid_packages',
      where: packageName == null
          ? 'repository_id = ? AND generation = ?'
          : 'repository_id = ? AND generation = ? AND package_name = ?',
      whereArgs: packageName == null
          ? [repositoryId, generation]
          : [repositoryId, generation, packageName],
      orderBy: 'name COLLATE NOCASE',
    );
    return Future.wait(
      packages.map((package) async {
        final versions = await db.query(
          'fdroid_versions',
          where:
              'repository_id = ? AND package_name = ? AND signer_sha256 = ? AND generation = ?',
          whereArgs: [
            repositoryId,
            package['package_name'],
            package['signer_sha256'],
            generation,
          ],
          orderBy: 'version_code DESC',
        );
        return _fdroidPackageFromRows(package, versions);
      }),
    );
  }

  Future<void> deleteFdroidRepository(String repositoryId) async {
    if (repositoryId == FdroidRepository.official().id) {
      throw StateError('The official F-Droid repository cannot be removed');
    }
    await (await database).delete(
      'fdroid_repositories',
      where: 'id = ?',
      whereArgs: [repositoryId],
    );
  }

  Future<void> beginFdroidGeneration(
    String repositoryId,
    String generation,
  ) async {
    await (await database).insert('sync_generations', {
      'repository_id': repositoryId,
      'generation': generation,
      'started_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<void> stageFdroidBatch(
    String repositoryId,
    String generation,
    List<FdroidPackage> packages,
  ) async {
    if (packages.length > 100) {
      throw const FormatException(
        'F-Droid batches may contain at most 100 packages',
      );
    }
    await transaction((txn) async {
      final batch = txn.batch();
      for (final package in packages) {
        if (package.repositoryId != repositoryId ||
            package.generation != generation) {
          throw const FormatException('F-Droid package generation mismatch');
        }
        batch.insert(
          'fdroid_packages',
          _fdroidPackageRow(package),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        for (final version in package.versions) {
          batch.insert(
            'fdroid_versions',
            _fdroidVersionRow(version, package.signerSha256, generation),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await batch.commit(noResult: true);
      await txn.rawUpdate(
        'UPDATE sync_generations SET package_count = package_count + ? WHERE repository_id = ? AND generation = ?',
        [packages.length, repositoryId, generation],
      );
    });
  }

  Future<void> publishFdroidGeneration({
    required String repositoryId,
    required String generation,
    required DateTime acceptedTimestamp,
  }) async {
    await transaction((txn) async {
      final repoRows = await txn.query(
        'fdroid_repositories',
        where: 'id = ?',
        whereArgs: [repositoryId],
        limit: 1,
      );
      if (repoRows.isEmpty) throw StateError('Unknown F-Droid repository');
      final previousTimestamp =
          repoRows.single['last_accepted_timestamp'] as int?;
      if (previousTimestamp != null &&
          acceptedTimestamp.millisecondsSinceEpoch < previousTimestamp) {
        throw const FormatException('F-Droid index timestamp replay rejected');
      }
      final generationRows = await txn.query(
        'sync_generations',
        where: 'repository_id = ? AND generation = ?',
        whereArgs: [repositoryId, generation],
        limit: 1,
      );
      if (generationRows.isEmpty) {
        throw StateError('Unknown F-Droid generation');
      }
      await txn.update(
        'sync_generations',
        {
          'completed_at': DateTime.now().toUtc().millisecondsSinceEpoch,
          'verified': 1,
        },
        where: 'repository_id = ? AND generation = ?',
        whereArgs: [repositoryId, generation],
      );
      await txn.update(
        'fdroid_repositories',
        {
          'last_accepted_timestamp': acceptedTimestamp
              .toUtc()
              .millisecondsSinceEpoch,
          'last_generation': generation,
          'sync_error': null,
        },
        where: 'id = ?',
        whereArgs: [repositoryId],
      );
      await _replaceFdroidDocuments(txn, repositoryId, generation);
      await txn.delete(
        'sync_generations',
        where: 'repository_id = ? AND generation <> ?',
        whereArgs: [repositoryId, generation],
      );
    });
  }

  Future<void> abortFdroidGeneration(
    String repositoryId,
    String generation,
    String error,
  ) async {
    await transaction((txn) async {
      await txn.delete(
        'sync_generations',
        where: 'repository_id = ? AND generation = ? AND verified = 0',
        whereArgs: [repositoryId, generation],
      );
      await txn.update(
        'fdroid_repositories',
        {'sync_error': error},
        where: 'id = ?',
        whereArgs: [repositoryId],
      );
    });
  }

  static Future<void> _replaceFdroidDocuments(
    DatabaseExecutor db,
    String repositoryId,
    String generation,
  ) async {
    await db.delete(
      'catalog_documents',
      where: 'origin_kind = ? AND entity_key LIKE ?',
      whereArgs: [
        CatalogOriginKind.fdroidPackage.name,
        'fdroid:$repositoryId:%',
      ],
    );
    final packages = await db.query(
      'fdroid_packages',
      where: 'repository_id = ? AND generation = ?',
      whereArgs: [repositoryId, generation],
    );
    for (final package in packages) {
      final entityKey =
          'fdroid:$repositoryId:${package['package_name']}:${package['signer_sha256']}';
      await db.insert('catalog_documents', {
        'catalog_key': entityKey,
        'entity_key': entityKey,
        'origin_kind': CatalogOriginKind.fdroidPackage.name,
        'localized_name': package['name'],
        'summary': package['summary'] ?? '',
        'description': package['description'] ?? '',
        'package_id': package['package_name'],
        'owner_path': package['package_name'],
        'categories': _searchText(package['categories']),
        'topics': '',
        'license': package['license'],
        'anti_features': _searchText(package['anti_features']),
        'provider': ProviderKind.fdroid.name,
        'host': repositoryId,
        'is_private': 0,
        'archived': 0,
        'is_fork': 0,
        'apk_available': 1,
        'device_compatible': null,
        'observed_at': package['observed_at'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> upsertForgeRepository(ForgeRepository repository) async {
    await transaction((txn) async {
      await txn.insert(
        'forge_repositories',
        _forgeRow(repository),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'catalog_documents',
        _forgeDocument(repository),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (repository.metrics case final metrics?) {
        await _insertMetric(txn, repository.catalogKey, metrics);
      }
      for (final release in repository.releases) {
        await txn.insert('release_summaries', {
          'entity_key': repository.catalogKey,
          'release_id': release.id,
          'published_at': release.publishedAt?.millisecondsSinceEpoch,
          'data_json': jsonEncode(release.toJson()),
          'observed_at': repository.observedAt.millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> saveMetrics(String entityKey, MetricSnapshot snapshot) async {
    await transaction((txn) async {
      await _insertMetric(txn, entityKey, snapshot);
      await txn.update(
        'catalog_documents',
        _metricDocumentColumns(snapshot),
        where: 'entity_key = ?',
        whereArgs: [entityKey],
      );
      await txn.update(
        'forge_repositories',
        {'metrics_json': jsonEncode(snapshot.toJson())},
        where: 'catalog_key = ?',
        whereArgs: [entityKey],
      );
      await txn.update(
        'catalog_documents',
        _metricDocumentColumns(snapshot),
        where:
            "entity_key IN (SELECT 'fdroid:' || repository_id || ':' || package_name || ':' || signer_sha256 FROM package_source_links WHERE forge_catalog_key = ?)",
        whereArgs: [entityKey],
      );
    });
  }

  static Future<void> _insertMetric(
    DatabaseExecutor db,
    String entityKey,
    MetricSnapshot snapshot,
  ) async {
    await db.insert('metric_snapshots', {
      'entity_key': entityKey,
      'observed_at': snapshot.observedAt.millisecondsSinceEpoch,
      'window_days': snapshot.windowDays,
      'sample_size': snapshot.issueSampleSize,
      'exact': snapshot.isEstimated ? 0 : 1,
      'estimated_fields': jsonEncode(snapshot.estimatedFields.toList()),
      'unavailable_fields': jsonEncode(snapshot.unavailableFields.toList()),
      'adapter_version': MetricSnapshot.adapterVersion,
      'values_json': jsonEncode(snapshot.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> linkPackageSource({
    required FdroidPackage package,
    required ForgeRepository repository,
  }) async {
    await (await database).insert('package_source_links', {
      'repository_id': package.repositoryId,
      'package_name': package.packageName,
      'signer_sha256': package.signerSha256,
      'forge_catalog_key': repository.catalogKey,
      'source_url': package.sourceCodeUrl.toString(),
      'observed_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> relinkFdroidSources(
    String repositoryId,
    String generation,
  ) async {
    await transaction((txn) async {
      await txn.delete(
        'package_source_links',
        where: 'repository_id = ?',
        whereArgs: [repositoryId],
      );
      final packages = await txn.query(
        'fdroid_packages',
        where:
            'repository_id = ? AND generation = ? AND source_code_url IS NOT NULL',
        whereArgs: [repositoryId, generation],
      );
      final forgeRows = await txn.query('forge_repositories');
      final forgeByUrl = <String, Map<String, Object?>>{
        for (final row in forgeRows)
          _canonicalSourceUrl(row['web_url']! as String): row,
      };
      for (final package in packages) {
        final sourceUrl = package['source_code_url']! as String;
        final forge = forgeByUrl[_canonicalSourceUrl(sourceUrl)];
        if (forge == null) continue;
        await txn.insert('package_source_links', {
          'repository_id': repositoryId,
          'package_name': package['package_name'],
          'signer_sha256': package['signer_sha256'],
          'forge_catalog_key': forge['catalog_key'],
          'source_url': sourceUrl,
          'observed_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        if (forge['metrics_json'] case final metricsJson?) {
          final metrics = MetricSnapshot.fromJson(
            Map<String, Object?>.from(jsonDecode(metricsJson as String) as Map),
          );
          await txn.update(
            'catalog_documents',
            _metricDocumentColumns(metrics),
            where: 'entity_key = ?',
            whereArgs: [
              'fdroid:$repositoryId:${package['package_name']}:${package['signer_sha256']}',
            ],
          );
        }
      }
    });
  }

  Future<void> saveSearchPage({
    required String cacheKey,
    required ProviderKind provider,
    required String host,
    required String? accountId,
    required CatalogQuery query,
    required List<String> catalogKeys,
    required PageCursor? next,
    required bool incomplete,
    required Duration ttl,
  }) async {
    final now = DateTime.now().toUtc();
    await (await database).insert('search_pages', {
      'cache_key': cacheKey,
      'provider': provider.name,
      'host': canonicalHost(host),
      'account_id': accountId ?? 'public',
      'query_json': jsonEncode({
        'text': query.text,
        'filters': query.filters.toJson(),
        'sort': query.sort.name,
      }),
      'cursor_json': query.cursor == null
          ? null
          : jsonEncode(query.cursor!.toJson()),
      'catalog_keys': jsonEncode(catalogKeys),
      'next_cursor_json': next == null ? null : jsonEncode(next.toJson()),
      'incomplete': incomplete ? 1 : 0,
      'observed_at': now.millisecondsSinceEpoch,
      'expires_at': now.add(ttl).millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<CachedSearchPage?> loadSearchPage(String cacheKey) async {
    final rows = await (await database).query(
      'search_pages',
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return CachedSearchPage(
      cacheKey: cacheKey,
      catalogKeys: List<String>.from(
        jsonDecode(row['catalog_keys']! as String) as List,
      ),
      next: row['next_cursor_json'] == null
          ? null
          : PageCursor.fromJson(
              Map<String, Object?>.from(
                jsonDecode(row['next_cursor_json']! as String) as Map,
              ),
            ),
      incomplete: row['incomplete'] == 1,
      observedAt: DateTime.fromMillisecondsSinceEpoch(
        row['observed_at']! as int,
        isUtc: true,
      ),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        row['expires_at']! as int,
        isUtc: true,
      ),
    );
  }

  Future<List<CatalogEntry>> queryCatalog(
    CatalogQuery query, {
    List<String>? restrictToKeys,
    int offset = 0,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    var from = 'catalog_documents d';
    final terms = query.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (terms.isNotEmpty) {
      from += ' JOIN catalog_fts f ON f.$_ftsRowIdColumn = d.docId';
      where.add('f.catalog_fts MATCH ?');
      args.add(terms.map(_ftsTerm).join(' '));
    }
    final filters = query.filters;
    void inSet(String column, Iterable<String> values) {
      final list = values.toList();
      if (list.isEmpty) return;
      where.add('$column IN (${List.filled(list.length, '?').join(',')})');
      args.addAll(list);
    }

    inSet('d.provider', filters.sources.map((e) => e.name));
    inSet('d.account_id', filters.accountIds);
    if (restrictToKeys != null) inSet('d.catalog_key', restrictToKeys);
    if (restrictToKeys == null) {
      where.add(
        'NOT (d.origin_kind = ? AND EXISTS ('
        'SELECT 1 FROM package_source_links l '
        'WHERE l.forge_catalog_key = d.entity_key))',
      );
      args.add(CatalogOriginKind.forgeRelease.name);
    }
    if (!filters.includeArchived) where.add('d.archived = 0');
    if (!filters.includeForks) where.add('d.is_fork = 0');
    if (filters.isPrivate != null) {
      where.add('d.is_private = ?');
      args.add(filters.isPrivate! ? 1 : 0);
    }
    _nullableBoolFilter(
      where,
      args,
      'd.apk_available',
      filters.apkAvailable,
      filters.includeUnknown,
    );
    _nullableBoolFilter(
      where,
      args,
      'd.device_compatible',
      filters.deviceCompatible,
      filters.includeUnknown,
    );
    _facetFilter(where, args, 'd.categories', filters.categories);
    _facetFilter(where, args, 'd.topics', filters.topics);
    _facetFilter(where, args, 'd.anti_features', filters.antiFeatures);
    _licenseFilter(where, args, 'd.license', filters.licenses);
    _minimum(
      where,
      args,
      'd.stars',
      filters.minimumStars,
      filters.includeUnknown,
    );
    _minimum(
      where,
      args,
      'd.active_contributors_90d',
      filters.minimumActiveContributors90d,
      filters.includeUnknown,
    );
    _minimum(
      where,
      args,
      'd.all_time_contributors',
      filters.minimumAllTimeContributors,
      filters.includeUnknown,
    );
    _minimum(
      where,
      args,
      'd.commits_90d',
      filters.minimumCommits90d,
      filters.includeUnknown,
    );
    _minimum(
      where,
      args,
      'd.releases_365d',
      filters.minimumReleases365d,
      filters.includeUnknown,
    );
    _minimum(
      where,
      args,
      'd.score',
      filters.minimumScore,
      filters.includeUnknown,
    );
    _minimum(
      where,
      args,
      'd.confidence',
      filters.minimumConfidence,
      filters.includeUnknown,
    );
    _minimum(
      where,
      args,
      'd.response_rate',
      filters.minimumResponseRate,
      filters.includeUnknown,
    );
    _minimum(
      where,
      args,
      'd.action_rate',
      filters.minimumActionRate,
      filters.includeUnknown,
    );
    _minimum(
      where,
      args,
      'd.close_rate',
      filters.minimumCloseRate,
      filters.includeUnknown,
    );
    _maximum(
      where,
      args,
      'd.days_since_commit',
      filters.maximumDaysSinceCommit,
      filters.includeUnknown,
    );
    _maximum(
      where,
      args,
      'd.days_since_release',
      filters.maximumDaysSinceRelease,
      filters.includeUnknown,
    );
    _maximum(
      where,
      args,
      'd.first_response_hours',
      filters.maximumFirstResponseHours,
      filters.includeUnknown,
    );

    final orderBy = switch (query.sort) {
      CatalogSort.relevance when terms.isNotEmpty => 'd.docId ASC',
      CatalogSort.emporionScore =>
        'd.score DESC, d.confidence DESC, d.last_activity DESC, d.catalog_key ASC',
      CatalogSort.stars => 'd.stars DESC, d.catalog_key ASC',
      CatalogSort.activity => 'd.last_activity DESC, d.catalog_key ASC',
      CatalogSort.releaseCadence =>
        'd.releases_365d DESC, d.days_since_release ASC, d.catalog_key ASC',
      CatalogSort.activeContributors =>
        'd.active_contributors_90d DESC, d.catalog_key ASC',
      CatalogSort.issueResponse =>
        'd.response_rate DESC, d.first_response_hours ASC, d.catalog_key ASC',
      CatalogSort.name =>
        'd.localized_name COLLATE NOCASE ASC, d.catalog_key ASC',
      _ => 'd.stars DESC, d.last_activity DESC, d.catalog_key ASC',
    };
    final rows = await (await database).rawQuery(
      'SELECT d.* FROM $from${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'} ORDER BY $orderBy LIMIT ? OFFSET ?',
      [...args, query.pageSize, offset],
    );
    final entries = <CatalogEntry>[];
    for (final row in rows) {
      final entry = await _entryFromDocument(row);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  Future<CatalogEntry?> _entryFromDocument(Map<String, Object?> row) async {
    final kind = CatalogOriginKind.values.byName(row['origin_kind']! as String);
    if (kind == CatalogOriginKind.forgeRelease) {
      final forgeRows = await (await database).query(
        'forge_repositories',
        where: 'catalog_key = ?',
        whereArgs: [row['entity_key']],
        limit: 1,
      );
      if (forgeRows.isEmpty) return null;
      final forge = _forgeFromRow(forgeRows.single);
      return CatalogEntry(
        catalogKey: forge.catalogKey,
        originKind: kind,
        name: forge.name,
        summary: forge.summary,
        description: forge.description,
        sourceLabel: forge.provider.name,
        host: forge.host,
        categories: forge.categories,
        topics: forge.topics,
        license: forge.license,
        antiFeatures: const {},
        isPrivate: forge.isPrivate,
        archived: forge.archived,
        fork: forge.fork,
        apkAvailability: forge.apkAvailability,
        deviceCompatibility: forge.deviceCompatibility,
        freshness: _freshness(forge.observedAt),
        observedAt: forge.observedAt,
        forgeRepository: forge,
        metrics: forge.metrics,
        installOrigins: _forgeOrigins(forge),
      );
    }
    final parts = (row['entity_key']! as String).split(':');
    if (parts.length < 4) return null;
    final package = await loadFdroidPackage(
      parts[1],
      parts[2],
      parts.sublist(3).join(':'),
    );
    if (package == null) return null;
    final repo = (await fdroidRepositories())
        .where((e) => e.id == package.repositoryId)
        .firstOrNull;
    final latest = package.versions.isEmpty ? null : package.versions.first;
    final linkRows = await (await database).query(
      'package_source_links',
      where: 'repository_id = ? AND package_name = ? AND signer_sha256 = ?',
      whereArgs: [
        package.repositoryId,
        package.packageName,
        package.signerSha256,
      ],
      limit: 1,
    );
    ForgeRepository? linkedForge;
    if (linkRows.isNotEmpty) {
      final forgeRows = await (await database).query(
        'forge_repositories',
        where: 'catalog_key = ?',
        whereArgs: [linkRows.single['forge_catalog_key']],
        limit: 1,
      );
      if (forgeRows.isNotEmpty) linkedForge = _forgeFromRow(forgeRows.single);
    }
    final fdroidOrigins = <InstallOrigin>[
      if (latest != null && repo != null)
        InstallOrigin(
          kind: CatalogOriginKind.fdroidPackage,
          label: repo.label,
          sourceUrl: Uri.parse(
            '${repo.canonicalUrl}?appId=${Uri.encodeQueryComponent(package.packageName)}',
          ),
          expectedPackageName: package.packageName,
          expectedSha256: latest.sha256,
          expectedSize: latest.size,
          expectedSignerSha256: latest.signerSha256,
          expectedVersionCode: latest.versionCode,
          compatibility: AvailabilityState.unknown,
          trusted: repo.trustState == RepositoryTrustState.trusted,
        ),
      if (linkedForge != null) ..._forgeOrigins(linkedForge),
    ];
    return CatalogEntry(
      catalogKey: package.catalogKey,
      originKind: kind,
      name: package.name,
      summary: package.summary,
      description: package.description,
      sourceLabel: repo?.label ?? 'F-Droid',
      host: repo == null
          ? package.repositoryId
          : Uri.parse(repo.canonicalUrl).host,
      packageName: package.packageName,
      categories: package.categories,
      topics: linkedForge?.topics ?? const {},
      license: package.license,
      antiFeatures: package.antiFeatures,
      isPrivate: false,
      archived: linkedForge?.archived ?? false,
      fork: linkedForge?.fork ?? false,
      apkAvailability: AvailabilityState.available,
      deviceCompatibility: AvailabilityState.unknown,
      freshness: _freshness(package.observedAt),
      observedAt: package.observedAt,
      fdroidPackage: package,
      forgeRepository: linkedForge,
      metrics: linkedForge?.metrics,
      installOrigins: fdroidOrigins,
    );
  }

  Future<FdroidPackage?> loadFdroidPackage(
    String repositoryId,
    String packageName,
    String signerSha256,
  ) async {
    final db = await database;
    final repo = await db.query(
      'fdroid_repositories',
      columns: ['last_generation'],
      where: 'id = ?',
      whereArgs: [repositoryId],
      limit: 1,
    );
    final generation = repo.firstOrNull?['last_generation'] as String?;
    if (generation == null) return null;
    final rows = await db.query(
      'fdroid_packages',
      where:
          'repository_id = ? AND package_name = ? AND signer_sha256 = ? AND generation = ?',
      whereArgs: [repositoryId, packageName, signerSha256, generation],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final versions = await db.query(
      'fdroid_versions',
      where:
          'repository_id = ? AND package_name = ? AND signer_sha256 = ? AND generation = ?',
      whereArgs: [repositoryId, packageName, signerSha256, generation],
      orderBy: 'version_code DESC',
    );
    return _fdroidPackageFromRows(rows.single, versions);
  }

  Future<void> close() async {
    final db = _database;
    _database = null;
    await db?.close();
  }

  static String _ftsTerm(String value) => '"${value.replaceAll('"', '""')}"*';
  static String _searchText(Object? jsonValue) {
    if (jsonValue is! String || jsonValue.isEmpty) return '';
    final decoded = jsonDecode(jsonValue);
    return decoded is List
        ? _facetText(decoded.map((value) => value.toString()))
        : _facetText([decoded.toString()]);
  }

  static String _facetText(Iterable<String> values) =>
      '|${values.map((value) => value.toLowerCase()).join('|')}|';

  static void _nullableBoolFilter(
    List<String> where,
    List<Object?> args,
    String column,
    bool? value,
    bool includeUnknown,
  ) {
    if (value == null) return;
    where.add(
      includeUnknown ? '($column = ? OR $column IS NULL)' : '$column = ?',
    );
    args.add(value ? 1 : 0);
  }

  static void _facetFilter(
    List<String> where,
    List<Object?> args,
    String column,
    Set<String> values,
  ) {
    if (values.isEmpty) return;
    where.add(
      '(${List.filled(values.length, 'INSTR(LOWER($column), ?) > 0').join(' OR ')})',
    );
    args.addAll(values.map((value) => '|${value.toLowerCase()}|'));
  }

  static void _licenseFilter(
    List<String> where,
    List<Object?> args,
    String column,
    Set<String> values,
  ) {
    if (values.isEmpty) return;
    where.add(
      'LOWER($column) IN (${List.filled(values.length, '?').join(',')})',
    );
    args.addAll(values.map((value) => value.toLowerCase()));
  }

  static void _minimum(
    List<String> where,
    List<Object?> args,
    String column,
    num? value,
    bool includeUnknown,
  ) {
    if (value == null) return;
    where.add(
      includeUnknown ? '($column >= ? OR $column IS NULL)' : '$column >= ?',
    );
    args.add(value);
  }

  static void _maximum(
    List<String> where,
    List<Object?> args,
    String column,
    num? value,
    bool includeUnknown,
  ) {
    if (value == null) return;
    where.add(
      includeUnknown ? '($column <= ? OR $column IS NULL)' : '$column <= ?',
    );
    args.add(value);
  }

  static String _canonicalSourceUrl(String value) {
    final uri = Uri.parse(value);
    var path = uri.path.replaceFirst(RegExp(r'/$'), '');
    if (path.toLowerCase().endsWith('.git')) {
      path = path.substring(0, path.length - 4);
    }
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          query: null,
          fragment: null,
          path: path,
        )
        .toString();
  }

  static Map<String, Object?> _accountRow(ProviderAccount account) => {
    'id': account.id,
    'provider': account.provider.name,
    'api_base_url': account.apiBaseUrl,
    'web_base_url': account.webBaseUrl,
    'label': account.label,
    'username': account.username,
    'validated_at': account.validatedAt.millisecondsSinceEpoch,
    'reconnect_required': account.reconnectRequired ? 1 : 0,
    'effective_scopes': account.effectiveScopes,
  };

  static ProviderAccount _accountFromRow(Map<String, Object?> row) =>
      ProviderAccount(
        id: row['id']! as String,
        provider: ProviderKind.values.byName(row['provider']! as String),
        apiBaseUrl: row['api_base_url']! as String,
        webBaseUrl: row['web_base_url']! as String,
        label: row['label']! as String,
        username: row['username']! as String,
        validatedAt: DateTime.fromMillisecondsSinceEpoch(
          row['validated_at']! as int,
          isUtc: true,
        ),
        reconnectRequired: row['reconnect_required'] == 1,
        effectiveScopes: row['effective_scopes'] as String?,
      );

  static Map<String, Object?> _fdroidRepositoryRow(
    FdroidRepository repository,
  ) => {
    'id': repository.id,
    'canonical_url': repository.canonicalUrl,
    'label': repository.label,
    'mirrors': jsonEncode(repository.mirrors),
    'fingerprint': repository.fingerprint,
    'signing_certificate': repository.signingCertificate,
    'trust_state': repository.trustState.name,
    'enabled': repository.enabled ? 1 : 0,
    'last_accepted_timestamp':
        repository.lastAcceptedTimestamp?.millisecondsSinceEpoch,
    'last_generation': repository.lastGeneration,
    'sync_error': repository.syncError,
  };

  static FdroidRepository _fdroidRepositoryFromRow(Map<String, Object?> row) =>
      FdroidRepository(
        id: row['id']! as String,
        canonicalUrl: row['canonical_url']! as String,
        label: row['label']! as String,
        mirrors: List<String>.from(
          jsonDecode(row['mirrors']! as String) as List,
        ),
        fingerprint: row['fingerprint']! as String,
        signingCertificate: row['signing_certificate'] as String?,
        trustState: RepositoryTrustState.values.byName(
          row['trust_state']! as String,
        ),
        enabled: row['enabled'] == 1,
        lastAcceptedTimestamp: row['last_accepted_timestamp'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                row['last_accepted_timestamp']! as int,
                isUtc: true,
              ),
        lastGeneration: row['last_generation'] as String?,
        syncError: row['sync_error'] as String?,
      );

  static Map<String, Object?> _forgeRow(ForgeRepository repository) => {
    'catalog_key': repository.catalogKey,
    'provider': repository.provider.name,
    'host': repository.host,
    'provider_repository_id': repository.providerRepositoryId,
    'account_id': repository.accountId,
    'web_url': repository.webUrl.toString(),
    'api_url': repository.apiUrl.toString(),
    'owner': repository.owner,
    'path': repository.path,
    'name': repository.name,
    'summary': repository.summary,
    'description': repository.description,
    'topics': jsonEncode(repository.topics.toList()),
    'categories': jsonEncode(repository.categories.toList()),
    'license': repository.license,
    'is_private': repository.isPrivate ? 1 : 0,
    'archived': repository.archived ? 1 : 0,
    'is_fork': repository.fork ? 1 : 0,
    'apk_availability': repository.apkAvailability.name,
    'device_compatibility': repository.deviceCompatibility.name,
    'last_activity': repository.lastActivity?.millisecondsSinceEpoch,
    'observed_at': repository.observedAt.millisecondsSinceEpoch,
    'metrics_json': repository.metrics == null
        ? null
        : jsonEncode(repository.metrics!.toJson()),
  };

  static ForgeRepository _forgeFromRow(Map<String, Object?> row) =>
      ForgeRepository(
        catalogKey: row['catalog_key']! as String,
        provider: ProviderKind.values.byName(row['provider']! as String),
        host: row['host']! as String,
        providerRepositoryId: row['provider_repository_id']! as String,
        accountId: row['account_id'] as String?,
        webUrl: Uri.parse(row['web_url']! as String),
        apiUrl: Uri.parse(row['api_url']! as String),
        owner: row['owner']! as String,
        path: row['path']! as String,
        name: row['name']! as String,
        summary: row['summary'] as String?,
        description: row['description'] as String?,
        topics: Set<String>.from(jsonDecode(row['topics']! as String) as List),
        categories: Set<String>.from(
          jsonDecode(row['categories']! as String) as List,
        ),
        license: row['license'] as String?,
        isPrivate: row['is_private'] == 1,
        archived: row['archived'] == 1,
        fork: row['is_fork'] == 1,
        apkAvailability: AvailabilityState.values.byName(
          row['apk_availability']! as String,
        ),
        deviceCompatibility: AvailabilityState.values.byName(
          row['device_compatibility']! as String,
        ),
        lastActivity: row['last_activity'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                row['last_activity']! as int,
                isUtc: true,
              ),
        observedAt: DateTime.fromMillisecondsSinceEpoch(
          row['observed_at']! as int,
          isUtc: true,
        ),
        metrics: row['metrics_json'] == null
            ? null
            : MetricSnapshot.fromJson(
                Map<String, Object?>.from(
                  jsonDecode(row['metrics_json']! as String) as Map,
                ),
              ),
      );

  static Map<String, Object?> _forgeDocument(ForgeRepository repository) => {
    'catalog_key': repository.catalogKey,
    'entity_key': repository.catalogKey,
    'origin_kind': CatalogOriginKind.forgeRelease.name,
    'localized_name': repository.name,
    'summary': repository.summary ?? '',
    'description': repository.description ?? '',
    'package_id': '',
    'owner_path': repository.path,
    'categories': _facetText(repository.categories),
    'topics': _facetText(repository.topics),
    'license': repository.license,
    'anti_features': '',
    'provider': repository.provider.name,
    'account_id': repository.accountId,
    'host': repository.host,
    'is_private': repository.isPrivate ? 1 : 0,
    'archived': repository.archived ? 1 : 0,
    'is_fork': repository.fork ? 1 : 0,
    'apk_available': _availabilityBool(repository.apkAvailability),
    'device_compatible': _availabilityBool(repository.deviceCompatibility),
    'last_activity': repository.lastActivity?.millisecondsSinceEpoch,
    'observed_at': repository.observedAt.millisecondsSinceEpoch,
    ...?repository.metrics == null
        ? null
        : _metricDocumentColumns(repository.metrics!),
  };

  static Map<String, Object?> _metricDocumentColumns(MetricSnapshot metrics) =>
      {
        'stars': metrics.stars,
        'active_contributors_90d': metrics.activeContributors90d,
        'all_time_contributors': metrics.allTimeContributors,
        'commits_90d': metrics.commits90d,
        'releases_365d': metrics.releases365d,
        'score': metrics.score,
        'confidence': metrics.confidence,
        'response_rate': metrics.responseRate,
        'action_rate': metrics.actionRate,
        'close_rate': metrics.closeRate,
        'days_since_commit': metrics.daysSinceCommit,
        'days_since_release': metrics.daysSinceRelease,
        'first_response_hours': metrics.medianFirstResponseHours,
      };

  static int? _availabilityBool(AvailabilityState value) => switch (value) {
    AvailabilityState.available => 1,
    AvailabilityState.unavailable => 0,
    AvailabilityState.unknown => null,
  };

  static FreshnessState _freshness(DateTime observedAt) {
    final age = DateTime.now().toUtc().difference(observedAt.toUtc());
    if (age <= const Duration(hours: 6)) return FreshnessState.fresh;
    if (age <= const Duration(days: 7)) return FreshnessState.stale;
    return FreshnessState.expired;
  }

  static List<InstallOrigin> _forgeOrigins(ForgeRepository repository) {
    for (final release in repository.releases) {
      final assets = release.assets.where((asset) => asset.isInstallable);
      if (assets.isEmpty) continue;
      return assets
          .map(
            (asset) => InstallOrigin(
              kind: CatalogOriginKind.forgeRelease,
              label: asset.name,
              sourceUrl: repository.webUrl,
              accountId: repository.accountId,
              expectedSha256: asset.sha256,
              expectedSize: asset.size,
              expectedSignerSha256: asset.signerSha256,
              compatibility: AvailabilityState.unknown,
              trusted: false,
            ),
          )
          .toList();
    }
    return const [];
  }

  static Map<String, Object?> _fdroidPackageRow(FdroidPackage package) => {
    'repository_id': package.repositoryId,
    'package_name': package.packageName,
    'signer_sha256': package.signerSha256,
    'generation': package.generation,
    'name': package.name,
    'summary': package.summary,
    'description': package.description,
    'categories': jsonEncode(package.categories.toList()),
    'license': package.license,
    'anti_features': jsonEncode(package.antiFeatures.toList()),
    'source_code_url': package.sourceCodeUrl?.toString(),
    'issue_tracker_url': package.issueTrackerUrl?.toString(),
    'icon_url': package.iconUrl?.toString(),
    'screenshots': jsonEncode(
      package.screenshots.map((e) => e.toString()).toList(),
    ),
    'observed_at': package.observedAt.millisecondsSinceEpoch,
  };

  static Map<String, Object?> _fdroidVersionRow(
    FdroidVersion version,
    String signerSha256,
    String generation,
  ) => {
    'repository_id': version.repositoryId,
    'package_name': version.packageName,
    'signer_sha256': signerSha256,
    'generation': generation,
    'version_code': version.versionCode,
    'version_name': version.versionName,
    'apk_url': version.apkUrl.toString(),
    'sha256': version.sha256,
    'size': version.size,
    'min_sdk': version.minSdk,
    'max_sdk': version.maxSdk,
    'abis': jsonEncode(version.abis.toList()),
    'densities': jsonEncode(version.densities.toList()),
    'languages': jsonEncode(version.languages.toList()),
    'release_channel': version.releaseChannel,
    'added_at': version.addedAt?.millisecondsSinceEpoch,
  };

  static FdroidPackage _fdroidPackageFromRows(
    Map<String, Object?> row,
    List<Map<String, Object?>> versionRows,
  ) => FdroidPackage(
    repositoryId: row['repository_id']! as String,
    packageName: row['package_name']! as String,
    signerSha256: row['signer_sha256']! as String,
    name: row['name']! as String,
    summary: row['summary'] as String?,
    description: row['description'] as String?,
    categories: Set<String>.from(
      jsonDecode(row['categories']! as String) as List,
    ),
    license: row['license'] as String?,
    antiFeatures: Set<String>.from(
      jsonDecode(row['anti_features']! as String) as List,
    ),
    sourceCodeUrl: row['source_code_url'] == null
        ? null
        : Uri.parse(row['source_code_url']! as String),
    issueTrackerUrl: row['issue_tracker_url'] == null
        ? null
        : Uri.parse(row['issue_tracker_url']! as String),
    iconUrl: row['icon_url'] == null
        ? null
        : Uri.parse(row['icon_url']! as String),
    screenshots: (jsonDecode(row['screenshots']! as String) as List)
        .map((e) => Uri.parse(e.toString()))
        .toList(),
    versions: versionRows
        .map(
          (version) => FdroidVersion(
            repositoryId: version['repository_id']! as String,
            packageName: version['package_name']! as String,
            versionName: version['version_name']! as String,
            versionCode: version['version_code']! as int,
            apkUrl: Uri.parse(version['apk_url']! as String),
            sha256: version['sha256']! as String,
            size: version['size']! as int,
            signerSha256: version['signer_sha256']! as String,
            minSdk: version['min_sdk'] as int?,
            maxSdk: version['max_sdk'] as int?,
            abis: Set<String>.from(
              jsonDecode(version['abis']! as String) as List,
            ),
            densities: Set<String>.from(
              jsonDecode(version['densities']! as String) as List,
            ),
            languages: Set<String>.from(
              jsonDecode(version['languages']! as String) as List,
            ),
            releaseChannel: version['release_channel']! as String,
            addedAt: version['added_at'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    version['added_at']! as int,
                    isUtc: true,
                  ),
          ),
        )
        .toList(),
    observedAt: DateTime.fromMillisecondsSinceEpoch(
      row['observed_at']! as int,
      isUtc: true,
    ),
    generation: row['generation']! as String,
  );
}
