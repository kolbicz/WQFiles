//
//  WQShortcuts.h
//  WQ Files
//
//  What the Shortcuts actions (WQShortcuts.swift, App Intents) do. Each call
//  runs the same code as the matching action in the app, on the same serial
//  I/O queue, and follows the same rules: Allow Deleting, backups of deleted
//  and replaced files, never replacing an item by accident. Everything that
//  changes files also needs Settings → Allow Shortcuts to Change Files.
//
//  Foundation types only: this header is the Swift bridging header.
//
//  GPL-3.0-or-later.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The outcome of one action. `message` is set when `ok` is NO.
@interface WQShortcutResult : NSObject
@property (nonatomic) BOOL ok;
@property (nonatomic, copy, nullable) NSString *message;
@property (nonatomic, copy, nullable) NSString *path;              // the item made, moved or renamed
@property (nonatomic, copy, nullable) NSArray<NSString *> *paths;  // List Folder
@property (nonatomic) unsigned long long bytes;                    // Clean Caches: bytes freed
@end

// Settings → Allow Shortcuts to Change Files (off until the user turns it on).
BOOL wq_shortcuts_may_change(void);
void wq_set_shortcuts_may_change(BOOL allowed);

// Reading: always allowed.
WQShortcutResult *wq_shortcut_list(NSString *folder);
// Copies a file to a temporary place of WQ Files' own and gives that path.
WQShortcutResult *wq_shortcut_export(NSString *path);

// Changing: need the setting. A name that is taken gives "Name 2", as in the app.
WQShortcutResult *wq_shortcut_copy(NSString *path, NSString *toFolder);
WQShortcutResult *wq_shortcut_move(NSString *path, NSString *toFolder);
WQShortcutResult *wq_shortcut_rename(NSString *path, NSString *newName);
WQShortcutResult *wq_shortcut_new_folder(NSString *folder, NSString *name);
// `localFile` is a file the shortcut handed over. With `replace`, an existing
// file of that name is replaced (and backed up first); without, kept.
WQShortcutResult *wq_shortcut_save(NSString *localFile, NSString *toFolder, NSString *name, BOOL replace);
// Also needs Allow Deleting. Files go to Recently Deleted first, as in the app.
WQShortcutResult *wq_shortcut_delete(NSString *path);

// Apps, by bundle id (implemented with the Apps code in WQApps.m).
// Clears Library/Caches and tmp. Needs the setting and Allow Deleting.
WQShortcutResult *wq_shortcut_clean_caches(NSString *bundleID);
// Backs up Documents and Library like Apps → Back Up. Needs the setting.
WQShortcutResult *wq_shortcut_backup_app(NSString *bundleID);

// For WQApps.m: the refusal when the setting (and, with `deleting`, Allow
// Deleting) is off; nil when the action may run.
WQShortcutResult *_Nullable wq_shortcut_refusal(BOOL deleting);
WQShortcutResult *wq_shortcut_failure(NSString *_Nullable message);

NS_ASSUME_NONNULL_END
