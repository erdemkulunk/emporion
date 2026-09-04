import 'package:flutter/material.dart';
import 'package:obtainium/catalog/accounts/account_service.dart';
import 'package:obtainium/catalog/catalog_provider.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:provider/provider.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final catalog = context.watch<CatalogProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Provider accounts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addAccount,
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
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
            child: catalog.accounts.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Accounts are optional. Public catalog requests never use a token. '
                        'Add a least-scope read token to explore private repositories.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: catalog.accounts.length,
                    itemBuilder: (context, index) =>
                        _accountCard(catalog.accounts[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _accountCard(ProviderAccount account) {
    final scopes = account.effectiveScopes?.trim();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: ListTile(
        leading: Icon(_providerIcon(account.provider)),
        title: Text(account.label),
        subtitle: Text(
          [
            '${account.username} · ${Uri.parse(account.webBaseUrl).host}',
            if (account.reconnectRequired) 'Reconnect required',
            if (scopes != null && scopes.isNotEmpty) 'Scopes: $scopes',
            'Validated ${account.validatedAt.toLocal()}',
          ].join('\n'),
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'repositories':
                _showRepositories(account);
              case 'replace':
                _replaceToken(account);
              case 'delete':
                _deleteAccount(account);
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'repositories',
              child: Text('My repositories'),
            ),
            PopupMenuItem(value: 'replace', child: Text('Replace token')),
            PopupMenuItem(value: 'delete', child: Text('Delete account')),
          ],
        ),
      ),
    );
  }

  Future<void> _addAccount() async {
    final input = await showDialog<_AccountInput>(
      context: context,
      builder: (context) => const _AccountDialog(),
    );
    if (input == null || !mounted) return;
    await _run(() async {
      await context.read<AccountService>().add(
        provider: input.provider,
        apiBaseUrl: input.apiBaseUrl,
        webBaseUrl: input.webBaseUrl,
        token: input.token,
        label: input.label,
      );
      if (mounted) await context.read<CatalogProvider>().reloadConfiguration();
    });
  }

  Future<void> _replaceToken(ProviderAccount account) async {
    final controller = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Replace ${account.label} token'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'API token'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Validate & replace'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (token == null || token.isEmpty || !mounted) return;
    await _run(() async {
      await context.read<AccountService>().replaceToken(account, token);
      if (mounted) await context.read<CatalogProvider>().reloadConfiguration();
    });
  }

  Future<void> _deleteAccount(ProviderAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${account.label}?'),
        content: const Text(
          'The encrypted token and private cached results will be deleted. '
          'Installed apps remain installed; dependent subscriptions will require reconnection.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await context.read<AccountService>().delete(account);
      if (mounted) await context.read<CatalogProvider>().reloadConfiguration();
    });
  }

  Future<void> _showRepositories(ProviderAccount account) async {
    await _run(() async {
      final repositories = await context
          .read<AccountService>()
          .listMyRepositories(account);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          builder: (context, controller) => ListView.builder(
            controller: controller,
            itemCount: repositories.length,
            itemBuilder: (context, index) {
              final repository = repositories[index];
              return ListTile(
                leading: Icon(
                  repository.isPrivate ? Icons.lock_outline : Icons.public,
                ),
                title: Text(repository.path),
                subtitle: Text(repository.summary ?? 'No description'),
              );
            },
          ),
        ),
      );
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  IconData _providerIcon(ProviderKind provider) => switch (provider) {
    ProviderKind.github => Icons.code,
    ProviderKind.gitlab => Icons.account_tree_outlined,
    ProviderKind.forgejo => Icons.fork_right,
    ProviderKind.fdroid => Icons.android,
  };
}

class _AccountInput {
  final ProviderKind provider;
  final String apiBaseUrl;
  final String webBaseUrl;
  final String token;
  final String label;

  const _AccountInput({
    required this.provider,
    required this.apiBaseUrl,
    required this.webBaseUrl,
    required this.token,
    required this.label,
  });
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog();

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  ProviderKind provider = ProviderKind.github;
  late final TextEditingController api;
  late final TextEditingController web;
  final label = TextEditingController();
  final token = TextEditingController();

  @override
  void initState() {
    super.initState();
    api = TextEditingController(text: 'https://api.github.com');
    web = TextEditingController(text: 'https://github.com');
  }

  @override
  void dispose() {
    api.dispose();
    web.dispose();
    label.dispose();
    token.dispose();
    super.dispose();
  }

  void _selectProvider(ProviderKind value) {
    setState(() {
      provider = value;
      switch (value) {
        case ProviderKind.github:
          api.text = 'https://api.github.com';
          web.text = 'https://github.com';
        case ProviderKind.gitlab:
          api.text = 'https://gitlab.com/api/v4';
          web.text = 'https://gitlab.com';
        case ProviderKind.forgejo:
          api.text = 'https://codeberg.org/api/v1';
          web.text = 'https://codeberg.org';
        case ProviderKind.fdroid:
          throw StateError('F-Droid does not use provider accounts');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add provider account'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<ProviderKind>(
              initialValue: provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items:
                  const [
                        ProviderKind.github,
                        ProviderKind.gitlab,
                        ProviderKind.forgejo,
                      ]
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value.name),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) _selectProvider(value);
              },
            ),
            TextField(
              controller: web,
              decoration: const InputDecoration(labelText: 'Web base URL'),
            ),
            TextField(
              controller: api,
              decoration: const InputDecoration(labelText: 'API base URL'),
            ),
            TextField(
              controller: label,
              decoration: const InputDecoration(labelText: 'Label (optional)'),
            ),
            TextField(
              controller: token,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'API token'),
            ),
            const SizedBox(height: 12),
            Text(switch (provider) {
              ProviderKind.github =>
                'Use a fine-grained token with Metadata, Contents, and Issues read access. Classic repo is a broad fallback.',
              ProviderKind.gitlab =>
                'Use read_api and add read_repository only when private release assets require it.',
              ProviderKind.forgejo =>
                'Use read:repository, read:issue, and read:user when the instance supports granular scopes.',
              ProviderKind.fdroid => '',
            }, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (token.text.trim().isEmpty) return;
            Navigator.pop(
              context,
              _AccountInput(
                provider: provider,
                apiBaseUrl: api.text.trim(),
                webBaseUrl: web.text.trim(),
                token: token.text,
                label: label.text.trim(),
              ),
            );
          },
          child: const Text('Validate & save'),
        ),
      ],
    );
  }
}
