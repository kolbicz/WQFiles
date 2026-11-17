> **Requires:** iOS 26.0 – 26.7.2, or iOS 27.0 up to 27.3 beta 1. **Not supported:** iOS 27.3 beta 2 and later, where Apple patched worse_query. Tested on iOS 27.0.1, 27.2.1, 27.3 beta 1 (confirmed by a user) and 26.7.1; see [Tested devices](https://github.com/kolbicz/WQFiles#tested-devices).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.18

Your own inspectors, your own cleaning targets, and Japanese.

## New

- **Custom inspectors** ([#45](https://github.com/kolbicz/WQFiles/issues/45)): small JavaScript programs that show a file's contents your way. Long-press a file → **Open As → Custom Inspector…**. WQ Files ships only the runtime; the inspectors are yours.
  - **Install:** open a `.zip` holding an inspector with WQ Files (share sheet, AirDrop, Files app), or copy its folder into **Settings → Inspectors**. Installing one with the same name again updates it.
  - **Write one:** a folder with `manifest.json` and `inspect.js`. The script gets the file as bytes, as text and, for property lists, already parsed, and returns sections with rows or text. A `data.json` can hold your own lookup tables. Two examples and the full format are in the [README](https://github.com/kolbicz/WQFiles#custom-inspectors).
  - **Results:** tap a value to copy it; Share sends everything as text. Script errors show with their line number.
  - **Safe by design:** inspectors only read. A script has no access to other files, the network or the app, and is stopped after 2 seconds.
- **Your own folders and files in the Cache Cleaner:** long-press a folder or file inside an app's data → **Add to Cache Cleaner**. Instagram, for example, keeps uploaded videos in `Library/Application Support/Instagram/VideoUpload` long after they're posted.
  - Choose **Always Select** (selected after every scan and by Select All, like caches) or **Select by Hand** (you pick it each time). Long-press it in the Cache Cleaner to switch **Select Automatically** later, or to take it off the list.
  - A folder is emptied (the folder itself stays), a file is deleted.
  - Only add what the app can do without: anything it keeps there (drafts, downloads, logins) is gone once cleaned. The app's settings folders can't be added.
  - Saved per app, so it keeps working when the app moves to a new container.
- **Japanese** ([#69](https://github.com/kolbicz/WQFiles/pull/69)), the 14th language. Thanks to kinboy56.

## Credit

New design: GpGp700. Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Resumable scans: hhh2210. Custom inspectors idea: deltaII. Translations: iosrxwy and FrogTool (Simplified Chinese), kinboy56 (Japanese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian), romlayvn-93 (Vietnamese), buraakkcayir (Turkish review). Thanks to everyone who sent screenshots and Logs. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `177b383c541f6deb04db331a8c7b5ed3ba8f574d85e24a72cb867f3699550a18`
