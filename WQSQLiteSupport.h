//
//  WQSQLiteSupport.h
//  WQ Files
//
//  UIKit-free helpers of the SQLite viewer: how a column value is shown and
//  whether it can be edited as text, and the CSV export. Header-only so the
//  host tests can include it.
//

#import <Foundation/Foundation.h>
#import <sqlite3.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#import "WQLocalization.h"

NS_ASSUME_NONNULL_BEGIN

// The kind recorded for a TEXT value whose bytes an NSString can't hold
// exactly (invalid UTF-8, or NUL bytes). Shown, but never edited as text:
// saving the displayed string back would change bytes nobody touched.
enum { WQSQLiteTextRaw = 0x100 };

static inline NSString *wq_sqlite_hex(const uint8_t *bytes, int length, int limit)
{
    NSMutableString *hex = [NSMutableString new];
    for (int i = 0; i < length && i < limit; i++) [hex appendFormat:@"%02x%s", bytes[i], (i % 4 == 3) ? " " : ""];
    if (length > limit) [hex appendString:@"…"];
    return hex;
}

// The TEXT bytes as a string only when it represents them exactly: valid
// UTF-8 without NUL bytes that encodes back to the same bytes. nil otherwise.
static inline NSString *_Nullable wq_sqlite_exact_text(const unsigned char *_Nullable bytes, int length)
{
    if (length <= 0) return @"";
    if (!bytes || memchr(bytes, 0, (size_t)length)) return nil;
    NSString *s = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    NSData *back = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!s || back.length != (NSUInteger)length || memcmp(back.bytes, bytes, (size_t)length) != 0) return nil;
    return s;
}

// A whole number in text (optional sign, ASCII digits) that fits a 64-bit
// integer exactly. NO for anything else, including values out of range.
static inline BOOL wq_sqlite_exact_integer(NSString *text, long long *value)
{
    const char *c = text.UTF8String;
    if (!c || !*c) return NO;
    const char *digits = (*c == '-' || *c == '+') ? c + 1 : c;
    if (!*digits) return NO;
    for (const char *p = digits; *p; p++) if (*p < '0' || *p > '9') return NO;
    errno = 0;
    char *end = NULL;
    long long parsed = strtoll(c, &end, 10);
    if (errno == ERANGE || !end || *end) return NO;
    if (value) *value = parsed;
    return YES;
}

// A REAL as text that reads back to the same double (review DR-29): 15
// digits when they round-trip (0.1 stays "0.1"), else the 17 that always do.
static inline NSString *wq_sqlite_real_text(double value)
{
    NSString *text = [NSString stringWithFormat:@"%.15g", value];
    if (strtod(text.UTF8String, NULL) == value) return text;
    return [NSString stringWithFormat:@"%.17g", value];
}

// A column value as display text; `full` shows long text and blobs in more
// detail. *kind gets the SQLite type, or WQSQLiteTextRaw (see above).
static inline NSString *wq_sqlite_value(sqlite3_stmt *stmt, int column, BOOL full, int *_Nullable kind)
{
    int type = sqlite3_column_type(stmt, column);
    if (kind) *kind = type;
    switch (type) {
        case SQLITE_NULL: return WQLocalized(@"NULL");
        case SQLITE_INTEGER: return [NSString stringWithFormat:@"%lld", sqlite3_column_int64(stmt, column)];
        case SQLITE_FLOAT: return wq_sqlite_real_text(sqlite3_column_double(stmt, column));
        case SQLITE_BLOB: {
            const uint8_t *bytes = sqlite3_column_blob(stmt, column);
            int length = sqlite3_column_bytes(stmt, column);
            if (length >= 8 && bytes && memcmp(bytes, "bplist0", 7) == 0)
                return WQLocalizedFormat(@"<binary plist, %d bytes>", length);
            NSString *hex = bytes ? wq_sqlite_hex(bytes, length, full ? 512 : 16) : @"";
            return WQLocalizedFormat(@"<%d bytes> %@", length, hex);
        }
        default: {
            const unsigned char *text = sqlite3_column_text(stmt, column);
            int length = sqlite3_column_bytes(stmt, column);
            NSString *s = wq_sqlite_exact_text(text, length);
            if (!s) {
                if (kind) *kind = WQSQLiteTextRaw;
                // Valid UTF-8 with NUL bytes: show them as ␀.
                NSString *decoded = text && length > 0
                    ? [[NSString alloc] initWithBytes:text length:(NSUInteger)length encoding:NSUTF8StringEncoding] : nil;
                if (decoded) s = [decoded stringByReplacingOccurrencesOfString:@"\0" withString:@"␀"];
                else return [WQLocalized(@"<text not UTF-8>") stringByAppendingFormat:@" %@",
                             text ? wq_sqlite_hex(text, length, full ? 512 : 16) : @""];
            }
            if (!full && s.length > 200) s = [[s substringToIndex:200] stringByAppendingString:@"…"];
            return s;
        }
    }
}

#pragma mark - CSV

// One CSV field from raw bytes, quoted (quotes doubled) when it holds a
// comma, quote, CR or LF.
static inline void wq_sqlite_csv_append(NSMutableData *line, const void *_Nullable bytes, size_t length)
{
    const uint8_t *p = bytes;
    BOOL quote = NO;
    for (size_t i = 0; i < length && !quote; i++) quote = p[i] == ',' || p[i] == '"' || p[i] == '\r' || p[i] == '\n';
    if (!quote) { if (length) [line appendBytes:p length:length]; return; }
    [line appendBytes:"\"" length:1];
    size_t start = 0;
    for (size_t i = 0; i < length; i++) {
        if (p[i] != '"') continue;
        [line appendBytes:p + start length:i + 1 - start];   // through the quote
        [line appendBytes:"\"" length:1];                    // doubled
        start = i + 1;
    }
    if (start < length) [line appendBytes:p + start length:length - start];
    [line appendBytes:"\"" length:1];
}

// The shortest %g form of a double that reads back as the same double.
static inline void wq_sqlite_csv_double(char *buffer, double value)
{
    for (int digits = 15; digits <= 17; digits++) {
        snprintf(buffer, 40, "%.*g", digits, value);
        if (strtod(buffer, NULL) == value) return;
    }
}

// One value: NULL is an empty field, numbers exact, TEXT its stored bytes
// (as SQLite returns them in UTF-8), BLOB "base64:" plus its bytes.
static inline void wq_sqlite_csv_value(NSMutableData *line, sqlite3_stmt *stmt, int column)
{
    switch (sqlite3_column_type(stmt, column)) {
        case SQLITE_NULL: return;
        case SQLITE_INTEGER: {
            char buffer[32];
            snprintf(buffer, sizeof buffer, "%lld", sqlite3_column_int64(stmt, column));
            wq_sqlite_csv_append(line, buffer, strlen(buffer));
            return;
        }
        case SQLITE_FLOAT: {
            char buffer[40];
            wq_sqlite_csv_double(buffer, sqlite3_column_double(stmt, column));
            wq_sqlite_csv_append(line, buffer, strlen(buffer));
            return;
        }
        case SQLITE_BLOB: {
            const void *bytes = sqlite3_column_blob(stmt, column);
            int length = sqlite3_column_bytes(stmt, column);
            NSData *data = bytes && length > 0 ? [NSData dataWithBytes:bytes length:(NSUInteger)length] : [NSData data];
            NSData *encoded = [[@"base64:" stringByAppendingString:[data base64EncodedStringWithOptions:0]] dataUsingEncoding:NSUTF8StringEncoding];
            [line appendData:encoded];
            return;
        }
        default: {
            const unsigned char *text = sqlite3_column_text(stmt, column);
            int length = sqlite3_column_bytes(stmt, column);
            wq_sqlite_csv_append(line, text, text && length > 0 ? (size_t)length : 0);
            return;
        }
    }
}

// write(2) by default; the tests swap it to simulate a full disk.
static ssize_t (*wq_sqlite_csv_write)(int, const void *, size_t) = write;

static inline BOOL wq_sqlite_csv_flush(int fd, NSMutableData *buffer)
{
    const uint8_t *p = buffer.bytes;
    size_t left = buffer.length;
    while (left > 0) {
        ssize_t n = wq_sqlite_csv_write(fd, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return NO; }
        p += n;
        left -= (size_t)n;
    }
    buffer.length = 0;
    return YES;
}

// Writes the result of the read-only statement `sql` as CSV to `path`, which
// must not exist yet: a header row with the column names, then one CRLF line
// per row. Succeeds only when every row was read (SQLITE_DONE) and written
// and the file closed; otherwise the partial file is removed and *error says
// why. `cancelled` (optional) is polled while stepping.
static inline BOOL wq_sqlite_export_csv(sqlite3 *db, NSString *sql, NSString *path,
                                        BOOL (^_Nullable cancelled)(void), NSString *_Nullable *_Nullable error)
{
    NSString *failure = nil;
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) {
        if (error) *error = WQLocalized(@"cannot create the CSV file");
        return NO;
    }
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        failure = @(sqlite3_errmsg(db));
    } else if (!stmt) {
        failure = WQLocalized(@"Nothing to run.");
    } else if (!sqlite3_stmt_readonly(stmt)) {
        failure = WQLocalized(@"Only read-only statements can run here.");
    } else {
        int count = sqlite3_column_count(stmt);
        NSMutableData *buffer = [NSMutableData dataWithCapacity:1 << 16];
        for (int i = 0; i < count; i++) {
            if (i) [buffer appendBytes:"," length:1];
            const char *name = sqlite3_column_name(stmt, i) ?: "?";
            wq_sqlite_csv_append(buffer, name, strlen(name));
        }
        [buffer appendBytes:"\r\n" length:2];
        int rc;
        while (!failure && (rc = sqlite3_step(stmt)) == SQLITE_ROW) {
            @autoreleasepool {
                for (int i = 0; i < count; i++) {
                    if (i) [buffer appendBytes:"," length:1];
                    wq_sqlite_csv_value(buffer, stmt, i);
                }
                [buffer appendBytes:"\r\n" length:2];
                if (buffer.length >= (1 << 16) && !wq_sqlite_csv_flush(fd, buffer))
                    failure = [WQLocalized(@"write failed") stringByAppendingFormat:@" (%s)", strerror(errno)];
                else if (cancelled && cancelled())
                    failure = WQLocalized(@"Cancelled");
            }
        }
        if (!failure && rc != SQLITE_DONE) failure = @(sqlite3_errmsg(db));
        if (!failure && !wq_sqlite_csv_flush(fd, buffer))
            failure = [WQLocalized(@"write failed") stringByAppendingFormat:@" (%s)", strerror(errno)];
    }
    sqlite3_finalize(stmt);
    if (close(fd) != 0 && !failure) failure = [WQLocalized(@"write failed") stringByAppendingFormat:@" (%s)", strerror(errno)];
    if (failure) {
        unlink(path.fileSystemRepresentation);
        if (error) *error = failure;
        return NO;
    }
    return YES;
}

NS_ASSUME_NONNULL_END
