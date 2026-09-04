import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Providers whose repositories can be explored directly.
enum ProviderKind { github, gitlab, forgejo, fdroid }

enum CatalogOriginKind { forgeRelease, fdroidPackage }

enum AvailabilityState { available, unavailable, unknown }

enum FreshnessState { fresh, stale, expired }

enum RepositoryTrustState {
  trusted,
  pendingConfirmation,
  fingerprintChanged,
  disabled,
}

enum CatalogSort {
  relevance,
  emporionScore,
  stars,
  activity,
  releaseCadence,
  activeContributors,
  issueResponse,
  name,
}

String canonicalHttpsBase(String value) {
  final parsed = Uri.parse(value.trim());
  if (parsed.scheme.toLowerCase() != 'https' || parsed.host.isEmpty) {
    throw const FormatException('A canonical HTTPS URL is required');
  }
  final normalizedPath = parsed.pathSegments
      .where((e) => e.isNotEmpty)
      .join('/');
  return Uri(
    scheme: 'https',
    host: parsed.host.toLowerCase(),
    port: parsed.hasPort && parsed.port != 443 ? parsed.port : null,
    path: normalizedPath.isEmpty ? null : '/$normalizedPath',
  ).toString().replaceFirst(RegExp(r'/$'), '');
}

String canonicalHost(String value) {
  final uri = value.contains('://')
      ? Uri.parse(value)
      : Uri.parse('https://$value');
  if (uri.host.isEmpty) throw const FormatException('A host is required');
  return uri.hasPort && uri.port != 443
      ? '${uri.host.toLowerCase()}:${uri.port}'
      : uri.host.toLowerCase();
}

class ProviderAccount {
  final String id;
  final ProviderKind provider;
  final String apiBaseUrl;
  final String webBaseUrl;
  final String label;
  final String username;
  final DateTime validatedAt;
  final bool reconnectRequired;
  final String? effectiveScopes;

  const ProviderAccount({
    required this.id,
    required this.provider,
    required this.apiBaseUrl,
    required this.webBaseUrl,
    required this.label,
    required this.username,
    required this.validatedAt,
    this.reconnectRequired = false,
    this.effectiveScopes,
  });

  factory ProviderAccount.validated({
    required ProviderKind provider,
    required String apiBaseUrl,
    required String webBaseUrl,
    required String label,
    required String username,
    required DateTime validatedAt,
    String? effectiveScopes,
  }) {
    final api = canonicalHttpsBase(apiBaseUrl);
    final web = canonicalHttpsBase(webBaseUrl);
    final identity =
        '${provider.name}|${canonicalHost(api)}|${username.toLowerCase()}';
    final id = sha256
        .convert(utf8.encode(identity))
        .toString()
        .substring(0, 16);
    return ProviderAccount(
      id: id,
      provider: provider,
      apiBaseUrl: api,
      webBaseUrl: web,
      label: label.trim().isEmpty ? username : label.trim(),
      username: username,
      validatedAt: validatedAt.toUtc(),
      effectiveScopes: effectiveScopes,
    );
  }

  ProviderAccount copyWith({
    String? label,
    DateTime? validatedAt,
    bool? reconnectRequired,
    String? effectiveScopes,
  }) => ProviderAccount(
    id: id,
    provider: provider,
    apiBaseUrl: apiBaseUrl,
    webBaseUrl: webBaseUrl,
    label: label ?? this.label,
    username: username,
    validatedAt: validatedAt ?? this.validatedAt,
    reconnectRequired: reconnectRequired ?? this.reconnectRequired,
    effectiveScopes: effectiveScopes ?? this.effectiveScopes,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'provider': provider.name,
    'apiBaseUrl': apiBaseUrl,
    'webBaseUrl': webBaseUrl,
    'label': label,
    'username': username,
    'validatedAt': validatedAt.toUtc().toIso8601String(),
    'reconnectRequired': reconnectRequired ? 1 : 0,
    'effectiveScopes': effectiveScopes,
  };

  factory ProviderAccount.fromMap(Map<String, Object?> map) => ProviderAccount(
    id: map['id']! as String,
    provider: ProviderKind.values.byName(map['provider']! as String),
    apiBaseUrl: map['apiBaseUrl']! as String,
    webBaseUrl: map['webBaseUrl']! as String,
    label: map['label']! as String,
    username: map['username']! as String,
    validatedAt: DateTime.parse(map['validatedAt']! as String).toUtc(),
    reconnectRequired:
        map['reconnectRequired'] == 1 || map['reconnectRequired'] == true,
    effectiveScopes: map['effectiveScopes'] as String?,
  );
}

class FdroidRepository {
  final String id;
  final String canonicalUrl;
  final String label;
  final List<String> mirrors;
  final String fingerprint;
  final String? signingCertificate;
  final RepositoryTrustState trustState;
  final bool enabled;
  final DateTime? lastAcceptedTimestamp;
  final String? lastGeneration;
  final String? syncError;

  const FdroidRepository({
    required this.id,
    required this.canonicalUrl,
    required this.label,
    required this.mirrors,
    required this.fingerprint,
    required this.trustState,
    required this.enabled,
    this.signingCertificate,
    this.lastAcceptedTimestamp,
    this.lastGeneration,
    this.syncError,
  });

  static const officialFingerprint =
      '43238D512C1E5EB2D6569F4A3AFBF5523418B82E0A3ED1552770ABB9A9C9CCAB';

  factory FdroidRepository.official() => const FdroidRepository(
    id: 'fdroid-official',
    canonicalUrl: 'https://f-droid.org/repo',
    label: 'F-Droid',
    mirrors: <String>[],
    fingerprint: officialFingerprint,
    trustState: RepositoryTrustState.trusted,
    enabled: true,
  );

  FdroidRepository copyWith({
    String? label,
    List<String>? mirrors,
    String? fingerprint,
    String? signingCertificate,
    RepositoryTrustState? trustState,
    bool? enabled,
    DateTime? lastAcceptedTimestamp,
    String? lastGeneration,
    String? syncError,
    bool clearSyncError = false,
  }) => FdroidRepository(
    id: id,
    canonicalUrl: canonicalUrl,
    label: label ?? this.label,
    mirrors: mirrors ?? this.mirrors,
    fingerprint: fingerprint ?? this.fingerprint,
    signingCertificate: signingCertificate ?? this.signingCertificate,
    trustState: trustState ?? this.trustState,
    enabled: enabled ?? this.enabled,
    lastAcceptedTimestamp: lastAcceptedTimestamp ?? this.lastAcceptedTimestamp,
    lastGeneration: lastGeneration ?? this.lastGeneration,
    syncError: clearSyncError ? null : syncError ?? this.syncError,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'canonicalUrl': canonicalUrl,
    'label': label,
    'mirrors': jsonEncode(mirrors),
    'fingerprint': fingerprint,
    'signingCertificate': signingCertificate,
    'trustState': trustState.name,
    'enabled': enabled ? 1 : 0,
    'lastAcceptedTimestamp': lastAcceptedTimestamp?.toUtc().toIso8601String(),
    'lastGeneration': lastGeneration,
    'syncError': syncError,
  };

  factory FdroidRepository.fromMap(Map<String, Object?> map) =>
      FdroidRepository(
        id: map['id']! as String,
        canonicalUrl: map['canonicalUrl']! as String,
        label: map['label']! as String,
        mirrors: List<String>.from(
          jsonDecode(map['mirrors']! as String) as List,
        ),
        fingerprint: map['fingerprint']! as String,
        signingCertificate: map['signingCertificate'] as String?,
        trustState: RepositoryTrustState.values.byName(
          map['trustState']! as String,
        ),
        enabled: map['enabled'] == 1 || map['enabled'] == true,
        lastAcceptedTimestamp: map['lastAcceptedTimestamp'] == null
            ? null
            : DateTime.parse(map['lastAcceptedTimestamp']! as String).toUtc(),
        lastGeneration: map['lastGeneration'] as String?,
        syncError: map['syncError'] as String?,
      );
}

class PageCursor {
  final Uri? next;
  final String? token;
  final int? page;

  const PageCursor({this.next, this.token, this.page});

  bool get hasNext => next != null || token != null || page != null;

  Map<String, Object?> toJson() => {
    'next': next?.toString(),
    'token': token,
    'page': page,
  };

  factory PageCursor.fromJson(Map<String, Object?> json) => PageCursor(
    next: json['next'] == null ? null : Uri.parse(json['next']! as String),
    token: json['token'] as String?,
    page: json['page'] as int?,
  );
}

class CatalogFilters {
  final Set<ProviderKind> sources;
  final Set<String> accountIds;
  final Set<String> categories;
  final Set<String> licenses;
  final Set<String> antiFeatures;
  final Set<String> topics;
  final bool? isPrivate;
  final bool? apkAvailable;
  final bool? deviceCompatible;
  final bool includeArchived;
  final bool includeForks;
  final bool includeUnknown;
  final int? minimumStars;
  final int? minimumActiveContributors90d;
  final int? minimumAllTimeContributors;
  final int? minimumCommits90d;
  final int? minimumReleases365d;
  final int? minimumScore;
  final int? minimumConfidence;
  final double? minimumResponseRate;
  final double? minimumActionRate;
  final double? minimumCloseRate;
  final int? maximumDaysSinceCommit;
  final int? maximumDaysSinceRelease;
  final double? maximumFirstResponseHours;

  const CatalogFilters({
    this.sources = const {},
    this.accountIds = const {},
    this.categories = const {},
    this.licenses = const {},
    this.antiFeatures = const {},
    this.topics = const {},
    this.isPrivate,
    this.apkAvailable,
    this.deviceCompatible,
    this.includeArchived = false,
    this.includeForks = false,
    this.includeUnknown = false,
    this.minimumStars,
    this.minimumActiveContributors90d,
    this.minimumAllTimeContributors,
    this.minimumCommits90d,
    this.minimumReleases365d,
    this.minimumScore,
    this.minimumConfidence,
    this.minimumResponseRate,
    this.minimumActionRate,
    this.minimumCloseRate,
    this.maximumDaysSinceCommit,
    this.maximumDaysSinceRelease,
    this.maximumFirstResponseHours,
  });

  int get activeCount => <bool>[
    sources.isNotEmpty,
    accountIds.isNotEmpty,
    categories.isNotEmpty,
    licenses.isNotEmpty,
    antiFeatures.isNotEmpty,
    topics.isNotEmpty,
    isPrivate != null,
    apkAvailable != null,
    deviceCompatible != null,
    includeArchived,
    includeForks,
    includeUnknown,
    minimumStars != null,
    minimumActiveContributors90d != null,
    minimumAllTimeContributors != null,
    minimumCommits90d != null,
    minimumReleases365d != null,
    minimumScore != null,
    minimumConfidence != null,
    minimumResponseRate != null,
    minimumActionRate != null,
    minimumCloseRate != null,
    maximumDaysSinceCommit != null,
    maximumDaysSinceRelease != null,
    maximumFirstResponseHours != null,
  ].where((v) => v).length;

  bool get requiresHeavyMetrics =>
      minimumActiveContributors90d != null ||
      minimumAllTimeContributors != null ||
      minimumCommits90d != null ||
      minimumReleases365d != null ||
      minimumScore != null ||
      minimumConfidence != null ||
      minimumResponseRate != null ||
      minimumActionRate != null ||
      minimumCloseRate != null ||
      maximumDaysSinceCommit != null ||
      maximumDaysSinceRelease != null ||
      maximumFirstResponseHours != null;

  Map<String, Object?> toJson() => {
    'sources': sources.map((e) => e.name).toList(),
    'accountIds': accountIds.toList(),
    'categories': categories.toList(),
    'licenses': licenses.toList(),
    'antiFeatures': antiFeatures.toList(),
    'topics': topics.toList(),
    'isPrivate': isPrivate,
    'apkAvailable': apkAvailable,
    'deviceCompatible': deviceCompatible,
    'includeArchived': includeArchived,
    'includeForks': includeForks,
    'includeUnknown': includeUnknown,
    'minimumStars': minimumStars,
    'minimumActiveContributors90d': minimumActiveContributors90d,
    'minimumAllTimeContributors': minimumAllTimeContributors,
    'minimumCommits90d': minimumCommits90d,
    'minimumReleases365d': minimumReleases365d,
    'minimumScore': minimumScore,
    'minimumConfidence': minimumConfidence,
    'minimumResponseRate': minimumResponseRate,
    'minimumActionRate': minimumActionRate,
    'minimumCloseRate': minimumCloseRate,
    'maximumDaysSinceCommit': maximumDaysSinceCommit,
    'maximumDaysSinceRelease': maximumDaysSinceRelease,
    'maximumFirstResponseHours': maximumFirstResponseHours,
  };
}

class CatalogQuery {
  final String text;
  final CatalogFilters filters;
  final CatalogSort sort;
  final PageCursor? cursor;
  final int pageSize;

  const CatalogQuery({
    required this.text,
    this.filters = const CatalogFilters(),
    this.sort = CatalogSort.relevance,
    this.cursor,
    this.pageSize = 30,
  });

  String cacheKey(ProviderKind adapter, String host, String? accountId) {
    final payload = <String, Object?>{
      'adapter': adapter.name,
      'host': canonicalHost(host),
      'account': accountId ?? 'public',
      'text': text.trim(),
      'filters': filters.toJson(),
      'sort': sort.name,
      'cursor': cursor?.toJson(),
      'pageSize': pageSize,
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }
}

class ReleaseAsset {
  final String name;
  final Uri downloadUrl;
  final int? size;
  final String? sha256;
  final String? signerSha256;
  final String contentType;

  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.contentType,
    this.size,
    this.sha256,
    this.signerSha256,
  });

  bool get isInstallable =>
      RegExp(r'\.(apk|apks|apkm|xapk)$', caseSensitive: false).hasMatch(name);

  Map<String, Object?> toJson() => {
    'name': name,
    'downloadUrl': downloadUrl.toString(),
    'size': size,
    'sha256': sha256,
    'signerSha256': signerSha256,
    'contentType': contentType,
  };

  factory ReleaseAsset.fromJson(Map<String, Object?> json) => ReleaseAsset(
    name: json['name']! as String,
    downloadUrl: Uri.parse(json['downloadUrl']! as String),
    size: json['size'] as int?,
    sha256: json['sha256'] as String?,
    signerSha256: json['signerSha256'] as String?,
    contentType: json['contentType'] as String? ?? 'application/octet-stream',
  );
}

class ReleaseSummary {
  final String id;
  final String version;
  final String? name;
  final String? changelog;
  final DateTime? publishedAt;
  final bool prerelease;
  final List<ReleaseAsset> assets;

  const ReleaseSummary({
    required this.id,
    required this.version,
    required this.assets,
    this.name,
    this.changelog,
    this.publishedAt,
    this.prerelease = false,
  });

  bool get hasInstallableAsset => assets.any((e) => e.isInstallable);

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version,
    'name': name,
    'changelog': changelog,
    'publishedAt': publishedAt?.toUtc().toIso8601String(),
    'prerelease': prerelease,
    'assets': assets.map((e) => e.toJson()).toList(),
  };

  factory ReleaseSummary.fromJson(Map<String, Object?> json) => ReleaseSummary(
    id: json['id']! as String,
    version: json['version']! as String,
    name: json['name'] as String?,
    changelog: json['changelog'] as String?,
    publishedAt: json['publishedAt'] == null
        ? null
        : DateTime.parse(json['publishedAt']! as String).toUtc(),
    prerelease: json['prerelease'] as bool? ?? false,
    assets: (json['assets'] as List<dynamic>? ?? const [])
        .map((e) => ReleaseAsset.fromJson(Map<String, Object?>.from(e as Map)))
        .toList(),
  );
}

class MetricSnapshot {
  static const adapterVersion = 1;

  final int? stars;
  final int? forks;
  final int? openIssues;
  final int? commits90d;
  final int? activeContributors90d;
  final int? allTimeContributors;
  final int? releases365d;
  final int? daysSinceCommit;
  final int? daysSinceRelease;
  final int issueSampleSize;
  final double? responseRate;
  final double? actionRate;
  final double? closeRate;
  final double? medianFirstResponseHours;
  final DateTime observedAt;
  final int windowDays;
  final Set<String> estimatedFields;
  final Set<String> unavailableFields;
  final int? score;
  final int confidence;

  const MetricSnapshot({
    required this.observedAt,
    this.stars,
    this.forks,
    this.openIssues,
    this.commits90d,
    this.activeContributors90d,
    this.allTimeContributors,
    this.releases365d,
    this.daysSinceCommit,
    this.daysSinceRelease,
    this.issueSampleSize = 0,
    this.responseRate,
    this.actionRate,
    this.closeRate,
    this.medianFirstResponseHours,
    this.windowDays = 90,
    this.estimatedFields = const {},
    this.unavailableFields = const {},
    this.score,
    this.confidence = 0,
  });

  bool get isEstimated => estimatedFields.isNotEmpty;
  bool isFreshAt(DateTime now, Duration ttl) =>
      now.toUtc().difference(observedAt.toUtc()) <= ttl;

  MetricSnapshot copyWith({int? score, int? confidence}) => MetricSnapshot(
    stars: stars,
    forks: forks,
    openIssues: openIssues,
    commits90d: commits90d,
    activeContributors90d: activeContributors90d,
    allTimeContributors: allTimeContributors,
    releases365d: releases365d,
    daysSinceCommit: daysSinceCommit,
    daysSinceRelease: daysSinceRelease,
    issueSampleSize: issueSampleSize,
    responseRate: responseRate,
    actionRate: actionRate,
    closeRate: closeRate,
    medianFirstResponseHours: medianFirstResponseHours,
    observedAt: observedAt,
    windowDays: windowDays,
    estimatedFields: estimatedFields,
    unavailableFields: unavailableFields,
    score: score ?? this.score,
    confidence: confidence ?? this.confidence,
  );

  Map<String, Object?> toJson() => {
    'stars': stars,
    'forks': forks,
    'openIssues': openIssues,
    'commits90d': commits90d,
    'activeContributors90d': activeContributors90d,
    'allTimeContributors': allTimeContributors,
    'releases365d': releases365d,
    'daysSinceCommit': daysSinceCommit,
    'daysSinceRelease': daysSinceRelease,
    'issueSampleSize': issueSampleSize,
    'responseRate': responseRate,
    'actionRate': actionRate,
    'closeRate': closeRate,
    'medianFirstResponseHours': medianFirstResponseHours,
    'observedAt': observedAt.toUtc().toIso8601String(),
    'windowDays': windowDays,
    'estimatedFields': estimatedFields.toList(),
    'unavailableFields': unavailableFields.toList(),
    'adapterVersion': adapterVersion,
    'score': score,
    'confidence': confidence,
  };

  factory MetricSnapshot.fromJson(Map<String, Object?> json) => MetricSnapshot(
    stars: json['stars'] as int?,
    forks: json['forks'] as int?,
    openIssues: json['openIssues'] as int?,
    commits90d: json['commits90d'] as int?,
    activeContributors90d: json['activeContributors90d'] as int?,
    allTimeContributors: json['allTimeContributors'] as int?,
    releases365d: json['releases365d'] as int?,
    daysSinceCommit: json['daysSinceCommit'] as int?,
    daysSinceRelease: json['daysSinceRelease'] as int?,
    issueSampleSize: json['issueSampleSize'] as int? ?? 0,
    responseRate: (json['responseRate'] as num?)?.toDouble(),
    actionRate: (json['actionRate'] as num?)?.toDouble(),
    closeRate: (json['closeRate'] as num?)?.toDouble(),
    medianFirstResponseHours: (json['medianFirstResponseHours'] as num?)
        ?.toDouble(),
    observedAt: DateTime.parse(json['observedAt']! as String).toUtc(),
    windowDays: json['windowDays'] as int? ?? 90,
    estimatedFields: Set<String>.from(
      json['estimatedFields'] as List? ?? const [],
    ),
    unavailableFields: Set<String>.from(
      json['unavailableFields'] as List? ?? const [],
    ),
    score: json['score'] as int?,
    confidence: json['confidence'] as int? ?? 0,
  );
}

class ForgeRepository {
  final String catalogKey;
  final ProviderKind provider;
  final String host;
  final String providerRepositoryId;
  final String? accountId;
  final Uri webUrl;
  final Uri apiUrl;
  final String owner;
  final String path;
  final String name;
  final String? summary;
  final String? description;
  final Set<String> topics;
  final Set<String> categories;
  final String? license;
  final bool isPrivate;
  final bool archived;
  final bool fork;
  final AvailabilityState apkAvailability;
  final AvailabilityState deviceCompatibility;
  final DateTime? lastActivity;
  final DateTime observedAt;
  final MetricSnapshot? metrics;
  final List<ReleaseSummary> releases;

  const ForgeRepository({
    required this.catalogKey,
    required this.provider,
    required this.host,
    required this.providerRepositoryId,
    required this.webUrl,
    required this.apiUrl,
    required this.owner,
    required this.path,
    required this.name,
    required this.topics,
    required this.categories,
    required this.isPrivate,
    required this.archived,
    required this.fork,
    required this.apkAvailability,
    required this.deviceCompatibility,
    required this.observedAt,
    this.accountId,
    this.summary,
    this.description,
    this.license,
    this.lastActivity,
    this.metrics,
    this.releases = const [],
  });

  static String identity(
    ProviderKind provider,
    String host,
    Object repositoryId,
  ) => '${provider.name}:${canonicalHost(host)}:${repositoryId.toString()}';

  ForgeRepository copyWith({
    AvailabilityState? apkAvailability,
    AvailabilityState? deviceCompatibility,
    MetricSnapshot? metrics,
    List<ReleaseSummary>? releases,
    DateTime? observedAt,
  }) => ForgeRepository(
    catalogKey: catalogKey,
    provider: provider,
    host: host,
    providerRepositoryId: providerRepositoryId,
    accountId: accountId,
    webUrl: webUrl,
    apiUrl: apiUrl,
    owner: owner,
    path: path,
    name: name,
    summary: summary,
    description: description,
    topics: topics,
    categories: categories,
    license: license,
    isPrivate: isPrivate,
    archived: archived,
    fork: fork,
    apkAvailability: apkAvailability ?? this.apkAvailability,
    deviceCompatibility: deviceCompatibility ?? this.deviceCompatibility,
    lastActivity: lastActivity,
    observedAt: observedAt ?? this.observedAt,
    metrics: metrics ?? this.metrics,
    releases: releases ?? this.releases,
  );
}

class FdroidVersion {
  final String repositoryId;
  final String packageName;
  final String versionName;
  final int versionCode;
  final Uri apkUrl;
  final String sha256;
  final int size;
  final String signerSha256;
  final int? minSdk;
  final int? maxSdk;
  final Set<String> abis;
  final Set<String> densities;
  final Set<String> languages;
  final String releaseChannel;
  final DateTime? addedAt;

  const FdroidVersion({
    required this.repositoryId,
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    required this.sha256,
    required this.size,
    required this.signerSha256,
    this.minSdk,
    this.maxSdk,
    this.abis = const {},
    this.densities = const {},
    this.languages = const {},
    this.releaseChannel = 'stable',
    this.addedAt,
  });

  String get identity =>
      '$repositoryId:$packageName:$versionCode:$signerSha256';

  Map<String, Object?> toJson() => {
    'repositoryId': repositoryId,
    'packageName': packageName,
    'versionName': versionName,
    'versionCode': versionCode,
    'apkUrl': apkUrl.toString(),
    'sha256': sha256,
    'size': size,
    'signerSha256': signerSha256,
    'minSdk': minSdk,
    'maxSdk': maxSdk,
    'abis': abis.toList(),
    'densities': densities.toList(),
    'languages': languages.toList(),
    'releaseChannel': releaseChannel,
    'addedAt': addedAt?.toUtc().toIso8601String(),
  };

  factory FdroidVersion.fromJson(Map<String, Object?> json) => FdroidVersion(
    repositoryId: json['repositoryId']! as String,
    packageName: json['packageName']! as String,
    versionName: json['versionName']! as String,
    versionCode: json['versionCode']! as int,
    apkUrl: Uri.parse(json['apkUrl']! as String),
    sha256: json['sha256']! as String,
    size: json['size']! as int,
    signerSha256: json['signerSha256']! as String,
    minSdk: json['minSdk'] as int?,
    maxSdk: json['maxSdk'] as int?,
    abis: Set<String>.from(json['abis'] as List? ?? const []),
    densities: Set<String>.from(json['densities'] as List? ?? const []),
    languages: Set<String>.from(json['languages'] as List? ?? const []),
    releaseChannel: json['releaseChannel'] as String? ?? 'stable',
    addedAt: json['addedAt'] == null
        ? null
        : DateTime.parse(json['addedAt']! as String).toUtc(),
  );
}

class FdroidPackage {
  final String repositoryId;
  final String packageName;
  final String signerSha256;
  final String name;
  final String? summary;
  final String? description;
  final Set<String> categories;
  final String? license;
  final Set<String> antiFeatures;
  final Uri? sourceCodeUrl;
  final Uri? issueTrackerUrl;
  final Uri? iconUrl;
  final List<Uri> screenshots;
  final List<FdroidVersion> versions;
  final DateTime observedAt;
  final String generation;

  const FdroidPackage({
    required this.repositoryId,
    required this.packageName,
    required this.signerSha256,
    required this.name,
    required this.categories,
    required this.antiFeatures,
    required this.screenshots,
    required this.versions,
    required this.observedAt,
    required this.generation,
    this.summary,
    this.description,
    this.license,
    this.sourceCodeUrl,
    this.issueTrackerUrl,
    this.iconUrl,
  });

  String get catalogKey => 'fdroid:$repositoryId:$packageName:$signerSha256';
  String get groupingKey => '$packageName:$signerSha256';
}

class InstallOrigin {
  final CatalogOriginKind kind;
  final String label;
  final Uri sourceUrl;
  final String? accountId;
  final String? expectedPackageName;
  final String? expectedSha256;
  final int? expectedSize;
  final String? expectedSignerSha256;
  final int? expectedVersionCode;
  final AvailabilityState compatibility;
  final bool trusted;

  const InstallOrigin({
    required this.kind,
    required this.label,
    required this.sourceUrl,
    required this.compatibility,
    required this.trusted,
    this.accountId,
    this.expectedPackageName,
    this.expectedSha256,
    this.expectedSize,
    this.expectedSignerSha256,
    this.expectedVersionCode,
  });
}

class CatalogEntry {
  final String catalogKey;
  final CatalogOriginKind originKind;
  final String name;
  final String? summary;
  final String? description;
  final String sourceLabel;
  final String host;
  final String? packageName;
  final Set<String> categories;
  final Set<String> topics;
  final String? license;
  final Set<String> antiFeatures;
  final bool isPrivate;
  final bool archived;
  final bool fork;
  final AvailabilityState apkAvailability;
  final AvailabilityState deviceCompatibility;
  final FreshnessState freshness;
  final DateTime observedAt;
  final ForgeRepository? forgeRepository;
  final FdroidPackage? fdroidPackage;
  final MetricSnapshot? metrics;
  final List<InstallOrigin> installOrigins;
  final bool subscribed;
  final bool installed;
  final bool signerVariantWarning;

  const CatalogEntry({
    required this.catalogKey,
    required this.originKind,
    required this.name,
    required this.sourceLabel,
    required this.host,
    required this.categories,
    required this.topics,
    required this.antiFeatures,
    required this.isPrivate,
    required this.archived,
    required this.fork,
    required this.apkAvailability,
    required this.deviceCompatibility,
    required this.freshness,
    required this.observedAt,
    required this.installOrigins,
    this.summary,
    this.description,
    this.packageName,
    this.license,
    this.forgeRepository,
    this.fdroidPackage,
    this.metrics,
    this.subscribed = false,
    this.installed = false,
    this.signerVariantWarning = false,
  });
}

class CatalogPage {
  final List<ForgeRepository> repositories;
  final PageCursor? next;
  final bool partial;
  final bool incomplete;
  final int? totalCount;
  final DateTime observedAt;

  const CatalogPage({
    required this.repositories,
    required this.observedAt,
    this.next,
    this.partial = false,
    this.incomplete = false,
    this.totalCount,
  });
}

class AccountValidation {
  final String username;
  final String? displayName;
  final String? effectiveScopes;
  final bool broadScopeWarning;

  const AccountValidation({
    required this.username,
    this.displayName,
    this.effectiveScopes,
    this.broadScopeWarning = false,
  });
}
