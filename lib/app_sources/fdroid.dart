import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/catalog/fdroid/verified_fdroid_catalog_source.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

class FDroid extends AppSource {
  static const repositoryUrl = 'https://f-droid.org/repo';

  @override
  String get name => tr('fdroid');

  FDroid() {
    hosts = ['f-droid.org'];
    naiveStandardVersionDetection = true;
    canSearch = true;
    inferAppIdFromUrlPath = true;
  }

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
    [
      GeneratedFormTextField(
        'filterVersionsByRegEx',
        label: tr('filterVersionsByRegEx'),
        required: false,
        additionalValidators: [regExValidator],
      ),
    ],
    [
      GeneratedFormSwitch(
        'trySelectingSuggestedVersionCode',
        label: tr('trySelectingSuggestedVersionCode'),
        value: true,
      ),
    ],
    [
      GeneratedFormSwitch(
        'autoSelectHighestVersionCode',
        label: tr('autoSelectHighestVersionCode'),
      ),
    ],
  ];

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    final uri = Uri.parse(url);
    final packageIndex = uri.pathSegments.indexOf('packages');
    if (packageIndex < 0 || packageIndex + 1 >= uri.pathSegments.length) {
      throw InvalidURLError(name);
    }
    final packageName = uri.pathSegments[packageIndex + 1];
    if (packageName.isEmpty) throw InvalidURLError(name);
    return 'https://f-droid.org/packages/$packageName';
  }

  Future<List<FdroidVersion>> _compatible(List<FdroidVersion> versions) async {
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

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final packageName = Uri.parse(standardUrl).pathSegments.last;
      final variants = await VerifiedFdroidCatalogSource.instance.packagesFor(
        repositoryUrl: repositoryUrl,
        packageName: packageName,
        locale: 'en-US',
      );
      if (variants.isEmpty) throw NoReleasesError();
      final expectedSigner =
          additionalSettings['fdroidSignerSha256'] as String?;
      if (variants.length > 1 && expectedSigner == null) {
        throw ObtainiumError(
          'Multiple signing variants exist for this package. Select a trusted signer in Explore.',
        );
      }
      final package = expectedSigner == null
          ? variants.first
          : variants
                .where((item) => item.signerSha256 == expectedSigner)
                .firstOrNull;
      if (package == null) throw NoReleasesError();
      var versions = [...package.versions]
        ..sort((a, b) => b.versionCode.compareTo(a.versionCode));
      final pattern = additionalSettings['filterVersionsByRegEx'] as String?;
      if (pattern != null && pattern.isNotEmpty) {
        final expression = RegExp(pattern);
        versions = versions
            .where((version) => expression.hasMatch(version.versionName))
            .toList();
      }
      if (additionalSettings['trySelectingSuggestedVersionCode'] == true) {
        final stable = versions
            .where(
              (version) => version.releaseChannel.toLowerCase() == 'stable',
            )
            .toList();
        if (stable.isNotEmpty) versions = stable;
      }
      if (versions.isEmpty) throw NoReleasesError();
      List<FdroidVersion> selected;
      if (additionalSettings['autoSelectHighestVersionCode'] == true) {
        selected = [versions.first];
      } else {
        selected = versions
            .where(
              (version) => version.versionName == versions.first.versionName,
            )
            .toList();
      }
      selected = await _compatible(selected);
      if (selected.isEmpty) throw NoReleasesError();
      return APKDetails(
        selected.first.versionName,
        getApkUrlsFromUrls(
          selected.map((version) => version.apkUrl.toString()).toList(),
        ),
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

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    final packages = await VerifiedFdroidCatalogSource.instance.packagesFor(
      repositoryUrl: repositoryUrl,
      locale: 'en-US',
    );
    final normalized = query.trim().toLowerCase();
    final results = <String, List<String>>{};
    for (final package in packages) {
      if (normalized.isNotEmpty &&
          !package.packageName.toLowerCase().contains(normalized) &&
          !package.name.toLowerCase().contains(normalized) &&
          !(package.summary?.toLowerCase().contains(normalized) ?? false)) {
        continue;
      }
      results.putIfAbsent(
        'https://f-droid.org/packages/${package.packageName}',
        () => [package.name, package.summary ?? tr('noDescription')],
      );
    }
    return results;
  }
}
