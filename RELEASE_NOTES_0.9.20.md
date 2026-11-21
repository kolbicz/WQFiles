> **Requires:** iOS 26.0 – 26.7.2, or iOS 27.0 up to 27.3 beta 1. **Not supported:** iOS 27.3 beta 2 and later, where Apple patched worse_query. Tested on iOS 27.0.1, 27.2.1, 27.3 beta 1 (confirmed by a user) and 26.7.1; see [Tested devices](https://github.com/kolbicz/WQFiles#tested-devices).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.20

Apps Manager backups, and safer handling of databases that are in use.

## New

- **Import Apps Manager backups** ([#19](https://github.com/kolbicz/WQFiles/issues/19)): **Apps** → tap the app → **Import as Backup…** now accepts `.adbk` files from Apps Manager. The app's data is saved as a normal WQ Files backup, ready to restore.
  - Only the app's own data folder is imported. App Group data in the file isn't, because WQ Files backups don't include App Groups. The keychain items Apps Manager saves are encrypted, so they can't be imported either. When you import, WQ Files lists what it left out.
  - If the file says it belongs to a different app than the one you tapped, WQ Files asks first, as with any other import.
  - Opening an `.adbk` from the Files app or the share sheet doesn't start an import; start it from Apps.

## Fixed

- **Files another app is using:** deleting or replacing them, for example an app's database in its App Group while the app runs, failed with "Resource temporarily unavailable (errno 35)". WQ Files now says another app is using the file and that quitting that app and trying again should work. Its extensions or widgets can keep the file open even after you quit it.
- **Databases in use stay intact:** an app's database comes with `-wal` and `-shm` files next to it, and while the app runs, iOS doesn't lock the `-wal` file. WQ Files could delete or replace it while refusing the database file, which lost the app's newest data. Now a database and its `-wal`, `-shm` and `-journal` files are only changed together: if one of them is in use, none of them is touched. This applies to deleting (also whole folders), replacing on import and editing.
- **Deleting or importing several files at once:** each database is handled before its `-wal` and `-shm` files, which are skipped if the database itself couldn't be deleted or replaced. "N of M files were imported" is translated now.

## Credit

New design: GpGp700. Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Resumable scans: hhh2210. Custom inspectors idea: deltaII. Translations: iosrxwy and FrogTool (Simplified Chinese), kinboy56 (Japanese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian), romlayvn-93 (Vietnamese), buraakkcayir (Turkish review). Thanks to braless for the Apps Manager sample, and to everyone who sent screenshots and Logs. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `9ddfa3c1ff01de4d76f601d3b6b76390436136d529f029b9bfaa48c501cfe197`
