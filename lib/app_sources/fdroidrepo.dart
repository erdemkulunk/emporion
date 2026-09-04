import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/catalog/fdroid/verified_fdroid_catalog_source.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

class FDroidRepo extends AppSource {
  @override
  String get name => tr('fdroidThirdPartyRepo');

  FDroidRepo() {
    canSearch = true;
    includeAdditionalOptsInMainSearch = true;
    neverAutoSelect = true;
    showReleaseDateAsVersionToggle = true;
  }

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
    [
      GeneratedFormTextField(
        'appIdOrName',
        label: tr('appIdOrName'),
        hint: tr('reposHaveMultipleApps'),
        required: true,
      ),
    ],
    [
      GeneratedFormSwitch(
        'pickHighestVersionCode',
        label: tr('pickHighestVersionCode'),
        value: false,
      ),
    ],
    [
      GeneratedFormSwitch(
        'trySelectingSuggestedVersionCode',
        label: tr('trySelectingSuggestedVersionCode'),
        value: true,
      ),
    ],
  ];

  String _withoutQuery(String url) {
    final uri = Uri.parse(url);
    return uri
        .replace(query: null, fragment: null)
        .toString()
        .replaceFirst(RegExp(r'/$'), '');
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    var uri = Uri.parse(url);
    final segments = [...uri.pathSegments];
    if (segments.isNotEmpty &&
        const {
          'index.xml',
          'index-v1.jar',
          'index-v2.json',
          'entry.jar',
        }.contains(segments.last)) {
      segments.removeLast();
      uri = uri.replace(pathSegments: segments);
    }
    final appId = uri.queryParameters['appId'];
    return uri
        .replace(
          queryParameters: appId == null ? null : {'appId': appId},
          fragment: null,
        )
        .toString()
        .replaceFirst(RegExp(r'\?$'), '');
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    final url = querySettings['url'] as String?;
    if (url == null) throw NoReleasesError();
    final packages = await VerifiedFdroidCatalogSource.instance.packagesFor(
      repositoryUrl: _withoutQuery(standardizeUrl(url)),
      locale: 'en-US',
    );
    final normalized = query.trim().toLowerCase();
    final grouped = <String, List<FdroidPackage>>{};
    for (final package in packages) {
      if (normalized.isNotEmpty &&
          !package.packageName.toLowerCase().contains(normalized) &&
          !package.name.toLowerCase().contains(normalized) &&
          !(package.summary?.toLowerCase().contains(normalized) ?? false)) {
        continue;
      }
      grouped.putIfAbsent(package.packageName, () => []).add(package);
    }
    return {
      for (final entry in grouped.entries)
        '${_withoutQuery(url)}?appId=${Uri.encodeQueryComponent(entry.key)}': [
          entry.value.first.name,
          [
            entry.value.first.summary ?? '',
            if (entry.value.length > 1)
              '${entry.value.length} signing variants',
          ].where((value) => value.isNotEmpty).join(' · '),
        ],
    };
  }

  @override
  Map<String, dynamic> runOnAddAppInputChange(String inputUrl) {
    try {
      final appId = Uri.parse(inputUrl).queryParameters['appId'];
      if (appId != null) return {'appIdOrName': appId};
    } catch (error) {
      AppLogger.info('Failed to parse F-Droid app ID: $error');
    }
    return {};
  }

  @override
  App postProcessApp(App app) {
    final uri = Uri.parse(app.url);
    String? appId;
    if (!isTempId(app)) {
      appId = app.id;
    } else {
      appId = uri.queryParameters['appId'];
    }
    if (appId == null) return app;
    return app.copyWith(
      id: appId,
      url: uri
          .replace(queryParameters: {...uri.queryParameters, 'appId': appId})
          .toString(),
      additionalSettings: {...app.additionalSettings, 'appIdOrName': appId},
    );
  }

  Future<List<FdroidVersion>> _filterVersionsByArch(
    List<FdroidVersion> versions,
  ) async {
    if (versions.length <= 1 ||
        versions.every((version) => version.abis.isEmpty)) {
      return versions;
    }
    final abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
    final compatible = versions
        .where(
          (version) => version.abis.isEmpty || version.abis.any(abis.contains),
        )
        .toList();
    return compatible.isEmpty ? versions : compatible;
  }

  FdroidPackage? _findPackage(List<FdroidPackage> packages, String value) {
    final expectedSigner = packages
        .where((package) => package.signerSha256 == value)
        .firstOrNull;
    if (expectedSigner != null) return expectedSigner;
    final exactId = packages
        .where((package) => package.packageName == value)
        .toList();
    if (exactId.isNotEmpty) return exactId.first;
    final normalized = value.toLowerCase();
    return packages
            .where((package) => package.name.toLowerCase() == normalized)
            .firstOrNull ??
        packages
            .where((package) => package.name.toLowerCase().contains(normalized))
            .firstOrNull;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final uri = Uri.parse(standardUrl);
      final appIdOrName =
          uri.queryParameters['appId'] ??
          additionalSettings['appIdOrName'] as String?;
      if (appIdOrName == null || appIdOrName.isEmpty) throw NoReleasesError();
      additionalSettings['appIdOrName'] = appIdOrName;
      final packages = await VerifiedFdroidCatalogSource.instance.packagesFor(
        repositoryUrl: _withoutQuery(standardUrl),
        packageName: uri.queryParameters['appId'],
        locale: 'en-US',
      );
      final matches = packages
          .where((package) => package.packageName == appIdOrName)
          .toList();
      final expectedSigner =
          additionalSettings['fdroidSignerSha256'] as String?;
      if (matches.length > 1 && expectedSigner == null) {
        throw ObtainiumError(
          'Multiple signing variants exist for this package. Select a trusted signer in Explore.',
        );
      }
      final package = expectedSigner == null
          ? _findPackage(packages, appIdOrName)
          : matches
                .where((item) => item.signerSha256 == expectedSigner)
                .firstOrNull;
      if (package == null) throw ObtainiumError(tr('appWithIdOrNameNotFound'));
      var releases = [...package.versions]
        ..sort((a, b) => b.versionCode.compareTo(a.versionCode));
      if (releases.isEmpty) throw NoReleasesError();
      if (additionalSettings['trySelectingSuggestedVersionCode'] == true) {
        final stable = releases
            .where(
              (version) => version.releaseChannel.toLowerCase() == 'stable',
            )
            .toList();
        if (stable.isNotEmpty) releases = stable;
      }
      List<FdroidVersion> selected;
      if (additionalSettings['pickHighestVersionCode'] == true) {
        selected = [releases.first];
      } else {
        selected = releases
            .where(
              (version) => version.versionName == releases.first.versionName,
            )
            .toList();
      }
      selected = await _filterVersionsByArch(selected);
      if (selected.isEmpty) throw NoReleasesError();
      final urls = selected
          .map((version) => version.apkUrl.toString())
          .toList();
      final useVersionCode =
          additionalSettings['useVersionCodeAsOSVersion'] == true;
      return APKDetails(
        useVersionCode
            ? selected.first.versionCode.toString()
            : selected.first.versionName,
        getApkUrlsFromUrls(urls),
        AppNames(name, package.name),
        releaseDate: selected.first.addedAt,
        sha256ByUrl: {
          for (final version in selected)
            version.apkUrl.toString(): version.sha256,
        },
        sizeByUrl: {
          for (final version in selected)
            version.apkUrl.toString(): version.size,
        },
        signerByUrl: {
          for (final version in selected)
            version.apkUrl.toString(): version.signerSha256,
        },
        versionCodeByUrl: {
          for (final version in selected)
            version.apkUrl.toString(): version.versionCode,
        },
      );
    } catch (error) {
      rethrowOrWrapError(error);
    }
  }
}
