import 'package:obtainium/catalog/adapters/forge_catalog_adapter.dart';
import 'package:obtainium/catalog/adapters/metrics_support.dart';
import 'package:obtainium/catalog/models.dart';

class GitHubCatalogAdapter implements ForgeCatalogAdapter {
  final CatalogTransport transport;

  const GitHubCatalogAdapter(this.transport);

  @override
  ProviderKind get kind => ProviderKind.github;
  @override
  String get adapterName => 'github-v1';
  @override
  String get defaultApiBaseUrl => 'https://api.github.com';
  @override
  String get defaultWebBaseUrl => 'https://github.com';

  Uri _endpoint(
    String base,
    String path, [
    Map<String, Object?> query = const {},
  ]) {
    final root = Uri.parse(base);
    final rootPath = root.path.replaceFirst(RegExp(r'/$'), '');
    return root.replace(
      path: '$rootPath$path',
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
    Map<String, String> headers = const {},
  }) async {
    final response = await transport.get(
      uri,
      provider: kind,
      account: account,
      credentialOverride: token,
      headers: {'accept': 'application/vnd.github+json', ...headers},
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
      displayName: data['name']?.toString(),
      effectiveScopes: scopes,
      broadScopeWarning:
          scopes?.split(',').map((e) => e.trim()).contains('repo') ?? false,
    );
  }

  @override
  Future<CatalogPage> search(
    CatalogQuery query, {
    ProviderAccount? account,
  }) async {
    if (query.cursor?.next case final next?) {
      return _searchResponse(
        await _get(next, account: account),
        account: account,
      );
    }
    final terms = <String>[
      if (query.text.trim().isNotEmpty) query.text.trim(),
      if (!query.filters.includeArchived) 'archived:false',
      if (!query.filters.includeForks) 'fork:false',
      if (query.filters.topics.length == 1)
        'topic:${query.filters.topics.single}',
    ];
    final sort = switch (query.sort) {
      CatalogSort.stars => 'stars',
      CatalogSort.activity => 'updated',
      _ => null,
    };
    final uri = _endpoint(defaultApiBaseUrl, '/search/repositories', {
      'q': terms.isEmpty ? 'topic:android archived:false' : terms.join(' '),
      'sort': sort,
      'order': sort == null ? null : 'desc',
      'per_page': query.pageSize.clamp(1, 100),
      'page': query.cursor?.page ?? 1,
    });
    return _searchResponse(await _get(uri, account: account), account: account);
  }

  CatalogPage _searchResponse(
    CatalogResponse response, {
    ProviderAccount? account,
  }) {
    final data = Map<String, dynamic>.from(response.json! as Map);
    final now = DateTime.now().toUtc();
    final next = nextLink(response);
    return CatalogPage(
      repositories: (data['items'] as List<dynamic>? ?? const [])
          .map(
            (e) => _repository(
              Map<String, dynamic>.from(e as Map),
              now,
              account?.id,
            ),
          )
          .toList(),
      next: next == null ? null : PageCursor(next: next),
      partial: response.rateState.exhausted,
      incomplete: data['incomplete_results'] == true,
      totalCount: data['total_count'] as int?,
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
          'visibility': 'all',
          'affiliation': 'owner,collaborator,organization_member',
          'sort': 'updated',
          'direction': 'desc',
          'per_page': 100,
          'page': cursor?.page ?? 1,
        });
    final response = await _get(uri, account: account);
    final now = DateTime.now().toUtc();
    final next = nextLink(response);
    return CatalogPage(
      repositories: (response.json as List<dynamic>)
          .map(
            (e) => _repository(
              Map<String, dynamic>.from(e as Map),
              now,
              account.id,
            ),
          )
          .toList(),
      next: next == null ? null : PageCursor(next: next),
      observedAt: now,
    );
  }

  @override
  Future<ForgeRepository> fetchRepository(
    Uri repositoryUrl, {
    ProviderAccount? account,
  }) async {
    final segments = repositoryUrl.pathSegments
        .where((e) => e.isNotEmpty)
        .toList();
    if (segments.length < 2) {
      throw const FormatException('GitHub repository URL requires owner/name');
    }
    final base = account?.apiBaseUrl ?? defaultApiBaseUrl;
    final response = await _get(
      _endpoint(
        base,
        '/repos/${Uri.encodeComponent(segments[0])}/${Uri.encodeComponent(segments[1])}',
      ),
      account: account,
    );
    return _repository(
      Map<String, dynamic>.from(response.json! as Map),
      DateTime.now().toUtc(),
      account?.id,
    );
  }

  ForgeRepository _repository(
    Map<String, dynamic> data,
    DateTime observedAt,
    String? accountId,
  ) {
    final owner =
        (data['owner'] as Map?)?['login']?.toString() ??
        data['full_name']?.toString().split('/').first ??
        '';
    final path = data['full_name']?.toString() ?? '$owner/${data['name']}';
    final host = Uri.parse(
      data['html_url']?.toString() ?? defaultWebBaseUrl,
    ).host;
    final metrics = MetricSnapshot(
      stars: data['stargazers_count'] as int?,
      forks: data['forks_count'] as int?,
      openIssues: data['open_issues_count'] as int?,
      observedAt: observedAt,
    );
    return ForgeRepository(
      catalogKey: ForgeRepository.identity(kind, host, data['id']!),
      provider: kind,
      host: host,
      providerRepositoryId: data['id']!.toString(),
      accountId: accountId,
      webUrl: Uri.parse(data['html_url']!.toString()),
      apiUrl: Uri.parse(data['url']!.toString()),
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
      fork: data['fork'] == true,
      apkAvailability: AvailabilityState.unknown,
      deviceCompatibility: AvailabilityState.unknown,
      lastActivity: parseDate(data['pushed_at'] ?? data['updated_at']),
      observedAt: observedAt,
      metrics: metrics,
    );
  }

  @override
  Future<List<ReleaseSummary>> fetchReleases(
    ForgeRepository repository, {
    ProviderAccount? account,
    int maxPages = 3,
  }) async {
    Uri? uri = _endpoint(
      account?.apiBaseUrl ?? defaultApiBaseUrl,
      '/repos/${repository.path}/releases',
      {'per_page': 100, 'page': 1},
    );
    final releases = <ReleaseSummary>[];
    for (var page = 0; page < maxPages && uri != null; page++) {
      final response = await _get(uri, account: account);
      for (final raw in response.json as List<dynamic>) {
        final data = Map<String, dynamic>.from(raw as Map);
        releases.add(
          ReleaseSummary(
            id: data['id'].toString(),
            version:
                data['tag_name']?.toString() ?? data['name']?.toString() ?? '',
            name: data['name']?.toString(),
            changelog: data['body']?.toString(),
            publishedAt: parseDate(data['published_at'] ?? data['created_at']),
            prerelease: data['prerelease'] == true,
            assets: (data['assets'] as List<dynamic>? ?? const []).map((asset) {
              final item = Map<String, dynamic>.from(asset as Map);
              return ReleaseAsset(
                name: item['name']!.toString(),
                downloadUrl: Uri.parse(
                  item['browser_download_url']!.toString(),
                ),
                size: item['size'] as int?,
                sha256: item['digest']?.toString().replaceFirst('sha256:', ''),
                contentType:
                    item['content_type']?.toString() ??
                    'application/octet-stream',
              );
            }).toList(),
          ),
        );
      }
      uri = nextLink(response);
    }
    return releases;
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
    final estimated = <String>{};
    final unavailable = <String>{};

    final contributorIds = <String>{};
    var commits = 0;
    DateTime? newestCommit;
    Uri? commitsUri = _endpoint(
      account?.apiBaseUrl ?? defaultApiBaseUrl,
      '/repos/${repository.path}/commits',
      {'since': cutoff90.toIso8601String(), 'per_page': 100, 'page': 1},
    );
    try {
      for (var page = 0; page < 5 && commitsUri != null; page++) {
        final response = await _get(commitsUri, account: account);
        final rows = response.json as List<dynamic>;
        commits += rows.length;
        for (final raw in rows) {
          final commit = Map<String, dynamic>.from(raw as Map);
          final author = commit['author'] as Map?;
          final commitAuthor = (commit['commit'] as Map?)?['author'] as Map?;
          final login = author?['login'];
          if (!isAutomatedContributor(login: login, type: author?['type'])) {
            final identity = normalizedContributorIdentity(
              id: author?['id'],
              login: login,
              email: commitAuthor?['email'],
              name: commitAuthor?['name'],
            );
            if (identity.isNotEmpty) contributorIds.add(identity);
          }
          newestCommit ??= parseDate(commitAuthor?['date']);
        }
        final next = nextLink(response);
        if (page == 4 && next != null) {
          estimated.addAll({'commits90d', 'activeContributors90d'});
        }
        commitsUri = next;
      }
    } on CatalogHttpException {
      unavailable.addAll({
        'commits90d',
        'activeContributors90d',
        'daysSinceCommit',
      });
    }

    int? allTimeContributors;
    try {
      final response = await _get(
        _endpoint(
          account?.apiBaseUrl ?? defaultApiBaseUrl,
          '/repos/${repository.path}/contributors',
          {'anon': 'true', 'per_page': 100, 'page': 1},
        ),
        account: account,
      );
      final rows = response.json as List<dynamic>;
      allTimeContributors = _lastPage(response.header('link')) ?? rows.length;
      if (nextLink(response) != null &&
          _lastPage(response.header('link')) == null) {
        estimated.add('allTimeContributors');
      }
    } on CatalogHttpException {
      unavailable.add('allTimeContributors');
    }

    var releases = repository.releases;
    if (releases.isEmpty) {
      try {
        releases = await fetchReleases(
          repository,
          account: account,
          maxPages: 3,
        );
      } on CatalogHttpException {
        unavailable.addAll({'releases365d', 'daysSinceRelease'});
      }
    }
    final datedReleases = releases.where((e) => e.publishedAt != null).toList()
      ..sort((a, b) => b.publishedAt!.compareTo(a.publishedAt!));
    final releases365 = datedReleases
        .where((e) => !e.publishedAt!.isBefore(cutoff365))
        .length;

    final sampledIssues = <SampledIssue>[];
    try {
      final response = await _get(
        _endpoint(
          account?.apiBaseUrl ?? defaultApiBaseUrl,
          '/repos/${repository.path}/issues',
          {
            'state': 'all',
            'sort': 'updated',
            'direction': 'desc',
            'since': cutoff180.toIso8601String(),
            'per_page': 100,
            'page': 1,
          },
        ),
        account: account,
      );
      final issues = (response.json as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((e) => !e.containsKey('pull_request'))
          .where(
            (e) => !(parseDate(e['created_at'])?.isBefore(cutoff180) ?? true),
          )
          .take(20);
      for (final issue in issues) {
        final created = parseDate(issue['created_at']);
        final author = (issue['user'] as Map?)?['login']?.toString();
        DateTime? firstResponse;
        final commentsUrl = Uri.parse(
          issue['comments_url']!.toString(),
        ).replace(queryParameters: {'per_page': '100', 'page': '1'});
        final commentsResponse = await _get(commentsUrl, account: account);
        for (final raw in commentsResponse.json as List<dynamic>) {
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
        sampledIssues.add(
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
    final issueCare = deriveIssueCare(sampledIssues);
    if (issueCare.sampleSize == 0) {
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
          : contributorIds.length,
      allTimeContributors: allTimeContributors,
      releases365d: unavailable.contains('releases365d') ? null : releases365,
      daysSinceCommit:
          unavailable.contains('daysSinceCommit') || newestCommit == null
          ? null
          : wholeDaysBetween(observedAt, newestCommit),
      daysSinceRelease:
          unavailable.contains('daysSinceRelease') || datedReleases.isEmpty
          ? null
          : wholeDaysBetween(observedAt, datedReleases.first.publishedAt),
      issueSampleSize: issueCare.sampleSize,
      responseRate: issueCare.responseRate,
      actionRate: issueCare.actionRate,
      closeRate: issueCare.closeRate,
      medianFirstResponseHours: issueCare.medianFirstResponseHours,
      observedAt: observedAt,
      estimatedFields: estimated,
      unavailableFields: unavailable,
    );
  }

  int? _lastPage(String? link) {
    if (link == null) return null;
    for (final segment in link.split(',')) {
      if (!segment.contains('rel="last"')) continue;
      final match = RegExp(r'<([^>]+)>').firstMatch(segment);
      final page = match == null
          ? null
          : Uri.tryParse(match.group(1)!)?.queryParameters['page'];
      return int.tryParse(page ?? '');
    }
    return null;
  }
}
