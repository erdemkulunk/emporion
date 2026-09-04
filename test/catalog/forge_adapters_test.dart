import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/catalog/adapters/forge_catalog_adapter.dart';
import 'package:obtainium/catalog/adapters/forgejo_catalog_adapter.dart';
import 'package:obtainium/catalog/adapters/github_catalog_adapter.dart';
import 'package:obtainium/catalog/adapters/gitlab_catalog_adapter.dart';
import 'package:obtainium/catalog/models.dart';

void main() {
  final account = ProviderAccount.validated(
    provider: ProviderKind.github,
    apiBaseUrl: 'https://api.github.com',
    webBaseUrl: 'https://github.com',
    label: 'Private',
    username: 'tester',
    validatedAt: DateTime.utc(2026),
  );

  test(
    'GitHub private listing preserves account and absolute pagination',
    () async {
      final transport = _ScriptedTransport([
        _jsonResponse(
          Uri.parse('https://api.github.com/user/repos'),
          [
            {
              'id': 7,
              'name': 'secret',
              'full_name': 'tester/secret',
              'html_url': 'https://github.com/tester/secret',
              'url': 'https://api.github.com/repos/tester/secret',
              'private': true,
              'archived': false,
              'fork': false,
              'owner': {'login': 'tester'},
            },
          ],
          headers: {
            'link': '<https://api.github.com/user/repos?page=2>; rel="next"',
          },
        ),
      ]);

      final page = await GitHubCatalogAdapter(
        transport,
      ).listAccessibleRepositories(account: account);

      expect(page.repositories.single.isPrivate, isTrue);
      expect(page.repositories.single.accountId, account.id);
      expect(page.repositories.single.path, 'tester/secret');
      expect(
        page.next?.next.toString(),
        'https://api.github.com/user/repos?page=2',
      );
      expect(transport.requests.single.accountId, account.id);
    },
  );

  test('GitLab private listing honors x-next-page', () async {
    final gitlabAccount = ProviderAccount.validated(
      provider: ProviderKind.gitlab,
      apiBaseUrl: 'https://gitlab.example/api/v4',
      webBaseUrl: 'https://gitlab.example',
      label: 'GitLab',
      username: 'tester',
      validatedAt: DateTime.utc(2026),
    );
    final transport = _ScriptedTransport([
      _jsonResponse(
        Uri.parse('https://gitlab.example/api/v4/projects'),
        [
          {
            'id': 11,
            'name': 'internal',
            'path': 'internal',
            'path_with_namespace': 'team/internal',
            'web_url': 'https://gitlab.example/team/internal',
            'visibility': 'private',
            'archived': false,
            'namespace': {'full_path': 'team'},
          },
        ],
        headers: {'x-next-page': '2', 'x-total': '101'},
      ),
    ]);

    final page = await GitLabCatalogAdapter(
      transport,
    ).listAccessibleRepositories(account: gitlabAccount);

    expect(page.repositories.single.isPrivate, isTrue);
    expect(page.repositories.single.accountId, gitlabAccount.id);
    expect(page.next?.page, 2);
    expect(page.totalCount, 101);
  });

  test('Forgejo search uses bounded page cursor when a page is full', () async {
    final transport = _ScriptedTransport([
      _jsonResponse(Uri.parse('https://codeberg.org/api/v1/repos/search'), {
        'data': [
          {
            'id': 3,
            'name': 'client',
            'full_name': 'team/client',
            'html_url': 'https://codeberg.org/team/client',
            'private': false,
            'archived': false,
            'fork': false,
            'owner': {'login': 'team'},
          },
        ],
        'total_count': 2,
      }),
    ]);

    final page = await ForgejoCatalogAdapter(
      transport,
    ).search(const CatalogQuery(text: 'client', pageSize: 1));

    expect(page.repositories.single.provider, ProviderKind.forgejo);
    expect(page.next?.page, 2);
    expect(transport.requests.single.uri.queryParameters['limit'], '1');
    expect(transport.requests.single.uri.queryParameters['archived'], 'false');
  });

  test('provider errors map every status without exposing response bodies', () {
    for (final status in [401, 403, 404, 429, 500, 503]) {
      final response = _jsonResponse(
        Uri.parse('https://api.example.invalid/private'),
        {'message': 'secret echoed by upstream', 'token': 'must-not-leak'},
        statusCode: status,
      );

      expect(
        () => providerError(response),
        throwsA(
          isA<CatalogHttpException>()
              .having((error) => error.statusCode, 'statusCode', status)
              .having(
                (error) => error.authorizationFailure,
                'authorizationFailure',
                status == 401 || status == 403,
              )
              .having(
                (error) => error.toString(),
                'message',
                allOf(
                  isNot(contains('secret echoed')),
                  isNot(contains('must-not-leak')),
                ),
              ),
        ),
      );
    }
  });

  test('GitHub reports incomplete and exhausted search pages', () async {
    final transport = _ScriptedTransport([
      CatalogResponse(
        statusCode: 200,
        headers: const {},
        bodyBytes: utf8.encode(
          jsonEncode({
            'total_count': 1,
            'incomplete_results': true,
            'items': [
              {
                'id': 1,
                'name': 'app',
                'full_name': 'team/app',
                'html_url': 'https://github.com/team/app',
                'url': 'https://api.github.com/repos/team/app',
                'private': false,
                'archived': false,
                'fork': false,
                'owner': {'login': 'team'},
              },
            ],
          }),
        ),
        requestUri: Uri.parse('https://api.github.com/search/repositories'),
        rateState: const CatalogRateState(limit: 10, remaining: 0),
      ),
    ]);

    final page = await GitHubCatalogAdapter(
      transport,
    ).search(const CatalogQuery(text: 'app'));

    expect(page.incomplete, isTrue);
    expect(page.partial, isTrue);
    expect(page.repositories, hasLength(1));
  });

  test('release assets recognize only supported install containers', () {
    ReleaseAsset asset(String name) => ReleaseAsset(
      name: name,
      downloadUrl: Uri.parse('https://downloads.example/$name'),
      contentType: 'application/octet-stream',
    );

    for (final name in ['app.apk', 'app.APKS', 'app.apkm', 'app.xapk']) {
      expect(asset(name).isInstallable, isTrue, reason: name);
    }
    for (final name in ['app.aab', 'app.zip', 'app.apk.sig', 'app']) {
      expect(asset(name).isInstallable, isFalse, reason: name);
    }
  });
  test(
    'GitHub metrics sample issues and exclude bots and pull requests',
    () async {
      final now = DateTime.utc(2026, 1, 15);
      final transport = _ScriptedTransport([
        _jsonResponse(Uri.parse('https://api.github.com/search/repositories'), {
          'total_count': 1,
          'incomplete_results': false,
          'items': [
            {
              'id': 9,
              'name': 'metrics',
              'full_name': 'team/metrics',
              'html_url': 'https://github.com/team/metrics',
              'url': 'https://api.github.com/repos/team/metrics',
              'private': false,
              'archived': false,
              'fork': false,
              'owner': {'login': 'team'},
              'stargazers_count': 10,
              'forks_count': 2,
              'open_issues_count': 3,
            },
          ],
        }),
        _jsonResponse(
          Uri.parse('https://api.github.com/repos/team/metrics/commits'),
          [
            {
              'author': {'id': 1, 'login': 'human', 'type': 'User'},
              'commit': {
                'author': {
                  'date': '2026-01-14T00:00:00Z',
                  'email': 'human@example.com',
                },
              },
            },
            {
              'author': {'id': 2, 'login': 'renovate[bot]', 'type': 'Bot'},
              'commit': {
                'author': {'date': '2026-01-13T00:00:00Z'},
              },
            },
          ],
        ),
        _jsonResponse(
          Uri.parse('https://api.github.com/repos/team/metrics/contributors'),
          [
            {'login': 'human'},
          ],
        ),
        _jsonResponse(
          Uri.parse('https://api.github.com/repos/team/metrics/releases'),
          [
            {
              'id': 1,
              'tag_name': 'v1.0.0',
              'published_at': '2026-01-10T00:00:00Z',
              'prerelease': false,
              'assets': const [],
            },
          ],
        ),
        _jsonResponse(
          Uri.parse('https://api.github.com/repos/team/metrics/issues'),
          [
            {
              'number': 1,
              'state': 'closed',
              'created_at': '2026-01-01T00:00:00Z',
              'comments_url':
                  'https://api.github.com/repos/team/metrics/issues/1/comments',
              'user': {'login': 'reporter'},
              'labels': [
                {'name': 'fixed'},
              ],
            },
            {
              'number': 2,
              'state': 'open',
              'created_at': '2026-01-02T00:00:00Z',
              'comments_url':
                  'https://api.github.com/repos/team/metrics/issues/2/comments',
              'user': {'login': 'other'},
              'labels': const [],
            },
            {
              'number': 3,
              'state': 'closed',
              'created_at': '2026-01-03T00:00:00Z',
              'comments_url':
                  'https://api.github.com/repos/team/metrics/issues/3/comments',
              'user': {'login': 'reporter'},
              'pull_request': {'url': 'https://api.github.com/pulls/3'},
            },
          ],
        ),
        _jsonResponse(
          Uri.parse(
            'https://api.github.com/repos/team/metrics/issues/1/comments',
          ),
          [
            {
              'created_at': '2026-01-01T01:00:00Z',
              'user': {'login': 'helper-bot', 'type': 'Bot'},
            },
            {
              'created_at': '2026-01-01T02:00:00Z',
              'user': {'login': 'maintainer', 'type': 'User'},
            },
          ],
        ),
        _jsonResponse(
          Uri.parse(
            'https://api.github.com/repos/team/metrics/issues/2/comments',
          ),
          const [],
        ),
      ]);
      final adapter = GitHubCatalogAdapter(transport);
      final repository = (await adapter.search(
        const CatalogQuery(text: 'metrics'),
      )).repositories.single;

      final metrics = await adapter.fetchMetrics(repository, now: now);

      expect(metrics.commits90d, 2);
      expect(metrics.activeContributors90d, 1);
      expect(metrics.allTimeContributors, 1);
      expect(metrics.releases365d, 1);
      expect(metrics.daysSinceCommit, 1);
      expect(metrics.daysSinceRelease, 5);
      expect(metrics.issueSampleSize, 2);
      expect(metrics.responseRate, 0.5);
      expect(metrics.actionRate, 0.5);
      expect(metrics.closeRate, 0.5);
      expect(metrics.medianFirstResponseHours, 2);
    },
  );
}

class _RequestRecord {
  final Uri uri;
  final String? accountId;

  const _RequestRecord(this.uri, this.accountId);
}

class _ScriptedTransport implements CatalogTransport {
  final List<CatalogResponse> responses;
  final List<_RequestRecord> requests = [];

  _ScriptedTransport(this.responses);

  @override
  Future<CatalogResponse> get(
    Uri uri, {
    required ProviderKind provider,
    ProviderAccount? account,
    String? credentialOverride,
    Map<String, String> headers = const {},
  }) async {
    requests.add(_RequestRecord(uri, account?.id));
    if (responses.isEmpty) throw StateError('Unexpected request: $uri');
    final scripted = responses.removeAt(0);
    return CatalogResponse(
      statusCode: scripted.statusCode,
      headers: scripted.headers,
      bodyBytes: scripted.bodyBytes,
      requestUri: uri,
      rateState: scripted.rateState,
    );
  }
}

CatalogResponse _jsonResponse(
  Uri uri,
  Object body, {
  Map<String, String> headers = const {},
  int statusCode = 200,
}) => CatalogResponse(
  statusCode: statusCode,
  headers: headers,
  bodyBytes: utf8.encode(jsonEncode(body)),
  requestUri: uri,
);
