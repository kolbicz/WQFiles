// Recently Deleted on the host: deleted files are listed (newest backup per
// path), overwritten files that still exist are not, and restoring recreates
// missing folders without replacing anything.
#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#import "../WQTrash.m"
#import "../WQSQLiteSave.m"
#include <stdlib.h>
#include <sys/stat.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static void put(NSString *path, NSString *text) { check([bytes(text) writeToFile:path atomically:YES], @"write fixture"); }
static BOOL has(NSString *path, NSString *text) { return [[NSData dataWithContentsOfFile:path] isEqual:bytes(text)]; }

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"WQTrashTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        check([fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil], @"fixture folder");
        wq_test_backup_root = [base stringByAppendingPathComponent:@"Backups"];
        wq_test_app_backup_root = [base stringByAppendingPathComponent:@"AppBackups"];
        NSString *data = [base stringByAppendingPathComponent:@"data"];
        NSString *folder = [data stringByAppendingPathComponent:@"Saves/Slot1"];
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *kept = [data stringByAppendingPathComponent:@"settings.plist"];
        NSString *gone = [data stringByAppendingPathComponent:@"notes.txt"];
        NSString *nested = [folder stringByAppendingPathComponent:@"game.sav"];
        put(kept, @"v1"); put(gone, @"first"); put(nested, @"progress");
        NSString *error = nil;

        check(wq_recently_deleted().count == 0, @"nothing deleted yet");
        check(wq_write(kept, bytes(@"v2"), &error), @"overwrite keeps a backup");
        check(wq_write(gone, bytes(@"second"), &error), @"overwrite before delete");
        usleep(1100000);   // a later stamp second for the delete
        check(wq_delete(gone, &error), @"delete a file");
        check(wq_delete(nested, &error), @"delete a file in a folder");
        check(rmdir(folder.fileSystemRepresentation) == 0 && rmdir(folder.stringByDeletingLastPathComponent.fileSystemRepresentation) == 0,
              @"remove the now empty folders");

        NSArray<WQDeletedItem *> *items = wq_recently_deleted();
        NSMutableSet *originals = [NSMutableSet new];
        for (WQDeletedItem *item in items) [originals addObject:item.originalPath];
        check(items.count == 2 && [originals isEqualToSet:[NSSet setWithObjects:gone, nested, nil]],
              @"lists exactly the deleted files, not the overwritten one that still exists");
        WQDeletedItem *notes = nil, *save = nil;
        for (WQDeletedItem *item in items) {
            if ([item.originalPath isEqualToString:gone]) notes = item;
            if ([item.originalPath isEqualToString:nested]) save = item;
        }
        check(has(notes.backupPath, @"second"), @"newest backup per path (the contents when deleted)");
        check(notes.date != nil && notes.size == 6, @"date and size known");

        check(wq_restore_deleted(save, &error) && has(nested, @"progress"), @"restore recreates the missing folders");
        check(wq_recently_deleted().count == 1, @"restored file leaves the list");
        put(gone, @"new file meanwhile");
        check(!wq_restore_deleted(notes, &error) && has(gone, @"new file meanwhile"), @"restore never replaces an existing file");
        check(wq_recently_deleted().count == 0, @"a path that exists again isn't listed");

        // Folder delete: everything inside goes, one backup unit, restorable.
        NSString *tree = [data stringByAppendingPathComponent:@"ADManager"];
        [fm createDirectoryAtPath:[tree stringByAppendingPathComponent:@"a/b/c"] withIntermediateDirectories:YES attributes:nil error:nil];
        put([tree stringByAppendingPathComponent:@"Backups.plist"], @"plist");
        put([tree stringByAppendingPathComponent:@"a/one.txt"], @"one");
        put([tree stringByAppendingPathComponent:@"a/b/c/deep.bin"], @"deep");
        put([tree stringByAppendingPathComponent:@"a/b/empty.dat"], @"");
        check(symlink("/etc/hosts", [tree stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0, @"link fixture");
        check(mkfifo([tree stringByAppendingPathComponent:@"a/pipe"].fileSystemRepresentation, 0600) == 0, @"pipe fixture");
        WQTreeCount count = wq_tree_count(tree, 1000);
        check(count.regular == 4 && count.other == 2 && count.bytes == 12 && count.state == WQTreeCountExact,
              @"count tells regular files (backed up) from links and special files (not backed up)");
        WQTreeCount limited = wq_tree_count(tree, 2);
        check(limited.state == WQTreeCountLimited, @"count reports when it stopped at the limit");
        WQTreeCount single = wq_tree_count([tree stringByAppendingPathComponent:@"link"], 10);
        check(single.regular == 0 && single.other == 1 && single.state == WQTreeCountExact, @"count of a single link");
        NSString *locked = [data stringByAppendingPathComponent:@"Locked"];
        [fm createDirectoryAtPath:[locked stringByAppendingPathComponent:@"inner"] withIntermediateDirectories:YES attributes:nil error:nil];
        put([locked stringByAppendingPathComponent:@"inner/x"], @"x");
        check(chmod([locked stringByAppendingPathComponent:@"inner"].fileSystemRepresentation, 0) == 0, @"unreadable folder fixture");
        check(wq_tree_count(locked, 100).state == WQTreeCountUnreadable, @"count reports an unreadable folder");
        chmod([locked stringByAppendingPathComponent:@"inner"].fileSystemRepresentation, 0755);
        [fm removeItemAtPath:locked error:nil];
        check(!wq_delete(tree, &error), @"plain delete still refuses a non-empty folder");
        NSUInteger deleted = 0, progressCalls = 0;
        __block NSUInteger *calls = &progressCalls;
        NSString *unit = nil;
        check(wq_delete_tree(tree, nil, ^(NSUInteger n) { (void)n; (*calls)++; }, &deleted, &unit, &error), @"folder delete");
        check(![fm fileExistsAtPath:tree] && deleted == 6 && progressCalls == 6, @"folder and everything inside removed");
        NSArray *unitFiles = [[fm subpathsOfDirectoryAtPath:unit error:nil] filteredArrayUsingPredicate:
                              [NSPredicate predicateWithFormat:@"SELF ENDSWITH '.txt' OR SELF ENDSWITH '.bin' OR SELF ENDSWITH '.plist' OR SELF ENDSWITH '.dat'"]];
        check(unitFiles.count == 4, @"the four regular files are in one backup unit");
        NSUInteger fromTree = 0;
        WQDeletedItem *deep = nil;
        for (WQDeletedItem *item in wq_recently_deleted())
            if ([item.originalPath hasPrefix:[tree stringByAppendingString:@"/"]]) {
                fromTree++;
                if ([item.originalPath.lastPathComponent isEqualToString:@"deep.bin"]) deep = item;
            }
        check(fromTree == 4 && deep.unitFileCount == 4, @"Recently Deleted lists the folder's files");
        check(wq_restore_deleted(deep, &error) && has([tree stringByAppendingPathComponent:@"a/b/c/deep.bin"], @"deep"),
              @"a file of the deleted folder restores with its folders");
        // Cancel stops early; what was deleted is backed up.
        NSString *many = [data stringByAppendingPathComponent:@"Many"];
        [fm createDirectoryAtPath:many withIntermediateDirectories:YES attributes:nil error:nil];
        for (int i = 0; i < 5; i++) put([many stringByAppendingPathComponent:[NSString stringWithFormat:@"x%d", i]], @"x");
        __block NSUInteger seen = 0;
        check(!wq_delete_tree(many, ^BOOL { return seen >= 2; }, ^(NSUInteger n) { seen = n; }, &deleted, NULL, &error) &&
              deleted == 2 && [fm fileExistsAtPath:many], @"cancel stops after the current file");
        // Protected folders.
        check(wq_is_protected_folder(@"/private/var/mobile/Containers/Data/Application/4CE791DB-6B04-4A39-8F59-AF32BA61D494"), @"container root protected");
        check(wq_is_protected_folder(@"/private/var/mobile/Containers/Data/Application"), @"container parent protected");
        check(wq_is_protected_folder(@"/private/var/mobile"), @"shallow system folder protected");
        check(!wq_is_protected_folder(@"/private/var/mobile/Containers/Data/Application/4CE791DB-6B04-4A39-8F59-AF32BA61D494/Documents"),
              @"folders inside a container can be deleted");
        check(!wq_delete_tree(@"/private/var/mobile/Containers/Shared/AppGroup", nil, nil, NULL, NULL, &error), @"tree delete refuses protected");

        check(wq_backup_stamp_date(@"20261111-175959-512-1") != nil && wq_backup_stamp_date(@"notastamp") == nil, @"stamp dates");

        // CR-14: units are compared numerically, so counter 10 is newer than 9
        // (text order puts "-10" first and used to win as "visited last").
        check(WQBackupStampCompare(@"20261112-170500-123-9", @"20261112-170500-123-10") == NSOrderedAscending &&
              WQBackupStampCompare(@"20261112-170500-123-10", @"20261112-170500-123-9") == NSOrderedDescending &&
              WQBackupStampCompare(@"20261112-170500-123-10", @"20261112-170500-123-10") == NSOrderedSame,
              @"stamp counters compare as numbers");
        check(WQBackupStampCompare(@"20261112-170500", @"20261112-170500-000") == NSOrderedAscending &&
              WQBackupStampCompare(@"20261112-170500-123", @"20261112-170500-123-1") == NSOrderedAscending &&
              WQBackupStampCompare(@"20261112-170459-999-99", @"20261112-170500") == NSOrderedAscending,
              @"legacy stamps without milliseconds or counter order before newer fields");
        check(WQBackupStampCompare(@"20261112-170500-123-1", @"notastamp") == NSOrderedAscending, @"invalid names order after stamps");
        NSString *counted = [data stringByAppendingPathComponent:@"counted.txt"];
        for (NSString *stamp in @[@"20261112-170500-123-9", @"20261112-170500-123-10"]) {
            NSString *copy = [[wq_test_backup_root stringByAppendingPathComponent:stamp] stringByAppendingString:counted];
            [fm createDirectoryAtPath:copy.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            put(copy, [stamp hasSuffix:@"-10"] ? @"newer" : @"older");
        }
        WQDeletedItem *countedItem = nil;
        for (WQDeletedItem *item in wq_recently_deleted())
            if ([item.originalPath isEqualToString:counted]) countedItem = item;
        check(countedItem && has(countedItem.backupPath, @"newer") && [countedItem.unitPath hasSuffix:@"-10"],
              @"Recently Deleted picks the -10 unit over -9");

        // CR-15: the parent-grant memo is a fast path only. A double evicts
        // the parent's token after each use; the second missing file under
        // that parent must still be listed (it used to be omitted).
        NSString *foreignParent = @"/wq-test-foreign/Container/Documents";
        for (NSString *leaf in @[@"a.txt", @"b.txt"]) {
            NSString *copy = [[wq_test_backup_root stringByAppendingPathComponent:@"20261112-170600-000-1"]
                              stringByAppendingString:[foreignParent stringByAppendingPathComponent:leaf]];
            [fm createDirectoryAtPath:copy.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            put(copy, leaf);
        }
        NSMutableSet<NSString *> *held = [NSMutableSet new];
        __block NSUInteger grants = 0;
        wq_test_trash_grant = ^BOOL(NSString *path) { grants++; [held addObject:path]; return YES; };
        wq_test_presence = ^WQPathPresence(NSString *path) {
            if (![path hasPrefix:@"/wq-test-foreign/"]) return wq_presence_lstat(path);
            NSString *parent = path.stringByDeletingLastPathComponent;
            if (![held containsObject:parent]) return WQPathUnknown;   // no token: sandbox-denied
            [held removeObject:parent];                                // evicted after this use
            return WQPathMissing;
        };
        NSUInteger foreignListed = 0;
        for (WQDeletedItem *item in wq_recently_deleted())
            if ([item.originalPath hasPrefix:foreignParent]) foreignListed++;
        wq_test_trash_grant = nil;
        wq_test_presence = nil;
        check(foreignListed == 2 && grants == 2, @"an evicted parent token is reacquired, both missing files listed");

        // Enumeration failure is not "Nothing deleted".
        NSString *problem = nil;
        check(chmod(wq_test_backup_root.fileSystemRepresentation, 0) == 0, @"unreadable Backups fixture");
        NSArray *unreadable = wq_recently_deleted_checked(&problem);
        chmod(wq_test_backup_root.fileSystemRepresentation, 0755);
        check(unreadable == nil && problem.length, @"an unreadable Backups folder is reported, not shown as empty");
        problem = @"stale";
        check(wq_recently_deleted_checked(&problem) != nil && problem == nil, @"a readable Backups folder reports no problem");

        // A failed restore removes only the empty folders it created.
        NSString *restoreTarget = [data stringByAppendingPathComponent:@"New/Deeper/restored.txt"];
        WQDeletedItem *bogus = [WQDeletedItem new];
        bogus.originalPath = restoreTarget;
        bogus.backupPath = [base stringByAppendingPathComponent:@"no-such-backup"];
        bogus.unitPath = [wq_test_backup_root stringByAppendingPathComponent:@"20261112-170700-000-1"];
        check(!wq_restore_deleted(bogus, &error) && ![fm fileExistsAtPath:[data stringByAppendingPathComponent:@"New"]] &&
              [fm fileExistsAtPath:data], @"failed restore removes the folders it created, nothing above");
        // A SQLite database is restored with its -wal/-shm or not at all.
        NSString *dbDir = [data stringByAppendingPathComponent:@"DbSet"];
        check([fm createDirectoryAtPath:dbDir withIntermediateDirectories:YES attributes:nil error:nil], @"database fixture folder");
        NSMutableData *dbBytes = [NSMutableData dataWithBytes:"SQLite format 3" length:16];
        [dbBytes increaseLengthBy:4080];
        NSString *dbBackup = [base stringByAppendingPathComponent:@"app.sqlite.backup"];
        check([dbBytes writeToFile:dbBackup atomically:YES], @"database backup fixture");
        WQDeletedItem *db = [WQDeletedItem new];
        db.originalPath = [dbDir stringByAppendingPathComponent:@"app.sqlite"];
        db.backupPath = dbBackup;
        db.unitPath = [wq_test_backup_root stringByAppendingPathComponent:@"20261112-170800-000-1"];
        NSString *liveWAL = [db.originalPath stringByAppendingString:@"-wal"];
        check([fm createDirectoryAtPath:liveWAL withIntermediateDirectories:NO attributes:nil error:nil], @"a -wal that is not a file");
        error = nil;
        check(!wq_restore_deleted(db, &error) && error.length && ![fm fileExistsAtPath:db.originalPath],
              @"a -wal that can't be reset refuses the restore before the database is put back");
        check([fm removeItemAtPath:liveWAL error:nil], @"remove the blocking -wal");
        put(liveWAL, @"stale pages of another database");
        check(wq_restore_deleted(db, &error) && [[NSData dataWithContentsOfFile:db.originalPath] isEqual:dbBytes] &&
              [NSData dataWithContentsOfFile:liveWAL].length == 0, @"a stale -wal is emptied when the database is restored");
        [fm removeItemAtPath:base error:nil];
        puts("All Recently Deleted tests passed.");
    }
    return 0;
}
