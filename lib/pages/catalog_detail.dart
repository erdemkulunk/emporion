import 'package:flutter/material.dart';
import 'package:obtainium/catalog/catalog_provider.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

class CatalogDetailPage extends StatefulWidget {
  final String catalogKey;
  final Future<void> Function(CatalogEntry entry, bool install)? onSubscribe;

  const CatalogDetailPage({
    super.key,
    required this.catalogKey,
    this.onSubscribe,
  });

  @override
  State<CatalogDetailPage> createState() => _CatalogDetailPageState();
}

class _CatalogDetailPageState extends State<CatalogDetailPage> {
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<CatalogProvider>().enrichEntry(widget.catalogKey);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final entry = context.select<CatalogProvider, CatalogEntry?>(
      (provider) => provider.entries
          .where((entry) => entry.catalogKey == widget.catalogKey)
          .firstOrNull,
    );
    if (entry == null) {
      return const Scaffold(
        body: Center(child: Text('Catalog entry is no longer available')),
      );
    }
    final fdroidRepository = entry.fdroidPackage == null
        ? null
        : context
              .read<CatalogProvider>()
              .fdroidRepositories
              .where(
                (repository) =>
                    repository.id == entry.fdroidPackage!.repositoryId,
              )
              .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(entry.name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                label: Text(
                  entry.originKind == CatalogOriginKind.fdroidPackage
                      ? 'F-Droid package'
                      : 'Forge repository',
                ),
              ),
              Chip(
                avatar: Icon(
                  entry.isPrivate ? Icons.lock_outline : Icons.public,
                  size: 18,
                ),
                label: Text(entry.isPrivate ? 'Private' : 'Public'),
              ),
              Chip(label: Text(entry.host)),
              Chip(label: Text(_freshness(entry.freshness))),
            ],
          ),
          const SizedBox(height: 16),
          if (entry.summary != null)
            Text(
              entry.summary!,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          if (entry.description != null) ...[
            const SizedBox(height: 12),
            Text(entry.description!),
          ],
          const SizedBox(height: 20),
          _sectionTitle(context, 'Install origins'),
          if (entry.installOrigins.isEmpty)
            const ListTile(
              leading: Icon(Icons.block),
              title: Text('No installable APK detected'),
              subtitle: Text(
                'Subscribe is unavailable until a compatible APK origin is known.',
              ),
            )
          else
            ...entry.installOrigins.map(
              (origin) => Card(
                child: ListTile(
                  leading: Icon(
                    origin.trusted
                        ? Icons.verified_user_outlined
                        : Icons.warning_amber_outlined,
                  ),
                  title: Text(origin.label),
                  subtitle: Text(
                    [
                      origin.sourceUrl.toString(),
                      'Trust: ${origin.trusted ? 'verified repository' : 'provider metadata only'}',
                      'Compatibility: ${origin.compatibility.name}',
                      if (origin.expectedSignerSha256 != null)
                        'Signer SHA-256: ${origin.expectedSignerSha256}',
                      if (origin.expectedSha256 != null)
                        'APK SHA-256: ${origin.expectedSha256}',
                      if (origin.expectedSize != null)
                        'Expected size: ${origin.expectedSize} bytes',
                      if (origin.expectedVersionCode != null)
                        'Expected versionCode: ${origin.expectedVersionCode}',
                    ].join('\n'),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 20),
          _sectionTitle(context, 'Emporion score'),
          _metrics(context, entry.metrics),
          if (entry.fdroidPackage case final package?) ...[
            const SizedBox(height: 20),
            _sectionTitle(context, 'F-Droid provenance'),
            Card(
              child: Column(
                children: [
                  _metricRow(
                    'Repository',
                    'Trust',
                    fdroidRepository?.trustState.name ?? 'Unavailable',
                  ),
                  _metricRow(
                    'Repository',
                    'Fingerprint',
                    fdroidRepository?.fingerprint,
                  ),
                  _metricRow(
                    'Index',
                    'Verified generation',
                    package.generation,
                  ),
                  _metricRow(
                    'Package',
                    'Signing certificate SHA-256',
                    package.signerSha256,
                  ),
                  _metricRow('Index', 'Observed', package.observedAt.toLocal()),
                  OverflowBar(
                    spacing: 8,
                    alignment: MainAxisAlignment.end,
                    children: [
                      if (package.sourceCodeUrl != null)
                        TextButton.icon(
                          onPressed: () => launchUrl(
                            package.sourceCodeUrl!,
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.code),
                          label: const Text('Source'),
                        ),
                      if (package.issueTrackerUrl != null)
                        TextButton.icon(
                          onPressed: () => launchUrl(
                            package.issueTrackerUrl!,
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.bug_report_outlined),
                          label: const Text('Issues'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          _sectionTitle(context, 'Metadata'),
          _metadata(context, entry),
          if (entry.forgeRepository case final repository?) ...[
            const SizedBox(height: 20),
            _sectionTitle(context, 'Releases'),
            if (repository.releases.isEmpty)
              const ListTile(title: Text('No release metadata available'))
            else
              ...repository.releases.map(
                (release) => ExpansionTile(
                  title: Text(release.name ?? release.version),
                  subtitle: Text(
                    release.publishedAt?.toLocal().toString() ??
                        'Publication date unavailable',
                  ),
                  children: [
                    if (release.changelog != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(release.changelog!),
                        ),
                      ),
                    ...release.assets.map(
                      (asset) => ListTile(
                        leading: Icon(
                          asset.isInstallable
                              ? Icons.android
                              : Icons.insert_drive_file_outlined,
                        ),
                        title: Text(asset.name),
                        subtitle: Text(
                          [
                            if (asset.size != null) '${asset.size} bytes',
                            if (asset.sha256 != null) 'SHA-256 ${asset.sha256}',
                          ].join(' · '),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            OverflowBar(
              spacing: 8,
              alignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => launchUrl(
                    repository.webUrl,
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.code),
                  label: const Text('Source'),
                ),
                if (repository.webUrl.host.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      repository.webUrl.resolve('issues'),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.bug_report_outlined),
                    label: const Text('Issues'),
                  ),
              ],
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      bottomNavigationBar:
          entry.installOrigins.isEmpty || widget.onSubscribe == null
          ? null
          : SafeArea(
              minimum: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _working
                          ? null
                          : () => _subscribe(entry, false),
                      child: const Text('Subscribe'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _working
                          ? null
                          : () => _subscribe(entry, true),
                      child: _working
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Install & subscribe'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> _subscribe(CatalogEntry entry, bool install) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onSubscribe!(entry, install);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _metrics(BuildContext context, MetricSnapshot? metrics) {
    if (metrics == null) {
      return const ListTile(
        leading: Icon(Icons.query_stats),
        title: Text('Insufficient data'),
        subtitle: Text(
          'Open this page while online to collect provider metrics.',
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              child: Text(metrics.score?.toString() ?? '—'),
            ),
            title: Text(
              metrics.score == null
                  ? 'Insufficient data'
                  : '${metrics.score}/100',
            ),
            subtitle: Text(
              'Confidence ${metrics.confidence}% · observed ${metrics.observedAt.toLocal()}',
            ),
          ),
          _metricRow('Popularity', 'Stars', metrics.stars),
          _metricRow('Development', 'Commits in 90 days', metrics.commits90d),
          _metricRow(
            'Development',
            'Days since commit',
            metrics.daysSinceCommit,
          ),
          _metricRow('Releases', 'Releases in 365 days', metrics.releases365d),
          _metricRow(
            'Releases',
            'Days since release',
            metrics.daysSinceRelease,
          ),
          _metricRow(
            'Contributors',
            'Active in 90 days',
            metrics.activeContributors90d,
          ),
          _metricRow('Contributors', 'All time', metrics.allTimeContributors),
          _metricRow(
            'Issue care',
            'Response rate',
            _percent(metrics.responseRate),
          ),
          _metricRow('Issue care', 'Action rate', _percent(metrics.actionRate)),
          _metricRow('Issue care', 'Close rate', _percent(metrics.closeRate)),
          _metricRow(
            'Issue care',
            'Median first response',
            metrics.medianFirstResponseHours == null
                ? null
                : '${metrics.medianFirstResponseHours!.toStringAsFixed(1)} hours',
          ),
          ListTile(
            dense: true,
            title: const Text('Issue sample'),
            trailing: Text('${metrics.issueSampleSize}/20 · 180-day window'),
          ),
          if (metrics.estimatedFields.isNotEmpty)
            ListTile(
              dense: true,
              title: const Text('Estimated'),
              subtitle: Text(metrics.estimatedFields.join(', ')),
            ),
          if (metrics.unavailableFields.isNotEmpty)
            ListTile(
              dense: true,
              title: const Text('Unavailable'),
              subtitle: Text(metrics.unavailableFields.join(', ')),
            ),
        ],
      ),
    );
  }

  Widget _metadata(BuildContext context, CatalogEntry entry) => Card(
    child: Column(
      children: [
        _metricRow('Package', 'ID', entry.packageName),
        _metricRow(
          'License',
          'Declared',
          entry.license ?? 'Unknown / not declared',
        ),
        _metricRow('APK', 'Availability', entry.apkAvailability.name),
        _metricRow('Device', 'Compatibility', entry.deviceCompatibility.name),
        if (entry.categories.isNotEmpty)
          _metricRow('Categories', 'Values', entry.categories.join(', ')),
        if (entry.topics.isNotEmpty)
          _metricRow('Topics', 'Values', entry.topics.join(', ')),
        if (entry.antiFeatures.isNotEmpty)
          _metricRow(
            'Anti-features',
            'Warnings',
            entry.antiFeatures.join(', '),
          ),
        if (entry.signerVariantWarning)
          const ListTile(
            leading: Icon(Icons.warning_amber),
            title: Text('Same package name has another signer variant'),
          ),
      ],
    ),
  );

  Widget _metricRow(String dimension, String label, Object? value) => ListTile(
    dense: true,
    title: Text(label),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(dimension),
        const SizedBox(height: 2),
        SelectableText(value?.toString() ?? 'Unavailable'),
      ],
    ),
  );

  String? _percent(double? value) =>
      value == null ? null : '${(value * 100).round()}%';

  Widget _sectionTitle(BuildContext context, String text) =>
      Text(text, style: Theme.of(context).textTheme.titleLarge);

  String _freshness(FreshnessState state) => switch (state) {
    FreshnessState.fresh => 'Fresh',
    FreshnessState.stale => 'Stale cache',
    FreshnessState.expired => 'Expired cache',
  };
}
