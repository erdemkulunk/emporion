import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:obtainium/catalog/adapters/forge_catalog_adapter.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/providers/source_provider.dart';

abstract interface class CredentialReader {
  Future<String?> get(ProviderAccount account);
}

class ProviderHttpClient implements CatalogTransport {
  static const sensitiveHeaders = {
    'authorization',
    'private-token',
    'proxy-authorization',
    'cookie',
  };
  static const sensitiveQueryKeys = {
    'access_token',
    'private_token',
    'token',
    'authorization',
    'auth',
    'key',
  };
  static const retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  final CredentialReader credentialReader;
  final http.Client? client;
  final HttpService httpService;
  final Future<void> Function(Duration duration) delay;
  final int? maxRequestsPerQueue;
  final Map<String, Future<void>> _serialTails = {};
  final Map<String, _ValidatedPayload> _validatedPayloads = {};
  final Map<String, CatalogRateState> _rateStates = {};
  final Map<String, int> _requestCounts = {};

  ProviderHttpClient({
    required this.credentialReader,
    this.client,
    HttpService? httpService,
    Future<void> Function(Duration duration)? delay,
    this.maxRequestsPerQueue,
  }) : httpService = httpService ?? HttpService(),
       delay = delay ?? Future<void>.delayed;

  @override
  Future<CatalogResponse> get(
    Uri uri, {
    required ProviderKind provider,
    ProviderAccount? account,
    String? credentialOverride,
    Map<String, String> headers = const {},
  }) {
    final queueKey =
        account?.id ??
        '${provider.name}:public:${canonicalHost(uri.toString())}';
    return _serial(
      queueKey,
      () => _getWithRetries(
        uri,
        provider: provider,
        account: account,
        credentialOverride: credentialOverride,
        headers: headers,
      ),
    );
  }

  Future<T> _serial<T>(String key, Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _serialTails[key] ?? Future<void>.value();
    late final Future<void> tail;
    tail = previous
        .catchError((_) {})
        .then((_) async {
          try {
            completer.complete(await action());
          } catch (error, stack) {
            completer.completeError(error, stack);
          }
        })
        .whenComplete(() {
          if (identical(_serialTails[key], tail)) _serialTails.remove(key);
        });
    _serialTails[key] = tail;
    return completer.future;
  }

  Future<CatalogResponse> _getWithRetries(
    Uri uri, {
    required ProviderKind provider,
    ProviderAccount? account,
    String? credentialOverride,
    required Map<String, String> headers,
  }) async {
    if (uri.scheme.toLowerCase() != 'https') {
      throw CatalogHttpException(
        'Credentialed provider requests require HTTPS',
        uri: _redactedUri(uri),
      );
    }
    final credential =
        credentialOverride ??
        (account == null ? null : await credentialReader.get(account));
    if (account != null && credential == null) {
      throw CatalogHttpException(
        'Account credential is unavailable; reconnect required',
        uri: _redactedUri(uri),
        authorizationFailure: true,
      );
    }
    final requestHeaders = <String, String>{
      'accept': 'application/json',
      'user-agent': 'Emporion/1',
      ...headers,
      ..._authorizationHeaders(provider, credential),
    };
    final validator = _validatedPayloads[uri.toString()];
    if (validator?.etag case final etag?) {
      requestHeaders['if-none-match'] = etag;
    }
    if (validator?.lastModified case final modified?) {
      requestHeaders['if-modified-since'] = modified;
    }

    Object? lastError;
    final queueKey =
        account?.id ??
        '${provider.name}:public:${canonicalHost(uri.toString())}';
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      final requestCount = _requestCounts[queueKey] ?? 0;
      if (maxRequestsPerQueue != null && requestCount >= maxRequestsPerQueue!) {
        throw CatalogHttpException(
          'Provider request budget exhausted',
          uri: _redactedUri(uri),
          retryAt: _rateStates[queueKey]?.resetAt,
        );
      }
      final previousRate = _rateStates[queueKey];
      if (previousRate?.limit case final limit?
          when previousRate?.remaining != null &&
              previousRate!.remaining! <= (limit * 0.1).ceil()) {
        throw CatalogHttpException(
          'Provider quota reserve reached',
          uri: _redactedUri(uri),
          retryAt: previousRate.resetAt,
        );
      }
      _requestCounts[queueKey] = requestCount + 1;
      try {
        final response = client == null
            ? await _sendWithHttpService(uri, requestHeaders)
            : await _sendWithInjectedClient(uri, requestHeaders);
        final normalized = response.statusCode == 304 && validator != null
            ? CatalogResponse(
                statusCode: 200,
                headers: response.headers,
                bodyBytes: validator.bodyBytes,
                requestUri: response.requestUri,
                rateState: response.rateState,
              )
            : response;
        _rateStates[queueKey] = normalized.rateState;
        if (normalized.statusCode >= 200 && normalized.statusCode < 300) {
          _validatedPayloads[uri.toString()] = _ValidatedPayload(
            bodyBytes: normalized.bodyBytes,
            etag: normalized.header('etag'),
            lastModified: normalized.header('last-modified'),
          );
          return normalized;
        }
        if (!_isTransient(normalized.statusCode)) return normalized;
        final retryAt = _retryAt(normalized);
        if (retryAt != null) {
          final wait = retryAt.difference(DateTime.now().toUtc());
          if (wait > retryDelays[min(attempt, retryDelays.length - 1)]) {
            throw CatalogHttpException(
              'Provider rate limit reached',
              statusCode: normalized.statusCode,
              uri: _redactedUri(uri),
              retryAt: retryAt,
            );
          }
        }
        lastError = CatalogHttpException(
          'Transient provider failure',
          statusCode: normalized.statusCode,
          uri: _redactedUri(uri),
          retryAt: retryAt,
        );
      } on CatalogHttpException {
        rethrow;
      } on SocketException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      } on TimeoutException catch (error) {
        lastError = error;
      }
      if (attempt == retryDelays.length) break;
      await delay(retryDelays[attempt]);
    }
    throw CatalogHttpException(
      'Provider request failed after ${retryDelays.length + 1} attempts'
      '${lastError == null ? '' : ' (${lastError.runtimeType})'}',
      uri: _redactedUri(uri),
    );
  }

  Map<String, String> _authorizationHeaders(
    ProviderKind provider,
    String? credential,
  ) {
    if (credential == null || credential.isEmpty) return const {};
    return switch (provider) {
      ProviderKind.github => {'authorization': 'Bearer $credential'},
      ProviderKind.gitlab => {'private-token': credential},
      ProviderKind.forgejo => {'authorization': 'token $credential'},
      ProviderKind.fdroid => const {},
    };
  }

  Future<CatalogResponse> _sendWithHttpService(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final stream = await httpService.sourceRequestStreamResponse(
      'GET',
      headers,
      {'url': uri.toString()},
    );
    final finalUri = stream.key;
    final nativeClient = stream.value.key;
    final nativeResponse = stream.value.value;
    final response = await httpService.httpClientResponseStreamToFinalResponse(
      nativeClient,
      'GET',
      finalUri.toString(),
      nativeResponse,
    );
    return CatalogResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      bodyBytes: response.bodyBytes,
      requestUri: finalUri,
      rateState: _rateState(response.headers),
    );
  }

  Future<CatalogResponse> _sendWithInjectedClient(
    Uri initialUri,
    Map<String, String> initialHeaders,
  ) async {
    var current = initialUri;
    final headers = Map<String, String>.from(initialHeaders);
    for (
      var redirects = 0;
      redirects <= HttpService.maxRedirects;
      redirects++
    ) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(headers);
      final streamed = await client!
          .send(request)
          .timeout(const Duration(seconds: 30));
      final bytes = await streamed.stream.toBytes();
      final responseHeaders = Map<String, String>.from(streamed.headers);
      if (streamed.isRedirect && responseHeaders['location'] != null) {
        if (redirects == HttpService.maxRedirects) {
          throw CatalogHttpException(
            'Too many redirects',
            uri: _redactedUri(initialUri),
          );
        }
        final next = current.resolve(responseHeaders['location']!);
        if (current.scheme == 'https' && next.scheme != 'https') {
          throw CatalogHttpException(
            'HTTPS downgrade redirect rejected',
            uri: _redactedUri(next),
          );
        }
        if (!HttpService.isSameOrigin(current, next)) {
          headers.removeWhere(
            (key, _) => sensitiveHeaders.contains(key.toLowerCase()),
          );
        }
        current = next;
        continue;
      }
      return CatalogResponse(
        statusCode: streamed.statusCode,
        headers: responseHeaders,
        bodyBytes: bytes,
        requestUri: current,
        rateState: _rateState(responseHeaders),
      );
    }
    throw CatalogHttpException(
      'Too many redirects',
      uri: _redactedUri(initialUri),
    );
  }

  CatalogRateState _rateState(Map<String, String> headers) {
    String? header(String name) {
      for (final entry in headers.entries) {
        if (entry.key.toLowerCase() == name) return entry.value;
      }
      return null;
    }

    final limit = int.tryParse(
      header('x-ratelimit-limit') ?? header('ratelimit-limit') ?? '',
    );
    final remaining = int.tryParse(
      header('x-ratelimit-remaining') ?? header('ratelimit-remaining') ?? '',
    );
    final resetRaw = header('x-ratelimit-reset') ?? header('ratelimit-reset');
    DateTime? resetAt;
    final resetSeconds = int.tryParse(resetRaw ?? '');
    if (resetSeconds != null) {
      resetAt = DateTime.fromMillisecondsSinceEpoch(
        resetSeconds * 1000,
        isUtc: true,
      );
    } else if (resetRaw != null) {
      resetAt = DateTime.tryParse(resetRaw)?.toUtc();
    }
    final retryRaw = header('retry-after');
    final retrySeconds = int.tryParse(retryRaw ?? '');
    final retryAfter = retrySeconds == null
        ? null
        : Duration(seconds: retrySeconds);
    resetAt ??= retryAfter == null
        ? null
        : DateTime.now().toUtc().add(retryAfter);
    return CatalogRateState(
      limit: limit,
      remaining: remaining,
      resetAt: resetAt,
      retryAfter: retryAfter,
    );
  }

  CatalogRateState? rateStateFor(ProviderAccount account) =>
      _rateStates[account.id];

  int requestCountFor(ProviderAccount account) =>
      _requestCounts[account.id] ?? 0;

  DateTime? _retryAt(CatalogResponse response) => response.rateState.resetAt;
  bool _isTransient(int statusCode) => statusCode == 429 || statusCode >= 500;

  Uri _redactedUri(Uri uri) => uri.replace(
    queryParameters: {
      for (final entry in uri.queryParameters.entries)
        if (!sensitiveQueryKeys.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    },
  );

  void close() => client?.close();
}

class _ValidatedPayload {
  final List<int> bodyBytes;
  final String? etag;
  final String? lastModified;

  const _ValidatedPayload({
    required this.bodyBytes,
    this.etag,
    this.lastModified,
  });
}
