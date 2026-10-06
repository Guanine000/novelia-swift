# Novelia iOS port (MVP)

An independent iOS-native prototype for the reading flow of [nobYoQ/novelia](https://github.com/nobYoQ/novelia). The upstream repository is not cloned or modified here. This MVP is a new Swift implementation with fictional local sample content; it does not include upstream source code, account credentials, or branding assets.

## Included

- SwiftUI demo shelf, live discovery search, and remote book details
- Chapter reader with original / translated / bilingual modes
- Read-only Novelia API connection for online search, book metadata, chapter lists, and chapter text
- Novelia account login through the upstream unified authentication page, with app-token storage in Keychain
- Adjustable reader text size
- Per-book reading progress and chapter bookmarks in `UserDefaults`
- iOS 17+ presentation

## Current limits

- The shelf uses `DemoLibrary`; the discovery tab calls the public Novelia API at `https://n.novelia.cc/api/`.
- Login and bearer-token attachment are connected for the novel account. Forum login, automatic 401 refresh, authenticated write operations, source/mirror selection, and ECH transport are not connected. If the network requires ECH or blocks the API host, remote requests will fail and show an in-app error.
- ECH transport, forum, WebDAV sync, offline download queues, import/export, and TTS are not ported yet.
- Demo Japanese and Chinese text is fictional and exists only to exercise the reading UI.

## Open in Xcode

Open `NoveliaIOS.xcodeproj` in Xcode 15 or newer and run the `Novelia` scheme on an iPhone simulator. The deployment target is iOS 17. `Package.swift` separately exposes the platform-independent model and sample library as `NoveliaIOSCore`.

The current machine has Swift command-line tools but no full Xcode installation, so an iOS simulator build could not be produced in this environment.

## Porting boundary

The upstream project uses Kotlin, Jetpack Compose, Android-specific persistence/background APIs, and a Go ECH transport built with the Android NDK. This prototype adapts documented list, detail, chapter, and novel-login flows; authenticated write APIs still need their own iOS implementation. Before reusing upstream implementation code in a distributable app, review its GPL-3.0-only terms and all third-party notices.
