import 'package:obtainium/catalog/adapters/forge_catalog_adapter.dart';
import 'package:obtainium/catalog/adapters/metrics_support.dart';
import 'package:obtainium/catalog/models.dart';

class ForgejoCatalogAdapter implements ForgeCatalogAdapter {
  final CatalogTransport transport;
  final String apiBaseUrl;
  final String webBaseUrl;

  const ForgejoCatalogAdapter(
    this.transport, {
    this.apiBaseUrl = 'https://codeberg.org/api/v1',
    this.webBaseUrl = 'https://codeberg.org',
  });

  @override
  ProviderKind get kind => ProviderKind.forgejo;
  @override
  String get adapterName => 'forgejo-v1';
  @override
  String get defaultApiBaseUrl => apiBaseUrl;
  @override
  String get defaultWebBaseUrl => webBaseUrl;

  Uri _endpoint(
    String base,
    String path, [
    Map<String, Object?> query = const {},
  ]) {
    final root = Uri.parse(base);
    return root.replace(
      path: '${root.path.replaceFirst(RegExp(r'/$'), '')}$path',
      queryParameters: {
        for (final entry in query.entries)
          if (entry.value != null) entry.key: entry.value.toString(),
      },
    );
  }

  Future<CatalogResponse> _get(
    Uri uri, {
    ProviderAccount? account,
    String? token,
  }) async {
    final response = await transport.get(
      uri,
      provider: kind,
      account: account,
      credentialOverride: token,
      headers: const {'accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      providerError(response);
    }
    return response;
  }

  @override
  Future<AccountValidation> validateAccount({
    required String apiBaseUrl,
    required String webBaseUrl,
    required String token,
  }) async {
    canonicalHttpsBase(apiBaseUrl);
    canonicalHttpsBase(webBaseUrl);
    final response = await _get(_endpoint(apiBaseUrl, '/user'), token: token);
    final data = Map<String, dynamic>.from(response.json! as Map);
    final scopes = response.header('x-oauth-scopes');
    return AccountValidation(
      username: data['login']!.toString(),
      displayName: data['full_name']?.toString(),
      effectiveScopes: scopes,
      broadScopeWarning: scopes == null || scopes.trim().isEmpty,
    );
  }

  @override
  Future<CatalogPage> search(
    CatalogQuery query, {
    ProviderAccount? account,
  }) async {
    final uri =
        query.cursor?.next ??
        _endpoint(account?.apiBaseUrl ?? apiBaseUrl, '/repos/search', {
          'q': query.text.trim().isEmpty ? 'android' : query.text.trim(),
          'topic': query.filters.topics.length == 1
              ? query.filters.topics.single
              : null,
          'includeDesc': true,
          'archived': query.filters.includeArchived ? null : false,
          'sort': query.sort == CatalogSort.stars
              ? 'stars'
              : query.sort == CatalogSort.activity
              ? 'updated'
              : 'alpha',
          'order': query.sort == CatalogSort.name ? 'asc' : 'desc',
          'limit': query.pageSize.clamp(1, 50),
          'page': query.cursor?.page ?? 1,
        });
    final response = await _get(uri, account: account);
    final data = Map<String, dynamic>.from(response.json! as Map);
    final rows = (data['data'] ?? data['items']) as List<dynamic>? ?? const [];
    final now = DateTime.now().toUtc();
    final next = nextLink(response);
    final page = query.cursor?.page ?? 1;
    final hasMore = rows.length == query.pageSize.clamp(1, 50);
    return CatalogPage(
      repositories: rows
          .map(
            (e) => _repository(
              Map<String, dynamic>.from(e as Map),
              now,
              account?.id,
              account?.apiBaseUrl ?? apiBaseUrl,
            ),
          )
          .toList(),
      next: next != null
          ? PageCursor(next: next)
          : hasMore
          ? PageCursor(page: page + 1)
          : null,
      totalCount: data['total_count'] as int?,
      partial: response.rateState.exhausted,
      observedAt: now,
    );
  }

  @override
  Future<CatalogPage> listAccessibleRepositories({
    required ProviderAccount account,
    PageCursor? cursor,
  }) async {
    final uri =
        cursor?.next ??
        _endpoint(account.apiBaseUrl, '/user/repos', {
          'limit': 50,
          'page': cursor?.page ?? 1,
        });
    final response = await _get(uri, account: account);
    final rows = response.json as List<dynamic>;
    final now = DateTime.now().toUtc();
    final page = cursor?.page ?? 1;
    final next = nextLink(response);
    return CatalogPage(
      repositories: rows
          .map(
            (e) => _repository(
              Map<String, dynamic>.from(e as Map),
              now,
              account.id,
              account.apiBaseUrl,
            ),
          )
          .toList(),
      next: next != null
          ? PageCursor(next: next)
          : rows.length == 50
          ? PageCursor(page: page + 1)
          : null,
      observedAt: now,
    );
  }

  ForgeRepository _repository(
    Map<String, dynamic> data,
    DateTime observedAt,
    String? accountId,
    String apiBase,
  ) {
    final owner =
        (data['owner'] as Map?)?['login']?.toString() ??
        data['full_name']?.toString().split('/').first ??
        '';
    final path = data['full_name']?.toString() ?? '$owner/${data['name']}';
    final webUrl = Uri.parse(
      data['html_url']?.toString() ?? '$webBaseUrl/$path',
    );
    return ForgeRepository(
      catalogKey: ForgeRepository.identity(kind, webUrl.host, data['id']!),
      provider: kind,
      host: webUrl.host,
      providerRepositoryId: data['id']!.toString(),
      accountId: accountId,
      webUrl: webUrl,
      apiUrl: _endpoint(apiBase, '/repos/$path'),
      owner: owner,
      path: path,
      name: data['name']!.toString(),
      summary: data['description']?.toString(),
      description: data['description']?.toString(),
      topics: Set<String>.from(data['topics'] as List? ?? const []),
      categories: const {},
      license: (data['license'] as Map?)?['spdx_id']?.toString(),
      isPrivate: data['private'] == true,
      archived: data['archived'] == true,
      fork: data['fork'] == true || data['parent'] != null,
      apkAvailability: AvailabilityState.unknown,
      deviceCompatibility: AvailabilityState.unknown,
      lastActivity: parseDate(data['updated_at'] ?? data['pushed_at']),
      observedAt: observedAt,
      metrics: MetricSnapshot(
        stars: (data['stars_count'] ?? data['stargazers_count']) as int?,
        forks: data['forks_count'] as int?,
        openIssues: data['open_issues_count'] as int?,
        observedAt: observedAt,
      ),
    );
  }

  @override
  Future<ForgeRepository> fetchRepository(
    Uri repositoryUrl, {
    ProviderAccount? account,
  }) async {
    final parts = repositoryUrl.pathSegments
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.length < 2) {
      throw const FormatException('Forge repository URL requires owner/name');
    }
    final base = account?.apiBaseUrl ?? apiBaseUrl;
    final response = await _get(
      _endpoint(base, '/repos/${parts[0]}/${parts[1]}'),
      account: account,
    );
    return _repository(
      Map<String, dynamic>.from(response.json! as Map),
      DateTime.now().toUtc(),
      account?.id,
      base,
    );
  }

  @override
  Future<List<ReleaseSummary>> fetchReleases(
    ForgeRepository repository, {
    ProviderAccount? account,
    int maxPages = 3,
  }) async {
    final base = account?.apiBaseUrl ?? apiBaseUrl;
    Uri? uri = _endpoint(base, '/repos/${repository.path}/releases', {
      'limit': 50,
      'page': 1,
    });
    final result = <ReleaseSummary>[];
    for (var page = 0; page < maxPages && uri != null; page++) {
      final response = await _get(uri, account: account);
      final rows = response.json as List<dynamic>;
      for (final raw in rows) {
        final data = Map<String, dynamic>.from(raw as Map);
        result.add(
          ReleaseSummary(
            id: data['id'].toString(),
            version:
                data['tag_name']?.toString() ?? data['name']?.toString() ?? '',
            name: data['name']?.toString(),
            changelog: data['body']?.toString(),
            publishedAt: parseDate(data['published_at'] ?? data['created_at']),
            prerelease: data['prerelease'] == true,
            assets: (data['assets'] as List<dynamic>? ?? const []).map((
              rawAsset,
            ) {
              final asset = rawAsset as Map;
              return ReleaseAsset(
                name: asset['name']!.toString(),
                downloadUrl: Uri.parse(
                  asset['browser_download_url']!.toString(),
                ),
                size: asset['size'] as int?,
                contentType:
                    asset['content_type']?.toString() ??
                    'application/octet-stream',
              );
            }).toList(),
          ),
        );
      }
      final next = nextLink(response);
      uri =
          next ??
          (rows.length == 50
              ? _endpoint(base, '/repos/${repository.path}/releases', {
                  'limit': 50,
                  'page': page + 2,
                })
              : null);
    }
    return result;
  }

  Future<Set<String>> capabilities({ProviderAccount? account}) async {
    final base = account?.apiBaseUrl ?? apiBaseUrl;
    final capabilities = <String>{};
    try {
      final response = await _get(
        _endpoint(base, '/settings/api'),
        account: account,
      );
      final data = response.json;
      if (data is Map) capabilities.addAll(data.keys.map((e) => e.toString()));
    } on CatalogHttpException {
      return capabilities;
    }
    try {
      final root = Uri.parse(base);
      final openApi = root.replace(path: '/swagger.v1.json', query: null);
      final response = await _get(openApi, account: account);
      final data = response.json;
      if (data is Map && data['paths'] is Map) {
        capabilities.addAll(
          (data['paths'] as Map).keys.map((e) => e.toString()),
        );
      }
    } on CatalogHttpException {
      // Older instances may expose only the settings endpoint.
    }
    return capabilities;
  }

  @override
  Future<MetricSnapshot> fetchMetrics(
    ForgeRepository repository, {
    ProviderAccount? account,
    DateTime? now,
  }) async {
    final observedAt = (now ?? DateTime.now()).toUtc();
    final cutoff90 = observedAt.subtract(const Duration(days: 90));
    final cutoff180 = observedAt.subtract(const Duration(days: 180));
    final cutoff365 = observedAt.subtract(const Duration(days: 365));
    final base = account?.apiBaseUrl ?? apiBaseUrl;
    final estimated = <String>{};
    final unavailable = <String>{'allTimeContributors'};
    final authors = <String>{};
    var commits = 0;
    DateTime? newestCommit;
    try {
      for (var page = 1; page <= 5; page++) {
        final response = await _get(
          _endpoint(base, '/repos/${repository.path}/commits', {
            'since': cutoff90.toIso8601String(),
            'until': observedAt.toIso8601String(),
            'limit': 100,
            'page': page,
          }),
          account: account,
        );
        final rows = response.json as List<dynamic>;
        commits += rows.length;
        for (final raw in rows) {
          final commit = raw as Map;
          final user = commit['author'] as Map?;
          final commitAuthor = (commit['commit'] as Map?)?['author'] as Map?;
          if (!isAutomatedContributor(
            login: user?['login'],
            type: user?['type'],
          )) {
            final identity = normalizedContributorIdentity(
              id: user?['id'],
              login: user?['login'],
              email: commitAuthor?['email'],
              name: commitAuthor?['name'],
            );
            if (identity.isNotEmpty) authors.add(identity);
          }
          newestCommit ??= parseDate(
            commitAuthor?['date'] ?? commit['created'],
          );
        }
        if (rows.length < 100) break;
        if (page == 5) {
          estimated.addAll({'commits90d', 'activeContributors90d'});
        }
      }
    } on CatalogHttpException {
      unavailable.addAll({
        'commits90d',
        'activeContributors90d',
        'daysSinceCommit',
      });
    }

    var releases = repository.releases;
    if (releases.isEmpty) {
      try {
        releases = await fetchReleases(repository, account: account);
      } on CatalogHttpException {
        unavailable.addAll({'releases365d', 'daysSinceRelease'});
      }
    }
    final datedReleases = releases.where((e) => e.publishedAt != null).toList()
      ..sort((a, b) => b.publishedAt!.compareTo(a.publishedAt!));

    final sampled = <SampledIssue>[];
    try {
      final issuesResponse = await _get(
        _endpoint(base, '/repos/${repository.path}/issues', {
          'state': 'all',
          'since': cutoff180.toIso8601String(),
          'type': 'issues',
          'limit': 20,
          'page': 1,
        }),
        account: account,
      );
      final issues =
          (issuesResponse.json as List<dynamic>)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .where((e) => e['pull_request'] == null)
              .where(
                (e) =>
                    !(parseDate(e['created_at'])?.isBefore(cutoff180) ?? true),
              )
              .toList()
            ..sort(
              (a, b) => (parseDate(b['updated_at']) ?? DateTime(0)).compareTo(
                parseDate(a['updated_at']) ?? DateTime(0),
              ),
            );
      for (final issue in issues.take(20)) {
        final created = parseDate(issue['created_at']);
        final author = (issue['user'] as Map?)?['login']?.toString();
        DateTime? firstResponse;
        final comments = await _get(
          _endpoint(
            base,
            '/repos/${repository.path}/issues/${issue['number'] ?? issue['index']}/comments',
            {'limit': 100, 'page': 1},
          ),
          account: account,
        );
        for (final raw in comments.json as List<dynamic>) {
          final comment = raw as Map;
          final user = comment['user'] as Map?;
          final login = user?['login']?.toString();
          if (login == author ||
              isAutomatedContributor(login: login, type: user?['type'])) {
            continue;
          }
          final createdAt = parseDate(comment['created_at']);
          if (createdAt != null &&
              (firstResponse == null || createdAt.isBefore(firstResponse))) {
            firstResponse = createdAt;
          }
        }
        sampled.add(
          SampledIssue(
            responded: firstResponse != null,
            actioned:
                issue['state'] == 'closed' ||
                issue['assignee'] != null ||
                (issue['assignees'] as List?)?.isNotEmpty == true ||
                (issue['labels'] as List?)?.isNotEmpty == true ||
                issue['milestone'] != null,
            closed: issue['state'] == 'closed',
            firstResponseHours: created == null || firstResponse == null
                ? null
                : firstResponse.difference(created).inSeconds / 3600,
          ),
        );
      }
    } on CatalogHttpException {
      unavailable.addAll({
        'responseRate',
        'actionRate',
        'closeRate',
        'medianFirstResponseHours',
      });
    }
    final care = deriveIssueCare(sampled);
    unavailable.add('allTimeContributors');
    if (care.sampleSize == 0) {
      unavailable.addAll({
        'responseRate',
        'actionRate',
        'closeRate',
        'medianFirstResponseHours',
      });
    }
    return MetricSnapshot(
      stars: repository.metrics?.stars,
      forks: repository.metrics?.forks,
      openIssues: repository.metrics?.openIssues,
      commits90d: unavailable.contains('commits90d') ? null : commits,
      activeContributors90d: unavailable.contains('activeContributors90d')
          ? null
          : authors.length,
      releases365d: unavailable.contains('releases365d')
          ? null
          : datedReleases
                .where((e) => !e.publishedAt!.isBefore(cutoff365))
                .length,
      daysSinceCommit:
          unavailable.contains('daysSinceCommit') || newestCommit == null
          ? null
          : wholeDaysBetween(observedAt, newestCommit),
      daysSinceRelease:
          unavailable.contains('daysSinceRelease') || datedReleases.isEmpty
          ? null
          : wholeDaysBetween(observedAt, datedReleases.first.publishedAt),
      issueSampleSize: care.sampleSize,
      responseRate: care.responseRate,
      actionRate: care.actionRate,
      closeRate: care.closeRate,
      medianFirstResponseHours: care.medianFirstResponseHours,
      observedAt: observedAt,
      estimatedFields: estimated,
      unavailableFields: unavailable,
    );
  }
}
