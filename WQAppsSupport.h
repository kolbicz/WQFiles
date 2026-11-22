#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

// Portable, side-effect-free validation shared by the Apps implementation and
// its macOS fixture tests. Filesystem agreement is checked by WQApps.m.
static inline BOOL WQAppsSupportIsBool(id value)
{
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static inline BOOL WQAppsSupportBundleIDValid(NSString *bundleID)
{
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length < 3 || bundleID.length > 255) return NO;
    if ([bundleID hasPrefix:@"."] || [bundleID hasSuffix:@"."] || [bundleID containsString:@".."]) return NO;
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    });
    // No dot required: some older App Store apps have one-word bundle ids
    // (Pinterest's is "pinterest"); the characters above keep it a safe folder name.
    return [bundleID rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static inline BOOL WQAppsSupportIsInteger(id value)
{
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    const char *type = [(NSNumber *)value objCType];
    return strcmp(type, @encode(char)) == 0 || strcmp(type, @encode(unsigned char)) == 0 ||
           strcmp(type, @encode(short)) == 0 || strcmp(type, @encode(unsigned short)) == 0 ||
           strcmp(type, @encode(int)) == 0 || strcmp(type, @encode(unsigned int)) == 0 ||
           strcmp(type, @encode(long)) == 0 || strcmp(type, @encode(unsigned long)) == 0 ||
           strcmp(type, @encode(long long)) == 0 || strcmp(type, @encode(unsigned long long)) == 0;
}

static inline BOOL WQAppsSupportManifestFailure(NSString **errorOut, NSString *message)
{
    if (errorOut) *errorOut = message;
    return NO;
}

static inline BOOL WQAppsSupportManifestFields(NSDictionary *manifest, NSString *bundleID,
                                        NSArray<NSString *> **partsOut, NSString **errorOut)
{
    if (![manifest isKindOfClass:NSDictionary.class]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest is not a dictionary");
    }
    if (!WQAppsSupportIsBool(manifest[@"Complete"]) || ![manifest[@"Complete"] boolValue]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest is not marked complete");
    }
    if (!WQAppsSupportIsInteger(manifest[@"Format"]) || [manifest[@"Format"] unsignedIntegerValue] != 1) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest format is unsupported");
    }
    if (![manifest[@"BundleID"] isKindOfClass:NSString.class] ||
        ![(NSString *)manifest[@"BundleID"] length] ||
        ![(NSString *)manifest[@"BundleID"] isEqualToString:bundleID]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest belongs to another app");
    }
    if (![manifest[@"Created"] isKindOfClass:NSDate.class]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest has no valid creation timestamp");
    }
    id reason = manifest[@"Reason"];
    if (reason && ![reason isKindOfClass:NSString.class]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest reason is malformed");
    }
    id sequence = manifest[@"Sequence"];
    if (sequence && (!WQAppsSupportIsInteger(sequence) || [sequence compare:@1] == NSOrderedAscending)) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest sequence is malformed");
    }
    NSArray *parts = manifest[@"Parts"];
    if (![parts isKindOfClass:NSArray.class]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest parts are malformed");
    }
    NSSet *allowed = [NSSet setWithObjects:@"Documents", @"Library", nil];
    NSMutableSet *seen = [NSMutableSet setWithCapacity:parts.count];
    for (id part in parts) {
        if (![part isKindOfClass:NSString.class] || ![allowed containsObject:part] || [seen containsObject:part]) {
            return WQAppsSupportManifestFailure(errorOut, @"The backup manifest contains an invalid or duplicate part");
        }
        [seen addObject:part];
    }
    NSMutableArray *canonical = [NSMutableArray arrayWithCapacity:seen.count];
    for (NSString *part in @[@"Documents", @"Library"])
        if ([seen containsObject:part]) [canonical addObject:part];
    id hashes = manifest[@"PartHashes"];
    if (hashes) {
        if (![hashes isKindOfClass:NSDictionary.class]) {
            return WQAppsSupportManifestFailure(errorOut, @"The backup manifest hashes are malformed");
        }
        NSDictionary *partHashes = hashes;
        if (![[NSSet setWithArray:partHashes.allKeys] isEqualToSet:seen]) {
            return WQAppsSupportManifestFailure(errorOut, @"The backup manifest hashes do not match its parts");
        }
        for (id key in partHashes) {
            id hash = partHashes[key];
            if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key] ||
                ![hash isKindOfClass:NSString.class] || ![hash length]) {
                return WQAppsSupportManifestFailure(errorOut, @"The backup manifest has an invalid part hash");
            }
        }
    }
    if (partsOut) *partsOut = canonical;
    return YES;
}

static inline void WQAppsSupportHashU64(CC_SHA256_CTX *ctx, uint64_t value)
{
    uint8_t bytes[8];
    for (NSUInteger i = 0; i < 8; i++) bytes[i] = (uint8_t)(value >> (56 - 8 * i));
    CC_SHA256_Update(ctx, bytes, (CC_LONG)sizeof(bytes));
}

static inline void WQAppsSupportHashBlob(CC_SHA256_CTX *ctx, const void *bytes, NSUInteger length)
{
    WQAppsSupportHashU64(ctx, (uint64_t)length);
    if (length) CC_SHA256_Update(ctx, bytes, (CC_LONG)length);
}

// Sockets, FIFOs and device files: wq_copy_contents leaves them out (they
// hold no data), so they are not part of the supported tree either.
static inline BOOL WQAppsSupportIsUnsupportedSpecial(mode_t mode)
{
    return S_ISSOCK(mode) || S_ISFIFO(mode) || S_ISCHR(mode) || S_ISBLK(mode);
}

// Every item below `path`, relative to it, in one fixed order: the tree
// signatures hash items in this order, so it must not depend on the disk's.
static inline NSArray<NSString *> *WQAppsSupportSortedRelativePaths(NSString *path)
{
    NSMutableArray<NSString *> *relativePaths = [NSMutableArray new];
    @autoreleasepool {
        for (NSString *relative in [NSFileManager.defaultManager enumeratorAtPath:path])
            [relativePaths addObject:relative];
    }
    [relativePaths sortUsingSelector:@selector(compare:)];
    return relativePaths;
}

// Deterministic SHA-256 over length-prefixed tree metadata. `includeIdentity`
// adds inode/mtime/ctime for source-stability checks; the shape variant omits
// them and is suitable for comparing a source with its copy. A digest keeps
// memory bounded and makes filenames containing delimiters unambiguous.
// Unsupported special entries (see above) are left out of both variants and
// counted in *omitted, so a source and its copy describe the same tree.
static inline NSString *WQAppsSupportTreeSignatureOmitting(NSString *path, BOOL includeIdentity,
                                                           BOOL *exists, NSUInteger *omitted, NSString **errorOut)
{
    if (omitted) *omitted = 0;
    struct stat rootStat;
    if (lstat(path.fileSystemRepresentation, &rootStat) != 0) {
        if (errno == ENOENT) {
            if (exists) *exists = NO;
            return @"<missing>";
        }
        if (errorOut) *errorOut = [NSString stringWithFormat:@"Cannot inspect %@", path.lastPathComponent];
        return nil;
    }
    if (!S_ISDIR(rootStat.st_mode)) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"%@ is not a directory", path.lastPathComponent];
        return nil;
    }
    NSError *listError = nil;
    if (![NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:&listError]) {
        if (errorOut) *errorOut = listError.localizedDescription ?: [NSString stringWithFormat:@"Cannot read %@", path.lastPathComponent];
        return nil;
    }
    if (exists) *exists = YES;

    NSArray<NSString *> *relativePaths = WQAppsSupportSortedRelativePaths(path);

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    // A pool per item: a restore walks trees of 100k+ files several times in
    // one block. The error leaves the pool in a strong local.
    NSString *failure = nil;
    int failureErrno = 0;
    for (NSString *relative in relativePaths) {
        @autoreleasepool {
            NSString *item = [path stringByAppendingPathComponent:relative];
            struct stat itemStat;
            if (lstat(item.fileSystemRepresentation, &itemStat) != 0) {
                failure = [NSString stringWithFormat:@"Cannot inspect %@", relative];
                break;
            }
            if (WQAppsSupportIsUnsupportedSpecial(itemStat.st_mode)) {
                if (omitted) (*omitted)++;
                continue;
            }
            unsigned type = (unsigned)(itemStat.st_mode & S_IFMT);
            const char *name = relative.UTF8String;
            NSUInteger nameLength = name ? strlen(name) : 0;
            if (!name) {
                failure = [NSString stringWithFormat:@"Cannot encode %@", relative];
                break;
            }
            uint8_t tag = includeIdentity ? 'I' : 'S';
            CC_SHA256_Update(&ctx, &tag, 1);
            WQAppsSupportHashBlob(&ctx, name, nameLength);
            WQAppsSupportHashU64(&ctx, type);
            WQAppsSupportHashU64(&ctx, (uint64_t)(itemStat.st_mode & 07777));
            if (includeIdentity) {
                WQAppsSupportHashU64(&ctx, (uint64_t)itemStat.st_ino);
                WQAppsSupportHashU64(&ctx, (uint64_t)itemStat.st_size);
                WQAppsSupportHashU64(&ctx, (uint64_t)itemStat.st_mtimespec.tv_sec);
                WQAppsSupportHashU64(&ctx, (uint64_t)itemStat.st_mtimespec.tv_nsec);
                WQAppsSupportHashU64(&ctx, (uint64_t)itemStat.st_ctimespec.tv_sec);
                WQAppsSupportHashU64(&ctx, (uint64_t)itemStat.st_ctimespec.tv_nsec);
            } else if (type == S_IFREG) {
                WQAppsSupportHashU64(&ctx, (uint64_t)itemStat.st_size);
            } else if (type == S_IFLNK) {
                char target[PATH_MAX];
                ssize_t length = readlink(item.fileSystemRepresentation, target, sizeof(target) - 1);
                if (length < 0 || length >= (ssize_t)sizeof(target) - 1) {
                    failure = [NSString stringWithFormat:@"Cannot inspect link %@", relative];
                    break;
                }
                WQAppsSupportHashBlob(&ctx, target, (NSUInteger)length);
            }
        }
        if (failure) break;
    }
    if (failure) {
        if (errorOut) *errorOut = failure;
        if (failureErrno) errno = failureErrno;
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static inline NSString *WQAppsSupportTreeSignature(NSString *path, BOOL includeIdentity,
                                                   BOOL *exists, NSString **errorOut)
{
    return WQAppsSupportTreeSignatureOmitting(path, includeIdentity, exists, NULL, errorOut);
}

// Content-level digest for backup verification: metadata plus every regular
// file's bytes. Reading is streamed; a file that changes while it is hashed
// fails with an error rather than producing a torn digest.
static inline NSString *WQAppsSupportTreeContentSignature(NSString *path, BOOL *exists, NSString **errorOut)
{
    struct stat rootStat;
    if (lstat(path.fileSystemRepresentation, &rootStat) != 0) {
        if (errno == ENOENT) {
            if (exists) *exists = NO;
            return @"<missing>";
        }
        if (errorOut) *errorOut = [NSString stringWithFormat:@"Cannot inspect %@", path.lastPathComponent];
        return nil;
    }
    if (!S_ISDIR(rootStat.st_mode)) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"%@ is not a directory", path.lastPathComponent];
        return nil;
    }
    NSError *listError = nil;
    if (![NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:&listError]) {
        if (errorOut) *errorOut = listError.localizedDescription ?: [NSString stringWithFormat:@"Cannot read %@", path.lastPathComponent];
        return nil;
    }
    if (exists) *exists = YES;

    NSArray<NSString *> *relativePaths = WQAppsSupportSortedRelativePaths(path);

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buffer[65536];
    // A pool per item: a restore walks trees of 100k+ files several times in
    // one block. The error leaves the pool in a strong local.
    NSString *failure = nil;
    int failureErrno = 0;
    for (NSString *relative in relativePaths) {
        @autoreleasepool {
            NSString *item = [path stringByAppendingPathComponent:relative];
            struct stat itemStat;
            if (lstat(item.fileSystemRepresentation, &itemStat) != 0) {
                failure = [NSString stringWithFormat:@"Cannot inspect %@", relative];
                break;
            }
            const char *name = relative.UTF8String;
            if (!name) {
                failure = [NSString stringWithFormat:@"Cannot encode %@", relative];
                break;
            }
            uint8_t tag = 'C';
            CC_SHA256_Update(&ctx, &tag, 1);
            WQAppsSupportHashBlob(&ctx, name, strlen(name));
            WQAppsSupportHashU64(&ctx, (uint64_t)(itemStat.st_mode & S_IFMT));
            WQAppsSupportHashU64(&ctx, (uint64_t)(itemStat.st_mode & 07777));
            WQAppsSupportHashU64(&ctx, (uint64_t)itemStat.st_size);
            if (S_ISREG(itemStat.st_mode)) {
                int fd = open(item.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
                if (fd < 0) {
                    failure = [NSString stringWithFormat:@"Cannot read %@", relative];
                    break;
                }
                struct stat after;
                BOOL ok = fstat(fd, &after) == 0 && S_ISREG(after.st_mode) &&
                    after.st_dev == itemStat.st_dev && after.st_ino == itemStat.st_ino;
                for (;;) {
                    if (!ok) break;
                    ssize_t n = read(fd, buffer, sizeof(buffer));
                    if (n < 0) {
                        if (errno == EINTR) continue;
                        ok = NO;
                        break;
                    }
                    if (n == 0) break;
                    CC_SHA256_Update(&ctx, buffer, (CC_LONG)n);
                }
                struct stat finalStat;
                if (ok && (fstat(fd, &finalStat) != 0 ||
                           finalStat.st_size != itemStat.st_size ||
                           finalStat.st_mtimespec.tv_sec != itemStat.st_mtimespec.tv_sec ||
                           finalStat.st_mtimespec.tv_nsec != itemStat.st_mtimespec.tv_nsec ||
                           finalStat.st_ctimespec.tv_sec != itemStat.st_ctimespec.tv_sec ||
                           finalStat.st_ctimespec.tv_nsec != itemStat.st_ctimespec.tv_nsec)) ok = NO;
                int err = errno;
                close(fd);
                if (!ok) {
                    failure = [NSString stringWithFormat:@"%@ changed while it was read", relative];
                    failureErrno = err;
                    break;
                }
            } else if (S_ISLNK(itemStat.st_mode)) {
                char target[PATH_MAX];
                ssize_t length = readlink(item.fileSystemRepresentation, target, sizeof(target) - 1);
                if (length < 0 || length >= (ssize_t)sizeof(target) - 1) {
                    failure = [NSString stringWithFormat:@"Cannot inspect link %@", relative];
                    break;
                }
                WQAppsSupportHashBlob(&ctx, target, (NSUInteger)length);
            }
        }
        if (failure) break;
    }
    if (failure) {
        if (errorOut) *errorOut = failure;
        if (failureErrno) errno = failureErrno;
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static inline NSUInteger WQAppsSupportBackupSequence(NSString *name)
{
    if (![name isKindOfClass:NSString.class] || !name.length) return 0;
    if ([name hasSuffix:@")"]) {
        NSRange open = [name rangeOfString:@" (" options:NSBackwardsSearch];
        if (open.location != NSNotFound && open.location + 3 < name.length) {
            NSString *digits = [name substringWithRange:NSMakeRange(open.location + 2, name.length - open.location - 3)];
            NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
            if (digits.length && [digits rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
                NSUInteger sequence = digits.integerValue;
                if (sequence > 0) return sequence;
            }
        }
    }
    return 1;
}

static inline NSComparisonResult WQAppsSupportCompareBackupMetadata(NSDate *dateA, NSUInteger sequenceA, NSString *nameA,
                                                              NSDate *dateB, NSUInteger sequenceB, NSString *nameB)
{
    NSComparisonResult dateOrder = [dateA compare:dateB];
    if (dateOrder != NSOrderedSame) return dateOrder;
    if (sequenceA < sequenceB) return NSOrderedAscending;
    if (sequenceA > sequenceB) return NSOrderedDescending;
    return [nameA compare:nameB options:NSNumericSearch];
}

typedef NS_ENUM(NSInteger, WQAppsSupportJournalState) {
    WQAppsSupportJournalMissing,
    WQAppsSupportJournalActive,
    WQAppsSupportJournalCommitted,
    WQAppsSupportJournalUnknown,
};

static inline WQAppsSupportJournalState WQAppsSupportJournalStateForDictionary(NSDictionary *journal)
{
    if (![journal isKindOfClass:NSDictionary.class]) return WQAppsSupportJournalMissing;
    id state = journal[@"State"];
    if (![state isKindOfClass:NSString.class]) return WQAppsSupportJournalUnknown;
    if ([state isEqualToString:@"Active"]) return WQAppsSupportJournalActive;
    if ([state isEqualToString:@"Committed"]) return WQAppsSupportJournalCommitted;
    return WQAppsSupportJournalUnknown;
}

// A new restore may start only when no recovery is pending. A committed
// journal is safe to clean up and replace; an Active or unknown journal must
// be recovered or explicitly discarded first.
static inline BOOL WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalState state, NSString **error)
{
    if (state == WQAppsSupportJournalActive) {
        if (error) *error = @"An interrupted restore is still active. Recover or discard it before starting another restore";
        return NO;
    }
    if (state == WQAppsSupportJournalUnknown) {
        if (error) *error = @"The existing restore recovery journal has an unknown state";
        return NO;
    }
    return YES;
}

// What launch recovery does with an Active journal before trying a rollback.
// A journal that can never be recovered must not stay: while it exists every
// restore of every app is refused.
typedef NS_ENUM(NSInteger, WQAppsSupportJournalFate) {
    WQAppsSupportJournalRecover = 0,        // roll back from the safety backup
    WQAppsSupportJournalSetAside,           // fields unusable: rename it, keep the file
    WQAppsSupportJournalCloseNoContainer,   // the app was removed or reinstalled
    WQAppsSupportJournalCloseNoSafety,      // the safety backup was deleted
};

static inline WQAppsSupportJournalFate WQAppsSupportJournalFateFor(BOOL fieldsValid, BOOL containerGone, BOOL safetyMissing)
{
    if (!fieldsValid) return WQAppsSupportJournalSetAside;
    if (containerGone) return WQAppsSupportJournalCloseNoContainer;
    if (safetyMissing) return WQAppsSupportJournalCloseNoSafety;
    return WQAppsSupportJournalRecover;
}

// Whether restoring a backup empties a part the backup doesn't hold. WQ Files'
// own backups record every part the app had, so a missing part means "the app
// had none". An imported ZIP or .adbk only says "not included".
static inline BOOL WQAppsSupportRestorePurgesMissingPart(NSString *reason)
{
    return ![reason isKindOfClass:NSString.class] || ![reason isEqualToString:@"Imported"];
}

#pragma mark - Import as Backup

// Apps Manager backups (.adbk, a ZIP; issue #19): Binfo.plist (id,
// displayName, date) next to the app's data folder, which is named after the
// bundle ID, plus ___groups___ (its App Group folders), __private_info
// (keychain items, encrypted by Apps Manager) and __pasteboards__.
static NSString *const kWQADBKInfo = @"Binfo.plist";
static NSString *const kWQADBKGroups = @"___groups___";
static NSString *const kWQADBKKeychain = @"__private_info";

static inline BOOL WQAppsSupportIsRegularFile(NSString *path)
{
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode);
}

static inline BOOL WQAppsSupportIsDirectory(NSString *path)
{
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
}

// The `id` in dir's Binfo.plist: a bundle ID, the invalid value as text in
// *invalid, or nil when dir holds no Apps Manager backup.
static inline NSString *WQAppsSupportADBKBundle(NSString *dir, NSString **invalid)
{
    if (invalid) *invalid = nil;
    NSString *info = [dir stringByAppendingPathComponent:kWQADBKInfo];
    if (!WQAppsSupportIsRegularFile(info)) return nil;
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:info];
    id value = [plist isKindOfClass:NSDictionary.class] ? plist[@"id"] : nil;
    if (!value) return nil;
    if (WQAppsSupportBundleIDValid(value)) return value;
    if (invalid) *invalid = [value isKindOfClass:NSString.class] ? value : [value description];
    return nil;
}

// The folder holding the Apps Manager backup that `root` came from (root's
// parent, inside the picked `top`), or nil for any other import.
static inline NSString *WQAppsSupportADBKDir(NSString *top, NSString *root)
{
    if (![root hasPrefix:[top stringByAppendingString:@"/"]]) return nil;
    NSString *parent = root.stringByDeletingLastPathComponent;
    return WQAppsSupportIsRegularFile([parent stringByAppendingPathComponent:kWQADBKInfo]) ? parent : nil;
}

// The App Group folders an Apps Manager backup holds; an import leaves them
// out (a WQ Files backup is the app's own data folder).
static inline NSArray<NSString *> *WQAppsSupportADBKGroups(NSString *adbkDir)
{
    NSMutableArray *groups = [NSMutableArray new];
    NSString *dir = [adbkDir stringByAppendingPathComponent:kWQADBKGroups];
    for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name hasPrefix:@"."] && WQAppsSupportIsDirectory([dir stringByAppendingPathComponent:name])) [groups addObject:name];
    }
    return groups;
}

// Whether an Apps Manager backup holds keychain items (encrypted, so they
// can't be imported).
static inline BOOL WQAppsSupportADBKHasKeychain(NSString *adbkDir)
{
    return WQAppsSupportIsRegularFile([adbkDir stringByAppendingPathComponent:kWQADBKKeychain]);
}

// The folder inside an import that holds Documents and/or Library: the
// picked folder itself, or the shallowest one below it (a shared backup ZIP
// or another tool's export usually wraps them in a folder). Several at the
// same depth are ambiguous. In an Apps Manager backup it is the folder its
// Binfo.plist names, never one of its App Group folders.
static inline NSString *WQAppsSupportImportRoot(NSString *dir, NSString **error)
{
    NSString *adbkBundle = WQAppsSupportADBKBundle(dir, NULL);
    if (adbkBundle) {
        NSString *data = [dir stringByAppendingPathComponent:adbkBundle];
        if (WQAppsSupportIsDirectory([data stringByAppendingPathComponent:@"Documents"]) ||
            WQAppsSupportIsDirectory([data stringByAppendingPathComponent:@"Library"])) return data;
        if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"This Apps Manager backup has no Documents or Library folder for %@.", nil), adbkBundle];
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *level = @[dir];
    for (int depth = 0; depth <= 3 && level.count; depth++) {
        NSMutableArray<NSString *> *found = [NSMutableArray new], *next = [NSMutableArray new];
        for (NSString *candidate in level) {
            BOOL has = NO;
            for (NSString *part in @[@"Documents", @"Library"]) {
                struct stat st;
                if (lstat([candidate stringByAppendingPathComponent:part].fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode))
                    has = YES;
            }
            if (has) { [found addObject:candidate]; continue; }
            for (NSString *name in [[fm contentsOfDirectoryAtPath:candidate error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
                if ([name hasPrefix:@"."] || [name isEqualToString:@"__MACOSX"]) continue;
                NSString *child = [candidate stringByAppendingPathComponent:name];
                struct stat st;
                if (lstat(child.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) [next addObject:child];
            }
        }
        if (found.count == 1) return found.firstObject;
        if (found.count > 1) {
            NSMutableArray *names = [NSMutableArray new];
            for (NSString *f in found) [names addObject:[f substringFromIndex:MIN(dir.length + 1, f.length)]];
            if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"It holds data of several apps (%@). Pick one of these folders instead.", nil),
                                 [names componentsJoinedByString:@", "]];
            return nil;
        }
        level = next;
    }
    if (error) *error = NSLocalizedString(@"No Documents or Library folder was found in it.", nil);
    return nil;
}

// Every bundle ID the imported data says it belongs to: a WQ Files backup's
// checklist and a container's metadata file, in that order, without
// duplicates. A declaration that is present but not a valid bundle ID is
// returned in *invalid (as text) instead; callers refuse such data.
static inline NSArray<NSString *> *WQAppsSupportImportDeclaredBundles(NSString *root, NSString **invalid)
{
    if (invalid) *invalid = nil;
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    NSArray *sources = @[@[@".wqbackup.plist", @"BundleID"],
                         @[@".com.apple.mobile_container_manager.metadata.plist", @"MCMMetadataIdentifier"]];
    for (NSArray *source in sources) {
        NSString *file = [root stringByAppendingPathComponent:source[0]];
        struct stat st;
        if (lstat(file.fileSystemRepresentation, &st) != 0) continue;   // not declared
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:file];
        id value = [plist isKindOfClass:NSDictionary.class] ? plist[source[1]] : nil;
        if (!value) continue;   // a file without this key declares nothing
        if (!WQAppsSupportBundleIDValid(value)) {
            if (invalid && !*invalid) *invalid = [value isKindOfClass:NSString.class] ? value : [value description];
            continue;
        }
        if (![ids containsObject:value]) [ids addObject:value];
    }
    return ids;
}

// As WQAppsSupportImportDeclaredBundles, plus the `id` of the Apps Manager
// backup (Binfo.plist) that `root` came from inside the picked `top`.
static inline NSArray<NSString *> *WQAppsSupportImportDeclaredBundlesIn(NSString *top, NSString *root, NSString **invalid)
{
    NSMutableArray<NSString *> *ids = [WQAppsSupportImportDeclaredBundles(root, invalid) mutableCopy];
    NSString *adbkDir = WQAppsSupportADBKDir(top, root);
    if (!adbkDir) return ids;
    NSString *adbkInvalid = nil;
    NSString *adbk = WQAppsSupportADBKBundle(adbkDir, &adbkInvalid);
    if (adbkInvalid && invalid && !*invalid) *invalid = adbkInvalid;
    if (adbk && ![ids containsObject:adbk]) [ids addObject:adbk];
    return ids;
}

// The first declared bundle ID, if any (see WQAppsSupportImportDeclaredBundles).
static inline NSString *WQAppsSupportImportDeclaredBundle(NSString *root)
{
    return WQAppsSupportImportDeclaredBundles(root, NULL).firstObject;
}

// Items next to Documents/Library that an import leaves out.
static inline NSArray<NSString *> *WQAppsSupportImportIgnored(NSString *root)
{
    NSMutableArray *ignored = [NSMutableArray new];
    for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([@[@"Documents", @"Library", @".wqbackup.plist", @".com.apple.mobile_container_manager.metadata.plist", @".DS_Store"] containsObject:name]) continue;
        [ignored addObject:name];
    }
    return ignored;
}
