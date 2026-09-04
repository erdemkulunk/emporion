import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/providers/apps_provider_import_export.dart';
import 'package:obtainium/providers/source_provider.dart';

void main() {
  test('v1 list migrates subscriptions and installed inventory', () {
    final app = _app(installedVersion: '1.0');

    final schema = ExportSchema.fromAny([app.toJson()]);

    expect(schema.schemaVersion, 1);
    expect(schema.product, portableExportProduct);
    expect(schema.apps.single['id'], app.id);
    expect(schema.installedInventory.single, containsPair('packageId', app.id));
    expect(schema.installedInventory.single['subscription'], isNotNull);
  });

  test('v2 strips credential and nonportable settings during migration', () {
    final schema = ExportSchema.fromAny({
      'schemaVersion': 2,
      'exportedAt': '2026-01-01T00:00:00Z',
      'appVersion': '2.0.0',
      'apps': [_app().toJson()],
      'settings': {
        'theme': 2,
        'github-creds': 'plaintext-secret',
        'exportDir': 'content://device-specific',
        'emporionPendingInstall': '{"package":"bad"}',
      },
    });

    expect(schema.settings, {'theme': 2});
    expect(schema.toJson().toString(), isNot(contains('plaintext-secret')));
    expect(schema.toJson().toString(), isNot(contains('content://')));
  });

  test('v3 emits the exact portable top-level contract', () {
    final schema = ExportSchema(
      schemaVersion: 3,
      product: portableExportProduct,
      exportedAt: '2026-01-01T00:00:00Z',
      appVersion: '3.0.0',
      apps: [_app().toJson()],
      installedInventory: const [],
      settings: const {'theme': 1},
      accounts: const [
        {
          'id': 'account',
          'provider': 'github',
          'apiBaseUrl': 'https://api.github.com',
          'webBaseUrl': 'https://github.com',
          'label': 'GitHub',
          'username': 'tester',
          'validatedAt': '2026-01-01T00:00:00Z',
        },
      ],
      fdroidRepositories: const [],
      catalogPreferences: const {'sort': 'emporionScore'},
    );

    expect(schema.toJson().keys.toSet(), {
      'schemaVersion',
      'product',
      'exportedAt',
      'appVersion',
      'apps',
      'installedInventory',
      'settings',
      'accounts',
      'fdroidRepositories',
      'catalogPreferences',
    });
    final parsed = ExportSchema.fromAny(schema.toJson());
    expect(parsed.product, portableExportProduct);
    expect(parsed.catalogPreferences['sort'], 'emporionScore');
  });

  test('v3 rejects foreign products and future versions', () {
    expect(
      () => ExportSchema.fromAny({'schemaVersion': 3, 'product': 'other'}),
      throwsFormatException,
    );
    expect(
      () => ExportSchema.fromAny({
        'schemaVersion': currentExportSchemaVersion + 1,
        'product': portableExportProduct,
      }),
      throwsFormatException,
    );
  });

  test('v3 keeps only canonical HTTPS repository mirrors', () {
    final schema = ExportSchema.fromAny({
      'schemaVersion': 3,
      'product': portableExportProduct,
      'apps': <dynamic>[],
      'installedInventory': <dynamic>[],
      'settings': <String, dynamic>{},
      'accounts': <dynamic>[],
      'fdroidRepositories': [
        {
          'id': 'fdroid-official',
          'canonicalUrl': 'https://f-droid.org/repo',
          'fingerprint': FdroidRepository.officialFingerprint,
          'mirrors': [
            'https://MIRROR.EXAMPLE/fdroid/repo/',
            'http://example.onion/fdroid/repo',
            'not a URL',
          ],
        },
      ],
      'catalogPreferences': <String, dynamic>{},
    });

    expect(schema.fdroidRepositories.single['mirrors'], [
      'https://mirror.example/fdroid/repo',
    ]);
    expect(
      schema.toJson()['fdroidRepositories'].toString(),
      isNot(contains('http://')),
    );
  });

  test('v3 account descriptors omit credentials and require reconnect', () {
    const secret = 'EMPORION_ACCOUNT_SECRET_QA';
    final schema = ExportSchema.fromAny({
      'schemaVersion': 3,
      'product': portableExportProduct,
      'apps': <dynamic>[],
      'installedInventory': <dynamic>[],
      'settings': <String, dynamic>{},
      'accounts': [
        {
          'id': 'fixture-account',
          'provider': 'github',
          'apiBaseUrl': 'https://api.github.com',
          'webBaseUrl': 'https://github.com',
          'label': 'Fixture account',
          'username': 'tester',
          'validatedAt': '2026-01-01T00:00:00Z',
          'token': secret,
        },
      ],
      'fdroidRepositories': <dynamic>[],
      'catalogPreferences': <String, dynamic>{},
    });

    expect(jsonEncode(schema.toJson()), isNot(contains(secret)));
    expect(schema.accounts.single, isNot(containsPair('token', secret)));
    final restored = restorePortableAccount(schema.accounts.single);
    expect(restored.reconnectRequired, isTrue);
    expect(restored.username, 'tester');
  });

  test(
    'import conflict staging detects only changed existing subscriptions',
    () {
      final current = _app();
      final same = App.fromJson(current.toJson());
      final changed = current.copyWith(latestVersion: '2.0');
      final newApp = _app(id: 'org.example.new');

      expect(
        findImportConflicts({current.id: current}, [same, changed, newApp]),
        {current.id},
      );
    },
  );

  test('restored F-Droid trust never silently accepts third-party keys', () {
    final restored = _repository(
      id: 'third-party',
      fingerprint:
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );

    final firstRestore = resolveRestoredFdroidRepository(restored);
    expect(firstRestore.trustState, RepositoryTrustState.pendingConfirmation);
    expect(firstRestore.enabled, isFalse);

    final configured = restored.copyWith(
      fingerprint:
          'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      trustState: RepositoryTrustState.trusted,
      enabled: true,
    );
    final mismatch = resolveRestoredFdroidRepository(
      restored,
      existing: configured,
    );
    expect(mismatch.fingerprint, configured.fingerprint);
    expect(mismatch.trustState, RepositoryTrustState.fingerprintChanged);
    expect(mismatch.enabled, isFalse);

    final official = resolveRestoredFdroidRepository(
      FdroidRepository.official(),
    );
    expect(official.trustState, RepositoryTrustState.trusted);
    expect(official.enabled, isTrue);
  });

  test('v3 strips app headers credentials and signed URL secrets', () {
    const secret = 'EMPORION_SECRET_QA_7f9b';
    final app = _app().toJson()
      ..['url'] =
          'https://user:$secret@example.org/app?access_token=$secret&channel=stable'
      ..['apkUrls'] = jsonEncode([
        ['app.apk', 'https://example.org/app.apk?token=$secret'],
      ])
      ..['additionalSettings'] = jsonEncode({
        'requestHeader': [
          {'requestHeader': 'User-Agent: Emporion test'},
          {'requestHeader': 'Authorization: Bearer $secret'},
        ],
        'accessToken': secret,
        'releaseChannel': 'stable',
      });
    final raw = {
      'schemaVersion': 3,
      'product': portableExportProduct,
      'exportedAt': '2026-01-01T00:00:00Z',
      'appVersion': '3.0.0',
      'apps': [app],
      'installedInventory': <dynamic>[],
      'settings': <String, dynamic>{},
      'accounts': <dynamic>[],
      'fdroidRepositories': <dynamic>[],
      'catalogPreferences': <String, dynamic>{},
    };

    final exported = jsonEncode(ExportSchema.fromAny(raw).toJson());

    expect(exported, isNot(contains(secret)));
    expect(exported, contains('User-Agent: Emporion test'));
    expect(exported, contains('channel=stable'));
    expect(exported, isNot(contains('access_token')));
    expect(exported, isNot(contains('Authorization')));
  });
}

App _app({String id = 'org.example.app', String? installedVersion}) => App(
  id: id,
  url: 'https://github.com/example/app',
  author: 'Example',
  name: 'Example',
  installedVersion: installedVersion,
  latestVersion: '1.0',
  preferredApkIndex: 0,
  additionalSettings: const {},
);

FdroidRepository _repository({
  required String id,
  required String fingerprint,
}) => FdroidRepository(
  id: id,
  canonicalUrl: 'https://repo.example/fdroid',
  label: 'Example',
  mirrors: const [],
  fingerprint: fingerprint,
  trustState: RepositoryTrustState.trusted,
  enabled: true,
);
