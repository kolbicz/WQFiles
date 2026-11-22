//
//  WQSQLiteSave.m
//  WQ Files
//

#import "WQSQLiteSave.h"
#import "WQAccess.h"
#import "WQLocalization.h"
#include <sys/stat.h>

static NSString *wq_sqlite_side(NSString *path, NSString *suffix) { return [path stringByAppendingString:suffix]; }

static BOOL wq_sqlite_side_exists(NSString *path, struct stat *st)
{
    return wq_stat(path, st) && S_ISREG(st->st_mode);
}

NSDictionary *wq_sqlite_source_state(NSString *path)
{
    NSDictionary *main = wq_file_version(path);
    if (!main) return nil;
    struct stat st;
    NSString *wal = wq_sqlite_side(path, @"-wal");
    id walVersion = wq_sqlite_side_exists(wal, &st) ? (wq_file_version(wal) ?: NSNull.null) : NSNull.null;
    return @{ @"main": main, @"wal": walVersion };
}

// One row of a PRAGMA as integers; NO if it didn't run.
static BOOL wq_sqlite_pragma_ints(sqlite3 *db, const char *sql, long long *values, int count)
{
    sqlite3_stmt *stmt = NULL;
    BOOL ok = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW;
    for (int i = 0; ok && i < count; i++) values[i] = sqlite3_column_int64(stmt, i);
    sqlite3_finalize(stmt);
    return ok;
}

static NSString *wq_sqlite_quick_check(sqlite3 *db)
{
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, NULL) != SQLITE_OK) return @(sqlite3_errmsg(db));
    NSString *result = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *text = sqlite3_column_text(stmt, 0);
        result = text ? @((const char *)text) : @"?";
    } else {
        result = @(sqlite3_errmsg(db));
    }
    sqlite3_finalize(stmt);
    return [result isEqualToString:@"ok"] ? nil : result;
}

// A self-contained copy of a database at `dest`: `main` with `wal` (nil when
// there is none) checkpointed into it, checked, and no sidecars left beside it.
static BOOL wq_sqlite_logical_copy(NSString *main, NSString *wal, NSString *dest, NSString **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *destWAL = wq_sqlite_side(dest, @"-wal"), *destSHM = wq_sqlite_side(dest, @"-shm");
    for (NSString *p in @[dest, destWAL, destSHM]) [fm removeItemAtPath:p error:nil];
    NSError *fsError = nil;
    if (![fm copyItemAtPath:main toPath:dest error:&fsError] || (wal && ![fm copyItemAtPath:wal toPath:destWAL error:&fsError])) {
        *error = fsError.localizedDescription ?: @"?";
        return NO;
    }
    sqlite3 *db = NULL;
    BOOL ok = sqlite3_open_v2(dest.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK;
    long long ckpt[3] = {0, 0, 0};
    NSString *problem = nil;
    if (ok && wal && (!wq_sqlite_pragma_ints(db, "PRAGMA wal_checkpoint(TRUNCATE)", ckpt, 3) || ckpt[0] != 0)) ok = NO;
    if (ok && (problem = wq_sqlite_quick_check(db))) ok = NO;
    if (!ok) *error = problem ?: (db ? @(sqlite3_errmsg(db)) : @"?");
    if (sqlite3_close(db) != SQLITE_OK && ok) { ok = NO; *error = @"close"; }
    // The checkpoint emptied the -wal; the main file now holds every row.
    if (ok && wal && (wq_sqlite_side_exists(destWAL, &(struct stat){0}) &&
                      [[fm attributesOfItemAtPath:destWAL error:nil] fileSize] > 0)) {
        ok = NO;
        *error = @"-wal";
    }
    [fm removeItemAtPath:destWAL error:nil];
    [fm removeItemAtPath:destSHM error:nil];
    return ok;
}

static BOOL wq_sqlite_fail(NSString **error, NSString *text)
{
    if (error) *error = text;
    return NO;
}

// SQLite owns the destination transaction, including WAL/journal handling.
// Closing or terminating this process mid-copy leaves SQLite able to recover
// the original database when the target app opens it.
static BOOL wq_sqlite_install(sqlite3 *source, NSString *original, NSString **error)
{
    // SQLite may need to create or open its journal and sidecars itself.
    wq_grant(original.stringByDeletingLastPathComponent);
    sqlite3 *destination = NULL;
    int rc = sqlite3_open_v2(original.fileSystemRepresentation, &destination,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, NULL);
    if ((rc == SQLITE_PERM || rc == SQLITE_CANTOPEN || rc == SQLITE_READONLY) && wq_grant(original)) {
        sqlite3_close(destination);
        destination = NULL;
        rc = sqlite3_open_v2(original.fileSystemRepresentation, &destination,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, NULL);
    }
    if (rc == SQLITE_OK)
        rc = sqlite3_exec(destination, "PRAGMA synchronous=FULL", NULL, NULL, NULL);
    if (rc == SQLITE_OK) {
        sqlite3_backup *backup = sqlite3_backup_init(destination, "main", source, "main");
        if (!backup) {
            rc = sqlite3_errcode(destination);
        } else {
            do {
                rc = sqlite3_backup_step(backup, 64);
#ifdef WQ_ACCESS_TESTING
                if (rc == SQLITE_OK) WQ_STREAM_HOOK(@"sqliteBackupInProgress", original);
#endif
            } while (rc == SQLITE_OK);
            int finish = sqlite3_backup_finish(backup);
            if (rc == SQLITE_DONE) rc = finish;
        }
    }
    if (rc != SQLITE_OK && error)
        *error = destination ? @(sqlite3_errmsg(destination)) : @(sqlite3_errstr(rc));
    sqlite3_close(destination);
    return rc == SQLITE_OK;
}

BOOL wq_sqlite_save(sqlite3 *copyDB, NSString *original, NSDictionary *state,
                    NSDictionary **newState, NSString **backupUnit, NSString **error)
{
    if (newState) *newState = nil;
    if (backupUnit) *backupUnit = nil;
    struct stat st;
    // A rollback journal left by a crash still has to be applied by SQLite:
    // writing now would mix two versions.
    NSString *journal = wq_sqlite_side(original, @"-journal");
    if (wq_sqlite_side_exists(journal, &st) && st.st_size > 0)
        return wq_sqlite_fail(error, WQLocalized(@"The app left an unfinished transaction (a -journal file). Open the app once and close it, then open the database again."));
    NSDictionary *now = wq_sqlite_source_state(original);
    if (!now) return wq_sqlite_fail(error, WQLocalized(@"The database can't be read anymore."));
    if (![now isEqualToDictionary:state])
        return wq_sqlite_fail(error, WQLocalized(@"The app changed the database since it was opened here. Saving would overwrite those changes: discard yours, close the app and open the database again."));

    // Everything into the copy's main file, then make sure it's sound.
    long long ckpt[3] = {0, 0, 0};
    if (!wq_sqlite_pragma_ints(copyDB, "PRAGMA wal_checkpoint(TRUNCATE)", ckpt, 3) || ckpt[0] != 0)
        return wq_sqlite_fail(error, WQLocalizedFormat(@"The copy could not be prepared for saving (%@).", @(sqlite3_errmsg(copyDB))));
    NSString *problem = wq_sqlite_quick_check(copyDB);
    if (problem)
        return wq_sqlite_fail(error, WQLocalizedFormat(@"The edited copy failed SQLite's integrity check, so nothing was saved: %@", problem));

    // Capture the previous database and its WAL for the user-visible backup.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"wq-sqlite-save-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *keepMain = [dir stringByAppendingPathComponent:@"main"], *keepWAL = [dir stringByAppendingPathComponent:@"wal"];
    NSString *empty = [dir stringByAppendingPathComponent:@"empty"];
    NSString *wal = wq_sqlite_side(original, @"-wal");
    BOOL walExists = wq_sqlite_side_exists(wal, &st);
    BOOL hasWAL = walExists && st.st_size > 0;
    NSString *copyError = nil;
    if (!wq_copy_to_local(original, keepMain, &copyError) || (hasWAL && !wq_copy_to_local(wal, keepWAL, &copyError)) ||
        ![fm createFileAtPath:empty contents:[NSData data] attributes:nil]) {
        [fm removeItemAtPath:dir error:nil];
        return wq_sqlite_fail(error, WQLocalizedFormat(@"Could not make a safety copy first: %@", copyError ?: @"?"));
    }
    if (![wq_sqlite_source_state(original) isEqualToDictionary:state]) {
        [fm removeItemAtPath:dir error:nil];
        return wq_sqlite_fail(error, WQLocalized(@"The app changed the database since it was opened here. Saving would overwrite those changes: discard yours, close the app and open the database again."));
    }

    // The previous database for Backups, made before anything is written:
    // the main file with its old WAL checkpointed into it (the WAL may hold
    // committed rows the main file lacks), plus an empty -wal so restoring
    // the whole unit can't leave newer WAL frames on top of it. One unit.
    NSString *logical = [dir stringByAppendingPathComponent:@"previous.sqlite"];
    NSString *unit = nil;
    if (!wq_sqlite_logical_copy(keepMain, hasWAL ? keepWAL : nil, logical, &copyError) ||
        !wq_backup_local_copy(original, logical, &unit, &copyError) ||
        (walExists && !wq_backup_local_copy(wal, empty, &unit, &copyError))) {
        if (unit) wq_delete_backup(unit, NULL);
        [fm removeItemAtPath:dir error:nil];
        return wq_sqlite_fail(error, WQLocalizedFormat(@"Could not make a safety copy first: %@", copyError ?: @"?"));
    }

    NSString *writeError = nil;
    if (![wq_sqlite_source_state(original) isEqualToDictionary:state]) {
        [fm removeItemAtPath:dir error:nil];
        return wq_sqlite_fail(error, WQLocalized(@"The app changed the database since it was opened here. Saving would overwrite those changes: discard yours, close the app and open the database again."));
    }
    BOOL installed = wq_sqlite_install(copyDB, original, &writeError);
    [fm removeItemAtPath:dir error:nil];
    if (!installed)
        return wq_sqlite_fail(error, WQLocalizedFormat(@"The database could not be written: %@", writeError ?: @"?"));
    wq_log(@"sqlite: saved %@ (backup %@)", original, unit.lastPathComponent);
    if (backupUnit) *backupUnit = unit;
    if (newState) *newState = wq_sqlite_source_state(original);
    return YES;
}

static BOOL wq_sqlite_is_database_file(NSString *path)
{
    int fd = wq_open_for_reading(path);
    if (fd < 0) return NO;
    char header[16] = {0};
    BOOL yes = pread(fd, header, sizeof header, 0) == (ssize_t)sizeof header && memcmp(header, "SQLite format 3", 16) == 0;
    close(fd);
    return yes;
}

// What wq_sqlite_restore_sidecars would refuse for sure, checked before the
// database itself is put back: a failure after that leaves a restored
// database beside sidecars that don't belong to it.
BOOL wq_sqlite_restore_sidecars_possible(NSString *original, NSString *backup, NSString **error)
{
    if (!wq_sqlite_is_database_file(backup)) return YES;
    for (NSString *suffix in @[@"-wal", @"-shm"]) {
        NSString *live = wq_sqlite_side(original, suffix);
        struct stat st;
        if (wq_stat(live, &st) && !S_ISREG(st.st_mode))
            return wq_sqlite_fail(error, WQLocalizedFormat(@"%@ is not a regular file, so the restored database could open with other data. Remove it and restore again.", live.lastPathComponent));
    }
    return YES;
}

BOOL wq_sqlite_restore_sidecars(NSString *original, NSString *backup, NSMutableArray<NSString *> *units, NSString **error)
{
    if (!wq_sqlite_is_database_file(backup)) return YES;
    NSString *dir = nil, *empty = nil;
    BOOL ok = YES;
    for (NSString *suffix in @[@"-wal", @"-shm"]) {
        NSString *live = wq_sqlite_side(original, suffix);
        struct stat st;
        if (!wq_stat(live, &st)) continue;              // none: nothing newer on top
        if (!S_ISREG(st.st_mode)) {
            ok = wq_sqlite_fail(error, WQLocalizedFormat(@"%@ is not a regular file, so the restored database could open with other data. Remove it and restore again.", live.lastPathComponent));
            break;
        }
        if (st.st_size == 0) continue;
        NSString *source = wq_sqlite_side(backup, suffix);
        struct stat bs;
        if (!(wq_stat(source, &bs) && S_ISREG(bs.st_mode))) {
            if (!empty) {
                dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"wq-sqlite-restore-" stringByAppendingString:NSUUID.UUID.UUIDString]];
                [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                empty = [dir stringByAppendingPathComponent:@"empty"];
                [NSFileManager.defaultManager createFileAtPath:empty contents:[NSData data] attributes:nil];
            }
            source = empty;
        }
        NSString *unit = nil, *writeError = nil;
        if (!wq_write_from_file_with_backup(live, source, &unit, &writeError)) {
            ok = wq_sqlite_fail(error, WQLocalizedFormat(@"%@ could not be reset: %@", live.lastPathComponent, writeError ?: @"?"));
            break;
        }
        if (unit) [units addObject:unit];
        wq_log(@"restore %@: %@ %@ (newer data kept in %@)", original.lastPathComponent, suffix,
               source == empty ? @"emptied" : @"restored from the backup", unit.lastPathComponent ?: @"?");
    }
    if (dir) [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    return ok;
}
