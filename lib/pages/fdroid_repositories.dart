import 'package:flutter/material.dart';
import 'package:obtainium/catalog/catalog_provider.dart';
import 'package:obtainium/catalog/fdroid/fdroid_repository_service.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:provider/provider.dart';

class FdroidRepositoriesPage extends StatefulWidget {
  const FdroidRepositoriesPage({super.key});

  @override
  State<FdroidRepositoriesPage> createState() => _FdroidRepositoriesPageState();
}

class _FdroidRepositoriesPageState extends State<FdroidRepositoriesPage> {
  final Set<String> _busy = {};
  String? _error;

  @override
  Widget build(BuildContext context) {
    final repositories = context.watch<CatalogProvider>().fdroidRepositories;
    return Scaffold(
      appBar: AppBar(title: const Text('F-Droid repositories')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add repository'),
      ),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: repositories.length,
              itemBuilder: (context, index) =>
                  _repositoryCard(repositories[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _repositoryCard(FdroidRepository repository) {
    final busy = _busy.contains(repository.id);
    final trusted = repository.trustState == RepositoryTrustState.trusted;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        children: [
          SwitchListTile(
            value: repository.enabled,
            onChanged: busy ? null : (value) => _setEnabled(repository, value),
            secondary: Icon(
              trusted ? Icons.verified_user_outlined : Icons.gpp_bad_outlined,
            ),
            title: Text(repository.label),
            subtitle: Text(
              '${repository.canonicalUrl}\n${_fingerprint(repository.fingerprint)}',
            ),
          ),
          if (repository.syncError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  repository.syncError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          OverflowBar(
            children: [
              if (!trusted)
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => _confirmFingerprint(repository),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Compare & confirm'),
                ),
              TextButton.icon(
                onPressed: busy || !repository.enabled || !trusted
                    ? null
                    : () => _sync(repository),
                icon: busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: const Text('Sync'),
              ),
              if (repository.id != FdroidRepository.official().id)
                TextButton.icon(
                  onPressed: busy ? null : () => _remove(repository),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final input = await showDialog<_RepositoryInput>(
      context: context,
      builder: (_) => const _RepositoryDialog(),
    );
    if (input == null || !mounted) return;
    await _run('new', () async {
      await context.read<FdroidRepositoryService>().add(
        input: input.url,
        label: input.label,
        enteredFingerprint: input.fingerprint,
        explicitlyConfirmed: input.confirmed,
      );
      if (mounted) await context.read<CatalogProvider>().reloadConfiguration();
    });
  }

  Future<void> _sync(
    FdroidRepository repository,
  ) => _run(repository.id, () async {
    final result = await context.read<FdroidRepositoryService>().sync(
      repository,
      locale: Localizations.localeOf(context).toLanguageTag(),
    );
    if (!mounted) return;
    await context.read<CatalogProvider>().reloadConfiguration();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${result.packageCount} package variants verified (${result.format})',
        ),
      ),
    );
  });

  Future<void> _setEnabled(FdroidRepository repository, bool enabled) => _run(
    repository.id,
    () async {
      await context.read<FdroidRepositoryService>().setEnabled(
        repository,
        enabled,
      );
      if (mounted) await context.read<CatalogProvider>().reloadConfiguration();
    },
  );

  Future<void> _confirmFingerprint(FdroidRepository repository) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Compare signing fingerprint'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Verify this value through an independent channel, then type or paste the complete SHA-256 fingerprint.',
            ),
            const SizedBox(height: 12),
            SelectableText(_fingerprint(repository.fingerprint)),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Confirmed fingerprint',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    await _run(repository.id, () async {
      await context.read<FdroidRepositoryService>().confirmChangedFingerprint(
        repository,
        comparedFingerprint: value,
      );
      if (mounted) await context.read<CatalogProvider>().reloadConfiguration();
    });
  }

  Future<void> _remove(FdroidRepository repository) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${repository.label}?'),
        content: const Text(
          'Cached packages from this repository will be deleted. Existing subscriptions remain in the Library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(repository.id, () async {
      await context.read<FdroidRepositoryService>().remove(repository);
      if (mounted) await context.read<CatalogProvider>().reloadConfiguration();
    });
  }

  Future<void> _run(String id, Future<void> Function() action) async {
    setState(() {
      _busy.add(id);
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  String _fingerprint(String value) {
    final normalized = FdroidRepositoryService.normalizeFingerprint(value);
    return [
      for (var i = 0; i < normalized.length; i += 4)
        normalized.substring(i, (i + 4).clamp(0, normalized.length)),
    ].join(' ');
  }
}

class _RepositoryInput {
  final String url;
  final String label;
  final String fingerprint;
  final bool confirmed;

  const _RepositoryInput(
    this.url,
    this.label,
    this.fingerprint,
    this.confirmed,
  );
}

class _RepositoryDialog extends StatefulWidget {
  const _RepositoryDialog();

  @override
  State<_RepositoryDialog> createState() => _RepositoryDialogState();
}

class _RepositoryDialogState extends State<_RepositoryDialog> {
  final url = TextEditingController();
  final label = TextEditingController();
  final fingerprint = TextEditingController();
  bool confirmed = false;

  @override
  void dispose() {
    url.dispose();
    label.dispose();
    fingerprint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add F-Droid repository'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: url,
            decoration: const InputDecoration(
              labelText: 'HTTPS or fingerprint-bearing link',
            ),
          ),
          TextField(
            controller: label,
            decoration: const InputDecoration(labelText: 'Label (optional)'),
          ),
          TextField(
            controller: fingerprint,
            decoration: const InputDecoration(
              labelText: 'SHA-256 signing fingerprint',
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: confirmed,
            onChanged: (value) => setState(() => confirmed = value == true),
            title: const Text(
              'I compared this fingerprint through an independent channel',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _RepositoryInput(url.text, label.text, fingerprint.text, confirmed),
        ),
        child: const Text('Add'),
      ),
    ],
  );
}
