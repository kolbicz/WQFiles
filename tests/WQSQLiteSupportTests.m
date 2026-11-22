// SQLite viewer helpers: TEXT that isn't exact UTF-8 is shown but marked
// non-editable, and the CSV export escapes headers, keeps values exact,
// requires SQLITE_DONE and leaves no partial file behind on failure.
#import "../WQSQLiteSupport.h"
#include <stdio.h>

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}

static void exec(sqlite3 *db, const char *sql)
{
    char *err = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &err) != SQLITE_OK) { fprintf(stderr, "sql: %s: %s\n", sql, err); exit(1); }
}

static void insertText(sqlite3 *db, int id, const char *bytes, int length)
{
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(db, "INSERT INTO t(id, v) VALUES (?, ?)", -1, &stmt, NULL);
    sqlite3_bind_int(stmt, 1, id);
    sqlite3_bind_text(stmt, 2, bytes, length, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) != SQLITE_DONE) { fprintf(stderr, "insert failed\n"); exit(1); }
    sqlite3_finalize(stmt);
}

// Display text and kind of t.v for one id.
static NSString *valueOf(sqlite3 *db, int id, int *kind)
{
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(db, "SELECT v FROM t WHERE id = ?", -1, &stmt, NULL);
    sqlite3_bind_int(stmt, 1, id);
    NSString *s = sqlite3_step(stmt) == SQLITE_ROW ? wq_sqlite_value(stmt, 0, YES, kind) : nil;
    sqlite3_finalize(stmt);
    return s;
}

static ssize_t failingWrite(int fd, const void *buffer, size_t length)
{
    (void)fd; (void)buffer; (void)length;
    errno = ENOSPC;
    return -1;
}

int main(void)
{
    @autoreleasepool {
        // DR-29: REAL values shown as text read back to the same double.
        double reals[] = {0.1, 1.0/3.0, 0.1 + 0.2, 1e-300, 123456789.123456789, -2.5};
        for (size_t i = 0; i < sizeof reals / sizeof reals[0]; i++)
            check(strtod(wq_sqlite_real_text(reals[i]).UTF8String, NULL) == reals[i], @"REAL text round-trips");
        check([wq_sqlite_real_text(0.1) isEqualToString:@"0.1"], @"short REAL text stays short");
        long long exact = 0;
        check(wq_sqlite_exact_integer(@"9223372036854775807", &exact) && exact == LLONG_MAX, @"largest integer is exact");
        check(wq_sqlite_exact_integer(@"-9223372036854775808", &exact) && exact == LLONG_MIN, @"smallest integer is exact");
        check(!wq_sqlite_exact_integer(@"9223372036854775808", &exact), @"an integer out of range is not clamped");
        check(!wq_sqlite_exact_integer(@"12x", &exact) && !wq_sqlite_exact_integer(@"", &exact) && !wq_sqlite_exact_integer(@"-", &exact) &&
              !wq_sqlite_exact_integer(@"1.0", &exact), @"only whole numbers");
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [@"WQSQLiteSupportTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        check([fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil], @"fixture folder");
        sqlite3 *db = NULL;
        check(sqlite3_open(":memory:", &db) == SQLITE_OK, @"open database");
        exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, v)");

        // --- Exact text, embedded NUL, invalid UTF-8 ---
        check([wq_sqlite_exact_text((const unsigned char *)"h\xc3\xa9llo", 6) isEqualToString:@"héllo"], @"valid UTF-8 is exact");
        check(wq_sqlite_exact_text((const unsigned char *)"a\0b", 3) == nil, @"embedded NUL is not exact");
        check(wq_sqlite_exact_text((const unsigned char *)"a\xff" "b", 3) == nil, @"invalid UTF-8 is not exact");
        check([wq_sqlite_exact_text(NULL, 0) isEqualToString:@""], @"empty text is exact");

        insertText(db, 1, "plain", 5);
        insertText(db, 2, "a\0b", 3);
        insertText(db, 3, "x\xff\xfey", 4);
        int kind = 0;
        NSString *shown = valueOf(db, 1, &kind);
        check([shown isEqualToString:@"plain"] && kind == SQLITE_TEXT, @"plain text shown and editable");
        shown = valueOf(db, 2, &kind);
        check([shown isEqualToString:@"a␀b"] && kind == WQSQLiteTextRaw, @"NUL text shown whole (a␀b) and marked raw");
        shown = valueOf(db, 3, &kind);
        check([shown hasPrefix:WQLocalized(@"<text not UTF-8>")] && [shown containsString:@"78fffe79"] && kind == WQSQLiteTextRaw,
              @"invalid UTF-8 shown as hex and marked raw");
        exec(db, "INSERT INTO t(id, v) VALUES (4, X'00ff'), (5, NULL), (6, 42), (7, 0.1)");
        valueOf(db, 4, &kind); check(kind == SQLITE_BLOB, @"blob kind");
        valueOf(db, 5, &kind); check(kind == SQLITE_NULL, @"null kind");
        valueOf(db, 6, &kind); check(kind == SQLITE_INTEGER, @"integer kind");

        // --- CSV: escaped headers, exact values ---
        NSString *csv = [base stringByAppendingPathComponent:@"a.csv"];
        NSString *error = nil;
        check(wq_sqlite_export_csv(db, @"SELECT 1 AS \"a,b\", 2 AS \"q\"\"x\", 3 AS \"line\nbreak\", 4 AS plain", csv, nil, &error),
              @"export with odd column names");
        NSData *bytes = [NSData dataWithContentsOfFile:csv];
        NSData *expected = [@"\"a,b\",\"q\"\"x\",\"line\nbreak\",plain\r\n1,2,3,4\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        check([bytes isEqualToData:expected], @"header names are CSV-escaped like values");

        exec(db, "CREATE TABLE u(id INTEGER PRIMARY KEY, v)");
        exec(db, "INSERT INTO u(v) VALUES (NULL), (''), (0.1), (0.30000000000000004), (1e300), ('say \"hi\", ok'), (X'00ff10')");
        sqlite3_stmt *ins = NULL;
        sqlite3_prepare_v2(db, "INSERT INTO u(v) VALUES (?)", -1, &ins, NULL);
        sqlite3_bind_text(ins, 1, "a\0b", 3, SQLITE_TRANSIENT); sqlite3_step(ins); sqlite3_reset(ins);
        sqlite3_bind_text(ins, 1, "x\xffy", 3, SQLITE_TRANSIENT); sqlite3_step(ins);
        sqlite3_finalize(ins);
        NSString *csv2 = [base stringByAppendingPathComponent:@"b.csv"];
        check(wq_sqlite_export_csv(db, @"SELECT v FROM u ORDER BY id", csv2, nil, &error), @"export typed values");
        // NULL and '' are both empty fields (CSV has no NULL); the rest exact.
        const char want[] = "v\r\n\r\n\r\n0.1\r\n0.30000000000000004\r\n1e+300\r\n\"say \"\"hi\"\", ok\"\r\nbase64:AP8Q\r\na\0b\r\nx\xffy\r\n";
        NSData *got = [NSData dataWithContentsOfFile:csv2];
        NSData *wantData = [NSData dataWithBytes:want length:sizeof want - 1];
        check([got isEqualToData:wantData], @"values exact: doubles round-trip, quotes doubled, blob base64, raw text bytes kept");

        // --- Failures leave nothing behind ---
        exec(db, "CREATE TABLE w(x INTEGER)");
        exec(db, "INSERT INTO w VALUES (1),(2),(3),(4)");
        NSString *csv3 = [base stringByAppendingPathComponent:@"c.csv"];
        error = nil;
        check(!wq_sqlite_export_csv(db, @"SELECT CASE WHEN x = 3 THEN abs(-9223372036854775807 - 1) ELSE x END FROM w", csv3, nil, &error) &&
              error.length && ![fm fileExistsAtPath:csv3], @"a failing step mid-export fails and removes the partial file");
        error = nil;
        wq_sqlite_csv_write = failingWrite;
        check(!wq_sqlite_export_csv(db, @"SELECT x FROM w", csv3, nil, &error) && [error containsString:@"write failed"] &&
              ![fm fileExistsAtPath:csv3], @"a failing write fails and removes the partial file");
        wq_sqlite_csv_write = write;
        error = nil;
        check(!wq_sqlite_export_csv(db, @"SELECT x FROM w", csv3, ^BOOL { return YES; }, &error) && ![fm fileExistsAtPath:csv3],
              @"a cancelled export removes the partial file");
        error = nil;
        check(!wq_sqlite_export_csv(db, @"DELETE FROM w", csv3, nil, &error) && ![fm fileExistsAtPath:csv3] &&
              [[NSData dataWithContentsOfFile:csv] isEqualToData:expected] == YES, @"writing statements are refused");
        error = nil;
        check(!wq_sqlite_export_csv(db, @"SELECT x FROM w", csv, nil, &error) && [[NSData dataWithContentsOfFile:csv] isEqualToData:expected],
              @"an existing file is never overwritten or appended to");
        sqlite3_stmt *countStmt = NULL;
        sqlite3_prepare_v2(db, "SELECT count(*) FROM w", -1, &countStmt, NULL);
        check(sqlite3_step(countStmt) == SQLITE_ROW && sqlite3_column_int(countStmt, 0) == 4, @"refused statement changed nothing");
        sqlite3_finalize(countStmt);

        sqlite3_close(db);
        [fm removeItemAtPath:base error:nil];
        puts("All SQLite support tests passed.");
    }
    return 0;
}
