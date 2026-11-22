//
//  WQSQLiteSave.h
//  WQ Files
//
//  Installs an edited private copy using SQLite's destination transaction.
//  Refuses changed sources and unfinished rollback journals. The target app
//  must be closed while saving.
//
#import <Foundation/Foundation.h>
#import <sqlite3.h>

NS_ASSUME_NONNULL_BEGIN

// The versions of `path` and its -wal (NSNull when there is none), recorded
// when the copy is made and compared again before saving. Nil if the
// database itself can't be read.
NSDictionary *_Nullable wq_sqlite_source_state(NSString *path);

// Checks the private copy and installs it into `original` through SQLite.
// `state` is what wq_sqlite_source_state returned when the copy was made;
// *newState gets the state after saving (for the next save), *backupUnit the
// Backups folder holding the previous database: one unit with the old main
// file with its old -wal checkpointed into it (so it holds every committed
// row on its own) and, if the app had a -wal, an empty -wal beside it.
// Restoring that unit (or just its main file) restores the whole database.
BOOL wq_sqlite_save(sqlite3 *copyDB, NSString *original, NSDictionary *state,
                    NSDictionary *_Nullable *_Nullable newState, NSString *_Nullable *_Nullable backupUnit,
                    NSString *_Nullable *_Nullable error);

// After `backup` (a file from Backups) was written back to `original`: if it
// is an SQLite database, the live -wal/-shm beside `original` still belong to
// the newer database and SQLite would reopen that (review DR-02). Each one
// that isn't empty is replaced by the backup's own sidecar (backup + "-wal")
// or else emptied, with the old bytes kept in Backups (their units are added
// to `units`). NO with *error when a sidecar can't be handled; nothing is done
// for files that aren't SQLite databases.
BOOL wq_sqlite_restore_sidecars_possible(NSString *original, NSString *backup, NSString *_Nullable *_Nullable error);
BOOL wq_sqlite_restore_sidecars(NSString *original, NSString *backup, NSMutableArray<NSString *> *_Nullable units,
                                NSString *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
