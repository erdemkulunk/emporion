# ![Emporion icon](./assets/graphics/icon_small.png) Emporion

Emporion is an Android app catalog and installer for discovering, evaluating,
subscribing to, installing, and updating applications directly from their
public release sources.

It combines signed F-Droid repositories with GitHub, GitLab, and
Forgejo/Gitea repositories. Search and ranking happen on-device against the
providers' public APIs and Emporion's local SQLite cache; Emporion has no
hosted catalog, crawler, ranking service, or telemetry backend.

## Features

- Explore Android repositories and signed F-Droid packages from one catalog.
- Search and filter by source, category, license, APK availability, device
  compatibility, stars, activity, release cadence, contributors, and issue
  response.
- Compare an explainable 0–100 Emporion score with raw, timestamped metrics
  and confidence.
- Connect personal GitHub, GitLab, Forgejo, Gitea, or Codeberg accounts with
  encrypted API tokens for private repositories.
- Subscribe to APK releases and reuse Obtainium's mature download, package
  inspection, install, and update pipeline.
- Export a credential-free portable configuration and restore subscriptions
  on another device.
- Continue browsing cached catalog data while providers are offline or rate
  limited.

## Sources

- [GitHub](https://github.com/)
- [GitLab](https://gitlab.com/)
- [Forgejo](https://forgejo.org/), [Gitea](https://about.gitea.com/), and
  [Codeberg](https://codeberg.org/)
- [F-Droid](https://f-droid.org/) and custom signed F-Droid repositories
- The additional direct-release sources inherited from Obtainium

## Installation

Release APKs are published at
[github.com/erdemkulunk/emporion/releases](https://github.com/erdemkulunk/emporion/releases).
Use the universal APK unless a device-specific ABI APK is required. Verify the
download against the release's `SHA256SUMS` before installation.

The normal package is `dev.erdem.emporion`; the F-Droid flavor is
`dev.erdem.emporion.fdroid`.

## Development

Emporion is a Flutter application with Android-native Kotlin bridges. The
minimum supported Android API level is 26.

```console
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --flavor normal
```

Release builds require the permanent release keystore and both compile-time
defines:

```console
flutter build apk --release --flavor normal \
  --dart-define=SELF_UPDATE_URL=https://github.com/erdemkulunk/emporion \
  --dart-define=SELF_UPDATE_ASSET_REGEX=^emporion-.*-universal\\.apk$
```

## Upstream and license

Emporion is a GPLv3 fork of
[ImranR98/Obtainium](https://github.com/ImranR98/Obtainium). The imported
baseline is upstream commit
[`00d545b36ea9c2ff74f97a2a73d345771839bf00`](https://github.com/ImranR98/Obtainium/commit/00d545b36ea9c2ff74f97a2a73d345771839bf00).
The Dart package name and `package:obtainium/...` imports remain unchanged to
keep upstream merges tractable.

Copyright and license notices from Obtainium and its contributors are
preserved. Emporion is distributed under the
[GNU General Public License v3](./LICENSE.txt).
