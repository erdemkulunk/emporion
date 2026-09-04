import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider_install.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';

void main() {
  group('downloaded artifact verification', () {
    test('accepts exact size SHA-256 and APK magic', () async {
      final directory = await Directory.systemTemp.createTemp(
        'emporion-artifact',
      );
      addTearDown(() => directory.delete(recursive: true));
      final bytes = <int>[0x50, 0x4b, 0x03, 0x04, 1, 2, 3, 4];
      final file = File('${directory.path}/fixture.apk')
        ..writeAsBytesSync(bytes);
      final app = _app(
        expectedSize: bytes.length,
        expectedSha256: sha256.convert(bytes).toString(),
        catalogSubscription: true,
      );

      await verifyDownloadedArtifact(app, file);

      expect(file.existsSync(), isTrue);
    });

    test('deletes size and hash mismatches before install', () async {
      final directory = await Directory.systemTemp.createTemp(
        'emporion-artifact',
      );
      addTearDown(() async {
        if (directory.existsSync()) await directory.delete(recursive: true);
      });
      final sizeMismatch = File('${directory.path}/size.apk')
        ..writeAsBytesSync([0x50, 0x4b, 0x03, 0x04]);
      await expectLater(
        verifyDownloadedArtifact(_app(expectedSize: 99), sizeMismatch),
        throwsA(isA<ObtainiumError>()),
      );
      expect(sizeMismatch.existsSync(), isFalse);

      final hashMismatch = File('${directory.path}/hash.apk')
        ..writeAsBytesSync([0x50, 0x4b, 0x03, 0x04]);
      await expectLater(
        verifyDownloadedArtifact(
          _app(expectedSha256: List.filled(32, '00').join()),
          hashMismatch,
        ),
        throwsA(isA<ObtainiumError>()),
      );
      expect(hashMismatch.existsSync(), isFalse);
    });

    test('catalog subscriptions reject non-APK container magic', () async {
      final directory = await Directory.systemTemp.createTemp(
        'emporion-artifact',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/payload.tar')
        ..writeAsBytesSync([1, 2, 3, 4]);

      await expectLater(
        verifyDownloadedArtifact(_app(catalogSubscription: true), file),
        throwsA(isA<ObtainiumError>()),
      );
      expect(file.existsSync(), isFalse);
    });
  });

  group('package and signing metadata validation', () {
    const signerA =
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    const signerB =
        'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
    const base = ParsedArtifactMetadata(
      packageName: 'org.example.app',
      versionCode: 42,
      currentSigners: {signerA},
      signingLineage: {signerA},
    );

    test('accepts exact package version signer lineage and splits', () {
      validateArtifactMetadata(
        _app(
          expectedVersionCode: 42,
          expectedSignerSha256: signerA.toLowerCase(),
        ),
        base,
        installed: const ParsedArtifactMetadata(
          packageName: 'org.example.app',
          versionCode: 41,
          currentSigners: {signerA},
          signingLineage: {signerA},
        ),
        splits: const [
          ParsedArtifactMetadata(
            packageName: 'org.example.app',
            versionCode: 42,
            currentSigners: {signerA},
            signingLineage: {signerA},
          ),
        ],
      );
    });

    for (final fixture
        in <
          ({
            String name,
            App app,
            ParsedArtifactMetadata base,
            ParsedArtifactMetadata? installed,
            List<ParsedArtifactMetadata> splits,
          })
        >[
          (
            name: 'package mismatch',
            app: _app(),
            base: const ParsedArtifactMetadata(
              packageName: 'org.attacker.app',
              versionCode: 42,
              currentSigners: {signerA},
              signingLineage: {signerA},
            ),
            installed: null,
            splits: const [],
          ),
          (
            name: 'expected version mismatch',
            app: _app(expectedVersionCode: 43),
            base: base,
            installed: null,
            splits: const [],
          ),
          (
            name: 'catalog signer mismatch',
            app: _app(expectedSignerSha256: signerB),
            base: base,
            installed: null,
            splits: const [],
          ),
          (
            name: 'installed lineage mismatch',
            app: _app(),
            base: base,
            installed: const ParsedArtifactMetadata(
              packageName: 'org.example.app',
              versionCode: 41,
              currentSigners: {signerB},
              signingLineage: {signerB},
            ),
            splits: const [],
          ),
          (
            name: 'split package mismatch',
            app: _app(),
            base: base,
            installed: null,
            splits: const [
              ParsedArtifactMetadata(
                packageName: 'org.other.app',
                versionCode: 42,
                currentSigners: {signerA},
                signingLineage: {signerA},
              ),
            ],
          ),
          (
            name: 'split version mismatch',
            app: _app(),
            base: base,
            installed: null,
            splits: const [
              ParsedArtifactMetadata(
                packageName: 'org.example.app',
                versionCode: 99,
                currentSigners: {signerA},
                signingLineage: {signerA},
              ),
            ],
          ),
          (
            name: 'split signer mismatch',
            app: _app(),
            base: base,
            installed: null,
            splits: const [
              ParsedArtifactMetadata(
                packageName: 'org.example.app',
                versionCode: 42,
                currentSigners: {signerB},
                signingLineage: {signerB},
              ),
            ],
          ),
        ]) {
      test('rejects ${fixture.name}', () {
        expect(
          () => validateArtifactMetadata(
            fixture.app,
            fixture.base,
            installed: fixture.installed,
            splits: fixture.splits,
          ),
          throwsA(isA<ObtainiumError>()),
        );
      });
    }
  });

  test('split selection keeps only current ABI density and locale', () {
    expect(isLikelySplitApkName('base.apk'), isFalse);
    expect(isLikelySplitApkName('split_config.arm64_v8a.apk'), isTrue);
    expect(
      isCompatibleSplitApkName(
        'split_config.arm64_v8a.apk',
        supportedAbis: {'arm64-v8a'},
        locale: 'en',
        density: 'xxhdpi',
      ),
      isTrue,
    );
    expect(
      isCompatibleSplitApkName(
        'split_config.x86.apk',
        supportedAbis: {'arm64-v8a'},
        locale: 'en',
        density: 'xxhdpi',
      ),
      isFalse,
    );
    expect(
      isCompatibleSplitApkName(
        'split_config.fr.apk',
        supportedAbis: {'arm64-v8a'},
        locale: 'en',
        density: 'xxhdpi',
      ),
      isFalse,
    );
    expect(
      isCompatibleSplitApkName(
        'split_config.xxhdpi.apk',
        supportedAbis: {'arm64-v8a'},
        locale: 'en',
        density: 'xxhdpi',
      ),
      isTrue,
    );
  });

  test('archive paths reject traversal absolute drive and NUL paths', () {
    expect(safeArchivePathSegments('splits/base.apk'), ['splits', 'base.apk']);
    expect(safeArchivePathSegments(r'splits\base.apk'), ['splits', 'base.apk']);
    for (final value in [
      '../base.apk',
      'splits/../../base.apk',
      '/absolute/base.apk',
      r'C:\absolute\base.apk',
      'bad\u0000name.apk',
    ]) {
      expect(() => safeArchivePathSegments(value), throwsFormatException);
    }
  });

  test('pseudo hash changes are not treated as downgrades', () {
    const app = App(
      id: 'org.example.pseudo',
      url: 'https://example.org/app.apk',
      author: 'Example',
      name: 'Example',
      installedVersion: '2910589c',
      latestVersion: 'e32c6835',
      preferredApkIndex: 0,
      additionalSettings: {
        'versionDetection': false,
        'defaultPseudoVersioningMethod': 'partialAPKHash',
      },
    );

    expect(isAppUpdateable(app, SettingsProvider()), isTrue);
  });
}

App _app({
  int? expectedSize,
  String? expectedSha256,
  String? expectedSignerSha256,
  int? expectedVersionCode,
  bool catalogSubscription = false,
}) => App(
  id: 'org.example.app',
  url: 'https://example.org/app',
  author: 'Example',
  name: 'Example',
  latestVersion: '42',
  preferredApkIndex: 0,
  additionalSettings: {
    if (catalogSubscription) 'emporionCatalogSubscription': true,
  },
  expectedSize: expectedSize,
  expectedSha256: expectedSha256,
  expectedSignerSha256: expectedSignerSha256,
  expectedVersionCode: expectedVersionCode,
);
