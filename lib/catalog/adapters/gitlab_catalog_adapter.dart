import 'package:obtainium/catalog/adapters/forge_catalog_adapter.dart';
import 'package:obtainium/catalog/adapters/metrics_support.dart';
import 'package:obtainium/catalog/models.dart';

class GitLabCatalogAdapter implements ForgeCatalogAdapter {
  final CatalogTransport transport;

  const GitLabCatalogAdapter(this.transport);

  @override
  ProviderKind get kind => ProviderKind.gitlab;
  @override
  String get adapterName => 'gitlab-v1';
  @override
  String get defaultApiBaseUrl => 'https://gitlab.com/api/v4';
  @override
  String get defaultWebBaseUrl => 'https://gitlab.com';

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
    final scopes =
        response.header('x-oauth-scopes') ??
        response.header('x-accepted-oauth-scopes');
    return AccountValidation(
      username: data['username']!.toString(),
      displayName: data['name']?.toString(),
      effectiveScopes: scopes,
      broadScopeWarning: scopes == null,
    );
  }

  @override
  Future<CatalogPage> search(
    CatalogQuery query, {
    ProviderAccount? account,
  }) async {
    final uri =
        query.cursor?.next ??
        _endpoint(account?.apiBaseUrl ?? defaultApiBaseUrl, '/projects', {
          'search': query.text.trim().isEmpty ? 'android' : query.text.trim(),
          'topic': query.filters.topics.length == 1
              ? query.filters.topics.single
              : null,
          'archived': query.filters.includeArchived ? null : false,
          'simple': true,
          'order_by': query.sort == CatalogSort.stars
              ? 'star_count'
              : query.sort == CatalogSort.activity
              ? 'last_activity_at'
              : 'similarity',
          'sort': 'desc',
          'per_page': query.pageSize.clamp(1, 100),
          'page': query.cursor?.page ?? 1,
        });
    final response = await _get(uri, account: account);
    return _page(response, account?.id);
  }

  @override
  Future<CatalogPage> listAccessibleRepositories({
    required ProviderAccount account,
    PageCursor? cursor,
  }) async {
    final uri =
        cursor?.next ??
        _endpoint(account.apiBaseUrl, '/projects', {
          'membership': true,
          'simple': true,
          'order_by': 'last_activity_at',
          'sort': 'desc',
          'per_page': 100,
          'page': cursor?.page ?? 1,
        });
    return _page(await _get(uri, account: account), account.id);
  }

  CatalogPage _page(CatalogResponse response, String? accountId) {
    final now = DateTime.now().toUtc();
    final nextPage = int.tryParse(response.header('x-next-page') ?? '');
    final next = nextLink(response);
    return CatalogPage(
      repositories: (response.json as List<dynamic>)
          .map(
            (e) => _repository(
              Map<String, dynamic>.from(e as Map),
              now,
              accountId,
            ),
          )
          .toList(),
      next: next != null
          ? PageCursor(next: next)
          : nextPage != null && nextPage > 0
          ? PageCursor(page: nextPage)
          : null,
      totalCount: int.tryParse(response.header('x-total') ?? ''),
      partial: response.rateState.exhausted,
      observedAt: now,
    );
  }

  ForgeRepository _repository(
    Map<String, dynamic> data,
    DateTime observedAt,
    String? accountId,
  ) {
    final webUrl = Uri.parse(data['web_url']!.toString());
    final namespace = data['namespace'] as Map?;
    final owner =
        namespace?['full_path']?.toString() ??
        data['path_with_namespace']?.toString().split('/').first ??
        '';
    final path =
        data['path_with_namespace']?.toString() ?? '$owner/${data['path']}';
    final apiBase = accountId == null
        ? defaultApiBaseUrl
        : webUrl.resolve('/api/v4').toString();
    return ForgeRepository(
      catalogKey: ForgeRepository.identity(kind, webUrl.host, data['id']!),
      provider: kind,
      host: webUrl.host,
      providerRepositoryId: data['id']!.toString(),
      accountId: accountId,
      webUrl: webUrl,
      apiUrl: _endpoint(apiBase, '/projects/${data['id']}'),
      owner: owner,
      path: path,
      name: data['name']!.toString(),
      summary: data['description']?.toString(),
      description: data['description']?.toString(),
      topics: Set<String>.from(
        (data['topics'] ?? data['tag_list']) as List? ?? const [],
      ),
      categories: const {},
      license: (data['license'] as Map?)?['key']?.toString(),
      isPrivate: data['visibility'] != null && data['visibility'] != 'public',
      archived: data['archived'] == true,
      fork: data['forked_from_project'] != null,
      apkAvailability: AvailabilityState.unknown,
      deviceCompatibility: AvailabilityState.unknown,
      lastActivity: parseDate(data['last_activity_at'] ?? data['updated_at']),
      observedAt: observedAt,
      metrics: MetricSnapshot(
        stars: data['star_count'] as int?,
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
    final path = repositoryUrl.pathSegments
        .where((e) => e.isNotEmpty)
        .join('/');
    if (path.isEmpty) {
      throw const FormatException(
        'GitLab project URL requires a namespace/path',
      );
    }
    final encoded = Uri.encodeComponent(path);
    final response = await _get(
      _endpoint(account?.apiBaseUrl ?? defaultApiBaseUrl, '/projects/$encoded'),
      account: account,
    );
    return _repository(
      Map<String, dynamic>.from(response.json! as Map),
      DateTime.now().toUtc(),
      account?.id,
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
      '/projects/${repository.providerRepositoryId}/releases',
      {'per_page': 100, 'page': 1},
    );
    final result = <ReleaseSummary>[];
    for (var page = 0; page < maxPages && uri != null; page++) {
      final response = await _get(uri, account: account);
      for (final raw in response.json as List<dynamic>) {
        final data = Map<String, dynamic>.from(raw as Map);
        final assets =
            (data['assets'] as Map?)?['links'] as List<dynamic>? ?? const [];
        result.add(
          ReleaseSummary(
            id: data['_links'] is Map
                ? ((data['_links'] as Map)['self'] ?? data['tag_name'])
                      .toString()
                : data['tag_name'].toString(),
            version: data['tag_name'].toString(),
            name: data['name']?.toString(),
            changelog: data['description']?.toString(),
            publishedAt: parseDate(data['released_at'] ?? data['created_at']),
            prerelease: data['upcoming_release'] == true,
            assets: assets.map((rawAsset) {
              final asset = Map<String, dynamic>.from(rawAsset as Map);
              return ReleaseAsset(
                name:
                    asset['name']?.toString() ??
                    Uri.parse(asset['url'].toString()).pathSegments.last,
                downloadUrl: Uri.parse(
                  asset['direct_asset_url']?.toString() ??
                      asset['url'].toString(),
                ),
                contentType:
                    asset['link_type']?.toString() ??
                    'application/octet-stream',
              );
            }).toList(),
          ),
        );
      }
      uri = nextLink(response);
      if (uri == null) {
        final nextPage = int.tryParse(response.header('x-next-page') ?? '');
        if (nextPage != null && nextPage > 0) {
          uri = _endpoint(
            account?.apiBaseUrl ?? defaultApiBaseUrl,
            '/projects/${repository.providerRepositoryId}/releases',
            {'per_page': 100, 'page': nextPage},
          );
        }
      }
    }
    return result;
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
    final unavailable = <String>{'allTimeContributors'};
    final estimated = <String>{};
    final authors = <String>{};
    var commits90d = 0;
    DateTime? newestCommit;
    var page = 1;
    try {
      for (; page <= 5; page++) {
        final response = await _get(
          _endpoint(
            account?.apiBaseUrl ?? defaultApiBaseUrl,
            '/projects/${repository.providerRepositoryId}/repository/commits',
            {
              'since': cutoff90.toIso8601String(),
              'until': observedAt.toIso8601String(),
              'with_stats': false,
              'per_page': 100,
              'page': page,
            },
          ),
          account: account,
        );
        final rows = response.json as List<dynamic>;
        commits90d += rows.length;
        for (final raw in rows) {
          final commit = raw as Map;
          final identity = normalizedContributorIdentity(
            email: commit['author_email'],
            name: commit['author_name'],
          );
          if (identity.isNotEmpty &&
              !isAutomatedContributor(login: commit['author_name'])) {
            authors.add(identity);
          }
          newestCommit ??= parseDate(
            commit['committed_date'] ?? commit['created_at'],
          );
        }
        final nextPage = int.tryParse(response.header('x-next-page') ?? '');
        if (nextPage == null || nextPage == 0) break;
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
        _endpoint(
          account?.apiBaseUrl ?? defaultApiBaseUrl,
          '/projects/${repository.providerRepositoryId}/issues',
          {
            'scope': 'all',
            'state': 'all',
            'order_by': 'updated_at',
            'sort': 'desc',
            'created_after': cutoff180.toIso8601String(),
            'per_page': 20,
            'page': 1,
          },
        ),
        account: account,
      );
      for (final raw in (issuesResponse.json as List<dynamic>).take(20)) {
        final issue = Map<String, dynamic>.from(raw as Map);
        if (issue['issue_type'] == 'incident') continue;
        final created = parseDate(issue['created_at']);
        final author = (issue['author'] as Map?)?['username']?.toString();
        DateTime? firstResponse;
        final notes = await _get(
          _endpoint(
            account?.apiBaseUrl ?? defaultApiBaseUrl,
            '/projects/${repository.providerRepositoryId}/issues/${issue['iid']}/notes',
            {
              'sort': 'asc',
              'order_by': 'created_at',
              'per_page': 100,
              'page': 1,
            },
          ),
          account: account,
        );
        for (final noteRaw in notes.json as List<dynamic>) {
          final note = noteRaw as Map;
          final noteAuthor = note['author'] as Map?;
          final login = noteAuthor?['username']?.toString();
          if (note['system'] == true ||
              note['internal'] == true ||
              login == author ||
              isAutomatedContributor(
                login: login,
                type: noteAuthor?['state'],
              )) {
            continue;
          }
          final createdAt = parseDate(note['created_at']);
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
      commits90d: unavailable.contains('commits90d') ? null : commits90d,
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
