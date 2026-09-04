import 'package:obtainium/catalog/accounts/credential_store.dart';
import 'package:obtainium/catalog/data/catalog_repository.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';

class AccountService {
  final CatalogRepository catalog;
  final CredentialStore credentials;
  final AppsProvider apps;
  final SettingsProvider settings;

  const AccountService({
    required this.catalog,
    required this.credentials,
    required this.apps,
    required this.settings,
  });

  Future<ProviderAccount> add({
    required ProviderKind provider,
    required String apiBaseUrl,
    required String webBaseUrl,
    required String token,
    required String label,
  }) async {
    final adapter = catalog.adapterFor(provider, webBaseUrl);
    final account = await catalog.addAccount(
      adapter: adapter,
      apiBaseUrl: apiBaseUrl,
      webBaseUrl: webBaseUrl,
      token: token,
      label: label,
      storeCredential: credentials.put,
    );
    apps.scheduleAutoExport();
    return account;
  }

  Future<void> replaceToken(ProviderAccount account, String token) async {
    final adapter = catalog.adapterFor(account.provider, account.webBaseUrl);
    final validation = await adapter.validateAccount(
      apiBaseUrl: account.apiBaseUrl,
      webBaseUrl: account.webBaseUrl,
      token: token,
    );
    if (validation.username.toLowerCase() != account.username.toLowerCase()) {
      throw const FormatException(
        'Replacement token belongs to a different account',
      );
    }
    await credentials.put(account, token);
    await catalog.database.upsertAccount(
      account.copyWith(
        validatedAt: DateTime.now().toUtc(),
        reconnectRequired: false,
        effectiveScopes: validation.effectiveScopes,
      ),
    );
    apps.scheduleAutoExport();
  }

  Future<void> delete(ProviderAccount account) async {
    await apps.ready;
    final dependants = apps.apps.values
        .map((e) => e.app)
        .where((app) => app.accountId == account.id)
        .map(
          (app) => app.copyWith(
            additionalSettings: {
              ...app.additionalSettings,
              'accountReconnectRequired': true,
            },
          ),
        )
        .toList();
    if (dependants.isNotEmpty) {
      await apps.saveApps(
        dependants,
        attemptToCorrectInstallStatus: false,
        reuseInstalledInfo: true,
      );
    }
    await catalog.deleteAccount(account, deleteCredential: credentials.delete);
    apps.scheduleAutoExport();
  }

  Future<List<ForgeRepository>> listMyRepositories(
    ProviderAccount account,
  ) async {
    final adapter = catalog.adapterFor(account.provider, account.webBaseUrl);
    final repositories = <ForgeRepository>[];
    PageCursor? cursor;
    do {
      final page = await adapter.listAccessibleRepositories(
        account: account,
        cursor: cursor,
      );
      repositories.addAll(page.repositories);
      for (final repository in page.repositories) {
        await catalog.database.upsertForgeRepository(repository);
      }
      cursor = page.next;
    } while (cursor != null);
    return repositories;
  }

  /// Migrates Obtainium's two legacy plaintext global PAT values. A plaintext
  /// value is deleted only after validation, encryption, account persistence,
  /// and subscription rewrites all succeed.
  Future<Map<String, Object>> migrateLegacyCredentials() async {
    await apps.ready;
    final prefs = settings.prefs;
    if (prefs == null) {
      throw StateError(
        'Settings must be initialized before credential migration',
      );
    }
    final results = <String, Object>{};
    for (final legacy in const [
      (
        key: 'github-creds',
        provider: ProviderKind.github,
        api: 'https://api.github.com',
        web: 'https://github.com',
      ),
      (
        key: 'gitlab-creds',
        provider: ProviderKind.gitlab,
        api: 'https://gitlab.com/api/v4',
        web: 'https://gitlab.com',
      ),
    ]) {
      var token = prefs.getString(legacy.key);
      if (token == null || token.trim().isEmpty) continue;
      if (legacy.provider == ProviderKind.github && token.contains(':')) {
        token = token.substring(token.indexOf(':') + 1);
      }
      try {
        final account = await add(
          provider: legacy.provider,
          apiBaseUrl: legacy.api,
          webBaseUrl: legacy.web,
          token: token,
          label: legacy.provider == ProviderKind.github ? 'GitHub' : 'GitLab',
        );
        final host = Uri.parse(legacy.web).host.toLowerCase();
        final migratedApps = apps.apps.values
            .map((e) => e.app)
            .where((app) => Uri.tryParse(app.url)?.host.toLowerCase() == host)
            .map(
              (app) => app.copyWith(
                accountId: account.id,
                additionalSettings: {
                  ...app.additionalSettings,
                  'accountId': account.id,
                  'accountProvider': legacy.provider.name,
                  'accountHost': canonicalHost(account.apiBaseUrl),
                  'accountReconnectRequired': false,
                },
              ),
            )
            .toList();
        if (migratedApps.isNotEmpty) {
          await apps.saveApps(
            migratedApps,
            attemptToCorrectInstallStatus: false,
            reuseInstalledInfo: true,
          );
        }
        await prefs.remove(legacy.key);
        results[legacy.key] = account;
      } catch (error) {
        results[legacy.key] = error;
      }
    }
    return results;
  }
}
