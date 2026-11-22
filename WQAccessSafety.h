// Portable implementation helpers for WQAccess; no privileged access is performed here.
#ifndef WQ_ACCESS_SAFETY_H
#define WQ_ACCESS_SAFETY_H
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static inline BOOL WQSameObject(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

// Only Apple's documented /var alias is allowed. Do not standardize away '..'
// before walking: every actual ancestor must be opened without following links.
static inline NSString *WQCanonicalVarPath(NSString *path)
{
    if ([path isEqualToString:@"/var"] || [path hasPrefix:@"/var/"])
        return [@"/private" stringByAppendingString:path];
    return path;
}

static inline int WQOpenDirectoryNoLinksFlags(NSString *path, int flags)
{
    path = WQCanonicalVarPath(path);
    if (![path hasPrefix:@"/"] || [path rangeOfString:@"\0"].location != NSNotFound) { errno = EINVAL; return -1; }
    // Ancestors need traversal, not enumeration. A file/folder-specific sandbox
    // extension need not grant read-directory rights on all container parents.
    int fd = open("/", O_SEARCH | O_CLOEXEC);
    if (fd < 0) return -1;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) { close(fd); errno = EINVAL; return -1; }
        int next = openat(fd, part.fileSystemRepresentation, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        int err = errno;
        close(fd);
        if (next < 0) { errno = err; return -1; }
        fd = next;
    }
    if (flags == O_SEARCH) return fd;
    int result = openat(fd, ".", flags | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int err = errno;
    close(fd);
    if (result < 0) errno = err;
    return result;
}

static inline int WQOpenDirectoryNoLinks(NSString *path)
{
    return WQOpenDirectoryNoLinksFlags(path, O_RDONLY);
}

static inline BOOL WQSyncDirectory(int fd)
{
    int readable = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (readable < 0) return NO;
    BOOL ok = fsync(readable) == 0;
    int err = errno;
    if (close(readable) != 0 && ok) { ok = NO; err = errno; }
    if (!ok) errno = err;
    return ok;
}

static inline int WQOpenRegularAt(int parent, const char *name, int flags, mode_t mode)
{
    // Never allow truncation before the file type has been verified.
    if (flags & O_TRUNC) { errno = EINVAL; return -1; }
    struct stat entry;
    if (fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(entry.st_mode)) { errno = EINVAL; return -1; }
    } else if (errno != ENOENT || !(flags & O_CREAT)) return -1;
    int fd = openat(parent, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode);
    if (fd < 0) return -1;
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        int err = errno;
        if (!S_ISREG(st.st_mode)) err = EINVAL;
        close(fd); errno = err; return -1;
    }
    return fd;
}

static inline BOOL WQWriteBytes(int fd, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    size_t done = 0;
    while (done < data.length) {
        ssize_t n = write(fd, bytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return NO; }
        done += (size_t)n;
    }
    return fsync(fd) == 0;
}

// A durable intent file precedes the rename. The preserved directory itself is
// never removed. Recovery accepts only our exact symlink or the original inode.
//
// Durability: this runs for every access grant (a Cache Cleaner scan makes
// over a thousand), so only the marker's contents are flushed. That flush is
// what recovery relies on: a marker that can't be read while the preserved
// directory exists must fail closed, so its contents have to reach the disk
// before Caches is renamed. The directory operations themselves need no flush:
// after an app crash or kill they are already in place, and APFS commits
// changes to one directory in order, so a power loss leaves one of the states
// WQCacheSwapRecover handles.
static const char *const WQCacheMarker = ".wq-caches-swap.plist";
static const char *const WQCacheMarkerTemp = ".wq-caches-swap.plist.tmp";
static const char *const WQCacheSaved = ".wq-caches-preserved";

// An invalid marker means Begin never completed the marker write, so no swap
// should have started. It is safe to discard only when Caches is still a real
// directory and no preserved directory exists. Otherwise fail closed.
static inline BOOL WQCacheInvalidMarkerCanBeDiscarded(int library)
{
    struct stat saved, caches;
    if (fstatat(library, WQCacheSaved, &saved, AT_SYMLINK_NOFOLLOW) == 0) { errno = EEXIST; return NO; }
    if (errno != ENOENT) return NO;
    if (fstatat(library, "Caches", &caches, AT_SYMLINK_NOFOLLOW) != 0) return NO;
    if (!S_ISDIR(caches.st_mode)) { errno = EINVAL; return NO; }
    if (unlinkat(library, WQCacheMarker, 0) != 0) return NO;
    return fsync(library) == 0;
}

static inline BOOL WQCacheSwapRecover(int library)
{
    int marker = WQOpenRegularAt(library, WQCacheMarker, O_RDONLY, 0);
    if (marker < 0) {
        if (errno != ENOENT) return NO;
        struct stat saved;
        if (fstatat(library, WQCacheSaved, &saved, AT_SYMLINK_NOFOLLOW) == 0) { errno = EEXIST; return NO; }
        return errno == ENOENT;
    }
    struct stat ms;
    if (fstat(marker, &ms) != 0 || ms.st_size <= 0 || ms.st_size > 65536) {
        close(marker);
        errno = EINVAL;
        return WQCacheInvalidMarkerCanBeDiscarded(library);
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)ms.st_size];
    size_t done = 0;
    while (done < data.length) {
        ssize_t n = read(marker, (uint8_t *)data.mutableBytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            close(marker);
            errno = EIO;
            return WQCacheInvalidMarkerCanBeDiscarded(library);
        }
        done += (size_t)n;
    }
    close(marker);
    id record = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"Format"] isEqual:@1] ||
        ![record[@"Device"] isKindOfClass:NSNumber.class] || ![record[@"Inode"] isKindOfClass:NSNumber.class] ||
        ![record[@"Target"] isKindOfClass:NSString.class]) {
        errno = EINVAL;
        return WQCacheInvalidMarkerCanBeDiscarded(library);
    }
    struct stat original = {0}, current = {0};
    original.st_dev = [record[@"Device"] intValue];
    original.st_ino = [record[@"Inode"] unsignedLongLongValue];
    BOOL savedExists = fstatat(library, WQCacheSaved, &original, AT_SYMLINK_NOFOLLOW) == 0;
    if (!savedExists && errno != ENOENT) return NO;
    struct stat expected = {0};
    expected.st_dev = [record[@"Device"] intValue];
    expected.st_ino = [record[@"Inode"] unsignedLongLongValue];
    if (savedExists && (!S_ISDIR(original.st_mode) || !WQSameObject(&original, &expected))) { errno = EINVAL; return NO; }
    BOOL cachesExists = fstatat(library, "Caches", &current, AT_SYMLINK_NOFOLLOW) == 0;
    if (!cachesExists && errno != ENOENT) return NO;
    if (savedExists) {
        if (cachesExists) {
            char link[65536];
            ssize_t n = S_ISLNK(current.st_mode) ? readlinkat(library, "Caches", link, sizeof(link) - 1) : -1;
            if (n < 0) { errno = EEXIST; return NO; }
            link[n] = 0;
            // The link was created from the target's file-system form, which
            // decomposes characters (é, ü, Hangul): compare in that form, or a
            // precomposed target never matches and the swap stays stuck.
            NSString *recorded = record[@"Target"];
            BOOL ours = [recorded isEqualToString:[NSString stringWithUTF8String:link] ?: @""] ||
                (recorded.length && strcmp(link, recorded.fileSystemRepresentation) == 0);
            if (!ours) { errno = EEXIST; return NO; }
            if (unlinkat(library, "Caches", 0) != 0) return NO;
        }
        if (renameatx_np(library, WQCacheSaved, library, "Caches", RENAME_EXCL) != 0) return NO;
    } else if (!cachesExists || !S_ISDIR(current.st_mode) || !WQSameObject(&current, &expected)) {
        errno = EINVAL; return NO;
    }
    return unlinkat(library, WQCacheMarker, 0) == 0;
}

// Normal startup performs no writes. Only an existing recovery marker or saved
// directory opens the same cross-process lock used by token issuance.
static inline BOOL WQRecoverCacheSwapAtPath(NSString *libraryPath)
{
    int library = WQOpenDirectoryNoLinks(libraryPath);
    if (library < 0) return errno == ENOENT;
    struct stat st;
    BOOL marker = fstatat(library, WQCacheMarker, &st, AT_SYMLINK_NOFOLLOW) == 0;
    int markerError = marker ? 0 : errno;
    BOOL saved = fstatat(library, WQCacheSaved, &st, AT_SYMLINK_NOFOLLOW) == 0;
    int savedError = saved ? 0 : errno;
    if ((!marker && markerError != ENOENT) || (!saved && savedError != ENOENT)) { close(library); return NO; }
    if (!marker && !saved) { close(library); return YES; }
    int lock = WQOpenRegularAt(library, ".wq-caches-lock", O_RDWR | O_CREAT, 0600);
    BOOL ok = lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 && WQCacheSwapRecover(library);
    int error = errno;
    if (lock >= 0) close(lock);
    close(library);
    if (!ok) errno = error;
    return ok;
}

// Manual repair (the startup check's Reset Access Cache): puts Library/Caches
// back to a plain folder whatever state it is in, e.g. a symbolic link left
// by another worse_query app sharing the App Group (issue #42). Nothing is
// deleted: anything in the way is renamed to .wq-caches-reset-<id>. `done`
// gets a short description of the steps, for the Log.
static inline BOOL WQCacheSwapReset(int library, NSMutableArray<NSString *> *done)
{
    if (unlinkat(library, WQCacheMarkerTemp, 0) == 0) [done addObject:@"removed the temporary marker"];
    NSString *(^aside)(void) = ^NSString *{ return [@".wq-caches-reset-" stringByAppendingString:NSUUID.UUID.UUIDString]; };
    struct stat st;
    if (fstatat(library, "Caches", &st, AT_SYMLINK_NOFOLLOW) == 0) {
        if (S_ISLNK(st.st_mode)) {
            if (unlinkat(library, "Caches", 0) != 0) return NO;
            [done addObject:@"removed the Caches link"];
        } else if (!S_ISDIR(st.st_mode)) {
            NSString *name = aside();
            if (renameatx_np(library, "Caches", library, name.fileSystemRepresentation, RENAME_EXCL) != 0) return NO;
            [done addObject:[@"moved a non-folder Caches to " stringByAppendingString:name]];
        }
    } else if (errno != ENOENT) return NO;
    if (fstatat(library, WQCacheSaved, &st, AT_SYMLINK_NOFOLLOW) == 0) {
        BOOL cachesFree = fstatat(library, "Caches", &st, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
        if (cachesFree) {
            if (renameatx_np(library, WQCacheSaved, library, "Caches", RENAME_EXCL) != 0) return NO;
            [done addObject:@"restored the preserved Caches"];
        } else {
            NSString *name = aside();
            if (renameatx_np(library, WQCacheSaved, library, name.fileSystemRepresentation, RENAME_EXCL) != 0) return NO;
            [done addObject:[@"moved the preserved Caches to " stringByAppendingString:name]];
        }
    } else if (errno != ENOENT) return NO;
    if (unlinkat(library, WQCacheMarker, 0) == 0) [done addObject:@"removed the swap marker"];
    else if (errno != ENOENT) return NO;
    if (fstatat(library, "Caches", &st, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno != ENOENT || mkdirat(library, "Caches", 0755) != 0) return NO;
        [done addObject:@"created Caches"];
    } else if (!S_ISDIR(st.st_mode)) { errno = EINVAL; return NO; }
    return fsync(library) == 0;
}

// Explicit repair only (Reset Access Cache). Token requests keep refusing a
// .wq-caches-lock that is not a regular file. Repair moves such an entry (a
// link, folder, pipe...) aside with a no-replace rename to
// .wq-caches-lock-quarantine-<id>; its target and contents are never
// followed, opened or removed. Then a new regular lock is created exclusively.
// Returns the open lock descriptor, or -1 with errno set.
static const char *const WQCacheLock = ".wq-caches-lock";
static inline int WQCacheLockOpenForRepair(int library, NSMutableArray<NSString *> *done)
{
    int lock = WQOpenRegularAt(library, WQCacheLock, O_RDWR | O_CREAT, 0600);
    if (lock >= 0) return lock;
    struct stat st;
    if (fstatat(library, WQCacheLock, &st, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    if (S_ISREG(st.st_mode)) { errno = EBUSY; return -1; }   // a regular lock that still could not be opened
    NSString *name = [@".wq-caches-lock-quarantine-" stringByAppendingString:NSUUID.UUID.UUIDString];
    if (renameatx_np(library, WQCacheLock, library, name.fileSystemRepresentation, RENAME_EXCL) != 0) return -1;
    struct stat moved;
    BOOL same = fstatat(library, name.fileSystemRepresentation, &moved, AT_SYMLINK_NOFOLLOW) == 0 && WQSameObject(&moved, &st);
    NSString *kind = S_ISLNK(st.st_mode) ? @"link" : S_ISDIR(st.st_mode) ? @"folder" : @"special file";
    [done addObject:[NSString stringWithFormat:@"moved a non-regular lock (%@%@) to %@", kind,
                     same ? @"" : @", replaced meanwhile", name]];
    lock = WQOpenRegularAt(library, WQCacheLock, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (lock < 0) return -1;
    if (fsync(library) != 0) { int err = errno; close(lock); errno = err; return -1; }
    [done addObject:@"created a new lock"];
    return lock;
}

static inline BOOL WQCacheSwapBegin(int library, NSString *target)
{
    if (!WQCacheSwapRecover(library)) return NO;
    struct stat st;
    if (fstatat(library, "Caches", &st, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno != ENOENT || mkdirat(library, "Caches", 0755) != 0 ||
            fstatat(library, "Caches", &st, AT_SYMLINK_NOFOLLOW) != 0) return NO;
    }
    if (!S_ISDIR(st.st_mode)) { errno = EINVAL; return NO; }
    NSDictionary *record = @{ @"Format": @1, @"Device": @(st.st_dev), @"Inode": @(st.st_ino), @"Target": target };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) { errno = EINVAL; return NO; }
    // A failed marker write must never leave a partial marker behind: write a
    // temporary sibling, flush it, then atomically rename it into place.
    unlinkat(library, WQCacheMarkerTemp, 0);
    int marker = WQOpenRegularAt(library, WQCacheMarkerTemp, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (marker < 0) return NO;
    BOOL durable = WQWriteBytes(marker, data);   // flushes the marker's contents
    if (close(marker) != 0) durable = NO;
    if (!durable) {
        unlinkat(library, WQCacheMarkerTemp, 0);
        return NO;
    }
    if (renameatx_np(library, WQCacheMarkerTemp, library, WQCacheMarker, RENAME_EXCL) != 0) {
        unlinkat(library, WQCacheMarkerTemp, 0);
        return NO;
    }
    if (renameatx_np(library, "Caches", library, WQCacheSaved, RENAME_EXCL) != 0) return NO;
    return symlinkat(target.fileSystemRepresentation, library, "Caches") == 0;
}

// The newest version named by the AltStore source (source.json): the first
// app's "version", a short string. nil for anything else.
static inline NSString *WQUpdateVersionInSource(NSData *data)
{
    if (!data.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    id apps = [json isKindOfClass:NSDictionary.class] ? json[@"apps"] : nil;
    id app = [apps isKindOfClass:NSArray.class] && [apps count] ? [apps firstObject] : nil;
    id version = [app isKindOfClass:NSDictionary.class] ? app[@"version"] : nil;
    if (![version isKindOfClass:NSString.class] || ![version length] || [version length] > 20) return nil;
    return version;
}

// "0.9.20" is newer than "0.9.9": the parts compare as numbers.
static inline BOOL WQVersionIsNewer(NSString *candidate, NSString *mine)
{
    return candidate.length && [candidate compare:mine options:NSNumericSearch] == NSOrderedDescending;
}

// Up to `samples` indexes spread over `count` items, each once, in order
// (2 of 2 gives 0 and 1; 3 of 10 gives 0, 3 and 6).
static inline NSArray<NSNumber *> *WQSpreadSampleIndexes(NSUInteger count, NSUInteger samples)
{
    NSUInteger n = MIN(count, samples);
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) [indexes addObject:@(i * count / n)];
    return indexes;
}

static inline BOOL WQAbsolutePathGrammar(NSString *path)
{
    if (![path hasPrefix:@"/"] || path.length < 2 || [path rangeOfString:@"\0"].location != NSNotFound) return NO;
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 1; i < parts.count; i++) {
        NSString *part = parts[i];
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    }
    return YES;
}

static inline int WQCreateDirectoriesNoLinksMode(NSString *path, mode_t mode)
{
    path = WQCanonicalVarPath(path);
    if (!WQAbsolutePathGrammar(path)) { errno = EINVAL; return -1; }
    int fd = open("/", O_SEARCH | O_CLOEXEC);
    if (fd < 0) return -1;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        int next = openat(fd, part.fileSystemRepresentation, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (next < 0 && errno == ENOENT) {
            if (mkdirat(fd, part.fileSystemRepresentation, mode) != 0 && errno != EEXIST) { int err = errno; close(fd); errno = err; return -1; }
            if (!WQSyncDirectory(fd)) { int err = errno; close(fd); errno = err; return -1; }
            next = openat(fd, part.fileSystemRepresentation, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        }
        int err = errno;
        close(fd);
        if (next < 0) { errno = err; return -1; }
        fd = next;
    }
    int result = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int err = errno;
    close(fd);
    if (result < 0) errno = err;
    return result;
}

static inline int WQCreateDirectoriesNoLinks(NSString *path)
{
    return WQCreateDirectoriesNoLinksMode(path, 0700);
}

static inline BOOL WQBackupStampValid(NSString *stamp)
{
    if (stamp.length < 15) return NO;
    static NSCache<NSString *, NSNumber *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 1024;
    });
    NSNumber *known = [cache objectForKey:stamp];
    if (known) return known.boolValue;

    // Recognize the historical second/millisecond stamps and the current
    // millisecond-counter format. No arbitrary directory can become a restore.
    NSString *pattern = @"^[0-9]{8}-[0-9]{6}(-[0-9]{3}(-[1-9][0-9]*)?)?$";
    NSRange match = [stamp rangeOfString:pattern options:NSRegularExpressionSearch];
    if (match.location != 0 || match.length != stamp.length) return NO;
    NSArray *parts = [stamp componentsSeparatedByString:@"-"];
    if (parts.count == 4) {
        uint64_t number = 0;
        for (NSUInteger i = 0; i < [parts[3] length]; i++) {
            unsigned digit = [parts[3] characterAtIndex:i] - '0';
            if (number > (UINT64_MAX - digit) / 10) return NO;
            number = number * 10 + digit;
        }
    }
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    fmt.lenient = NO;
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *datePart = [stamp substringToIndex:15];
    NSDate *date = [fmt dateFromString:datePart];
    BOOL valid = date && [[fmt stringFromDate:date] isEqualToString:datePart];
    [cache setObject:@(valid) forKey:stamp];
    return valid;
}

// One numeric field of a valid stamp (digits only, overflow already ruled out
// by WQBackupStampValid).
static inline uint64_t WQBackupStampField(NSString *part)
{
    uint64_t number = 0;
    for (NSUInteger i = 0; i < part.length; i++) number = number * 10 + (uint64_t)([part characterAtIndex:i] - '0');
    return number;
}

// Chronological order of backup unit names: date-time, then milliseconds,
// then the counter as a number ("-10" is newer than "-9"). A legacy stamp
// without milliseconds or counter sorts before one with them at the same
// prefix. Invalid names fall back to text order, after every valid stamp.
// The time is local wall-clock time: a later clock or time-zone rollback can
// still make a newer unit compare older (the format stores no offset).
static inline NSComparisonResult WQBackupStampCompare(NSString *a, NSString *b)
{
    BOOL validA = WQBackupStampValid(a), validB = WQBackupStampValid(b);
    if (!validA || !validB) {
        if (validA != validB) return validA ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"-"], *pb = [b componentsSeparatedByString:@"-"];
    for (NSUInteger i = 0; i < MAX(pa.count, pb.count); i++) {
        if (i >= pa.count) return NSOrderedAscending;
        if (i >= pb.count) return NSOrderedDescending;
        uint64_t x = WQBackupStampField(pa[i]), y = WQBackupStampField(pb[i]);
        if (x != y) return x < y ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}
// iOS 27.2 replaced the container's identifier attribute with
// "com.apple.containermanager.identity", text lines such as
// "v: 01", "schema: 002", "uuid: …", "identifier: group.com.apple.newsd".
// Returns the identifier, or nil when the text has none or several.
static inline NSString *WQIdentityAttributeIdentifier(NSData *value)
{
    if (value.length == 0 || value.length > 4096) return nil;
    NSString *text = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    if (!text) return nil;
    NSString *found = nil;
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![line hasPrefix:@"identifier:"]) continue;
        NSString *ident = [[line substringFromIndex:11] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!ident.length || [ident rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return nil;
        if (found) return nil;
        found = ident;
    }
    return found;
}
// The App Group folder the container manager hands out tokens for. Inside
// LiveContainer, NSFileManager returns a stand-in under LiveContainer's own
// group (<real group>/LiveContainer/Data/AppGroup/<id>); the token is for the
// real group's Library/Caches, so swapping the stand-in never works (#65).
static inline NSString *WQGroupRootForPath(NSString *path)
{
    if (!path.length) return nil;
    NSRange lc = [path rangeOfString:@"/LiveContainer/Data/AppGroup/"];
    if (lc.location == NSNotFound) return path;
    NSString *real = [path substringToIndex:lc.location];
    // Only a container directly under Shared/AppGroup qualifies.
    NSString *parent = WQCanonicalVarPath(real.stringByDeletingLastPathComponent);
    if (![parent isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup"]) return path;
    return real;
}

// The group container root from the path an App Group token covers:
// "/private/var/mobile/Containers/Shared/AppGroup/<one name>/Library/Caches"
// gives ".../AppGroup/<one name>"; anything else gives nil.
static inline NSString *WQGroupRootFromTokenPath(NSString *path)
{
    if (!path.length) return nil;
    NSString *p = WQCanonicalVarPath(path);
    if (![p hasSuffix:@"/Library/Caches"]) return nil;
    NSString *root = [p substringToIndex:p.length - @"/Library/Caches".length];
    if (![root.stringByDeletingLastPathComponent isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup"]) return nil;
    NSString *name = root.lastPathComponent;
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) return nil;
    return root;
}

// Apple patched worse_query in iOS 27.3 beta 2 (build 24C5049d; beta 1 was
// 24C5037i and still works). `build` is kern.osversion, e.g. "24C5049d":
// iOS major - 3 as a number, a letter per minor-release train, then the build
// (betas 5xxx, releases below 1000). Patched: every later train and iOS, and
// in the 24C train every build except betas before 24C5049. NO for an
// unreadable build.
static inline BOOL WQWorseQueryPatchedBuild(NSString *build)
{
    const char *s = build.UTF8String;
    if (!s) return NO;
    int major = 0, number = 0, digits = 0;
    while (*s >= '0' && *s <= '9') { major = major * 10 + (*s++ - '0'); digits++; }
    if (!digits || *s < 'A' || *s > 'Z') return NO;
    char train = *s++;
    digits = 0;
    while (*s >= '0' && *s <= '9' && digits < 6) { number = number * 10 + (*s++ - '0'); digits++; }
    if (!digits) return NO;
    if (major != 24) return major > 24;
    if (train != 'C') return train > 'C';
    return !(number >= 5000 && number < 5049);
}

#endif
