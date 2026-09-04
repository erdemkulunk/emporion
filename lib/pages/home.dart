import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/catalog/catalog_provider.dart';
import 'package:obtainium/catalog/models.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/pages/explore.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/utils/nav_helper.dart';
import 'package:provider/provider.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final SourceProvider sourceProvider;
  late final SettingsProvider settingsProvider;
  late final AppsProvider appsProvider;

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  bool _providersInitialized = false;

  final GlobalKey<AppsPageState> appsPageKey = GlobalKey<AppsPageState>();
  String? selectedAppId;
  bool appsSelecting = false;
  int destinationIndex = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_providersInitialized) {
      sourceProvider = context.read<SourceProvider>();
      settingsProvider = context.read<SettingsProvider>();
      appsProvider = context.read<AppsProvider>();
      _providersInitialized = true;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showWelcomeDialogs();
      if (!mounted) return;
      unawaited(initDeepLinks());
    });
  }

  void selectApp(String appId) {
    destinationIndex = 1;
    selectedAppId = appId;
    setState(() {});
  }

  void clearSelectedApp() {
    selectedAppId = null;
    setState(() {});
  }

  void setAppsSelecting(bool has) {
    appsSelecting = has;
    setState(() {});
  }

  Future<bool> waitUntil(
    bool Function() condition, {
    Duration interval = const Duration(milliseconds: 50),
    int maxAttempts = 100,
  }) async {
    var attempts = 0;
    while (!condition()) {
      if (++attempts > maxAttempts) return false;
      await Future.delayed(interval);
    }
    return true;
  }

  void pushAddApp({String? initialUrl}) {
    NavHelper.pushAddAppPage(context, initialUrl: initialUrl);
  }

  void pushSettings() {
    NavHelper.pushSettingsPage(context);
  }

  Future<void> showWelcomeDialogs() async {
    final sp = settingsProvider;
    if (!sp.welcomeShown) {
      await showDialog(
        context: context,
        builder: (BuildContext ctx) {
          return AlertDialog(
            title: Text(tr('welcome')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 20,
              children: [
                Text(tr('documentationLinksNote')),
                const LinkText(
                  text:
                      'https://github.com/erdemkulunk/emporion/blob/main/README.md',
                  url:
                      'https://github.com/erdemkulunk/emporion/blob/main/README.md',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            actions: [
              FilledButton.tonal(
                autofocus: sp.isTV,
                onPressed: () {
                  sp.welcomeShown = true;
                  Navigator.of(context).pop(null);
                },
                child: Text(tr('ok')),
              ),
            ],
          );
        },
      );
    }
    if (!mounted) return;
    if (!sp.googleVerificationWarningShown) {
      await showDialog(
        context: context,
        builder: (BuildContext ctx) {
          return AlertDialog(
            title: Text(tr('note')),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 20,
              children: [
                Text(tr('googleVerificationWarningP1')),
                LinkText(
                  text: tr('googleVerificationWarningP2'),
                  url: 'https://keepandroidopen.org/',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(tr('googleVerificationWarningP3')),
              ],
            ),
            actions: [
              FilledButton.tonal(
                autofocus: sp.isTV,
                onPressed: () {
                  sp.googleVerificationWarningShown = true;
                  Navigator.of(context).pop(null);
                },
                child: Text(tr('ok')),
              ),
            ],
          );
        },
      );
    }
  }

  Future<void> initDeepLinks() async {
    _appLinks = AppLinks();

    Future<void> goToAddApp(String data) async {
      if (context.mounted) pushAddApp(initialUrl: data);
    }

    Future<void> goToExistingApp(String appId) async {
      if (!mounted) return;
      setState(() => destinationIndex = 1);
      await waitUntil(
        () => appsPageKey.currentState != null,
        interval: const Duration(milliseconds: 100),
        maxAttempts: 50,
      );
      await appsPageKey.currentState?.openAppById(appId);
    }

    Future<void> interpretLink(Uri uri) async {
      final action = uri.host;
      final data =
          uri.queryParameters['url'] ??
          (uri.path.length > 1
              ? Uri.decodeComponent(uri.path.substring(1))
              : '');
      try {
        if (action == 'add') {
          final AppsProvider ap = appsProvider;
          await waitUntil(
            () => !ap.loadingApps,
            interval: const Duration(milliseconds: 10),
            maxAttempts: 500,
          );

          String? standardizedUrl;
          try {
            standardizedUrl = sourceProvider
                .getSource(data)
                .standardizeUrl(data);
          } catch (_) {
            standardizedUrl = null;
          }

          final AppInMemory? existingApp = ap.apps.values
              .where(
                (AppInMemory a) =>
                    a.app.url == standardizedUrl || a.app.url == data,
              )
              .firstOrNull;

          if (existingApp != null) {
            await goToExistingApp(existingApp.app.id);
          } else {
            await goToAddApp(data);
          }
        } else if (action == 'app' || action == 'apps') {
          if (!context.mounted) return;
          if (await showDialog(
                context: context,
                builder: (BuildContext ctx) {
                  return GeneratedFormModal(
                    title: tr(
                      'importX',
                      args: [
                        (action == 'app' ? tr('app') : tr('appsString'))
                            .toLowerCase(),
                      ],
                    ),
                    items: const [],
                    additionalWidgets: [
                      ExpansionTile(
                        title: Text(tr('rawJson')),
                        children: [
                          Text(
                            data,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ) !=
              null) {
            if (!context.mounted) return;
            final ap = appsProvider;
            dynamic parsedData;
            try {
              parsedData = jsonDecode(data);
            } catch (e) {
              AppLogger.error(e, message: 'Failed to decode deep-link JSON');
              throw ObtainiumError(tr('invalidInput'));
            }
            final importPayload = jsonEncode(<String, dynamic>{
              'apps': action == 'app' ? <dynamic>[parsedData] : parsedData,
            });
            final result = await ap.import(importPayload);
            if (mounted) {
              showMessage(
                tr(
                  'importedX',
                  args: [plural('apps', result.key.length).toLowerCase()],
                ),
                context,
              );
            }
          }
        } else if (action == 'refresh') {
          final targetId = uri.queryParameters['id'];
          await appsProvider.checkUpdates(
            forceAll: targetId == null,
            specificIds: targetId != null ? [targetId] : null,
          );
        } else {
          throw ObtainiumError(tr('unknown'));
        }
      } catch (e) {
        if (mounted) {
          showError(e, context);
        }
      }
    }

    final initialLink = await _appLinks.getInitialLink();
    if (initialLink != null) {
      await interpretLink(initialLink);
    }

    if (!mounted) return;
    var dedupeInitial = initialLink != null;
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      if (dedupeInitial) {
        dedupeInitial = false;
        if (uri == initialLink) {
          return;
        }
      }
      await interpretLink(uri);
    });
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  Future<void> subscribeFromCatalog(CatalogEntry entry, bool install) async {
    final origin = await _chooseInstallOrigin(entry);
    if (origin == null) {
      throw ObtainiumError('Install source selection was cancelled');
    }
    if (!mounted) {
      throw ObtainiumError('The catalog page is no longer active');
    }
    final settings = <String, dynamic>{
      'emporionCatalogSubscription': true,
      'includePrereleases': false,
      'releaseChannel': 'stable',
    };
    late final AppSource source;
    late final String url;
    var sourceIsOverridden = false;

    if (origin.kind == CatalogOriginKind.fdroidPackage) {
      final package = entry.fdroidPackage;
      if (package == null) {
        throw ObtainiumError(
          'Verified F-Droid package metadata is unavailable',
        );
      }
      final repository = context
          .read<CatalogProvider>()
          .fdroidRepositories
          .where((repo) => repo.id == package.repositoryId)
          .firstOrNull;
      if (repository == null ||
          !repository.enabled ||
          repository.trustState != RepositoryTrustState.trusted) {
        throw ObtainiumError('The selected F-Droid repository is not trusted');
      }
      settings
        ..['appId'] = package.packageName
        ..['appIdOrName'] = package.packageName
        ..['fdroidSignerSha256'] = package.signerSha256
        ..['trySelectingSuggestedVersionCode'] = true;
      if (repository.canonicalUrl == FDroid.repositoryUrl) {
        source = FDroid();
        url = 'https://f-droid.org/packages/${package.packageName}';
      } else {
        source = FDroidRepo();
        url =
            '${repository.canonicalUrl}?appId=${Uri.encodeQueryComponent(package.packageName)}';
        sourceIsOverridden = true;
      }
    } else {
      final repository = entry.forgeRepository;
      if (repository == null) {
        throw ObtainiumError('Forge repository metadata is unavailable');
      }
      url = repository.webUrl.toString();
      final overrideSource = switch (repository.provider) {
        ProviderKind.github when repository.host != 'github.com' => 'GitHub',
        ProviderKind.gitlab when repository.host != 'gitlab.com' => 'GitLab',
        ProviderKind.forgejo => 'Codeberg',
        _ => null,
      };
      source = sourceProvider.getSource(url, overrideSource: overrideSource);
      sourceIsOverridden = overrideSource != null;
      if (origin.accountId != null) {
        settings
          ..['accountId'] = origin.accountId
          ..['accountHost'] = repository.host
          ..['accountProvider'] = repository.provider.name;
      }
      final installableAssets = entry.installOrigins
          .where((origin) => origin.kind == CatalogOriginKind.forgeRelease)
          .toList();
      if (installableAssets.length > 1) {
        settings['apkFilterRegEx'] = '^${RegExp.escape(origin.label)}\$';
      }
    }

    var app = await sourceProvider.getApp(
      source,
      url,
      settings,
      sourceIsOverriden: sourceIsOverridden,
      inferAppIdIfOptional: origin.expectedPackageName != null,
    );
    app = app.copyWith(
      expectedSha256: app.expectedSha256 ?? origin.expectedSha256,
      expectedSize: app.expectedSize ?? origin.expectedSize,
      expectedSignerSha256:
          app.expectedSignerSha256 ?? origin.expectedSignerSha256,
      accountId: app.accountId ?? origin.accountId,
      expectedVersionCode:
          app.expectedVersionCode ?? origin.expectedVersionCode,
    );
    final duplicate = appsProvider.apps.values
        .where(
          (existing) =>
              existing.app.id == app.id || existing.app.url == app.url,
        )
        .firstOrNull;
    if (duplicate != null) {
      throw ObtainiumError(
        'Already subscribed: ${duplicate.app.name} (${duplicate.app.id})',
      );
    }
    await appsProvider.saveApps([app], onlyIfExists: false);
    if (install && !mounted) {
      throw ObtainiumError('The catalog page is no longer active');
    }
    if (install) {
      await appsProvider.downloadAndInstallLatestApps([app.id], context);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            install
                ? '${app.name} was subscribed and sent to the installer'
                : '${app.name} was added to Library',
          ),
        ),
      );
    }
  }

  Future<InstallOrigin?> _chooseInstallOrigin(CatalogEntry entry) async {
    final origins = entry.installOrigins;
    if (origins.isEmpty) {
      throw ObtainiumError('No compatible APK source is available');
    }
    final installed = entry.packageName == null
        ? null
        : appsProvider.apps[entry.packageName!];
    final installedLineage =
        installed?.certificateHashes
            .map((digest) => digest.replaceAll(':', '').toUpperCase())
            .toSet() ??
        const <String>{};
    final lineageMatches = origins
        .where(
          (origin) =>
              origin.expectedSignerSha256 != null &&
              installedLineage.contains(
                origin.expectedSignerSha256!.replaceAll(':', '').toUpperCase(),
              ),
        )
        .toList();
    if (lineageMatches.length == 1) return lineageMatches.single;
    if (origins.length == 1 &&
        origins.single.trusted &&
        origins.single.compatibility != AvailabilityState.unavailable &&
        entry.deviceCompatibility != AvailabilityState.unavailable) {
      return origins.single;
    }
    if (!mounted) return null;
    return showDialog<InstallOrigin>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Choose install origin'),
        children: origins
            .map(
              (origin) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, origin),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    origin.trusted
                        ? Icons.verified_user_outlined
                        : Icons.warning_amber_outlined,
                  ),
                  title: Text(origin.label),
                  subtitle: Text(
                    [
                      origin.sourceUrl.host,
                      origin.trusted
                          ? 'Cryptographically verified repository'
                          : 'Provider metadata; APK identity verified before install',
                      'Compatibility: ${origin.compatibility.name}',
                      if (origin.expectedSha256 != null)
                        'SHA-256 ${origin.expectedSha256}',
                      if (origin.expectedSignerSha256 != null)
                        'Signer ${origin.expectedSignerSha256}',
                    ].join('\n'),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final isTV = context.select<SettingsProvider, bool>((p) => p.isTV);

    final layoutWidth = MediaQuery.sizeOf(context).width;
    final useLargeScreen = isTV || layoutWidth >= 840;
    final useTwoPane = useLargeScreen && !settingsProvider.alwaysUsePhoneLayout;

    final detailPane =
        selectedAppId != null &&
            context.select<AppsProvider, bool>(
              (p) => p.apps.containsKey(selectedAppId),
            )
        ? AppPage(
            key: ValueKey(selectedAppId),
            appId: selectedAppId!,
            onClose: () => clearSelectedApp(),
          )
        : EmptyState(
            icon: Icons.touch_app_outlined,
            message: tr('selectAppForDetails'),
          );

    final appsPage = AppsPage(
      key: appsPageKey,
      onAppSelected: useTwoPane ? selectApp : null,
      selectedAppId: selectedAppId,
      onSelectionChanged: setAppsSelecting,
    );

    void onAddPressed() {
      settingsProvider.selectionClick();
      pushAddApp();
    }

    void onActionsPressed() {
      settingsProvider.selectionClick();
      appsPageKey.currentState?.showSelectedAppActions();
    }

    // Use the same extended (icon + label) FABs on every layout, so the
    // tablet/two-pane UI matches mobile.
    final actionsFab = FloatingActionButton.extended(
      onPressed: onActionsPressed,
      tooltip: plural('action', 2),
      icon: const Icon(Icons.more_vert),
      label: Text(plural('action', 2)),
    );
    final createFabExtended = FloatingActionButton.extended(
      onPressed: onAddPressed,
      tooltip: tr('addApp'),
      icon: const Icon(Icons.add),
      label: Text(tr('add')),
    );

    final loadingApps = context.select<AppsProvider, bool>(
      (p) => p.loadingApps,
    );

    final Widget? fab = isTV
        ? null
        : appsSelecting
        ? actionsFab
        : (loadingApps ? null : createFabExtended);

    final showingLibrary = destinationIndex == 1;
    final Widget destinationContent;
    if (!showingLibrary) {
      destinationContent = ExplorePage(
        onOpenSettings: pushSettings,
        onSubscribe: subscribeFromCatalog,
      );
    } else if (useTwoPane) {
      // Host the FAB in a nested Scaffold around the first pane so it aligns
      // with the app list instead of floating over the detail pane.
      destinationContent = Row(
        children: [
          Expanded(
            flex: 2,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: appsPage,
              floatingActionButton: fab,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(flex: 3, child: detailPane),
        ],
      );
    } else {
      destinationContent = appsPage;
    }

    final content = useLargeScreen
        ? Row(
            children: [
              NavigationRail(
                selectedIndex: destinationIndex,
                onDestinationSelected: (index) =>
                    setState(() => destinationIndex = index),
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.explore_outlined),
                    selectedIcon: Icon(Icons.explore),
                    label: Text('Explore'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.apps_outlined),
                    selectedIcon: Icon(Icons.apps),
                    label: Text('Library'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: destinationContent),
            ],
          )
        : destinationContent;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && showingLibrary && selectedAppId != null) {
          clearSelectedApp();
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: useTwoPane || !showingLibrary
            ? content
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: content,
                ),
              ),
        bottomNavigationBar: useLargeScreen
            ? null
            : NavigationBar(
                selectedIndex: destinationIndex,
                onDestinationSelected: (index) =>
                    setState(() => destinationIndex = index),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.explore_outlined),
                    selectedIcon: Icon(Icons.explore),
                    label: 'Explore',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.apps_outlined),
                    selectedIcon: Icon(Icons.apps),
                    label: 'Library',
                  ),
                ],
              ),
        floatingActionButton: showingLibrary && !useTwoPane ? fab : null,
      ),
    );
  }
}
