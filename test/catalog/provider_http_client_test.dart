import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:obtainium/catalog/adapters/forge_catalog_adapter.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/catalog/network/provider_http_client.dart';

void main() {
  test(
    'adds provider credential and strips it on cross-origin redirect',
    () async {
      final requests = <http.BaseRequest>[];
      final client = ProviderHttpClient(
        credentialReader: const _CredentialReader('secret-token'),
        client: _StreamingClient((request) async {
          requests.add(request);
          if (requests.length == 1) {
            return _response(
              request,
              302,
              headers: {'location': 'https://objects.example/download'},
              isRedirect: true,
            );
          }
          return _response(request, 200, body: '{}');
        }),
      );
      await client.get(
        Uri.parse('https://api.github.com/resource'),
        provider: ProviderKind.github,
        account: _account(),
      );

      expect(requests.first.headers['authorization'], 'Bearer secret-token');
      expect(requests.last.url.host, 'objects.example');
      expect(requests.last.headers, isNot(contains('authorization')));
    },
  );

  test('retains credentials only for same-origin redirects', () async {
    final requests = <http.BaseRequest>[];
    final client = ProviderHttpClient(
      credentialReader: const _CredentialReader('secret-token'),
      client: _StreamingClient((request) async {
        requests.add(request);
        if (requests.length == 1) {
          return _response(
            request,
            307,
            headers: {'location': '/next'},
            isRedirect: true,
          );
        }
        return _response(request, 200, body: '{}');
      }),
    );
    await client.get(
      Uri.parse('https://api.github.com/resource'),
      provider: ProviderKind.github,
      account: _account(),
    );

    expect(requests.last.headers['authorization'], 'Bearer secret-token');
  });

  test('rejects HTTPS downgrade and redacts sensitive query values', () async {
    final client = ProviderHttpClient(
      credentialReader: const _CredentialReader('secret-token'),
      client: MockClient((_) async => http.Response('', 500)),
    );

    Object? error;
    try {
      await client.get(
        Uri.parse('http://api.example/resource?token=query-secret&safe=yes'),
        provider: ProviderKind.github,
        account: _account(),
      );
    } catch (caught) {
      error = caught;
    }
    expect(error, isA<CatalogHttpException>());
    expect(error.toString(), isNot(contains('query-secret')));
    expect(
      (error as CatalogHttpException).uri.toString(),
      endsWith('?safe=yes'),
    );
  });

  test('reuses validated ETag bodies on 304', () async {
    final requests = <http.Request>[];
    var call = 0;
    final client = ProviderHttpClient(
      credentialReader: const _CredentialReader(null),
      client: MockClient((request) async {
        requests.add(request);
        call++;
        if (call == 1) {
          return http.Response(
            '{"cached":true}',
            200,
            headers: {'etag': '"fixture"'},
          );
        }
        return http.Response('', 304);
      }),
    );
    final uri = Uri.parse('https://api.example/resource');

    await client.get(uri, provider: ProviderKind.github);
    final cached = await client.get(uri, provider: ProviderKind.github);

    expect(requests.last.headers['if-none-match'], '"fixture"');
    expect(jsonDecode(utf8.decode(cached.bodyBytes)), {'cached': true});
  });

  test('retries transient failures with bounded exponential delays', () async {
    final delays = <Duration>[];
    var calls = 0;
    final client = ProviderHttpClient(
      credentialReader: const _CredentialReader(null),
      client: MockClient((_) async {
        calls++;
        return calls < 5 ? http.Response('', 500) : http.Response('{}', 200);
      }),
      delay: (duration) async => delays.add(duration),
    );

    final response = await client.get(
      Uri.parse('https://api.example/resource'),
      provider: ProviderKind.gitlab,
    );

    expect(response.statusCode, 200);
    expect(calls, 5);
    expect(delays, const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ]);
  });

  test(
    'honors long Retry-After without sleeping and enforces request budgets',
    () async {
      var delayed = false;
      final rateLimited = ProviderHttpClient(
        credentialReader: const _CredentialReader(null),
        client: MockClient(
          (_) async => http.Response('', 429, headers: {'retry-after': '3600'}),
        ),
        delay: (_) async => delayed = true,
      );
      await expectLater(
        rateLimited.get(
          Uri.parse('https://api.example/resource'),
          provider: ProviderKind.github,
        ),
        throwsA(
          isA<CatalogHttpException>()
              .having((error) => error.statusCode, 'statusCode', 429)
              .having((error) => error.retryAt, 'retryAt', isNotNull),
        ),
      );
      expect(delayed, isFalse);

      final bounded = ProviderHttpClient(
        credentialReader: const _CredentialReader(null),
        client: MockClient((_) async => http.Response('{}', 200)),
        maxRequestsPerQueue: 1,
      );
      final uri = Uri.parse('https://api.example/resource');
      await bounded.get(uri, provider: ProviderKind.forgejo);
      await expectLater(
        bounded.get(uri, provider: ProviderKind.forgejo),
        throwsA(isA<CatalogHttpException>()),
      );
    },
  );
}

class _CredentialReader implements CredentialReader {
  final String? credential;

  const _CredentialReader(this.credential);

  @override
  Future<String?> get(ProviderAccount account) async => credential;
}

ProviderAccount _account() => ProviderAccount(
  id: 'fixture-account',
  provider: ProviderKind.github,
  apiBaseUrl: 'https://api.github.com',
  webBaseUrl: 'https://github.com',
  label: 'Fixture',
  username: 'fixture',
  validatedAt: DateTime.utc(2026),
);

class _StreamingClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  _StreamingClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

http.StreamedResponse _response(
  http.BaseRequest request,
  int statusCode, {
  String body = '',
  Map<String, String> headers = const {},
  bool isRedirect = false,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(body)),
  statusCode,
  headers: headers,
  request: request,
  isRedirect: isRedirect,
);
