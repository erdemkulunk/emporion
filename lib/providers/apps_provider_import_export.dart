import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_package_manager/android_package_manager.dart';
import 'package:crypto/crypto.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_storage/shared_storage.dart' as saf;

import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

const int currentExportSchemaVersion = 3;
const String portableExportProduct = 'emporion';
const String kPackageVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.0.0',
);

/// Preferences that are meaningful on another device. Credentials, filesystem
/// locations, installer components, pending work, export controls and warning
/// acknowledgements are deliberately absent.
const Set<String> portableSettingKeys = {
  'useSystemFont',
  'theme',
  'themeColor',
  'colourSchemeMode',
  'useBlackTheme',
  'updateInterval',
  'updateIntervalSliderVal',
  'checkOnStart',
  'sortColumn',
  'sortOrder',
  'showAppWebpage',
  'pinUpdates',
  'buryNonInstalled',
  'groupBy',
  'categories',
  'forcedLocale',
  'hideDowngrades',
  'tactileFeedbackEnabled',
  'includePrereleasesByDefault',
  'removeOnExternalUninstall',
  'checkUpdateOnDetailPage',
  'enableBackgroundUpdates',
  'enableCertificatePinning',
  'bgUpdatesOnWiFiOnly',
  'bgUpdatesWhileChargingOnly',
  'highlightTouchTargets',
  'disableSwipeActions',
  'alwaysUsePhoneLayout',
  'globalApkFilterRegEx',
  'onlyCheckInstalledOrTrackOnlyApps',
  'collapseGroupsOnStartup',
  'skipBulkUpdateConfirmation',
  'minimumUpdateAgeDays',
  'parallelDownloads',
  'searchDeselected',
  'actionBannerMode',
  'beforeNewInstallsShareToAppVerifier',
};

class PortableImportPlan {
  final ExportSchema schema;
  final List<App> apps;
  final Set<String> conflictingAppIds;

  const PortableImportPlan({
    required this.schema,
    required this.apps,
    required this.conflictingAppIds,
  });

  bool get hasSettings => schema.settings.isNotEmpty;
}

/// Import/export of portable Emporion configuration for [AppsProvider].
extension AppsProviderImportExport on AppsProvider {
  Future<Map<String, dynamic>> generateExportJSON({
    List<String>? appIds,
    int? overrideExportSettings,
  }) async {
    final appList = apps.values
        .where((entry) => appIds == null || appIds.contains(entry.app.id))
        .where(
          (entry) =>
              !settingsProvider.exportInstalledOnly ||
              entry.app.installedVersion != null,
        )
        .map((entry) => entry.app.toJson())
        .toList();
    final exportSettings =
        overrideExportSettings ?? settingsProvider.exportSettings;
    final settings = exportSettings > 0 ? _portableSettings() : null;
    final accounts = await catalogDatabase.accounts();
    final repositories = await catalogDatabase.fdroidRepositories();
    final query = catalogProvider?.query;
    final schema = ExportSchema(
      schemaVersion: currentExportSchemaVersion,
      product: portableExportProduct,
      exportedAt: DateTime.now().toUtc().toIso8601String(),
      appVersion: kPackageVersion,
      apps: appList,
      installedInventory: await _installedInventory(appIds: appIds),
      settings: settings ?? const <String, dynamic>{},
      accounts: accounts.map(_portableAccount).toList(),
      fdroidRepositories: repositories.map(_portableRepository).toList(),
      catalogPreferences: query == null
          ? const <String, dynamic>{}
          : <String, dynamic>{
              'sort': query.sort.name,
              'filters': query.filters.toJson(),
              'pageSize': query.pageSize,
            },
    );
    return schema.toJson();
  }

  Map<String, dynamic> _portableSettings() {
    final prefs = settingsProvider.prefs;
    return {
      for (final key in portableSettingKeys)
        if (prefs?.containsKey(key) ?? false) key: prefs!.get(key),
    };
  }

  Future<List<Map<String, dynamic>>> _installedInventory({
    List<String>? appIds,
  }) async {
    List<PackageInfo> installed;
    try {
      installed = await getAllInstalledInfo();
    } catch (_) {
      installed = apps.values
          .map((entry) => entry.installedInfo)
          .whereType<PackageInfo>()
          .toList();
    }
    final trackedById = {
      for (final entry in apps.values) entry.app.id: entry.app,
    };
    final result = <Map<String, dynamic>>[];
    for (final info in installed) {
      final packageName = info.packageName;
      if (packageName == null || packageName.isEmpty) continue;
      if (appIds != null && !appIds.contains(packageName)) continue;
      // ApplicationInfo.FLAG_SYSTEM. Updated system apps remain OS-managed and
      // are intentionally excluded from a portable user-app inventory.
      if (((info.applicationInfo?.flags ?? 0) & 1) != 0) continue;
      final tracked = trackedById[packageName];
      String? label;
      try {
        label = await info.applicationInfo?.getAppLabel();
      } catch (_) {}
      result.add({
        'packageId': packageName,
        'name': label ?? tracked?.finalName ?? packageName,
        'versionName': info.versionName,
        'versionCode': info.longVersionCode ?? info.versionCode,
        'signersSha256': _packageSignerDigests(info),
        'subscription': tracked == null
            ? null
            : {
                'url': tracked.url,
                'overrideSource': tracked.overrideSource,
                'catalogSubscription':
                    tracked.additionalSettings['emporionCatalogSubscription'] ==
                    true,
              },
        'unresolved': tracked == null,
      });
    }
    result.sort(
      (a, b) => (a['packageId'] as String).compareTo(b['packageId'] as String),
    );
    return result;
  }

  Future<String?> export({
    bool pickOnly = false,
    isAuto = false,
    SettingsProvider? sp,
  }) async {
    if (!isAuto && !pickOnly) {
      await writePortableBackup();
    }
    final settings = sp ?? settingsProvider;
    final customName = settings.autoExportFileName;
    final hasCustomName = customName != null && customName.isNotEmpty;
    var exportDir = await settings.getExportDir();
    if (isAuto) {
      if (!settings.autoExportOnChanges || exportDir == null) return null;
      final files = await saf
          .listFiles(exportDir, columns: [saf.DocumentFileColumn.id])
          .where((file) {
            final name = file.uri.pathSegments.last;
            return name.endsWith('-auto.json') ||
                (hasCustomName && name == '$customName.json');
          })
          .toList();
      for (final file in files) {
        await saf.delete(file.uri);
      }
    }
    if (exportDir == null || pickOnly) {
      await settings.pickExportDir();
      exportDir = await settings.getExportDir();
    }
    if (exportDir == null) return null;
    String? returnPath;
    if (!pickOnly) {
      const encoder = JsonEncoder.withIndent('    ');
      final finalExport = await generateExportJSON();
      final displayName = (isAuto && hasCustomName)
          ? '$customName.json'
          : '${tr('obtainiumExportHyphenatedLowercase')}-${DateTime.now().toIso8601String().replaceAll(':', '-')}${isAuto ? '-auto' : ''}.json';
      final result = await saf.createFile(
        exportDir,
        displayName: displayName,
        mimeType: 'application/json',
        bytes: Uint8List.fromList(utf8.encode(encoder.convert(finalExport))),
      );
      if (result == null) throw ObtainiumError(tr('unexpectedError'));
      returnPath = exportDir.pathSegments
          .join('/')
          .replaceFirst('tree/primary:', '/');
    }
    return returnPath;
  }

  /// Creates or replaces the private, Android-backed portable snapshot. This
  /// file is the only application-data file admitted by Android backup rules.
  Future<void> writePortableBackup() async {
    final filesDirectory = await getApplicationSupportDirectory();
    final directory = Directory('${filesDirectory.path}/backup');
    await directory.create(recursive: true);
    final target = File('${directory.path}/emporion.json');
    final temporary = File('${target.path}.tmp');
    const encoder = JsonEncoder.withIndent('  ');
    await temporary.writeAsString(
      encoder.convert(await generateExportJSON()),
      flush: true,
    );
    await temporary.rename(target.path);
  }

  PortableImportPlan prepareImport(String appsJSON) {
    dynamic decoded;
    try {
      decoded = jsonDecode(appsJSON);
    } catch (error) {
      throw ObtainiumError('${tr('failedToImport')}: $error');
    }
    try {
      final schema = ExportSchema.fromAny(decoded);
      final importedApps = schema.apps.map(App.fromJson).toList();
      final conflicts = findImportConflicts({
        for (final entry in apps.entries) entry.key: entry.value.app,
      }, importedApps);
      return PortableImportPlan(
        schema: schema,
        apps: importedApps,
        conflictingAppIds: conflicts,
      );
    } catch (error) {
      throw ObtainiumError('${tr('failedToImport')}: $error');
    }
  }

  Future<MapEntry<List<App>, bool>> applyImport(
    PortableImportPlan plan, {
    required bool overwriteConflicts,
  }) async {
    await waitForAppsToLoad();
    final selected = plan.apps
        .where(
          (app) =>
              overwriteConflicts || !plan.conflictingAppIds.contains(app.id),
        )
        .toList();
    for (var index = 0; index < selected.length; index++) {
      final app = selected[index];
      final installedInfo = await getInstalledInfo(app.id);
      selected[index] = app.copyWith(
        installedVersion: app.settings.getBool('useVersionCodeAsOSVersion')
            ? installedInfo?.versionCode.toString()
            : installedInfo?.versionName,
      );
    }

    // All input is parsed and conflicts are resolved before this apply phase.
    // No provider refresh, artifact download, or install is triggered here.
    await saveApps(selected, onlyIfExists: false);
    await _applyPortableSettings(plan.schema.settings);
    await _restoreCatalogConfiguration(plan.schema);
    final preferences = plan.schema.catalogPreferences;
    if (preferences.isNotEmpty && catalogProvider != null) {
      catalogProvider!.restorePreferences(
        sort: _enumByName(
          CatalogSort.values,
          preferences['sort'],
          CatalogSort.relevance,
        ),
        filters: _filtersFromJson(preferences['filters']),
        pageSize: _boundedInt(preferences['pageSize'], 10, 100, 30),
      );
    }
    await writePortableBackup();
    return MapEntry(selected, plan.hasSettings);
  }

  Future<MapEntry<List<App>, bool>> import(String appsJSON) async {
    final plan = prepareImport(appsJSON);
    return applyImport(plan, overwriteConflicts: false);
  }

  Future<void> _applyPortableSettings(Map<String, dynamic> imported) async {
    final prefs = settingsProvider.prefs;
    if (prefs == null) return;
    for (final entry in imported.entries) {
      if (!portableSettingKeys.contains(entry.key) ||
          entry.key.endsWith('-creds')) {
        continue;
      }
      final value = entry.value;
      if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is List) {
        await prefs.setStringList(
          entry.key,
          value.whereType<String>().toList(),
        );
      } else if (value is String) {
        await prefs.setString(entry.key, value);
      }
    }
    settingsProvider.batchUpdate(() {});
  }

  Future<void> _restoreCatalogConfiguration(ExportSchema schema) async {
    final currentAccounts = await catalogDatabase.accounts();
    final accountIds = currentAccounts.map((account) => account.id).toSet();
    for (final json in schema.accounts) {
      final account = restorePortableAccount(json);
      if (accountIds.add(account.id)) {
        await catalogDatabase.upsertAccount(account);
      }
    }

    final existingRepositories = await catalogDatabase.fdroidRepositories();
    final byUrl = {
      for (final repository in existingRepositories)
        repository.canonicalUrl: repository,
    };
    for (final json in schema.fdroidRepositories) {
      final restored = _repositoryFromPortable(json);
      final resolved = resolveRestoredFdroidRepository(
        restored,
        existing: byUrl[restored.canonicalUrl],
      );
      await catalogDatabase.upsertFdroidRepository(resolved);
    }
    await catalogProvider?.reloadConfiguration();
  }
}

Set<String> findImportConflicts(Map<String, App> existing, List<App> imported) {
  final conflicts = <String>{};
  for (final app in imported) {
    final current = existing[app.id];
    if (current != null &&
        jsonEncode(current.toJson()) != jsonEncode(app.toJson())) {
      conflicts.add(app.id);
    }
  }
  return conflicts;
}

FdroidRepository resolveRestoredFdroidRepository(
  FdroidRepository restored, {
  FdroidRepository? existing,
}) {
  if (existing != null &&
      existing.fingerprint.toUpperCase() !=
          restored.fingerprint.toUpperCase()) {
    return existing.copyWith(
      trustState: RepositoryTrustState.fingerprintChanged,
      enabled: false,
      syncError: 'Backup fingerprint differs from the configured repository',
    );
  }
  if (existing != null) {
    return existing.copyWith(label: restored.label, mirrors: restored.mirrors);
  }
  if (restored.id == FdroidRepository.official().id &&
      restored.fingerprint.toUpperCase() ==
          FdroidRepository.officialFingerprint) {
    return restored.copyWith(
      trustState: RepositoryTrustState.trusted,
      enabled: true,
    );
  }
  return restored.copyWith(
    trustState: RepositoryTrustState.pendingConfirmation,
    enabled: false,
  );
}

Map<String, dynamic> _sanitizePortableAppMap(Map<String, dynamic> source) {
  final sanitized = Map<String, dynamic>.from(source);
  if (sanitized['url'] case final String url) {
    sanitized['url'] = _sanitizePortableUrl(url);
  }
  for (final key in const ['apkUrls', 'otherAssetUrls']) {
    if (sanitized[key] case final String encoded) {
      try {
        final decoded = jsonDecode(encoded);
        sanitized[key] = jsonEncode(_sanitizePortableValue(decoded));
      } catch (_) {
        sanitized[key] = '[]';
      }
    }
  }
  if (sanitized['additionalSettings'] case final value?) {
    try {
      final decoded = value is String ? jsonDecode(value) : value;
      final safe = _sanitizePortableValue(decoded);
      sanitized['additionalSettings'] = value is String
          ? jsonEncode(safe)
          : safe;
    } catch (_) {
      sanitized['additionalSettings'] = '{}';
    }
  }
  return sanitized;
}

dynamic _sanitizePortableValue(dynamic value) {
  if (value is List) {
    return value.map(_sanitizePortableValue).toList();
  }
  if (value is Map) {
    final sanitized = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (_isSensitivePortableKey(key)) continue;
      if (key == 'requestHeader' && entry.value is List) {
        sanitized[key] = (entry.value as List)
            .where((item) {
              if (item is! Map) return false;
              final header = item['requestHeader'];
              if (header is! String || !header.contains(':')) return false;
              return !_isSensitiveHeaderName(header.split(':').first);
            })
            .map(_sanitizePortableValue)
            .toList();
        continue;
      }
      sanitized[key] = _sanitizePortableValue(entry.value);
    }
    return sanitized;
  }
  if (value is String) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.isAbsolute && uri.host.isNotEmpty) {
      return _sanitizePortableUrl(value);
    }
  }
  return value;
}

bool _isSensitivePortableKey(String key) {
  final lower = key.toLowerCase();
  if (lower.endsWith('-creds')) return true;
  final normalized = lower.replaceAll(RegExp('[^a-z0-9]'), '');
  return normalized == 'authorization' ||
      normalized == 'cookie' ||
      normalized == 'setcookie' ||
      normalized.endsWith('token') ||
      normalized.endsWith('secret') ||
      normalized.endsWith('password') ||
      normalized.endsWith('passwd') ||
      normalized.endsWith('credential') ||
      normalized.endsWith('credentials') ||
      normalized.endsWith('apikey');
}

bool _isSensitiveHeaderName(String name) {
  final normalized = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return normalized.contains('authorization') ||
      normalized.contains('cookie') ||
      normalized.contains('token') ||
      normalized.contains('secret') ||
      normalized.contains('credential') ||
      normalized.contains('password') ||
      normalized.endsWith('key');
}

String _sanitizePortableUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.isAbsolute || uri.host.isEmpty) return value;
  final query = <String, dynamic>{};
  var removedQueryValue = false;
  for (final entry in uri.queryParametersAll.entries) {
    if (_isSensitivePortableKey(entry.key)) {
      removedQueryValue = true;
      continue;
    }
    query[entry.key] = entry.value.length == 1
        ? entry.value.single
        : entry.value;
  }
  if (uri.userInfo.isEmpty && !removedQueryValue) return value;
  final safeQuery = query.isEmpty ? '' : Uri(queryParameters: query).query;
  return uri.replace(userInfo: '', query: safeQuery).toString();
}

List<Map<String, dynamic>> _portableAppList(dynamic value) =>
    (value as List<dynamic>? ?? const [])
        .map(
          (entry) =>
              _sanitizePortableAppMap(Map<String, dynamic>.from(entry as Map)),
        )
        .toList();

class ExportSchema {
  final int schemaVersion;
  final String product;
  final String exportedAt;
  final String appVersion;
  final List<Map<String, dynamic>> apps;
  final List<Map<String, dynamic>> installedInventory;
  final Map<String, dynamic> settings;
  final List<Map<String, dynamic>> accounts;
  final List<Map<String, dynamic>> fdroidRepositories;
  final Map<String, dynamic> catalogPreferences;

  const ExportSchema({
    required this.schemaVersion,
    required this.product,
    required this.exportedAt,
    required this.appVersion,
    required this.apps,
    required this.installedInventory,
    required this.settings,
    required this.accounts,
    required this.fdroidRepositories,
    required this.catalogPreferences,
  });

  factory ExportSchema.fromAny(dynamic decoded) {
    if (decoded is List) {
      return ExportSchema._legacy(apps: decoded);
    }
    if (decoded is! Map) {
      throw const FormatException('The backup root must be an object or list');
    }
    final json = Map<String, dynamic>.from(decoded);
    final schemaVersion = json['schemaVersion'] as int? ?? 1;
    if (schemaVersion > currentExportSchemaVersion) {
      throw FormatException(
        'Export was created by a newer version of Emporion '
        '(schema v$schemaVersion, current is v$currentExportSchemaVersion). '
        'Please update Emporion to import this file.',
      );
    }
    if (schemaVersion < 3) {
      return ExportSchema._legacy(
        apps: json['apps'] as List<dynamic>? ?? const [],
        settings: _portableSettingsFrom(json['settings']),
        schemaVersion: schemaVersion,
        exportedAt: json['exportedAt'] as String? ?? '',
        appVersion: json['appVersion'] as String? ?? '',
      );
    }
    if (json['product'] != portableExportProduct) {
      throw const FormatException(
        'This schema-v3 backup is not an Emporion backup',
      );
    }
    return ExportSchema(
      schemaVersion: schemaVersion,
      product: portableExportProduct,
      exportedAt: json['exportedAt'] as String? ?? '',
      appVersion: json['appVersion'] as String? ?? '',
      apps: _portableAppList(json['apps']),
      installedInventory: _mapList(json['installedInventory']),
      settings: _portableSettingsFrom(json['settings']),
      accounts: _portableAccountList(json['accounts']),
      fdroidRepositories: _portableRepositoryList(json['fdroidRepositories']),
      catalogPreferences: _stringMap(json['catalogPreferences']),
    );
  }

  factory ExportSchema._legacy({
    required List<dynamic> apps,
    Map<String, dynamic> settings = const {},
    int schemaVersion = 1,
    String exportedAt = '',
    String appVersion = '',
  }) {
    final appMaps = _portableAppList(apps);
    return ExportSchema(
      schemaVersion: schemaVersion,
      product: portableExportProduct,
      exportedAt: exportedAt,
      appVersion: appVersion,
      apps: appMaps,
      installedInventory: appMaps
          .where((app) => app['id'] is String)
          .map(
            (app) => <String, dynamic>{
              'packageId': app['id'],
              'name': app['name'],
              'versionName': app['installedVersion'],
              'versionCode': null,
              'signersSha256': const <String>[],
              'subscription': {'url': app['url']},
              'unresolved': false,
            },
          )
          .toList(),
      settings: settings,
      accounts: const [],
      fdroidRepositories: const [],
      catalogPreferences: const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': currentExportSchemaVersion,
    'product': product,
    'exportedAt': exportedAt,
    'appVersion': appVersion,
    'apps': apps.map(_sanitizePortableAppMap).toList(),
    'installedInventory': installedInventory,
    'settings': settings,
    'accounts': _portableAccountList(accounts),
    'fdroidRepositories': _portableRepositoryList(fdroidRepositories),
    'catalogPreferences': catalogPreferences,
  };
}

Map<String, dynamic> _portableSettingsFrom(dynamic value) {
  if (value is! Map) return {};
  return {
    for (final entry in value.entries)
      if (entry.key is String &&
          portableSettingKeys.contains(entry.key) &&
          !(entry.key as String).endsWith('-creds'))
        entry.key as String: entry.value,
  };
}

Map<String, dynamic> _portableAccount(ProviderAccount account) => {
  'id': account.id,
  'provider': account.provider.name,
  'apiBaseUrl': account.apiBaseUrl,
  'webBaseUrl': account.webBaseUrl,
  'label': account.label,
  'username': account.username,
  'validatedAt': account.validatedAt.toUtc().toIso8601String(),
};

List<Map<String, dynamic>> _portableAccountList(dynamic value) =>
    _mapList(value)
        .map(
          (account) => <String, dynamic>{
            for (final key in const [
              'id',
              'provider',
              'apiBaseUrl',
              'webBaseUrl',
              'label',
              'username',
              'validatedAt',
            ])
              if (account.containsKey(key)) key: account[key],
          },
        )
        .toList();

ProviderAccount restorePortableAccount(Map<String, dynamic> json) {
  final validated = ProviderAccount.validated(
    provider: ProviderKind.values.byName(json['provider'] as String),
    apiBaseUrl: json['apiBaseUrl'] as String,
    webBaseUrl: json['webBaseUrl'] as String,
    label: json['label'] as String? ?? '',
    username: json['username'] as String,
    validatedAt:
        DateTime.tryParse(json['validatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
  return validated.copyWith(reconnectRequired: true);
}

Map<String, dynamic> _portableRepository(FdroidRepository repository) => {
  'id': repository.id,
  'canonicalUrl': repository.canonicalUrl,
  'label': repository.label,
  'mirrors': _portableHttpsMirrors(repository.mirrors),
  'fingerprint': repository.fingerprint,
  'enabled': repository.enabled,
  'trustState': repository.trustState.name,
  'lastAcceptedTimestamp': repository.lastAcceptedTimestamp
      ?.toUtc()
      .toIso8601String(),
  'lastGeneration': repository.lastGeneration,
};

List<String> _portableHttpsMirrors(dynamic value) {
  if (value is! Iterable) return const [];
  final mirrors = <String>[];
  for (final candidate in value.whereType<String>()) {
    try {
      final normalized = canonicalHttpsBase(candidate);
      if (!mirrors.contains(normalized)) mirrors.add(normalized);
    } on FormatException {
      // Cleartext and malformed mirrors are not portable trust roots.
    }
  }
  return mirrors;
}

List<Map<String, dynamic>> _portableRepositoryList(dynamic value) =>
    _mapList(value)
        .map(
          (repository) => <String, dynamic>{
            ...repository,
            'mirrors': _portableHttpsMirrors(repository['mirrors']),
          },
        )
        .toList();

FdroidRepository _repositoryFromPortable(Map<String, dynamic> json) {
  final canonicalUrl = canonicalHttpsBase(json['canonicalUrl'] as String);
  final fingerprint = (json['fingerprint'] as String).toUpperCase();
  if (!RegExp(r'^[A-F0-9]{64}$').hasMatch(fingerprint)) {
    throw const FormatException(
      'An F-Droid fingerprint must be 64 hexadecimal characters',
    );
  }
  final mirrors = (json['mirrors'] as List<dynamic>? ?? const [])
      .whereType<String>()
      .map(canonicalHttpsBase)
      .toList();
  return FdroidRepository(
    id: json['id'] as String,
    canonicalUrl: canonicalUrl,
    label: json['label'] as String? ?? Uri.parse(canonicalUrl).host,
    mirrors: mirrors,
    fingerprint: fingerprint,
    trustState: RepositoryTrustState.pendingConfirmation,
    enabled: false,
    lastAcceptedTimestamp: DateTime.tryParse(
      json['lastAcceptedTimestamp'] as String? ?? '',
    ),
    lastGeneration: json['lastGeneration'] as String?,
  );
}

List<String> _packageSignerDigests(PackageInfo info) {
  final signingInfo = info.signingInfo;
  final signatures = signingInfo?.hasMultipleSigners == true
      ? signingInfo?.apkContentSigners
      : signingInfo?.signingCertificateHistory;
  return signatures
          ?.map(
            (signature) => sha256
                .convert(signature)
                .bytes
                .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
                .join()
                .toUpperCase(),
          )
          .toList() ??
      const [];
}

CatalogFilters _filtersFromJson(dynamic value) {
  final json = _stringMap(value);
  Set<String> strings(String key) =>
      (json[key] as List<dynamic>? ?? const []).whereType<String>().toSet();
  T? nullable<T>(String key) => json[key] is T ? json[key] as T : null;
  return CatalogFilters(
    sources: strings('sources')
        .map(
          (name) => ProviderKind.values
              .where((value) => value.name == name)
              .firstOrNull,
        )
        .whereType<ProviderKind>()
        .toSet(),
    accountIds: strings('accountIds'),
    categories: strings('categories'),
    licenses: strings('licenses'),
    antiFeatures: strings('antiFeatures'),
    topics: strings('topics'),
    isPrivate: nullable<bool>('isPrivate'),
    apkAvailable: nullable<bool>('apkAvailable'),
    deviceCompatible: nullable<bool>('deviceCompatible'),
    includeArchived: nullable<bool>('includeArchived') ?? false,
    includeForks: nullable<bool>('includeForks') ?? false,
    includeUnknown: nullable<bool>('includeUnknown') ?? false,
    minimumStars: nullable<int>('minimumStars'),
    minimumActiveContributors90d: nullable<int>('minimumActiveContributors90d'),
    minimumAllTimeContributors: nullable<int>('minimumAllTimeContributors'),
    minimumCommits90d: nullable<int>('minimumCommits90d'),
    minimumReleases365d: nullable<int>('minimumReleases365d'),
    minimumScore: nullable<int>('minimumScore'),
    minimumConfidence: nullable<int>('minimumConfidence'),
    minimumResponseRate: nullable<num>('minimumResponseRate')?.toDouble(),
    minimumActionRate: nullable<num>('minimumActionRate')?.toDouble(),
    minimumCloseRate: nullable<num>('minimumCloseRate')?.toDouble(),
    maximumDaysSinceCommit: nullable<int>('maximumDaysSinceCommit'),
    maximumDaysSinceRelease: nullable<int>('maximumDaysSinceRelease'),
    maximumFirstResponseHours: nullable<num>(
      'maximumFirstResponseHours',
    )?.toDouble(),
  );
}

List<Map<String, dynamic>> _mapList(dynamic value) =>
    (value as List<dynamic>? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();

Map<String, dynamic> _stringMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

T _enumByName<T extends Enum>(List<T> values, dynamic name, T fallback) =>
    values.where((value) => value.name == name).firstOrNull ?? fallback;

int _boundedInt(dynamic value, int min, int max, int fallback) {
  if (value is! int) return fallback;
  return value.clamp(min, max);
}
