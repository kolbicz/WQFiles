//
//  WQTrash.m
//  WQ Files
//

#import "WQSQLiteSave.h"
#import "WQTrash.h"
#import "WQAccess.h"
#import "WQLocalization.h"
#import "WQAccessSafety.h"
#include <sys/stat.h>

@implementation WQDeletedItem
@end

NSDate *wq_backup_stamp_date(NSString *stamp)
{
    if (stamp.length < 15) return nil;
    static NSDateFormatter *format;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        format = [NSDateFormatter new];
        format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        format.dateFormat = @"yyyyMMdd-HHmmss";
    });
    @synchronized (format) { return [format dateFromString:[stamp substringToIndex:15]]; }
}

typedef NS_ENUM(NSInteger, WQPathPresence) { WQPathPresent, WQPathMissing, WQPathUnknown };

static WQPathPresence wq_presence_lstat(NSString *path)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) == 0) return WQPathPresent;
    return (errno == ENOENT || errno == ENOTDIR) ? WQPathMissing : WQPathUnknown;
}

#ifdef WQ_ACCESS_TESTING
// Host doubles for sandbox presence and grants (token eviction tests).
static WQPathPresence (^wq_test_presence)(NSString *path);
static BOOL (^wq_test_trash_grant)(NSString *path);
static WQPathPresence wq_presence_once(NSString *path) { return wq_test_presence ? wq_test_presence(path) : wq_presence_lstat(path); }
static BOOL wq_trash_grant(NSString *path) { return wq_test_trash_grant ? wq_test_trash_grant(path) : wq_grant(path); }
#else
static WQPathPresence wq_presence_once(NSString *path) { return wq_presence_lstat(path); }
static BOOL wq_trash_grant(NSString *path) { return wq_grant(path); }
#endif

// Whether the original is still there. Other apps' folders may refuse a plain
// lstat; then a token for the parent settles it. Unknown counts as present,
// so nothing is listed as deleted unless it really is. The memo of granted
// parents is only a fast path: WQAccess may have released (evicted) that
// token since, so an lstat that is still unknown asks for it again.
static BOOL wq_original_missing(NSString *path, NSMutableDictionary<NSString *, NSNumber *> *grantedParents)
{
    WQPathPresence p = wq_presence_once(path);
    if (p != WQPathUnknown) return p == WQPathMissing;
    NSString *parent = path.stringByDeletingLastPathComponent;
    NSNumber *granted = grantedParents[parent];
    BOOL fresh = !granted;
    if (fresh) {
        granted = @(wq_trash_grant(parent));
        grantedParents[parent] = granted;
    }
    if (!granted.boolValue) {
        // No token: the parent itself may be gone (a deleted folder).
        return wq_presence_once(parent) == WQPathMissing;
    }
    p = wq_presence_once(path);
    if (p == WQPathUnknown && !fresh) {
        // The memoized token may have been evicted: reacquire it once.
        BOOL again = wq_trash_grant(parent);
        grantedParents[parent] = @(again);
        if (again) p = wq_presence_once(path);
        else return wq_presence_once(parent) == WQPathMissing;
    }
    return p == WQPathMissing;
}

NSArray<WQDeletedItem *> *wq_recently_deleted_checked(NSString **problem)
{
    if (problem) *problem = nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = wq_backup_root();
    NSError *listError = nil;
    NSArray<NSString *> *units = [fm contentsOfDirectoryAtPath:root error:&listError];
    if (!units) {
        struct stat st;
        if (lstat(root.fileSystemRepresentation, &st) != 0 && errno == ENOENT) return @[];   // no backups yet
        wq_log(@"recently deleted: cannot list %@: %@", root, listError.localizedDescription ?: @"unknown error");
        if (problem) *problem = WQLocalizedFormat(@"Backups could not be read: %@",
                                                  listError.localizedDescription ?: WQLocalized(@"unknown error"));
        return nil;
    }
    __block BOOL incomplete = NO;
    NSMutableDictionary<NSString *, WQDeletedItem *> *newest = [NSMutableDictionary new];
    for (NSString *unitName in units) {
        if ([unitName hasPrefix:@"."]) continue;
        NSDate *date = wq_backup_stamp_date(unitName);
        if (!date || !WQBackupStampValid(unitName)) continue;
        NSString *unit = [root stringByAppendingPathComponent:unitName];
        NSMutableArray<NSString *> *files = [NSMutableArray new];
        NSDirectoryEnumerator *walk = [fm enumeratorAtURL:[NSURL fileURLWithPath:unit]
                               includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey] options:0
                                             errorHandler:^BOOL(NSURL *url, NSError *error) {
            incomplete = YES;
            wq_log(@"recently deleted: cannot read %@: %@", url.path, error.localizedDescription ?: @"unknown error");
            return YES;
        }];
        if (!walk) { incomplete = YES; continue; }
        for (NSURL *url in walk) {
            NSNumber *regular = nil, *link = nil;
            [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            [url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
            if (regular.boolValue && !link.boolValue) [files addObject:url.path];
        }
        for (NSString *file in files) {
            NSString *original = wq_backup_original_path(file);
            if (!original) continue;
            // Chronological, not directory or text order: "-10" is newer than "-9".
            WQDeletedItem *known = newest[original];
            if (known && WQBackupStampCompare(known.unitPath.lastPathComponent, unitName) != NSOrderedAscending) continue;
            WQDeletedItem *item = known ?: [WQDeletedItem new];
            item.backupPath = file;
            item.originalPath = original;
            item.unitPath = unit;
            item.unitFileCount = files.count;
            item.date = date;
            struct stat st;
            item.size = lstat(file.fileSystemRepresentation, &st) == 0 ? (unsigned long long)st.st_size : 0;
            newest[original] = item;
        }
    }
    NSMutableDictionary *grantedParents = [NSMutableDictionary new];
    NSMutableArray<WQDeletedItem *> *deleted = [NSMutableArray new];
    for (WQDeletedItem *item in newest.allValues)
        if (wq_original_missing(item.originalPath, grantedParents)) [deleted addObject:item];
    [deleted sortUsingComparator:^NSComparisonResult(WQDeletedItem *a, WQDeletedItem *b) {
        NSComparisonResult byStamp = WQBackupStampCompare(b.unitPath.lastPathComponent, a.unitPath.lastPathComponent);
        return byStamp != NSOrderedSame ? byStamp : [a.originalPath compare:b.originalPath];
    }];
    if (incomplete && problem) *problem = WQLocalized(@"Some backups could not be read, so this list may be incomplete.");
    return deleted;
}

NSArray<WQDeletedItem *> *wq_recently_deleted(void)
{
    return wq_recently_deleted_checked(NULL) ?: @[];
}

BOOL wq_restore_deleted(WQDeletedItem *item, NSString **errorText)
{
    // Recreate missing parent folders, outermost first.
    NSMutableArray<NSString *> *missing = [NSMutableArray new];
    NSString *dir = item.originalPath.stringByDeletingLastPathComponent;
    while (dir.length > 1) {
        struct stat st;
        if (wq_stat(dir, &st)) {
            if (!S_ISDIR(st.st_mode)) {
                if (errorText) *errorText = WQLocalizedFormat(@"%@ is not a folder anymore.", dir);
                return NO;
            }
            break;
        }
        [missing insertObject:dir atIndex:0];
        dir = dir.stringByDeletingLastPathComponent;
    }
    // Folders this call created, with their identity, so a failed restore
    // removes only those (and only while they are still empty and the same).
    NSMutableArray<NSString *> *created = [NSMutableArray new];
    NSMutableArray<NSDictionary *> *identities = [NSMutableArray new];
    BOOL ok = YES;
    for (NSString *folder in missing) {
        if (!wq_create_dir(folder, errorText)) { ok = NO; break; }
        NSDictionary *identity = wq_item_identity(folder);
        if (!identity) break;   // cannot verify it later: leave it in place
        [created addObject:folder];
        [identities addObject:identity];
    }
    // All or nothing for a SQLite database: what can be known to fail is
    // checked first, and a database already put back is taken out again when
    // its -wal/-shm can't be reset (it would open with data that isn't its).
    if (ok) ok = wq_sqlite_restore_sidecars_possible(item.originalPath, item.backupPath, errorText);
    NSDictionary *published = nil;
    if (ok) {
        ok = wq_create_file_from(item.originalPath, item.backupPath, errorText);
        if (ok) published = wq_item_identity(item.originalPath);
    }
    // A deleted SQLite database whose -wal/-shm stayed behind would reopen
    // with them; they're kept in Backups and replaced or emptied.
    if (ok && !wq_sqlite_restore_sidecars(item.originalPath, item.backupPath, nil, errorText)) {
        ok = NO;
        NSString *undoError = nil;
        BOOL undone = published && wq_delete_expecting(item.originalPath, published, &undoError);
        wq_log(@"recently deleted: %@ was taken out again after its -wal/-shm could not be reset: %@",
               item.originalPath, undone ? @"OK (it is in Recently Deleted)" : (undoError ?: @"FAILED; the restored file is still there"));
    }
    if (!ok) {
        for (NSUInteger i = created.count; i-- > 0; ) {
            if (!wq_delete_expecting(created[i], identities[i], NULL)) break;   // not empty or not ours: stop there
        }
    }
    wq_log(@"recently deleted: restore %@ from %@: %@", item.originalPath, item.unitPath.lastPathComponent,
           ok ? @"OK" : (errorText && *errorText ? *errorText : @"failed"));
    return ok;
}
