> **Requires:** iOS 26.0 – 26.7.2, or iOS 27.0 up to 27.3 beta 1. **Not supported:** iOS 27.3 beta 2 and later, where Apple patched worse_query. Tested on iOS 27.0.1, 27.2.1, 27.3 beta 1 (confirmed by a user) and 26.7.1; see [Tested devices](https://github.com/kolbicz/WQFiles#tested-devices).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.19

A small fix release, plus optional App Store icons.

## New

- **Settings → App Store Icons** (off by default): other apps' icons can't be read with worse_query, so WQ Files can fetch them from Apple's public App Store lookup instead. This sends the bundle ids of your installed apps and your region to Apple. Sideloaded apps and apps that were removed from the App Store keep the placeholder. Icons are stored in WQ Files (about 7 KB each, not backed up); turning the setting off deletes them.

## Fixed

- **Apps with one-word bundle ids** like Pinterest (`pinterest`) showed "container identity unavailable" and 0 KB, and couldn't be opened, backed up or cleared. They work now.
- **App icons:** other apps' icons can't be read with worse_query, so they show a placeholder. Third-party apps now all get the neutral one, instead of misleading guesses like the Books icon for Facebook or the Music icon for TikTok. Apple services that iOS only gives a placeholder for no longer show iOS's grey grid in dark mode.
- **iOS 27 beta 5 / public beta 3** ([#70](https://github.com/kolbicz/WQFiles/issues/70)): after swiping back from App Backups, the first row on the Backups tab stopped responding. It keeps working now. The blurred band under the bar can still look too tall on that beta; that's an iOS bug. Release versions of iOS aren't affected.

## Credit

New design: GpGp700. Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Resumable scans: hhh2210. Custom inspectors idea: deltaII. Translations: iosrxwy and FrogTool (Simplified Chinese), kinboy56 (Japanese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian), romlayvn-93 (Vietnamese), buraakkcayir (Turkish review). Thanks to control0forver for testing four debug builds, and to everyone who sent screenshots and Logs. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `912f036be87cfe682e6ec8fba7e58ceda2e9f2b77c2ac3f7e25e026e25b1d79f`
