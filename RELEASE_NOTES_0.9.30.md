> **Requires:** iOS 26.0 – 26.7.2, or iOS 27.0 up to 27.3 beta 1. **Not supported:** iOS 27.3 beta 2 and later, where Apple patched worse_query. Tested on iOS 27.0.1, 27.2.1, 27.3 beta 1 (confirmed by a user) and 26.7.1; see [Tested devices](https://github.com/kolbicz/WQFiles#tested-devices).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.30

Shortcuts actions, and a round of fixes after a full review of the code: safer restores and imports, fewer hangs, and faster lists.

## New

- **Shortcuts actions:** WQ Files now adds actions to the Shortcuts app, for shortcuts and automations.
  - **Files:** List Folder, Get File, Save File, Copy, Move, Rename, New Folder and Delete. They take full paths and work in any app's container, like the file browser.
  - **Apps:** Clean App Caches and Back Up App Data, by bundle identifier. Clean App Caches also takes the identifier of an app extension, as the Cache Cleaner lists them.
  - List Folder and Get File always work. Everything that changes files needs **Settings → Allow Shortcuts to Change Files**, which is off until you turn it on. Deleting and cleaning also need **Allow Deleting**.
  - The actions follow the app's rules: deleted files go to Recently Deleted, a replaced file is kept in Backups, and nothing is replaced by accident: Copy and Save File give "Name 2" for a name that is taken, and Move, Rename and New Folder refuse it.
  - An action that had to wait more than 20 seconds because WQ Files was busy is not run, so nothing is changed after Shortcuts has reported a failure.
  - Most action names and descriptions in the Shortcuts app are in English for now.
  - See [Shortcuts](https://github.com/kolbicz/WQFiles#shortcuts) in the README.
- **Cache Cleaner:** the long-press menu of an app has **Copy Bundle ID**, handy for the Shortcuts actions.

## Fixed

### Files and folders

- **Sort by Size:** when folder sizes finished measuring, the list was put in the new order but the rows on screen weren't. A tap, a swipe to delete or the long-press menu could then act on a different item than the row showed. The rows follow the order now.
- **Folder sizes after an error:** after pulling down on a folder that first couldn't be listed, sizes were not measured until you left and came back.
- **Folders with é, ü, Korean or similar characters in their path** could leave the access cache stuck, so every folder was refused until **Settings → Reset Access Cache**. They open normally now, and a cache that is already stuck is repaired on its own.
- **Folders WQ Files couldn't open** were sometimes reported as cleaned or deleted, with nothing removed. They are reported as not accessible.
- **Pictures over 4 MB** showed cut off, or as a hex dump. They are read whole and scaled down for viewing.
- **Alphabet index** with Folders on Top listed its letters out of order in folders that hold both folders and files.
- **Container roots and WQ Files' own backup folders** could be moved or renamed in the file browser. They are refused, as deleting them already was.
- **Renaming, moving or uploading a file to a `-wal` or `-journal` name** next to a database another app has open is refused, as creating one already was.
- **Importing several files with Keep Both:** when a database got a new name ("db 2.sqlite"), its `-wal` and `-shm` files kept their old names and landed next to the database that was already there, which could damage it. They now get the same new name.

### Apps and backups

- **Import as Backup:** on some devices nothing could be selected in the Files sheet ([#72](https://github.com/kolbicz/WQFiles/issues/72)). It now asks first whether you want to pick a file or a folder, and writes to the Log what the Files sheet returned.
- **An interrupted restore that can't be undone** (the app was removed or reinstalled since, or its safety backup was deleted) blocked every restore of every app, with the same message at each launch. It is closed with a note that says where the data from before is.
- **Imported backups with only Documents or only Library:** restoring one emptied the other folder of the app. It is left as it is now, and the import says when a folder is missing.
- **Import as Backup** says how many symbolic links in the ZIP were left out, instead of calling the result verified without a word.
- **A restore that was refused before it started** left a full "Before restore" copy of the app behind while saying nothing was changed.
- **Selecting backups to delete:** a checked backup couldn't be unchecked.
- **Cache Cleaner:** rows you unchecked were checked again by the rescan that starts on its own after 10 minutes or after cleaning. They stay unchecked; pull down to start over.
- **Recently Deleted:** a database is restored together with its `-wal` and `-shm` files or not at all. Before, a failed restore could still leave the database in place. A `-wal` that was deleted together with its database now comes back with it; before, the database was restored without its latest changes.
- **Apps reinstalled or updated since the app database was written:** the app's icon, its installed/offloaded state and **Open App Bundle** could point at the bundle of an earlier install. The bundle that exists is used.
- **Your own Cache Cleaner entries** were offered as "Add to Cache Cleaner" again in the file browser after the app was reinstalled. They are recognised by app.
- **An interrupted restore** could be closed at launch as "app removed" when the app's folder only couldn't be seen yet. Access is asked for before that is decided.

### Viewers and editors

- **Custom inspectors:** a faulty script could close WQ Files, or keep every later inspector waiting behind it. Scripts are stopped after about twice the time limit in total, and a replacement that doesn't load puts the inspector from before back. Where iOS offers no time limit for scripts, inspectors are not run.
- **Syntax colors** stopped at the first very long text value (for example an embedded image in JSON), and a CSS file with a large embedded image could take minutes. Both are colored quickly and completely.
- **SQLite:**
  - Tapping **Edit** on a large database froze WQ Files until all row counts were done.
  - A whole number too large for the database was stored as a different number without a warning.
  - Scripts whose later statements need the earlier ones (create a table, then fill it) were refused.
  - Scrolling far into a large table got slower with every page.
- **Property lists:** negative numbers and numbers with "e" couldn't be typed into a Real value on iPhone, and "1,5" was refused in regions that write decimals with a comma.
- **Hex editor on iPad:** changing bytes after rotating or resizing the window could close WQ Files.

### Wi-Fi Sharing

- The sharing screen now says that the connection is **not encrypted**: others on the same network can read the password and the files, so share only on a network you trust.
- An upload is refused at the start when the device doesn't have room for it, and only one ZIP is prepared at a time, so a browser can't fill the device's storage.
- A browser that connects and then sends nothing no longer holds a connection for good.

### Start screen and settings

- **Check for Updates** never reported a new version: it looked for the version in the wrong place of the update list. Versions after this one are announced on the start screen.
- **Sharing Password** in the new design's Settings kept showing the old state after it was changed.
- **Theme export:** the temporary copy stayed until the next launch after sharing.
- **Reopen Last Folder** was skipped when the "Not everything works here" notice was shown.
- **Switching New Design** after a failed access check showed "Access check passed", and hid the update notice until the next launch.
- **App Store Icons:** turning the setting on had no effect on lists that were already loaded. Turning it off stops the requests that are under way.
- **Themes** named "Default" or "Color" could be imported but never used.
- **The scan question** ("Scan all files?") could disappear without an answer and leave the Apps and Cache scans waiting until WQ Files was restarted.

## Faster

- **Interrupted scans resume:** measuring an app's folder started from the beginning after every interruption. It continues where it stopped.
- **Less memory** while measuring, cleaning, backing up and restoring large apps.
- **Sharing a folder** no longer holds up folder listings and the Apps and Cache scans while the ZIP is made.
- **Backup folders** and the **Backed Up** filter read the disk once per listing, not on every tap and keystroke.

## Housekeeping

- Temporary copies left behind when WQ Files was closed by iOS (database copies, uploads, ZIPs) are removed at the next launch.
- The in-app Log keeps the newest lines, about 1 MB, and says how many earlier lines it left out.

## Credit

New design: GpGp700. Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Resumable scans: hhh2210. Custom inspectors idea: deltaII. Translations: iosrxwy and FrogTool (Simplified Chinese), kinboy56 (Japanese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian), romlayvn-93 (Vietnamese), buraakkcayir (Turkish review). Thanks to everyone who sent screenshots and Logs. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `28deac3c001962a0431532644452efdba24d97c1913a5d9193f5339aba7b9a11`
