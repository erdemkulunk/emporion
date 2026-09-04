import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:obtainium/catalog/data/catalog_database.dart';
import 'package:obtainium/catalog/fdroid/verified_fdroid_catalog_source.dart';
import 'package:obtainium/catalog/models.dart';

class FdroidRepositoryCandidate {
  final String canonicalUrl;
  final String fingerprint;
  final bool fingerprintFromLink;

  const FdroidRepositoryCandidate({
    required this.canonicalUrl,
    required this.fingerprint,
    required this.fingerprintFromLink,
  });
}

class FdroidRepositoryService {
  final CatalogDatabase database;
  final VerifiedFdroidCatalogSource source;
  final void Function()? onConfigurationChanged;

  const FdroidRepositoryService({
    required this.database,
    required this.source,
    this.onConfigurationChanged,
  });

  FdroidRepositoryCandidate parseCandidate(
    String input, {
    String? enteredFingerprint,
  }) {
    final raw = Uri.parse(input.trim());
    final scheme = raw.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'fdroidrepos') {
      throw const FormatException('F-Droid repositories must use HTTPS');
    }
    final linkFingerprint = raw.queryParameters['fingerprint'];
    final fingerprint = normalizeFingerprint(
      linkFingerprint ?? enteredFingerprint ?? '',
    );
    if (fingerprint.length != 64) {
      throw const FormatException(
        'A full SHA-256 signing fingerprint is required',
      );
    }
    final path = raw.path.endsWith('/')
        ? raw.path.substring(0, raw.path.length - 1)
        : raw.path;
    final canonical = Uri(
      scheme: 'https',
      host: raw.host.toLowerCase(),
      port: raw.hasPort && raw.port != 443 ? raw.port : null,
      path: path.isEmpty ? '/repo' : path,
    );
    if (canonical.host.isEmpty || canonical.userInfo.isNotEmpty) {
      throw const FormatException('Invalid F-Droid repository URL');
    }
    return FdroidRepositoryCandidate(
      canonicalUrl: canonical.toString(),
      fingerprint: fingerprint,
      fingerprintFromLink: linkFingerprint != null,
    );
  }

  Future<FdroidRepository> add({
    required String input,
    required String label,
    String? enteredFingerprint,
    required bool explicitlyConfirmed,
  }) async {
    final candidate = parseCandidate(
      input,
      enteredFingerprint: enteredFingerprint,
    );
    if (!candidate.fingerprintFromLink && !explicitlyConfirmed) {
      throw StateError(
        'Compare and confirm the signing fingerprint before first sync',
      );
    }
    final repositories = await database.fdroidRepositories();
    final existing = repositories
        .where((repo) => repo.canonicalUrl == candidate.canonicalUrl)
        .firstOrNull;
    if (existing != null &&
        normalizeFingerprint(existing.fingerprint) != candidate.fingerprint) {
      final changed = existing.copyWith(
        fingerprint: candidate.fingerprint,
        trustState: RepositoryTrustState.fingerprintChanged,
        enabled: false,
        syncError:
            'Signing fingerprint changed. Confirm it separately before syncing.',
      );
      await database.upsertFdroidRepository(changed);
      onConfigurationChanged?.call();
      return changed;
    }
    final id =
        existing?.id ??
        'fdroid-${sha256.convert(utf8.encode(candidate.canonicalUrl)).toString().substring(0, 16)}';
    final repository = FdroidRepository(
      id: id,
      canonicalUrl: candidate.canonicalUrl,
      label: label.trim().isEmpty ? candidate.canonicalUrl : label.trim(),
      mirrors: existing?.mirrors ?? const [],
      fingerprint: candidate.fingerprint,
      signingCertificate: existing?.signingCertificate,
      trustState: RepositoryTrustState.trusted,
      enabled: true,
      lastAcceptedTimestamp: existing?.lastAcceptedTimestamp,
      lastGeneration: existing?.lastGeneration,
    );
    await database.upsertFdroidRepository(repository);
    onConfigurationChanged?.call();
    return repository;
  }

  Future<FdroidRepository> confirmChangedFingerprint(
    FdroidRepository repository, {
    required String comparedFingerprint,
  }) async {
    final compared = normalizeFingerprint(comparedFingerprint);
    if (compared != normalizeFingerprint(repository.fingerprint)) {
      throw const FormatException(
        'Compared fingerprint does not match the repository fingerprint',
      );
    }
    final confirmed = repository.copyWith(
      trustState: RepositoryTrustState.trusted,
      enabled: true,
      clearSyncError: true,
    );
    await database.upsertFdroidRepository(confirmed);
    onConfigurationChanged?.call();
    return confirmed;
  }

  Future<void> setEnabled(FdroidRepository repository, bool enabled) async {
    if (enabled && repository.trustState != RepositoryTrustState.trusted) {
      throw StateError('Confirm the repository fingerprint before enabling it');
    }
    await database.upsertFdroidRepository(
      repository.copyWith(enabled: enabled),
    );
    onConfigurationChanged?.call();
  }

  Future<void> remove(FdroidRepository repository) async {
    await database.deleteFdroidRepository(repository.id);
    onConfigurationChanged?.call();
  }

  Future<FdroidSyncResult> sync(
    FdroidRepository repository, {
    required String locale,
  }) => source.sync(repository, locale: locale);

  static String normalizeFingerprint(String value) =>
      value.replaceAll(RegExp('[^0-9A-Fa-f]'), '').toUpperCase();
}
