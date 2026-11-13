> **Requires:** iOS 27, or iOS 26.0 – 26.7.2. Tested on iOS 27.0.1, 27.2.1, 26.7.1 and the 27.3 beta (confirmed by a user).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.6

## New

- **Search Inside Folders…** (••• menu): finds names in all subfolders, with progress and **Stop**.
- **Largest Files** (••• menu): the 100 biggest files below a folder, to see where storage goes.
- **Get Info** (long-press): path, kind, size (folders counted), dates, owner, permissions, inode and a file's SHA-256. Tap a row to copy it.
- **Duplicate** and **Copy to Folder…** (long-press): copy files and folders, also into other apps' data, like Move.
- **Favorites:** add a folder from its ••• menu; they're listed under Tools.
- **Reopen Last Folder** ([#41](https://github.com/kolbicz/WQFiles/issues/41)): WQ Files starts in the folder you were in. It's a switch on the start screen.
- **Check for Updates** ([#41](https://github.com/kolbicz/WQFiles/issues/41)): a note on the start screen when a new version is out.
  - **What's sent:** WQ Files reads the public release list on GitHub at most twice a day and sends nothing about your device. This is its only network access.
  - **Turning it off:** use the switch on the start screen.
- **Open ZIP files by tapping them** ([#41](https://github.com/kolbicz/WQFiles/issues/41)): **Extract and Open** unpacks it next to itself and opens the folder. **Open as File** shows the file as before.
- **Thai** ([#52](https://github.com/kolbicz/WQFiles/issues/52)).

## Changed

- **SQLite save** writes through SQLite itself, which takes care of the database's journal and WAL files, so a save is safer if WQ Files is closed midway.
- **App restore** copies and checks the backup in a private folder first, and installs exactly what was checked.
- **Replace All** when importing only replaces the file versions shown in the question; a file that changed meanwhile is imported under a new name.
- **Turkish and Thai:** clearer wording.

## Fixed

- **App names missing** on some devices (e.g. iOS 26.1): when the app database uses a layout WQ Files doesn't know, it now works out where the names are from the database itself. App identities, which decide where backups go, still only come from the app's own folder tag or a known layout. WQ Files also uses the newest database file when iOS keeps an old one, and the Log lists them.
- **App backups could come out empty** when WQ Files didn't have access to the app's folder yet; it worked on the second or third try. Backup now fails with "try again" instead, and an empty backup is never restored (restoring one would empty the app's data).

## Credit

Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Translations: iosrxwy (Simplified Chinese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian). Thanks to everyone who sent Logs and ideas. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `93ab6b1c88623fc4079c88b5881b368d9ff2481a8288d651c5c86b9b46cf3279`
