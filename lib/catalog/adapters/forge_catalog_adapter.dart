import 'dart:convert';

import 'package:obtainium/catalog/models.dart';

class CatalogRateState {
  final int? limit;
  final int? remaining;
  final DateTime? resetAt;
  final Duration? retryAfter;

  const CatalogRateState({
    this.limit,
    this.remaining,
    this.resetAt,
    this.retryAfter,
  });

  bool get exhausted => remaining != null && remaining! <= 0;
}

class CatalogResponse {
  final int statusCode;
  final Map<String, String> headers;
  final List<int> bodyBytes;
  final Uri requestUri;
  final CatalogRateState rateState;

  const CatalogResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
    required this.requestUri,
    this.rateState = const CatalogRateState(),
  });

  String get body => utf8.decode(bodyBytes);
  Object? get json => jsonDecode(body);

  String? header(String name) {
    final expected = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == expected) return entry.value;
    }
    return null;
  }
}

class CatalogHttpException implements Exception {
  final int? statusCode;
  final Uri? uri;
  final String message;
  final DateTime? retryAt;
  final bool authorizationFailure;

  const CatalogHttpException(
    this.message, {
    this.statusCode,
    this.uri,
    this.retryAt,
    this.authorizationFailure = false,
  });

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

abstract interface class CatalogTransport {
  Future<CatalogResponse> get(
    Uri uri, {
    required ProviderKind provider,
    ProviderAccount? account,
    String? credentialOverride,
    Map<String, String> headers = const {},
  });
}

abstract interface class ForgeCatalogAdapter {
  ProviderKind get kind;
  String get adapterName;
  String get defaultApiBaseUrl;
  String get defaultWebBaseUrl;

  Future<AccountValidation> validateAccount({
    required String apiBaseUrl,
    required String webBaseUrl,
    required String token,
  });

  Future<CatalogPage> search(CatalogQuery query, {ProviderAccount? account});

  Future<CatalogPage> listAccessibleRepositories({
    required ProviderAccount account,
    PageCursor? cursor,
  });

  Future<ForgeRepository> fetchRepository(
    Uri repositoryUrl, {
    ProviderAccount? account,
  });

  Future<List<ReleaseSummary>> fetchReleases(
    ForgeRepository repository, {
    ProviderAccount? account,
    int maxPages = 3,
  });

  Future<MetricSnapshot> fetchMetrics(
    ForgeRepository repository, {
    ProviderAccount? account,
    DateTime? now,
  });
}

Uri? nextLink(CatalogResponse response) {
  final link = response.header('link');
  if (link == null) return null;
  for (final segment in link.split(',')) {
    final match = RegExp(
      r'<([^>]+)>\s*;\s*rel="?next"?',
    ).firstMatch(segment.trim());
    if (match != null) return Uri.tryParse(match.group(1)!);
  }
  return null;
}

DateTime? parseDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

int wholeDaysBetween(DateTime? newer, DateTime? older) {
  if (newer == null || older == null) return 0;
  return newer.toUtc().difference(older.toUtc()).inDays.clamp(0, 1 << 31);
}

Never providerError(CatalogResponse response, {String? fallback}) {
  final message =
      fallback ??
      switch (response.statusCode) {
        401 => 'Provider authentication failed',
        403 => 'Provider access was denied',
        404 => 'Provider resource was not found',
        429 => 'Provider rate limit reached',
        >= 500 => 'Provider service is unavailable',
        _ => 'Provider request failed',
      };
  throw CatalogHttpException(
    message,
    statusCode: response.statusCode,
    uri: response.requestUri,
    retryAt: response.rateState.resetAt,
    authorizationFailure:
        response.statusCode == 401 || response.statusCode == 403,
  );
}

bool isHumanLogin(Object? value) {
  final login = value?.toString().trim().toLowerCase();
  if (login == null || login.isEmpty) return false;
  return !login.endsWith('[bot]') && !login.endsWith('-bot') && login != 'bot';
}
