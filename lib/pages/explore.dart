import 'dart:async';

import 'package:flutter/material.dart';
import 'package:obtainium/catalog/catalog_provider.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/pages/catalog_detail.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:provider/provider.dart';
import 'package:workmanager/workmanager.dart';

class ExplorePage extends StatefulWidget {
  final VoidCallback onOpenSettings;
  final Future<void> Function(CatalogEntry entry, bool install)? onSubscribe;

  const ExplorePage({
    super.key,
    required this.onOpenSettings,
    this.onSubscribe,
  });

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  late final TextEditingController _search;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = context.watch<CatalogProvider>();
    final _ = context.watch<AppsProvider>();
    final categories =
        catalog.entries.expand((entry) => entry.categories).toSet().toList()
          ..sort();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explore'),
        actions: [
          IconButton(
            onPressed: catalog.refreshing ? null : _refresh,
            tooltip: 'Refresh catalog',
            icon: catalog.refreshing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: widget.onOpenSettings,
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _controls(context, catalog, categories)),
            if (catalog.error != null ||
                catalog.stale ||
                catalog.partial ||
                catalog.incomplete)
              SliverToBoxAdapter(child: _statusBanner(context, catalog)),
            if (!catalog.initialized)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (catalog.entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      catalog.refreshing
                          ? 'Searching configured providers…'
                          : 'No cached matches. Pull to refresh or adjust filters.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              )
            else if (catalog.query.text.trim().isEmpty)
              ..._shelves(catalog.entries)
            else
              _resultList(catalog.entries),
            if (catalog.incomplete || catalog.partial)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton(
                    onPressed: catalog.refreshing ? null : catalog.evaluateMore,
                    child: Text(catalog.statusMessage ?? 'Evaluate more'),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton.icon(
                    onPressed: catalog.loadingMore ? null : catalog.loadMore,
                    icon: catalog.loadingMore
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.expand_more),
                    label: const Text('Load more cached results'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(
    BuildContext context,
    CatalogProvider catalog,
    List<String> categories,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchBar(
          controller: _search,
          hintText: 'Search apps and repositories',
          leading: const Icon(Icons.search),
          trailing: [
            if (_search.text.isNotEmpty)
              IconButton(
                onPressed: () {
                  _search.clear();
                  catalog.setSearchText('');
                  setState(() {});
                },
                icon: const Icon(Icons.clear),
              ),
          ],
          onChanged: (value) {
            catalog.setSearchText(value);
            setState(() {});
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<CatalogSort>(
                initialValue: catalog.query.sort,
                decoration: const InputDecoration(
                  labelText: 'Sort',
                  isDense: true,
                ),
                items: CatalogSort.values
                    .map(
                      (sort) => DropdownMenuItem(
                        value: sort,
                        child: Text(_sortLabel(sort)),
                      ),
                    )
                    .toList(),
                onChanged: (sort) {
                  if (sort != null) catalog.setSort(sort);
                },
              ),
            ),
            const SizedBox(width: 10),
            Badge(
              isLabelVisible: catalog.query.filters.activeCount > 0,
              label: Text('${catalog.query.filters.activeCount}'),
              child: OutlinedButton.icon(
                onPressed: () => _showFilters(catalog),
                icon: const Icon(Icons.tune),
                label: const Text('Filters'),
              ),
            ),
          ],
        ),
        if (categories.isNotEmpty) ...[
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: categories.take(12).map((category) {
                final selected = catalog.query.filters.categories.contains(
                  category,
                );
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(category),
                    selected: selected,
                    onSelected: (value) {
                      final selectedCategories = {
                        ...catalog.query.filters.categories,
                      };
                      value
                          ? selectedCategories.add(category)
                          : selectedCategories.remove(category);
                      catalog.setFilters(
                        _copyFilters(
                          catalog.query.filters,
                          categories: selectedCategories,
                        ),
                      );
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _statusBanner(BuildContext context, CatalogProvider catalog) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: ListTile(
      leading: Icon(
        catalog.error == null
            ? Icons.cloud_off_outlined
            : Icons.warning_amber_outlined,
      ),
      title: Text(
        catalog.error != null
            ? 'Some providers could not refresh'
            : catalog.stale
            ? 'Showing stale cached data'
            : 'Results are partial',
      ),
      subtitle: Text(
        catalog.error ??
            catalog.statusMessage ??
            'Rate limits or bounded provider feeds may limit this result set.',
      ),
    ),
  );

  List<Widget> _shelves(List<CatalogEntry> entries) {
    final popular = [...entries]
      ..sort(
        (a, b) => (b.metrics?.stars ?? -1).compareTo(a.metrics?.stars ?? -1),
      );
    final active = [...entries]
      ..sort(
        (a, b) => (b.forgeRepository?.lastActivity ?? DateTime(0)).compareTo(
          a.forgeRepository?.lastActivity ?? DateTime(0),
        ),
      );
    final fdroidByCategory = <String, List<CatalogEntry>>{};
    for (final entry in entries.where((entry) => entry.fdroidPackage != null)) {
      for (final category in entry.categories) {
        fdroidByCategory.putIfAbsent(category, () => []).add(entry);
      }
    }
    final widgets = <Widget>[
      _shelf('Popular', popular.take(10).toList()),
      _shelf('Recently active', active.take(10).toList()),
    ];
    for (final category in fdroidByCategory.keys.take(3)) {
      widgets.add(
        _shelf(
          'F-Droid · $category',
          fdroidByCategory[category]!.take(10).toList(),
        ),
      );
    }
    return widgets;
  }

  Widget _shelf(String title, List<CatalogEntry> entries) =>
      SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
          ),
          SliverList.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) => _entryCard(entries[index]),
          ),
        ],
      );

  Widget _resultList(List<CatalogEntry> entries) => SliverList.builder(
    itemCount: entries.length,
    itemBuilder: (context, index) => _entryCard(entries[index]),
  );

  Widget _entryCard(CatalogEntry entry) {
    final provider = context.read<AppsProvider>();
    final match = provider.apps.values
        .where(
          (candidate) =>
              (entry.packageName != null &&
                  candidate.app.id == entry.packageName) ||
              candidate.app.url == entry.forgeRepository?.webUrl.toString(),
        )
        .firstOrNull;
    final libraryState = (
      subscribed: match != null,
      installed: match?.installedInfo != null,
    );
    final metrics = entry.metrics;
    final score = metrics?.score;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CatalogDetailPage(
              catalogKey: entry.catalogKey,
              onSubscribe: widget.onSubscribe,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    entry.fdroidPackage == null
                        ? Icons.source_outlined
                        : Icons.android,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (entry.isPrivate) const Icon(Icons.lock_outline, size: 18),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 19,
                    child: Text(score?.toString() ?? '—'),
                  ),
                ],
              ),
              if (entry.summary != null) ...[
                const SizedBox(height: 6),
                Text(
                  entry.summary!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 5,
                children: [
                  _fact(
                    Icons.dns_outlined,
                    '${entry.sourceLabel} · ${entry.host}',
                  ),
                  _fact(Icons.android, 'APK ${entry.apkAvailability.name}'),
                  _fact(
                    libraryState.installed
                        ? Icons.verified_outlined
                        : libraryState.subscribed
                        ? Icons.bookmark_added_outlined
                        : Icons.bookmark_border,
                    libraryState.installed
                        ? 'Installed'
                        : libraryState.subscribed
                        ? 'Subscribed'
                        : 'Not subscribed',
                  ),
                  _fact(
                    Icons.devices,
                    'Device ${entry.deviceCompatibility.name}',
                  ),
                  if (metrics?.stars != null)
                    _fact(Icons.star_outline, '${metrics!.stars} stars'),
                  if (metrics?.commits90d != null)
                    _fact(Icons.commit, '${metrics!.commits90d} commits/90d'),
                  if (metrics?.releases365d != null)
                    _fact(
                      Icons.new_releases_outlined,
                      '${metrics!.releases365d} releases/year',
                    ),
                  _fact(Icons.schedule, _freshness(entry.freshness)),
                  if (score == null)
                    _fact(Icons.query_stats, 'Insufficient score data'),
                  if (entry.signerVariantWarning)
                    _fact(Icons.warning_amber, 'Signer variant'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fact(IconData icon, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16),
      const SizedBox(width: 4),
      Text(text, style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  Future<void> _showFilters(CatalogProvider catalog) async {
    final result = await showModalBottomSheet<CatalogFilters>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ExploreFiltersSheet(
        initial: catalog.query.filters,
        accounts: catalog.accounts,
      ),
    );
    if (result != null) catalog.setFilters(result);
  }

  Future<void> _refresh() async {
    unawaited(
      Workmanager().registerOneOffTask(
        'emporionCatalogRefreshManual',
        'emporionCatalogRefreshManual',
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
          requiresStorageNotLow: true,
        ),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      ),
    );
    await context.read<CatalogProvider>().refresh(allowReorder: true);
  }

  static String _freshness(FreshnessState state) => switch (state) {
    FreshnessState.fresh => 'Fresh',
    FreshnessState.stale => 'Stale',
    FreshnessState.expired => 'Expired',
  };

  static String _sortLabel(CatalogSort sort) => switch (sort) {
    CatalogSort.relevance => 'Relevance',
    CatalogSort.emporionScore => 'Emporion score',
    CatalogSort.stars => 'Stars',
    CatalogSort.activity => 'Recent activity',
    CatalogSort.releaseCadence => 'Release cadence',
    CatalogSort.activeContributors => 'Active contributors',
    CatalogSort.issueResponse => 'Issue response',
    CatalogSort.name => 'Name',
  };
}

class ExploreFiltersSheet extends StatefulWidget {
  final CatalogFilters initial;
  final List<ProviderAccount> accounts;

  const ExploreFiltersSheet({
    super.key,
    required this.initial,
    required this.accounts,
  });

  @override
  State<ExploreFiltersSheet> createState() => _ExploreFiltersSheetState();
}

class _ExploreFiltersSheetState extends State<ExploreFiltersSheet> {
  late Set<ProviderKind> sources;
  late Set<String> accounts;
  late bool includeArchived;
  late bool includeForks;
  late bool includeUnknown;
  bool? private;
  bool? apk;
  bool? compatible;
  late final Map<String, TextEditingController> text;

  @override
  void initState() {
    super.initState();
    final value = widget.initial;
    sources = {...value.sources};
    accounts = {...value.accountIds};
    includeArchived = value.includeArchived;
    includeForks = value.includeForks;
    includeUnknown = value.includeUnknown;
    private = value.isPrivate;
    apk = value.apkAvailable;
    compatible = value.deviceCompatible;
    text = {
      'categories': TextEditingController(text: value.categories.join(', ')),
      'licenses': TextEditingController(text: value.licenses.join(', ')),
      'antiFeatures': TextEditingController(
        text: value.antiFeatures.join(', '),
      ),
      'topics': TextEditingController(text: value.topics.join(', ')),
      'stars': TextEditingController(
        text: value.minimumStars?.toString() ?? '',
      ),
      'active': TextEditingController(
        text: value.minimumActiveContributors90d?.toString() ?? '',
      ),
      'allContributors': TextEditingController(
        text: value.minimumAllTimeContributors?.toString() ?? '',
      ),
      'commits': TextEditingController(
        text: value.minimumCommits90d?.toString() ?? '',
      ),
      'releases': TextEditingController(
        text: value.minimumReleases365d?.toString() ?? '',
      ),
      'score': TextEditingController(
        text: value.minimumScore?.toString() ?? '',
      ),
      'confidence': TextEditingController(
        text: value.minimumConfidence?.toString() ?? '',
      ),
      'response': TextEditingController(
        text: value.minimumResponseRate == null
            ? ''
            : '${(value.minimumResponseRate! * 100).round()}',
      ),
      'action': TextEditingController(
        text: value.minimumActionRate == null
            ? ''
            : '${(value.minimumActionRate! * 100).round()}',
      ),
      'close': TextEditingController(
        text: value.minimumCloseRate == null
            ? ''
            : '${(value.minimumCloseRate! * 100).round()}',
      ),
      'commitDays': TextEditingController(
        text: value.maximumDaysSinceCommit?.toString() ?? '',
      ),
      'releaseDays': TextEditingController(
        text: value.maximumDaysSinceRelease?.toString() ?? '',
      ),
      'responseHours': TextEditingController(
        text: value.maximumFirstResponseHours?.toString() ?? '',
      ),
    };
  }

  @override
  void dispose() {
    for (final controller in text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .82,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Catalog filters',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(onPressed: _reset, child: const Text('Reset')),
                FilledButton(onPressed: _apply, child: const Text('Apply')),
              ],
            ),
            Expanded(
              child: ListView(
                children: [
                  const ListTile(title: Text('Sources')),
                  Wrap(
                    spacing: 8,
                    children: ProviderKind.values
                        .map(
                          (source) => FilterChip(
                            label: Text(source.name),
                            selected: sources.contains(source),
                            onSelected: (selected) => setState(
                              () => selected
                                  ? sources.add(source)
                                  : sources.remove(source),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  if (widget.accounts.isNotEmpty) ...[
                    const ListTile(title: Text('Accounts')),
                    Wrap(
                      spacing: 8,
                      children: widget.accounts
                          .map(
                            (account) => FilterChip(
                              label: Text(account.label),
                              selected: accounts.contains(account.id),
                              onSelected: (selected) => setState(
                                () => selected
                                    ? accounts.add(account.id)
                                    : accounts.remove(account.id),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                  _facetField('categories', 'Categories (comma-separated)'),
                  _facetField('licenses', 'Licenses (comma-separated)'),
                  _facetField(
                    'antiFeatures',
                    'Anti-features (comma-separated)',
                  ),
                  _facetField('topics', 'Topics (comma-separated)'),
                  _triState(
                    'Visibility',
                    private,
                    (value) => setState(() => private = value),
                    falseLabel: 'Public',
                    trueLabel: 'Private',
                  ),
                  _triState(
                    'APK available',
                    apk,
                    (value) => setState(() => apk = value),
                  ),
                  _triState(
                    'Device compatible',
                    compatible,
                    (value) => setState(() => compatible = value),
                  ),
                  SwitchListTile(
                    title: const Text('Include archived'),
                    value: includeArchived,
                    onChanged: (value) =>
                        setState(() => includeArchived = value),
                  ),
                  SwitchListTile(
                    title: const Text('Include forks'),
                    value: includeForks,
                    onChanged: (value) => setState(() => includeForks = value),
                  ),
                  SwitchListTile(
                    title: const Text('Include unknown threshold values'),
                    value: includeUnknown,
                    onChanged: (value) =>
                        setState(() => includeUnknown = value),
                  ),
                  const ListTile(title: Text('Minimum values')),
                  _numericGrid([
                    ('stars', 'Stars'),
                    ('active', 'Active contributors / 90d'),
                    ('allContributors', 'All-time contributors'),
                    ('commits', 'Commits / 90d'),
                    ('releases', 'Releases / 365d'),
                    ('score', 'Score (0–100)'),
                    ('confidence', 'Confidence (0–100)'),
                    ('response', 'Response rate %'),
                    ('action', 'Action rate %'),
                    ('close', 'Close rate %'),
                  ]),
                  const ListTile(title: Text('Maximum recency / response')),
                  _numericGrid([
                    ('commitDays', 'Days since commit'),
                    ('releaseDays', 'Days since release'),
                    ('responseHours', 'First response hours'),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _facetField(String key, String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: TextField(
      controller: text[key],
      decoration: InputDecoration(labelText: label),
    ),
  );

  Widget _numericGrid(List<(String, String)> fields) => Wrap(
    spacing: 10,
    runSpacing: 8,
    children: fields
        .map(
          (field) => SizedBox(
            width: 180,
            child: TextField(
              controller: text[field.$1],
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: field.$2),
            ),
          ),
        )
        .toList(),
  );

  Widget _triState(
    String label,
    bool? value,
    ValueChanged<bool?> onChanged, {
    String falseLabel = 'No',
    String trueLabel = 'Yes',
  }) => ListTile(
    title: Text(label),
    trailing: SegmentedButton<bool?>(
      showSelectedIcon: false,
      segments: [
        const ButtonSegment(value: null, label: Text('Any')),
        ButtonSegment(value: true, label: Text(trueLabel)),
        ButtonSegment(value: false, label: Text(falseLabel)),
      ],
      selected: {value},
      onSelectionChanged: (selection) => onChanged(selection.first),
    ),
  );

  void _reset() => Navigator.pop(context, const CatalogFilters());

  void _apply() {
    int? integer(String key) => int.tryParse(text[key]!.text.trim());
    double? percent(String key) {
      final value = double.tryParse(text[key]!.text.trim());
      return value == null ? null : (value / 100).clamp(0, 1).toDouble();
    }

    Set<String> facet(String key) => text[key]!.text
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    Navigator.pop(
      context,
      CatalogFilters(
        sources: sources,
        accountIds: accounts,
        categories: facet('categories'),
        licenses: facet('licenses'),
        antiFeatures: facet('antiFeatures'),
        topics: facet('topics'),
        isPrivate: private,
        apkAvailable: apk,
        deviceCompatible: compatible,
        includeArchived: includeArchived,
        includeForks: includeForks,
        includeUnknown: includeUnknown,
        minimumStars: integer('stars'),
        minimumActiveContributors90d: integer('active'),
        minimumAllTimeContributors: integer('allContributors'),
        minimumCommits90d: integer('commits'),
        minimumReleases365d: integer('releases'),
        minimumScore: integer('score'),
        minimumConfidence: integer('confidence'),
        minimumResponseRate: percent('response'),
        minimumActionRate: percent('action'),
        minimumCloseRate: percent('close'),
        maximumDaysSinceCommit: integer('commitDays'),
        maximumDaysSinceRelease: integer('releaseDays'),
        maximumFirstResponseHours: double.tryParse(
          text['responseHours']!.text.trim(),
        ),
      ),
    );
  }
}

CatalogFilters _copyFilters(CatalogFilters value, {Set<String>? categories}) =>
    CatalogFilters(
      sources: value.sources,
      accountIds: value.accountIds,
      categories: categories ?? value.categories,
      licenses: value.licenses,
      antiFeatures: value.antiFeatures,
      topics: value.topics,
      isPrivate: value.isPrivate,
      apkAvailable: value.apkAvailable,
      deviceCompatible: value.deviceCompatible,
      includeArchived: value.includeArchived,
      includeForks: value.includeForks,
      includeUnknown: value.includeUnknown,
      minimumStars: value.minimumStars,
      minimumActiveContributors90d: value.minimumActiveContributors90d,
      minimumAllTimeContributors: value.minimumAllTimeContributors,
      minimumCommits90d: value.minimumCommits90d,
      minimumReleases365d: value.minimumReleases365d,
      minimumScore: value.minimumScore,
      minimumConfidence: value.minimumConfidence,
      minimumResponseRate: value.minimumResponseRate,
      minimumActionRate: value.minimumActionRate,
      minimumCloseRate: value.minimumCloseRate,
      maximumDaysSinceCommit: value.maximumDaysSinceCommit,
      maximumDaysSinceRelease: value.maximumDaysSinceRelease,
      maximumFirstResponseHours: value.maximumFirstResponseHours,
    );
