> **Requires:** iOS 26.0 – 26.7.2, or iOS 27.0 up to 27.3 beta 1. **Not supported:** iOS 27.3 beta 2 and later, where Apple patched worse_query. Tested on iOS 27.0.1, 27.2.1, 27.3 beta 1 (confirmed by a user) and 26.7.1; see [Tested devices](https://github.com/kolbicz/WQFiles#tested-devices).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.19

A small fix release.

## Fixed

- **Apps with one-word bundle ids** like Pinterest (`pinterest`) showed "container identity unavailable" and 0 KB, and couldn't be opened, backed up or cleared. They work now.
- **App icons:** other apps' icons can't be read with worse_query, so they show a placeholder. Third-party apps now all get the neutral one, instead of misleading guesses like the Books icon for Facebook or the Music icon for TikTok.
- **iOS 27 beta 5 / public beta 3** ([#70](https://github.com/kolbicz/WQFiles/issues/70)): after swiping back from App Backups, the first row on the Backups tab stopped responding. It keeps working now. The blurred band under the bar can still look too tall on that beta; that's an iOS bug. Release versions of iOS aren't affected.

## Credit

New design: GpGp700. Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Resumable scans: hhh2210. Custom inspectors idea: deltaII. Translations: iosrxwy and FrogTool (Simplified Chinese), kinboy56 (Japanese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian), romlayvn-93 (Vietnamese), buraakkcayir (Turkish review). Thanks to control0forver for testing four debug builds, and to everyone who sent screenshots and Logs. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `96e69ccdc366d55cb6aa63a5d1717c15cdec50a5f253fdf8532cf8385c330b13`
