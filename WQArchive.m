//
//  WQArchive.m
//  WQ Files
//

#import "WQArchive.h"
#import "WQLocalization.h"
#import <dirent.h>
#import <fcntl.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>
#import <zlib.h>

static const size_t kWQZipChunk = 256 * 1024;
static const uint32_t kWQZipMax32 = 0xFFFFFFFFu;

// Extracting a real container (an import as backup, issue #72) hits iOS'
// sandbox guard: creating a file named .com.apple.mobile_container_manager.
// metadata.plist is refused (Operation not permitted), so the whole extract
// fails. The name is skipped; WQAppsSupportImportDeclaredBundles reads the
// declaration from .wqbackup.plist instead when the metadata file is absent.
static NSSet<NSString *> *wq_zip_unwritable_names(void)
{
    static NSSet<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithObject:@".com.apple.mobile_container_manager.metadata.plist"];
    });
    return names;
}

@implementation WQArchiveIO
@end

int wq_archive_errno(NSError *error)
{
    for (NSError *e = error; e; e = e.userInfo[NSUnderlyingErrorKey]) {
        if ([e.domain isEqualToString:NSPOSIXErrorDomain] && e.code > 0) return (int)e.code;
    }
    if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoPermissionError) return EACCES;
    if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError) return ENOENT;
    return EIO;
}

WQArchiveIO *wq_archive_posix_io(void)
{
    WQArchiveIO *io = [WQArchiveIO new];
    io.stat = ^BOOL(NSString *path, struct stat *st) { return lstat(path.fileSystemRepresentation, st) == 0; };
    io.list = ^NSArray<NSString *> *(NSString *dir) {
        NSError *error = nil;
        NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
        if (!names) errno = wq_archive_errno(error);
        return names;
    };
    io.openRead = ^int(NSString *path) {
        return open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    };
    return io;
}

#pragma mark Little-endian helpers

static void wq_put16(NSMutableData *d, uint16_t v) { uint8_t b[2] = { (uint8_t)v, (uint8_t)(v >> 8) }; [d appendBytes:b length:2]; }
static void wq_put32(NSMutableData *d, uint32_t v)
{
    uint8_t b[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) };
    [d appendBytes:b length:4];
}
static uint16_t wq_rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t wq_rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t wq_rd64(const uint8_t *p) { return (uint64_t)wq_rd32(p) | ((uint64_t)wq_rd32(p + 4) << 32); }

static BOOL wq_write_fd(int fd, const void *buf, size_t n)
{
    const uint8_t *p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return NO;
        p += w; n -= (size_t)w;
    }
    return YES;
}

static BOOL wq_pread_all(int fd, void *buf, size_t n, off_t offset)
{
    uint8_t *p = buf;
    while (n > 0) {
        ssize_t r = pread(fd, p, n, offset);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return NO;
        p += r; n -= (size_t)r; offset += r;
    }
    return YES;
}

static ssize_t wq_read_some(int fd, void *buf, size_t n)
{
    for (;;) {
        ssize_t r = read(fd, buf, n);
        if (r < 0 && errno == EINTR) continue;
        return r;
    }
}

static void wq_dos_time(time_t t, uint16_t *dosTime, uint16_t *dosDate)
{
    struct tm tm;
    localtime_r(&t, &tm);
    if (tm.tm_year < 80) { *dosTime = 0; *dosDate = (1 << 5) | 1; return; }   // 1980-01-01
    if (tm.tm_year > 207) tm.tm_year = 207;
    *dosTime = (uint16_t)((tm.tm_hour << 11) | (tm.tm_min << 5) | (tm.tm_sec / 2));
    *dosDate = (uint16_t)(((tm.tm_year - 80) << 9) | ((tm.tm_mon + 1) << 5) | tm.tm_mday);
}

static time_t wq_from_dos_time(uint16_t dosTime, uint16_t dosDate)
{
    struct tm tm = {0};
    tm.tm_year = ((dosDate >> 9) & 0x7f) + 80;
    tm.tm_mon = ((dosDate >> 5) & 0x0f) - 1;
    tm.tm_mday = dosDate & 0x1f;
    tm.tm_hour = (dosTime >> 11) & 0x1f;
    tm.tm_min = (dosTime >> 5) & 0x3f;
    tm.tm_sec = (dosTime & 0x1f) * 2;
    tm.tm_isdst = -1;
    if (tm.tm_mon < 0 || tm.tm_mday == 0) return 0;
    return mktime(&tm);
}

#pragma mark Writing

@interface WQZipEntry : NSObject
@property (nonatomic) NSData *name;
@property (nonatomic) BOOL dir;
@property (nonatomic) uint16_t method, time, date;
@property (nonatomic) uint32_t crc, mode;
@property (nonatomic) uint64_t csize, usize, offset;
@end
@implementation WQZipEntry
@end

typedef struct {
    int out;
    uint64_t offset;
    unsigned long long bytesRead;
    NSUInteger skipped;
    NSMutableArray<WQZipEntry *> *entries;
    WQArchiveIO *io;
    WQArchiveCancelled cancelled;
    WQArchiveProgress progress;
    NSString *error;
} WQZipWriter;

static BOOL wq_zip_fail(WQZipWriter *w, NSString *message)
{
    if (!w->error) w->error = message;
    return NO;
}

static BOOL wq_zip_too_big(WQZipWriter *w)
{
    return wq_zip_fail(w, WQLocalized(@"The archive would be larger than 4 GB, which isn't supported yet."));
}

static BOOL wq_zip_local_header(WQZipWriter *w, WQZipEntry *e)
{
    if (w->offset >= kWQZipMax32) return wq_zip_too_big(w);
    if (w->entries.count >= 0xFFFF) return wq_zip_fail(w, WQLocalized(@"Too many items for one ZIP (more than 65535)."));
    e.offset = w->offset;
    NSMutableData *h = [NSMutableData dataWithCapacity:30 + e.name.length];
    wq_put32(h, 0x04034b50);
    wq_put16(h, 20);               // version needed
    wq_put16(h, 0x0800);           // UTF-8 names
    wq_put16(h, e.method);
    wq_put16(h, e.time);
    wq_put16(h, e.date);
    wq_put32(h, 0); wq_put32(h, 0); wq_put32(h, 0);   // crc and sizes, patched later
    wq_put16(h, (uint16_t)e.name.length);
    wq_put16(h, 0);
    [h appendData:e.name];
    if (!wq_write_fd(w->out, h.bytes, h.length)) return wq_zip_fail(w, @(strerror(errno)));
    w->offset += h.length;
    [w->entries addObject:e];
    return YES;
}

static BOOL wq_zip_add_file(WQZipWriter *w, NSString *path, NSString *name, const struct stat *st)
{
    int in = w->io.openRead(path);
    if (in < 0 && w->io.skipUnreadable && (errno == EACCES || errno == EPERM)) {
        if ([w->io.expectedUnreadableNames containsObject:path.lastPathComponent]) w->io.expectedUnreadable++;
        else w->io.unreadable++;
        return YES;
    }
    if (in < 0) return wq_zip_fail(w, WQLocalizedFormat(@"Can't read %@ (%s)", name, strerror(errno)));
    WQZipEntry *e = [WQZipEntry new];
    e.name = [name dataUsingEncoding:NSUTF8StringEncoding];
    e.method = 8;
    e.mode = st->st_mode & 0777;
    uint16_t t, d; wq_dos_time(st->st_mtimespec.tv_sec, &t, &d); e.time = t; e.date = d;
    if (!wq_zip_local_header(w, e)) { close(in); return NO; }

    z_stream z = {0};
    if (deflateInit2(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        close(in); return wq_zip_fail(w, WQLocalized(@"Can't start compression"));
    }
    uint8_t *inBuf = malloc(kWQZipChunk), *outBuf = malloc(kWQZipChunk);
    BOOL ok = inBuf && outBuf;
    if (!ok) wq_zip_fail(w, WQLocalized(@"Out of memory"));
    uLong crc = crc32(0, NULL, 0);
    uint64_t usize = 0, csize = 0;
    BOOL eof = NO;
    while (ok && !eof) {
        if (w->cancelled && w->cancelled()) { ok = wq_zip_fail(w, @"Cancelled"); break; }
        ssize_t n = wq_read_some(in, inBuf, kWQZipChunk);
        if (n < 0) { ok = wq_zip_fail(w, WQLocalizedFormat(@"Can't read %@ (%s)", name, strerror(errno))); break; }
        eof = n == 0;
        crc = crc32(crc, inBuf, (uInt)n);
        usize += (uint64_t)n;
        w->bytesRead += (unsigned long long)n;
        if (usize >= kWQZipMax32) { ok = wq_zip_too_big(w); break; }
        z.next_in = inBuf; z.avail_in = (uInt)n;
        int flush = eof ? Z_FINISH : Z_NO_FLUSH;
        int rc;
        do {
            z.next_out = outBuf; z.avail_out = (uInt)kWQZipChunk;
            rc = deflate(&z, flush);
            if (rc == Z_STREAM_ERROR) { ok = wq_zip_fail(w, WQLocalized(@"Compression failed")); break; }
            size_t have = kWQZipChunk - z.avail_out;
            if (have && !wq_write_fd(w->out, outBuf, have)) { ok = wq_zip_fail(w, @(strerror(errno))); break; }
            csize += have;
        } while (z.avail_out == 0);
        if (ok && w->progress) w->progress(w->bytesRead);
    }
    deflateEnd(&z);
    free(inBuf); free(outBuf);
    close(in);
    if (!ok) return NO;
    w->offset += csize;
    if (w->offset >= kWQZipMax32) return wq_zip_too_big(w);
    e.crc = (uint32_t)crc; e.csize = csize; e.usize = usize;
    NSMutableData *patch = [NSMutableData dataWithCapacity:12];
    wq_put32(patch, e.crc); wq_put32(patch, (uint32_t)csize); wq_put32(patch, (uint32_t)usize);
    if (pwrite(w->out, patch.bytes, 12, (off_t)e.offset + 14) != 12) return wq_zip_fail(w, @(strerror(errno)));
    return YES;
}

static BOOL wq_zip_add(WQZipWriter *w, NSString *path, NSString *name, NSUInteger depth)
{
    if (w->cancelled && w->cancelled()) return wq_zip_fail(w, @"Cancelled");
    if (depth > 64) return wq_zip_fail(w, WQLocalized(@"Folders are nested too deeply"));
    struct stat st;
    if (!w->io.stat(path, &st)) return wq_zip_fail(w, WQLocalizedFormat(@"Can't read %@ (%s)", name, strerror(errno)));
    if (S_ISREG(st.st_mode)) return wq_zip_add_file(w, path, name, &st);
    if (!S_ISDIR(st.st_mode)) { w->skipped++; return YES; }   // links and special files
    WQZipEntry *e = [WQZipEntry new];
    e.name = [[name stringByAppendingString:@"/"] dataUsingEncoding:NSUTF8StringEncoding];
    e.dir = YES;
    e.mode = st.st_mode & 0777;
    uint16_t t, d; wq_dos_time(st.st_mtimespec.tv_sec, &t, &d); e.time = t; e.date = d;
    e.crc = 0;
    if (!wq_zip_local_header(w, e)) return NO;
    errno = 0;
    NSArray<NSString *> *children = w->io.list(path);
    int listError = errno;
    // Only a refusal (permissions, sandbox) is skipped; any other failure
    // would silently drop a subtree from what looks like a complete archive.
    if (!children && w->io.skipUnreadable && (listError == EACCES || listError == EPERM)) {
        w->io.unreadable++; return YES;   // kept as an empty folder
    }
    if (!children) return wq_zip_fail(w, WQLocalizedFormat(@"Can't list %@", name));
    for (NSString *child in [children sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if (!wq_zip_add(w, [path stringByAppendingPathComponent:child], [name stringByAppendingFormat:@"/%@", child], depth + 1))
            return NO;
    }
    return YES;
}

static BOOL wq_zip_central_directory(WQZipWriter *w)
{
    uint64_t cdStart = w->offset;
    NSMutableData *cd = [NSMutableData new];
    for (WQZipEntry *e in w->entries) {
        wq_put32(cd, 0x02014b50);
        wq_put16(cd, (3 << 8) | 20);   // made by Unix, ZIP 2.0
        wq_put16(cd, 20);
        wq_put16(cd, 0x0800);
        wq_put16(cd, e.method);
        wq_put16(cd, e.time);
        wq_put16(cd, e.date);
        wq_put32(cd, e.crc);
        wq_put32(cd, (uint32_t)e.csize);
        wq_put32(cd, (uint32_t)e.usize);
        wq_put16(cd, (uint16_t)e.name.length);
        wq_put16(cd, 0); wq_put16(cd, 0); wq_put16(cd, 0); wq_put16(cd, 0);
        uint32_t type = e.dir ? S_IFDIR : S_IFREG;
        wq_put32(cd, ((type | e.mode) << 16) | (e.dir ? 0x10 : 0));
        wq_put32(cd, (uint32_t)e.offset);
        [cd appendData:e.name];
    }
    uint32_t cdLength = (uint32_t)cd.length;
    if (cdStart + cd.length >= kWQZipMax32) return wq_zip_too_big(w);
    wq_put32(cd, 0x06054b50);
    wq_put16(cd, 0); wq_put16(cd, 0);
    wq_put16(cd, (uint16_t)w->entries.count);
    wq_put16(cd, (uint16_t)w->entries.count);
    wq_put32(cd, cdLength);
    wq_put32(cd, (uint32_t)cdStart);
    wq_put16(cd, 0);
    if (!wq_write_fd(w->out, cd.bytes, cd.length)) return wq_zip_fail(w, @(strerror(errno)));
    return YES;
}

BOOL wq_zip_write(NSArray<NSString *> *paths, NSString *zipPath, WQArchiveIO *io,
                  WQArchiveCancelled cancelled, WQArchiveProgress progress,
                  NSUInteger *skipped, NSString **errorText)
{
    if (paths.count == 0) { if (errorText) *errorText = WQLocalized(@"Nothing to compress"); return NO; }
    int out = open(zipPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (out < 0) { if (errorText) *errorText = @(strerror(errno)); return NO; }
    NSMutableArray *entries = [NSMutableArray new];
    NSString *error = nil;
    WQZipWriter w = { .out = out, .entries = entries, .io = io, .cancelled = cancelled, .progress = progress };
    BOOL ok = YES;
    NSMutableSet<NSString *> *topNames = [NSMutableSet new];
    for (NSString *path in paths) {
        NSString *name = path.lastPathComponent;
        if (!name.length || [topNames containsObject:name]) { ok = wq_zip_fail(&w, WQLocalized(@"Two selected items have the same name")); break; }
        [topNames addObject:name];
        if (!(ok = wq_zip_add(&w, path, name, 0))) break;
    }
    if (ok) ok = wq_zip_central_directory(&w);
    if (ok && fsync(out) != 0) ok = wq_zip_fail(&w, @(strerror(errno)));
    error = w.error;
    if (close(out) != 0 && ok) { ok = NO; error = @(strerror(errno)); }
    if (!ok) unlink(zipPath.fileSystemRepresentation);
    if (skipped) *skipped = w.skipped;
    if (!ok && errorText) *errorText = error ?: WQLocalized(@"Could not create the ZIP");
    return ok;
}

#pragma mark Reading

NSString *wq_zip_safe_entry_path(NSString *name)
{
    if (!name.length || [name rangeOfString:@"\0"].location != NSNotFound) return nil;
    NSString *slashed = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([slashed hasPrefix:@"/"]) return nil;
    if (slashed.length >= 2 && [slashed characterAtIndex:1] == ':') return nil;   // "C:/…"
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *part in [slashed componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) return nil;
        if (strlen(part.fileSystemRepresentation ?: "") > 255) return nil;
        [parts addObject:part];
    }
    return parts.count ? [parts componentsJoinedByString:@"/"] : nil;
}

typedef struct {
    NSString *name;
    uint16_t flags, method, time, date, madeBy;
    uint32_t crc, external;
    uint64_t csize, usize, offset;
} WQZipItem;

static NSString *wq_zip_decode_name(const uint8_t *p, uint16_t len, uint16_t flags)
{
    NSData *raw = [NSData dataWithBytes:p length:len];
    NSString *s = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
    if (!s && !(flags & 0x0800))
        s = [[NSString alloc] initWithData:raw encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSLatinUS)];
    return s;
}

// Checks one end-of-central-directory candidate (the 22 bytes at eocdPos).
// A real one has its comment running exactly to the end of the file, and its
// central directory ending exactly where the end records begin, starting with
// a directory record. EOCD-shaped bytes inside a comment rarely pass this.
static BOOL wq_zip_eocd_candidate(int fd, uint64_t fileSize, const uint8_t *rec, uint64_t eocdPos,
                                  uint64_t *countOut, uint64_t *cdSizeOut, uint64_t *cdOffsetOut)
{
    uint64_t disk = wq_rd16(rec + 4), cdDisk = wq_rd16(rec + 6), diskCount = wq_rd16(rec + 8);
    uint64_t count = wq_rd16(rec + 10), cdSize = wq_rd32(rec + 12), cdOffset = wq_rd32(rec + 16);
    if (eocdPos + 22 + wq_rd16(rec + 20) != fileSize) return NO;
    uint64_t cdEnd = eocdPos;
    if (eocdPos >= 20) {
        uint8_t loc[20], rec64[56];
        if (wq_pread_all(fd, loc, 20, (off_t)(eocdPos - 20)) && wq_rd32(loc) == 0x07064b50) {
            uint64_t recPos = wq_rd64(loc + 8);
            if (recPos > eocdPos - 20 || eocdPos - 20 - recPos < 56 ||
                !wq_pread_all(fd, rec64, 56, (off_t)recPos) || wq_rd32(rec64) != 0x06064b50 ||
                wq_rd64(rec64 + 4) != eocdPos - 20 - recPos - 12) return NO;
            cdEnd = recPos;
            if (disk == 0xFFFF) disk = wq_rd32(rec64 + 16);
            if (cdDisk == 0xFFFF) cdDisk = wq_rd32(rec64 + 20);
            if (diskCount == 0xFFFF) diskCount = wq_rd64(rec64 + 24);
            if (count == 0xFFFF) count = wq_rd64(rec64 + 32);
            if (cdSize == kWQZipMax32) cdSize = wq_rd64(rec64 + 40);
            if (cdOffset == kWQZipMax32) cdOffset = wq_rd64(rec64 + 48);
        }
    }
    if (disk != 0 || cdDisk != 0 || diskCount != count) return NO;   // multi-disk archives aren't supported
    if (cdOffset > cdEnd || cdSize != cdEnd - cdOffset) return NO;
    if (count == 0) { if (cdSize != 0) return NO; }
    else {
        uint8_t sig[4];
        if (count > cdSize / 46 || !wq_pread_all(fd, sig, 4, (off_t)cdOffset) || wq_rd32(sig) != 0x02014b50) return NO;
    }
    *countOut = count; *cdSizeOut = cdSize; *cdOffsetOut = cdOffset;
    return YES;
}

static BOOL wq_zip_read_directory(int fd, uint64_t fileSize, WQZipItem **itemsOut, NSUInteger *countOut, NSString **error)
{
    size_t tailLen = (size_t)MIN(fileSize, (uint64_t)(22 + 65535));
    if (tailLen < 22) { *error = WQLocalized(@"Not a ZIP file"); return NO; }
    uint8_t *tail = malloc(tailLen);
    if (!tail || !wq_pread_all(fd, tail, tailLen, (off_t)(fileSize - tailLen))) { free(tail); *error = WQLocalized(@"Can't read the ZIP file"); return NO; }
    // Every signature in the tail is a candidate; exactly one may be consistent.
    BOOL signature = NO;
    NSUInteger valid = 0;
    uint64_t count = 0, cdSize = 0, cdOffset = 0;
    for (ssize_t i = (ssize_t)tailLen - 22; i >= 0; i--) {
        if (wq_rd32(tail + i) != 0x06054b50) continue;
        signature = YES;
        uint64_t c, s, o;
        if (!wq_zip_eocd_candidate(fd, fileSize, tail + i, fileSize - tailLen + (uint64_t)i, &c, &s, &o)) continue;
        if (++valid == 1) { count = c; cdSize = s; cdOffset = o; }
    }
    free(tail);
    if (!signature) { *error = WQLocalized(@"Not a ZIP file (no directory found)"); return NO; }
    if (valid > 1) { *error = WQLocalized(@"The ZIP file is ambiguous (it has more than one directory)"); return NO; }
    if (valid == 0 || cdSize > 256ull * 1024 * 1024) {
        *error = WQLocalized(@"The ZIP file is damaged (bad directory)");
        return NO;
    }
    if (count > kWQZipMaxEntries) {
        *error = WQLocalizedFormat(@"This ZIP has too many items (more than %lu).", (unsigned long)kWQZipMaxEntries);
        return NO;
    }
    uint8_t *cd = malloc(cdSize ? (size_t)cdSize : 1);
    if (!cd || (cdSize && !wq_pread_all(fd, cd, (size_t)cdSize, (off_t)cdOffset))) { free(cd); *error = WQLocalized(@"Can't read the ZIP directory"); return NO; }
    WQZipItem *items = calloc((size_t)MAX(count, 1), sizeof(WQZipItem));
    if (!items) { free(cd); *error = WQLocalized(@"Out of memory"); return NO; }
    uint64_t pos = 0;
    NSUInteger n = 0;
    BOOL ok = YES;
    for (uint64_t i = 0; i < count; i++) {
        if (pos + 46 > cdSize || wq_rd32(cd + pos) != 0x02014b50) { ok = NO; break; }
        const uint8_t *p = cd + pos;
        uint16_t nameLen = wq_rd16(p + 28), extraLen = wq_rd16(p + 30), commentLen = wq_rd16(p + 32);
        if (pos + 46 + nameLen + extraLen + commentLen > cdSize) { ok = NO; break; }
        WQZipItem it = {0};
        it.madeBy = wq_rd16(p + 4);
        it.flags = wq_rd16(p + 8);
        it.method = wq_rd16(p + 10);
        it.time = wq_rd16(p + 12);
        it.date = wq_rd16(p + 14);
        it.crc = wq_rd32(p + 16);
        it.csize = wq_rd32(p + 20);
        it.usize = wq_rd32(p + 24);
        it.external = wq_rd32(p + 38);
        it.offset = wq_rd32(p + 42);
        // ZIP64 extra field: the 64-bit values for the fields marked 0xFFFFFFFF, in order.
        const uint8_t *x = p + 46 + nameLen, *xEnd = x + extraLen;
        while (x + 4 <= xEnd) {
            uint16_t xid = wq_rd16(x), xlen = wq_rd16(x + 2);
            if (x + 4 + xlen > xEnd) break;
            if (xid == 0x0001) {
                const uint8_t *v = x + 4, *vEnd = v + xlen;
                if (it.usize == kWQZipMax32 && v + 8 <= vEnd) { it.usize = wq_rd64(v); v += 8; }
                if (it.csize == kWQZipMax32 && v + 8 <= vEnd) { it.csize = wq_rd64(v); v += 8; }
                if (it.offset == kWQZipMax32 && v + 8 <= vEnd) it.offset = wq_rd64(v);
            }
            x += 4 + xlen;
        }
        it.name = wq_zip_decode_name(p + 46, nameLen, it.flags);
        if (!it.name) { ok = NO; break; }
        // The assignment retains the name (a strong field under ARC);
        // wq_zip_free_items lets go of it.
        items[n] = it;
        n++;
        pos += 46 + nameLen + extraLen + commentLen;
    }
    // The records must fill the directory exactly: a short count (e.g. a
    // 16-bit count that wrapped) would silently drop entries.
    if (ok && pos != cdSize) ok = NO;
    free(cd);
    if (!ok) {
        for (NSUInteger i = 0; i < n; i++) items[i].name = nil;
        free(items);
        *error = WQLocalized(@"The ZIP file is damaged (bad entry)");
        return NO;
    }
    *itemsOut = items;
    *countOut = n;
    return YES;
}

static void wq_zip_free_items(WQZipItem *items, NSUInteger n)
{
    for (NSUInteger i = 0; i < n; i++) items[i].name = nil;
    free(items);
}

static BOOL wq_zip_extract_entry(int fd, uint64_t fileSize, const WQZipItem *it, int out,
                                 unsigned long long *written, unsigned long long maxBytes,
                                 WQArchiveCancelled cancelled, WQArchiveProgress progress, NSString **error)
{
    uint8_t lh[30];
    if (it->offset + 30 > fileSize || !wq_pread_all(fd, lh, 30, (off_t)it->offset) || wq_rd32(lh) != 0x04034b50) {
        *error = WQLocalized(@"The ZIP file is damaged (bad entry header)"); return NO;
    }
    uint64_t dataPos = it->offset + 30 + wq_rd16(lh + 26) + wq_rd16(lh + 28);
    if (dataPos > fileSize || it->csize > fileSize - dataPos) { *error = WQLocalized(@"The ZIP file is damaged (entry out of range)"); return NO; }
    uint8_t *inBuf = malloc(kWQZipChunk), *outBuf = malloc(kWQZipChunk);
    if (!inBuf || !outBuf) { free(inBuf); free(outBuf); *error = WQLocalized(@"Out of memory"); return NO; }
    z_stream z = {0};
    BOOL inflating = it->method == 8;
    if (inflating && inflateInit2(&z, -MAX_WBITS) != Z_OK) { free(inBuf); free(outBuf); *error = WQLocalized(@"Can't start decompression"); return NO; }
    uLong crc = crc32(0, NULL, 0);
    uint64_t remaining = it->csize, produced = 0;
    off_t readPos = (off_t)dataPos;
    BOOL ok = YES, done = it->usize == 0 && it->csize == 0 && !inflating;
    while (ok && !done) {
        if (cancelled && cancelled()) { *error = @"Cancelled"; ok = NO; break; }
        if (z.avail_in == 0 && remaining > 0) {
            size_t chunk = (size_t)MIN(remaining, (uint64_t)kWQZipChunk);
            if (!wq_pread_all(fd, inBuf, chunk, readPos)) { *error = WQLocalized(@"Can't read the ZIP file"); ok = NO; break; }
            readPos += (off_t)chunk; remaining -= chunk;
            z.next_in = inBuf; z.avail_in = (uInt)chunk;
        }
        const uint8_t *data;
        size_t have;
        if (inflating) {
            z.next_out = outBuf; z.avail_out = (uInt)kWQZipChunk;
            int rc = inflate(&z, Z_NO_FLUSH);
            if (rc == Z_STREAM_END) done = YES;
            else if (rc == Z_BUF_ERROR && z.avail_in == 0 && remaining == 0) {
                *error = WQLocalized(@"The ZIP file is damaged (data ends early)"); ok = NO; break;
            } else if (rc != Z_OK && rc != Z_BUF_ERROR) {
                *error = WQLocalized(@"The ZIP file is damaged (bad compressed data)"); ok = NO; break;
            }
            data = outBuf; have = kWQZipChunk - z.avail_out;
        } else {
            data = z.next_in; have = z.avail_in;
            z.avail_in = 0;
            done = remaining == 0;
        }
        produced += have;
        if (produced > it->usize) { *error = WQLocalized(@"The ZIP file is damaged (entry larger than stated)"); ok = NO; break; }
        if (*written + have > maxBytes) { *error = WQLocalized(@"Not enough free space to extract this ZIP"); ok = NO; break; }
        if (have && !wq_write_fd(out, data, have)) { *error = @(strerror(errno)); ok = NO; break; }
        crc = crc32(crc, data, (uInt)have);
        *written += have;
        if (progress && have) progress(*written);
    }
    if (inflating) inflateEnd(&z);
    free(inBuf); free(outBuf);
    if (ok && (produced != it->usize || (uint32_t)crc != it->crc)) {
        *error = WQLocalized(@"The ZIP file is damaged (checksum mismatch)"); ok = NO;
    }
    return ok;
}

BOOL wq_zip_extract(NSString *zipPath, NSString *outDir, WQArchiveIO *io, unsigned long long maxBytes,
                    WQArchiveCancelled cancelled, WQArchiveProgress progress,
                    NSUInteger *filesOut, NSUInteger *skippedOut, NSString **errorText)
{
    NSString *error = nil;
    int fd = io.openRead(zipPath);
    if (fd < 0) { if (errorText) *errorText = @(strerror(errno)); return NO; }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) { close(fd); if (errorText) *errorText = WQLocalized(@"Not a regular file"); return NO; }
    uint64_t fileSize = (uint64_t)st.st_size;
    WQZipItem *items = NULL;
    NSUInteger count = 0;
    if (!wq_zip_read_directory(fd, fileSize, &items, &count, &error)) {
        close(fd); if (errorText) *errorText = error; return NO;
    }
    // Check everything before writing anything.
    unsigned long long declared = 0;
    NSMutableArray<NSString *> *safeNames = [NSMutableArray arrayWithCapacity:count];
    BOOL ok = YES;
    for (NSUInteger i = 0; i < count && ok; i++) {
        WQZipItem *it = &items[i];
        NSString *safe = wq_zip_safe_entry_path(it->name);
        if (!safe) {
            ok = NO; error = WQLocalizedFormat(@"The ZIP contains an unsafe name (%@); nothing was extracted.", it->name);
            break;
        }
        if ([safe componentsSeparatedByString:@"/"].count > kWQZipMaxPathDepth ||
            strlen(safe.fileSystemRepresentation ?: "") > kWQZipMaxPathBytes) {
            ok = NO; error = WQLocalizedFormat(@"The ZIP contains a path that is too long or too deep (%@); nothing was extracted.", it->name);
            break;
        }
        [safeNames addObject:safe];
        if (it->flags & 0x0001) { ok = NO; error = WQLocalized(@"This ZIP is encrypted, which isn't supported."); break; }
        BOOL isDir = [it->name hasSuffix:@"/"] || [it->name hasSuffix:@"\\"];
        if (!isDir && it->method != 0 && it->method != 8) {
            ok = NO; error = WQLocalizedFormat(@"This ZIP uses a compression method that isn't supported (%u).", it->method);
            break;
        }
        if (it->method == 0 && it->csize != it->usize) { ok = NO; error = WQLocalized(@"The ZIP file is damaged (bad sizes)"); break; }
        declared += it->usize;
    }
    if (ok && declared > maxBytes) { ok = NO; error = WQLocalized(@"Not enough free space to extract this ZIP"); }
    NSUInteger files = 0, skipped = 0;
    unsigned long long written = 0;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSUInteger i = 0; i < count && ok; i++) {
        WQZipItem *it = &items[i];
        NSString *rel = safeNames[i];
        if ([rel isEqualToString:@"__MACOSX"] || [rel hasPrefix:@"__MACOSX/"]) continue;
        // iOS refuses to create container metadata files (issue #72); skip
        // them instead of failing the whole extraction. Every other entry
        // extracts as before.
        NSString *lastName = rel.lastPathComponent;
        if ([wq_zip_unwritable_names() containsObject:lastName]) { skipped++; continue; }
        BOOL unixMade = (it->madeBy >> 8) == 3;
        mode_t mode = unixMade ? (mode_t)(it->external >> 16) : 0;
        if (unixMade && S_ISLNK(mode)) { skipped++; continue; }
        BOOL isDir = [it->name hasSuffix:@"/"] || [it->name hasSuffix:@"\\"] || (unixMade && S_ISDIR(mode)) || (it->external & 0x10);
        NSString *target = [outDir stringByAppendingPathComponent:rel];
        if (isDir) {
            if (![fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:nil]) {
                ok = NO; error = WQLocalizedFormat(@"Can't create the folder %@", rel);
            }
            continue;
        }
        NSString *parent = target.stringByDeletingLastPathComponent;
        if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil]) {
            ok = NO; error = WQLocalizedFormat(@"Can't create the folder for %@", rel); break;
        }
        int out = open(target.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (out < 0) {
            ok = NO;
            error = errno == EEXIST ? WQLocalizedFormat(@"The ZIP contains %@ twice", rel)
                                    : WQLocalizedFormat(@"Can't create %@ (%s)", rel, strerror(errno));
            break;
        }
        NSString *entryError = nil;
        ok = wq_zip_extract_entry(fd, fileSize, it, out, &written, maxBytes, cancelled, progress, &entryError);
        if (ok) {
            time_t when = wq_from_dos_time(it->time, it->date);
            if (when > 0) {
                struct timeval tv[2] = { { when, 0 }, { when, 0 } };
                futimes(out, tv);
            }
        }
        if (close(out) != 0 && ok) { ok = NO; entryError = @(strerror(errno)); }
        if (!ok) error = entryError ?: WQLocalized(@"Extraction failed");
        else files++;
    }
    close(fd);
    wq_zip_free_items(items, count);
    if (filesOut) *filesOut = files;
    if (skippedOut) *skippedOut = skipped;
    if (!ok && errorText) *errorText = error ?: WQLocalized(@"Extraction failed");
    return ok;
}
