import 'dart:math';

import 'package:flutter/services.dart';
import 'package:obtainium/catalog/data/catalog_database.dart';
import 'package:obtainium/catalog/models.dart';

class FdroidSyncResult {
  final FdroidRepository repository;
  final int packageCount;
  final String format;

  const FdroidSyncResult({
    required this.repository,
    required this.packageCount,
    required this.format,
  });
}

class VerifiedFdroidCatalogSource {
  static const MethodChannel _channel = MethodChannel(
    'dev.erdem.emporion/fdroid_index',
  );
  static VerifiedFdroidCatalogSource? _instance;

  static VerifiedFdroidCatalogSource get instance =>
      _instance ??
      (throw StateError('Verified F-Droid catalog source is not initialized'));

  final CatalogDatabase database;
  final Random _random;
  String? _activeRepositoryId;
  String? _activeGeneration;
  int _packageCount = 0;

  VerifiedFdroidCatalogSource({required this.database, Random? random})
    : _random = random ?? Random.secure() {
    _channel.setMethodCallHandler(_handleNativeCall);
    _instance = this;
  }

  Future<List<FdroidPackage>> packagesFor({
    required String repositoryUrl,
    String? packageName,
    required String locale,
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final input = Uri.parse(repositoryUrl);
    final canonical = input
        .replace(
          query: null,
          fragment: null,
          path: input.path.replaceFirst(RegExp(r'/$'), ''),
        )
        .toString();
    final repository = await database.fdroidRepositoryByUrl(canonical);
    if (repository == null) {
      throw StateError(
        'Add and verify this F-Droid repository before using its packages',
      );
    }
    var cached = await database.fdroidPackagesForRepository(
      repository.id,
      packageName: packageName,
    );
    final stale =
        repository.lastAcceptedTimestamp == null ||
        DateTime.now()
                .toUtc()
                .difference(repository.lastAcceptedTimestamp!)
                .abs() >
            maxAge;
    if (stale) {
      try {
        await sync(repository, locale: locale);
        cached = await database.fdroidPackagesForRepository(
          repository.id,
          packageName: packageName,
        );
      } catch (_) {
        if (cached.isEmpty) rethrow;
      }
    }
    return cached;
  }

  Future<FdroidSyncResult> sync(
    FdroidRepository repository, {
    required String locale,
  }) async {
    if (!repository.enabled) throw StateError('F-Droid repository is disabled');
    if (repository.trustState != RepositoryTrustState.trusted) {
      throw StateError('F-Droid repository fingerprint is not trusted');
    }
    if (_activeRepositoryId != null) {
      throw StateError('An F-Droid sync is already in progress');
    }
    final generation = _newGeneration();
    _activeRepositoryId = repository.id;
    _activeGeneration = generation;
    _packageCount = 0;
    await database.beginFdroidGeneration(repository.id, generation);
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('sync', {
        'repositoryId': repository.id,
        'repositoryUrl': repository.canonicalUrl,
        'fingerprint': repository.fingerprint,
        'locale': locale,
        'generation': generation,
        'lastTimestamp':
            repository.lastAcceptedTimestamp?.millisecondsSinceEpoch ?? 0,
        // Runtime syncs use full indexes so publication remains one atomic
        // generation. The native bridge separately supports verified diffs.
        'allowDiff': false,
      });
      if (result == null) {
        throw StateError('F-Droid verifier returned no result');
      }
      final fingerprint = (result['fingerprint'] as String).toUpperCase();
      if (_normalizeFingerprint(fingerprint) !=
          _normalizeFingerprint(repository.fingerprint)) {
        throw const FdroidFingerprintChangedException();
      }
      final timestamp = result['timestamp']! as int;
      final acceptedAt = DateTime.fromMillisecondsSinceEpoch(
        timestamp,
        isUtc: true,
      );
      if (repository.lastAcceptedTimestamp != null &&
          acceptedAt.isBefore(repository.lastAcceptedTimestamp!)) {
        throw StateError('F-Droid index replay rejected');
      }
      final repositoryData = (result['repository'] as Map?)
          ?.cast<Object?, Object?>();
      final mirrors =
          (repositoryData?['mirrors'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          repository.mirrors;
      final label = repositoryData?['name']?.toString().trim();
      final updated = repository.copyWith(
        label: label == null || label.isEmpty ? repository.label : label,
        mirrors: mirrors,
        signingCertificate: result['certificate'] as String?,
        trustState: RepositoryTrustState.trusted,
        enabled: true,
        lastAcceptedTimestamp: acceptedAt,
        lastGeneration: generation,
        clearSyncError: true,
      );
      await database.upsertFdroidRepository(updated);
      await database.publishFdroidGeneration(
        repositoryId: repository.id,
        generation: generation,
        acceptedTimestamp: acceptedAt,
      );
      await database.relinkFdroidSources(repository.id, generation);
      return FdroidSyncResult(
        repository: updated,
        packageCount: _packageCount,
        format: result['format']! as String,
      );
    } catch (error) {
      final changed =
          error is FdroidFingerprintChangedException ||
          error.toString().toLowerCase().contains('fingerprint') ||
          error.toString().toLowerCase().contains('signing certificate');
      await database.abortFdroidGeneration(
        repository.id,
        generation,
        error.toString(),
      );
      if (changed) {
        await database.upsertFdroidRepository(
          repository.copyWith(
            trustState: RepositoryTrustState.fingerprintChanged,
            enabled: false,
            syncError:
                'Signing fingerprint changed. Compare and confirm it before syncing again.',
          ),
        );
      }
      rethrow;
    } finally {
      _activeRepositoryId = null;
      _activeGeneration = null;
      _packageCount = 0;
    }
  }

  Future<List<FdroidSyncResult>> syncEnabled({required String locale}) async {
    final results = <FdroidSyncResult>[];
    for (final repository in await database.fdroidRepositories()) {
      if (!repository.enabled ||
          repository.trustState != RepositoryTrustState.trusted) {
        continue;
      }
      results.add(await sync(repository, locale: locale));
    }
    return results;
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    final arguments = (call.arguments as Map).cast<Object?, Object?>();
    if (arguments['repositoryId'] != _activeRepositoryId ||
        arguments['generation'] != _activeGeneration) {
      throw StateError('Rejected an unexpected F-Droid bridge batch');
    }
    switch (call.method) {
      case 'fdroidBatch':
        final rawPackages = arguments['packages']! as List;
        if (rawPackages.length > 100) {
          throw const FormatException(
            'F-Droid bridge batches may contain at most 100 packages',
          );
        }
        final packages = rawPackages
            .map(
              (raw) => _packageFromMap((raw as Map).cast<Object?, Object?>()),
            )
            .toList();
        await database.stageFdroidBatch(
          _activeRepositoryId!,
          _activeGeneration!,
          packages,
        );
        _packageCount += packages.length;
        return null;
      case 'fdroidDiffBatch':
        throw UnsupportedError(
          'Runtime F-Droid publication requires a complete generation',
        );
      default:
        throw MissingPluginException(
          'Unknown F-Droid bridge callback ${call.method}',
        );
    }
  }

  FdroidPackage _packageFromMap(Map<Object?, Object?> map) {
    final versions = (map['versions']! as List)
        .map((raw) => _versionFromMap((raw as Map).cast<Object?, Object?>()))
        .where((version) => version.apkUrl.path.toLowerCase().endsWith('.apk'))
        .toList();
    return FdroidPackage(
      repositoryId: map['repositoryId']! as String,
      packageName: map['packageName']! as String,
      signerSha256: map['signerSha256']! as String,
      name: map['name']! as String,
      summary: map['summary'] as String?,
      description: map['description'] as String?,
      categories: Set<String>.from(map['categories'] as List? ?? const []),
      license: map['license'] as String?,
      antiFeatures: Set<String>.from(map['antiFeatures'] as List? ?? const []),
      sourceCodeUrl: _optionalUri(map['sourceCodeUrl']),
      issueTrackerUrl: _optionalUri(map['issueTrackerUrl']),
      iconUrl: _optionalUri(map['iconUrl']),
      screenshots: (map['screenshots'] as List? ?? const [])
          .map((value) => Uri.parse(value as String))
          .toList(),
      versions: versions,
      observedAt: DateTime.fromMillisecondsSinceEpoch(
        map['observedAt']! as int,
        isUtc: true,
      ),
      generation: map['generation']! as String,
    );
  }

  FdroidVersion _versionFromMap(Map<Object?, Object?> map) => FdroidVersion(
    repositoryId: map['repositoryId']! as String,
    packageName: map['packageName']! as String,
    versionName: map['versionName']! as String,
    versionCode: (map['versionCode']! as num).toInt(),
    apkUrl: Uri.parse(map['apkUrl']! as String),
    sha256: map['sha256']! as String,
    size: (map['size']! as num).toInt(),
    signerSha256: map['signerSha256']! as String,
    minSdk: (map['minSdk'] as num?)?.toInt(),
    maxSdk: (map['maxSdk'] as num?)?.toInt(),
    abis: Set<String>.from(map['abis'] as List? ?? const []),
    densities: Set<String>.from(map['densities'] as List? ?? const []),
    languages: Set<String>.from(map['languages'] as List? ?? const []),
    releaseChannel: map['releaseChannel'] as String? ?? 'stable',
    addedAt: map['addedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (map['addedAt']! as num).toInt(),
            isUtc: true,
          ),
  );

  Uri? _optionalUri(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    return uri != null && uri.hasScheme ? uri : null;
  }

  String _newGeneration() {
    final random = List<int>.generate(16, (_) => _random.nextInt(256));
    final suffix = random
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${DateTime.now().toUtc().microsecondsSinceEpoch}-$suffix';
  }

  String _normalizeFingerprint(String value) =>
      value.replaceAll(RegExp('[^0-9A-Fa-f]'), '').toUpperCase();
}

class FdroidFingerprintChangedException implements Exception {
  const FdroidFingerprintChangedException();

  @override
  String toString() => 'F-Droid signing fingerprint changed';
}
