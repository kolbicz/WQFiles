//
//  WQShortcuts.m
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import "WQShortcuts.h"
#import "WQAccess.h"
#import "WQLocalization.h"
#import "WQUI.h"
#import <sys/stat.h>

@implementation WQShortcutResult
@end

static NSString *const kWQShortcutsChangePref = @"WQShortcutsMayChangeFiles";

BOOL wq_shortcuts_may_change(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kWQShortcutsChangePref];
}

void wq_set_shortcuts_may_change(BOOL allowed)
{
    [NSUserDefaults.standardUserDefaults setBool:allowed forKey:kWQShortcutsChangePref];
}

WQShortcutResult *wq_shortcut_failure(NSString *message)
{
    WQShortcutResult *result = [WQShortcutResult new];
    result.message = message.length ? message : WQLocalized(@"unknown error");
    return result;
}

static WQShortcutResult *wq_shortcut_done(NSString *path)
{
    WQShortcutResult *result = [WQShortcutResult new];
    result.ok = YES;
    result.path = path;
    return result;
}

WQShortcutResult *wq_shortcut_refusal(BOOL deleting)
{
    if (!wq_shortcuts_may_change())
        return wq_shortcut_failure(WQLocalized(@"Shortcuts may not change files. Turn on Allow Shortcuts to Change Files in the settings of WQ Files."));
    if (deleting && !wq_deleting_allowed())
        return wq_shortcut_failure(WQLocalized(@"Turn on Allow Deleting on the start screen of WQ Files to delete, clear or clean."));
    return nil;
}

// Shortcuts hands over text: an absolute path without "." or ".." parts and
// without a trailing slash, or nil.
static NSString *wq_shortcut_path(NSString *text)
{
    NSString *path = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while (path.length > 1 && [path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    if (![path hasPrefix:@"/"] || path.length < 2) return nil;
    for (NSString *part in [[path substringFromIndex:1] componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."]) return nil;
    return path;
}

static BOOL wq_shortcut_name_ok(NSString *name)
{
    return name.length && ![name containsString:@"/"] && ![name isEqualToString:@"."] && ![name isEqualToString:@".."] &&
        [name rangeOfString:@"\0"].location == NSNotFound;
}

// A name in `folder` that nothing uses yet: "Name", "Name 2", … (keeps the extension).
static NSString *wq_shortcut_free_name(NSString *folder, NSString *name)
{
    NSString *ext = name.pathExtension, *stem = name.stringByDeletingPathExtension;
    if (!stem.length) { stem = name; ext = @""; }
    for (NSUInteger n = 1; n < 10000; n++) {
        NSString *candidate = n == 1 ? name : [NSString stringWithFormat:@"%@ %lu", stem, (unsigned long)n];
        if (n > 1 && ext.length) candidate = [candidate stringByAppendingPathExtension:ext];
        struct stat st;
        if (!wq_stat([folder stringByAppendingPathComponent:candidate], &st)) return candidate;
    }
    return nil;
}

// Runs `work` on the app's serial I/O queue, like every file action in the
// app, so a shortcut and the app never change the same folder at once.
static WQShortcutResult *wq_shortcut_run(NSString *what, WQShortcutResult *(^work)(void))
{
    __block WQShortcutResult *result = nil;
    dispatch_sync(wq_io(), ^{ @autoreleasepool { result = work(); } });
    wq_log(@"shortcut: %@: %@", what, result.ok ? @"OK" : (result.message ?: @"failed"));
    return result;
}

static WQShortcutResult *wq_shortcut_bad_path(void)
{
    return wq_shortcut_failure(WQLocalized(@"Invalid file path"));
}

WQShortcutResult *wq_shortcut_list(NSString *folderText)
{
    NSString *folder = wq_shortcut_path(folderText);
    if (!folder) return wq_shortcut_bad_path();
    return wq_shortcut_run([@"list " stringByAppendingString:folder], ^WQShortcutResult *{
        NSString *error = nil;
        NSArray<NSString *> *names = wq_list(folder, &error);
        if (!names) return wq_shortcut_failure(error);
        NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:names.count];
        for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)])
            [paths addObject:[folder stringByAppendingPathComponent:name]];
        WQShortcutResult *result = wq_shortcut_done(folder);
        result.paths = paths;
        return result;
    });
}

WQShortcutResult *wq_shortcut_export(NSString *pathText)
{
    NSString *path = wq_shortcut_path(pathText);
    if (!path) return wq_shortcut_bad_path();
    return wq_shortcut_run([@"get " stringByAppendingString:path], ^WQShortcutResult *{
        struct stat st;
        if (!wq_stat(path, &st)) return wq_shortcut_failure(WQLocalized(@"Not found."));
        if (!S_ISREG(st.st_mode)) return wq_shortcut_failure(WQLocalized(@"WQ Files can't open this file."));
        // Swept at launch once it is an hour old (wq_share_sweep_stale_exports).
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"WQShare-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil])
            return wq_shortcut_failure(nil);
        NSString *local = [dir stringByAppendingPathComponent:path.lastPathComponent];
        NSString *error = nil;
        if (!wq_copy_to_local(path, local, &error)) {
            [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
            return wq_shortcut_failure(error);
        }
        return wq_shortcut_done(local);
    });
}

WQShortcutResult *wq_shortcut_copy(NSString *pathText, NSString *folderText)
{
    WQShortcutResult *refusal = wq_shortcut_refusal(NO);
    if (refusal) return refusal;
    NSString *path = wq_shortcut_path(pathText), *folder = wq_shortcut_path(folderText);
    if (!path || !folder) return wq_shortcut_bad_path();
    return wq_shortcut_run([NSString stringWithFormat:@"copy %@ to %@", path, folder], ^WQShortcutResult *{
        struct stat st;
        if (!wq_stat(path, &st)) return wq_shortcut_failure(WQLocalized(@"Not found."));
        // A same-named item there is kept; the copy gets "Name 2".
        NSString *name = wq_shortcut_free_name(folder, path.lastPathComponent);
        if (!name) return wq_shortcut_failure(WQLocalized(@"No free name in this folder"));
        NSString *destination = [folder stringByAppendingPathComponent:name];
        NSString *error = nil;
        BOOL ok = S_ISDIR(st.st_mode) ? wq_copy_tree_new(path, destination, nil, &error)
                                      : wq_create_file_from(destination, path, &error);
        return ok ? wq_shortcut_done(destination) : wq_shortcut_failure(error);
    });
}

WQShortcutResult *wq_shortcut_move(NSString *pathText, NSString *folderText)
{
    WQShortcutResult *refusal = wq_shortcut_refusal(NO);
    if (refusal) return refusal;
    NSString *path = wq_shortcut_path(pathText), *folder = wq_shortcut_path(folderText);
    if (!path || !folder) return wq_shortcut_bad_path();
    return wq_shortcut_run([NSString stringWithFormat:@"move %@ to %@", path, folder], ^WQShortcutResult *{
        NSString *error = nil;
        // Never replaces an item of the same name there.
        if (!wq_move(path, folder, &error)) return wq_shortcut_failure(error);
        return wq_shortcut_done([folder stringByAppendingPathComponent:path.lastPathComponent]);
    });
}

WQShortcutResult *wq_shortcut_rename(NSString *pathText, NSString *newName)
{
    WQShortcutResult *refusal = wq_shortcut_refusal(NO);
    if (refusal) return refusal;
    NSString *path = wq_shortcut_path(pathText);
    if (!path || !wq_shortcut_name_ok(newName)) return wq_shortcut_bad_path();
    return wq_shortcut_run([NSString stringWithFormat:@"rename %@ to %@", path, newName], ^WQShortcutResult *{
        NSString *error = nil;
        if (!wq_rename(path, newName, &error)) return wq_shortcut_failure(error);
        return wq_shortcut_done([path.stringByDeletingLastPathComponent stringByAppendingPathComponent:newName]);
    });
}

WQShortcutResult *wq_shortcut_new_folder(NSString *folderText, NSString *name)
{
    WQShortcutResult *refusal = wq_shortcut_refusal(NO);
    if (refusal) return refusal;
    NSString *folder = wq_shortcut_path(folderText);
    if (!folder || !wq_shortcut_name_ok(name)) return wq_shortcut_bad_path();
    return wq_shortcut_run([NSString stringWithFormat:@"new folder %@ in %@", name, folder], ^WQShortcutResult *{
        NSString *created = [folder stringByAppendingPathComponent:name];
        NSString *error = nil;
        return wq_create_dir(created, &error) ? wq_shortcut_done(created) : wq_shortcut_failure(error);
    });
}

WQShortcutResult *wq_shortcut_save(NSString *localFile, NSString *folderText, NSString *name, BOOL replace)
{
    WQShortcutResult *refusal = wq_shortcut_refusal(NO);
    if (refusal) return refusal;
    NSString *folder = wq_shortcut_path(folderText);
    if (!folder || !wq_shortcut_name_ok(name) || !localFile.length) return wq_shortcut_bad_path();
    return wq_shortcut_run([NSString stringWithFormat:@"save %@ in %@%@", name, folder, replace ? @" (replacing)" : @""], ^WQShortcutResult *{
        NSString *wanted = [folder stringByAppendingPathComponent:name];
        struct stat st;
        NSString *error = nil;
        if (replace && wq_stat(wanted, &st)) {
            if (!S_ISREG(st.st_mode)) return wq_shortcut_failure(WQLocalized(@"WQ Files can't open this file."));
            // The file from before is kept in Backups first, as when the app replaces one.
            return wq_write_from_file(wanted, localFile, &error) ? wq_shortcut_done(wanted) : wq_shortcut_failure(error);
        }
        NSString *free = wq_shortcut_free_name(folder, name);
        if (!free) return wq_shortcut_failure(WQLocalized(@"No free name in this folder"));
        NSString *destination = [folder stringByAppendingPathComponent:free];
        return wq_create_file_from(destination, localFile, &error) ? wq_shortcut_done(destination) : wq_shortcut_failure(error);
    });
}

WQShortcutResult *wq_shortcut_delete(NSString *pathText)
{
    WQShortcutResult *refusal = wq_shortcut_refusal(YES);
    if (refusal) return refusal;
    NSString *path = wq_shortcut_path(pathText);
    if (!path) return wq_shortcut_bad_path();
    return wq_shortcut_run([@"delete " stringByAppendingString:path], ^WQShortcutResult *{
        struct stat st;
        if (!wq_stat(path, &st)) return wq_shortcut_failure(WQLocalized(@"Not found."));
        NSString *error = nil;
        // Folders: container roots and the folders above them are refused,
        // and every file is backed up first (one unit in Recently Deleted).
        BOOL ok = S_ISDIR(st.st_mode) ? wq_delete_tree(path, nil, nil, NULL, NULL, &error) : wq_delete(path, &error);
        return ok ? wq_shortcut_done(path) : wq_shortcut_failure(error);
    });
}
