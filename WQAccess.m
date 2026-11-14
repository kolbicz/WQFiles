//
//  WQAccess.m
//  WQ Files
//
//  Sandbox extension technique: worse_query by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//
//  Notes from testing on 27.0.1:
//  - An extension covers the folder it was issued for. A container root
//    extension was not enough to open a file two levels down for writing, so
//    writes always ask for the file's own folder first.
//  - /var/containers/Shared/SystemGroup itself gets no token; its children do.
//

#import "WQAccess.h"
#import "WQCore.h"
#import "WQAccessSafety.h"
#import "WQLocalization.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <stdatomic.h>
#import <sys/clonefile.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/xattr.h>
#import <unistd.h>
#import <xpc/xpc.h>

@implementation WQScanCancellation {
    _Atomic BOOL _cancelled;
}

- (BOOL)isCancelled
{
    return atomic_load_explicit(&_cancelled, memory_order_relaxed);
}

- (void)cancel
{
    atomic_store_explicit(&_cancelled, YES, memory_order_relaxed);
}

@end

#pragma mark - Log

static NSMutableString *gLog;
static NSLock *gLogLock;

void wq_log(NSString *format, ...)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLog = [NSMutableString new]; gLogLock = [NSLock new]; });
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[wqfiles] %@", line);
    [gLogLock lock];
    [gLog appendFormat:@"%@\n", line];
    [gLogLock unlock];
}

NSString *wq_log_text(void)
{
    [gLogLock lock];
    NSString *text = [gLog copy] ?: @"";
    [gLogLock unlock];
    return text;
}

static NSString *wq_errno(int err) { return [NSString stringWithFormat:@"%s (errno %d)", strerror(err), err]; }

#pragma mark - App group

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

NSString *wq_app_group(void)
{
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *groups = nil;
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (task) {
            CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
            if (value) groups = (__bridge_transfer NSArray *)value;
            CFRelease(task);
        }
        for (id candidate in groups) {
            if (![candidate isKindOfClass:NSString.class]) continue;
            NSURL *root = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:candidate];
            if (root) {
                group = candidate;
                if (!WQRecoverCacheSwapAtPath([root.path stringByAppendingPathComponent:@"Library"]))
                    wq_log(@"App-group cache recovery requires attention; preserved contents retained: %@ (%@)", root.path, wq_errno(errno));
                break;
            }
        }
        wq_log(@"App group: %@ (entitled: %@)", group ?: @"NONE",
               groups.count ? [groups componentsJoinedByString:@", "] : @"none");
    });
    return group;
}

#pragma mark - worse_query

typedef void *(*cq_create_fn)(void);
typedef void (*cq_set_u64_fn)(void *, uint64_t);
typedef void (*cq_set_ids_fn)(void *, xpc_object_t);
typedef void *(*cq_result_fn)(void *);
typedef void (*cq_free_fn)(void *);
typedef char *(*cq_token_fn)(void *);
typedef int64_t (*ext_consume_fn)(const char *);
// The callback returns true to continue; a void block leaves that value undefined.
typedef void (*cq_iterate_fn)(void *, bool (^)(void *));
typedef const char *(*co_get_path_fn)(void *);
typedef const char *(*co_get_id_fn)(void *);

static void wq_release_handle(int64_t handle);

static int64_t wq_query_token(NSString *group, BOOL altFlags)
{
    static void *mgr;
    static cq_create_fn create;
    static cq_set_u64_fn setClass, setFlags, setPart;
    static cq_set_ids_fn setGroups;
    static cq_result_fn single;
    static cq_free_fn freeQuery;
    static cq_token_fn copyToken;
    static ext_consume_fn consume;
    if (!mgr) {
        mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (!mgr) return -2;
        create = (cq_create_fn)dlsym(mgr, "container_query_create");
        setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
        setGroups = (cq_set_ids_fn)dlsym(mgr, "container_query_set_group_identifiers");
        setFlags = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_flags");
        setPart = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_part");
        single = (cq_result_fn)dlsym(mgr, "container_query_get_single_result");
        freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
        copyToken = (cq_token_fn)dlsym(mgr, "container_copy_sandbox_token");
        consume = (ext_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    }
    if (!create || !setClass || !setGroups || !setFlags || !setPart || !single || !freeQuery || !copyToken || !consume) return -2;

    void *query = create();
    if (!query) return -3;
    char *token = NULL;
    @try {
        setClass(query, 7);  // app group container
        xpc_object_t ident = xpc_string_create(group.UTF8String);
        setGroups(query, ident);
        setPart(query, 3);   // Library/Caches
        setFlags(query, altFlags ? 0x0000000800000000ULL : 0x0000008000000000ULL);
        void *result = single(query);
        token = result ? copyToken(result) : NULL;
        int64_t handle = token ? consume(token) : (result ? -6 : -5);
        return token && handle < 0 ? -7 : handle;
    } @finally {
        if (token) free(token);
        freeQuery(query);
    }
}

BOOL wq_system_areas_reachable(void)
{
    // worse_query reaches System Data, the system groups and the App Groups
    // parent only on iOS 27; on iOS 26 it reaches the individual app,
    // extension, daemon and app group containers.
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

// What Library looks like when the Caches swap can't be undone, for the Log:
// the swap marker, the preserved folder and what Caches is now.
static NSString *wq_cache_state(int library)
{
    struct stat st;
    NSString *marker = fstatat(library, WQCacheMarker, &st, AT_SYMLINK_NOFOLLOW) == 0 ? @"present" : @"none";
    NSString *saved = fstatat(library, WQCacheSaved, &st, AT_SYMLINK_NOFOLLOW) == 0
        ? (S_ISDIR(st.st_mode) ? @"folder" : @"not a folder") : @"none";
    NSString *caches;
    if (fstatat(library, "Caches", &st, AT_SYMLINK_NOFOLLOW) != 0) {
        caches = errno == ENOENT ? @"missing" : wq_errno(errno);
    } else if (S_ISLNK(st.st_mode)) {
        char link[1024];
        ssize_t n = readlinkat(library, "Caches", link, sizeof(link) - 1);
        link[n > 0 ? n : 0] = 0;
        caches = [@"link to " stringByAppendingString:@(link) ?: @"?"];
    } else {
        caches = S_ISDIR(st.st_mode) ? @"folder" : @"not a folder";
    }
    return [NSString stringWithFormat:@"swap marker %@, preserved Caches %@, Caches %@", marker, saved, caches];
}

// Logged in full the first time and whenever the reason or state changes;
// repeats (every token request fails the same way) are only counted.
static void wq_log_recovery_failure(NSString *libraryPath, int error, NSString *state)
{
    static NSString *last;
    static NSUInteger repeats;
    NSString *line = [NSString stringWithFormat:@"%@ (%@; %@)", libraryPath, wq_errno(error), state];
    @synchronized (NSFileManager.class) {
        if ([line isEqualToString:last]) {
            repeats++;
            if (repeats % 25 == 0) wq_log(@"token cache recovery still failing (%lu more times)", (unsigned long)repeats);
            return;
        }
        last = line;
        repeats = 0;
    }
    wq_log(@"token cache recovery failed: %@; preserved contents retained. Every folder outside WQ Files is refused until this is repaired: Settings → Reset Access Cache.", line);
}

static int64_t wq_query(NSString *target, BOOL altFlags)
{
    NSString *group = wq_app_group();
    if (!group) return -1;
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return -1;
    NSString *libraryPath = [root.path stringByAppendingPathComponent:@"Library"];
    if (![files createDirectoryAtPath:libraryPath withIntermediateDirectories:YES attributes:nil error:nil]) return -4;
    int library = WQOpenDirectoryNoLinks(libraryPath);
    if (library < 0) return -4;
    int lock = WQOpenRegularAt(library, ".wq-caches-lock", O_RDWR | O_CREAT, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        if (lock >= 0) close(lock);
        close(library);
        return -4;
    }
    int64_t handle = -4;
    @try {
        // Keep the exact Caches swap point required by worse_query, but preserve
        // its original inode and nested contents. Next acquisition recovers an
        // interrupted swap from the durable marker, before doing another query.
        if (WQCacheSwapBegin(library, target)) handle = wq_query_token(group, altFlags);
    } @catch (NSException *exception) {
        wq_log(@"token query exception: %@", exception.reason);
        handle = -9;
    } @finally {
        if (!WQCacheSwapRecover(library)) {
            int error = errno;
            wq_log_recovery_failure(libraryPath, error, wq_cache_state(library));
            if (handle >= 0) wq_release_handle(handle);
            handle = -8;
        }
        close(lock);
        close(library);
    }
    return handle;
}

BOOL wq_reset_access_cache(NSString **errorText)
{
    NSString *group = wq_app_group();
    NSURL *root = group ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
    if (!root) { if (errorText) *errorText = WQLocalized(@"The App Group is missing."); return NO; }
    NSString *libraryPath = [root.path stringByAppendingPathComponent:@"Library"];
    [NSFileManager.defaultManager createDirectoryAtPath:libraryPath withIntermediateDirectories:YES attributes:nil error:nil];
    int library = WQOpenDirectoryNoLinks(libraryPath);
    if (library < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    NSMutableArray<NSString *> *done = [NSMutableArray new];
    // Unlike token requests, repair moves a non-regular lock aside first.
    int lock = WQCacheLockOpenForRepair(library, done);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        int err = errno;
        if (lock >= 0) close(lock);
        close(library);
        wq_log(@"access cache reset in %@: lock unavailable (%@)%@", libraryPath, wq_errno(err),
               done.count ? [@"; " stringByAppendingString:[done componentsJoinedByString:@", "]] : @"");
        if (errorText) *errorText = wq_errno(err);
        return NO;
    }
    BOOL ok = WQCacheSwapReset(library, done);
    int err = errno;
    close(lock);
    close(library);
    wq_log(@"access cache reset in %@: %@%@", libraryPath, done.count ? [done componentsJoinedByString:@", "] : @"nothing to repair",
           ok ? @"" : [@"; FAILED: " stringByAppendingString:wq_errno(err)]);
    if (!ok && errorText) *errorText = wq_errno(err);
    return ok;
}

static NSMutableDictionary<NSString *, NSNumber *> *gGrants;
static NSMutableArray<NSString *> *gGrantOrder;   // oldest first
// The kernel limits how many sandbox extensions a process may hold. Keep a
// bounded working set and release the oldest; released paths are simply
// granted again when they are next used.
static const NSUInteger kMaxGrants = 192;

static void wq_release_handle(int64_t handle)
{
    typedef int (*ext_release_fn)(int64_t);
    static ext_release_fn release;
    if (!release) release = (ext_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release && handle >= 0) release(handle);
}
static NSRecursiveLock *gGrantLock;

static NSString *wq_norm(NSString *path)
{
    NSString *p = path.stringByStandardizingPath;
    if ([p hasPrefix:@"/var/"]) p = [@"/private" stringByAppendingString:p];
    return p;
}

// Whether the target can now be opened. Only a sandbox denial (EPERM) counts
// as "the token didn't help": EACCES is ordinary file permissions (root-owned
// system containers), which a token never changes.
static BOOL wq_grant_opens(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) { close(fd); return YES; }
    return errno != EPERM;
}

BOOL wq_grant(NSString *path)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gGrants = [NSMutableDictionary new];
        gGrantOrder = [NSMutableArray new];
        gGrantLock = [NSRecursiveLock new];
    });
    NSString *key = wq_norm(path);
    [gGrantLock lock];
    NSNumber *known = gGrants[key];
    if (known) {
        [gGrantOrder removeObject:key];   // most recently used goes last
        [gGrantOrder addObject:key];
        [gGrantLock unlock];
        return YES;
    }
    while (gGrantOrder.count >= kMaxGrants) {
        NSString *oldest = gGrantOrder.firstObject;
        wq_release_handle(gGrants[oldest].longLongValue);
        [gGrants removeObjectForKey:oldest];
        [gGrantOrder removeObjectAtIndex:0];
    }
    struct stat st;
    if (lstat(key.fileSystemRepresentation, &st) != 0) {
        [gGrantLock unlock];
        return NO;  // worse_query needs an existing target
    }
    // iOS 26 needs the alternative query flags; try the likely ones first so
    // a grant costs one query, and the other set only when that fails. A
    // token can also be issued and consumed yet not open the target (seen on
    // 27.0.1 with an AltStore app group): check, and then try the other flags.
    // The set that works is remembered for the rest of the run.
    static int preferAlt = -1;
    BOOL altFirst = preferAlt >= 0 ? (BOOL)preferAlt : !wq_system_areas_reachable();
    int64_t handle = wq_query(key, altFirst);
    BOOL usedAlt = altFirst;
    if (handle >= 0 && !wq_grant_opens(key)) {
        static BOOL logged;
        if (!logged) {
            logged = YES;
            wq_log(@"grant: the token for %@ doesn't open it (%@ query flags); trying the other flags", key,
                   altFirst ? @"alternative" : @"standard");
        }
        wq_release_handle(handle);
        handle = -8;
    }
    if (handle < 0 && handle != -1 && handle != -2) {
        int64_t alt = wq_query(key, !altFirst);
        if (alt >= 0 && !wq_grant_opens(key)) {
            wq_release_handle(alt);
            alt = -8;
        }
        if (alt >= 0) {
            handle = alt;
            usedAlt = !altFirst;
        }
    }
    // Decided once, by the first grant that works: some targets refuse to
    // open for their own reasons, and a per-target fallback already covers
    // the rest, so flipping the preference back and forth only costs queries.
    if (handle >= 0 && preferAlt < 0) {
        preferAlt = usedAlt;
        if (usedAlt != !wq_system_areas_reachable())
            wq_log(@"grant: the %@ query flags work on this device", usedAlt ? @"alternative" : @"standard");
    }
    if (handle >= 0) {  // failures are retried next time
        gGrants[key] = @(handle);
        [gGrantOrder addObject:key];
    }
    [gGrantLock unlock];
    return handle >= 0;
}

static BOOL wq_is_denied(int err) { return err == EPERM || err == EACCES; }

#pragma mark - Backups

#ifdef WQ_ACCESS_TESTING
static NSString *wq_test_backup_root;
static NSString *wq_test_app_backup_root;
static int64_t wq_test_volume_limit = -1;
static void (^wq_test_mutation_hook)(NSString *stage, NSString *path);
static void (^wq_test_tree_hook)(NSString *stage, NSString *path);
static void (^wq_test_stream_hook)(NSString *stage, NSString *path);
static NSDictionary<NSString *, NSArray<NSString *> *> *(^wq_test_shared_scan_runner)(BOOL inodeOnly);
#define WQ_TREE_HOOK(stage, path) do { if (wq_test_tree_hook) wq_test_tree_hook(stage, path); } while (0)
#define WQ_MUTATION_HOOK(stage, path) do { if (wq_test_mutation_hook) wq_test_mutation_hook(stage, path); } while (0)
#define WQ_STREAM_HOOK(stage, path) do { if (wq_test_stream_hook) wq_test_stream_hook(stage, path); } while (0)
#else
#define WQ_MUTATION_HOOK(stage, path) do {} while (0)
#define WQ_TREE_HOOK(stage, path) do {} while (0)
#define WQ_STREAM_HOOK(stage, path) do {} while (0)
#endif

NSString *wq_backup_root(void)
{
#ifdef WQ_ACCESS_TESTING
    if (wq_test_backup_root) return wq_test_backup_root;
#endif
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Backups"];
}

NSString *wq_app_backup_root(void)
{
#ifdef WQ_ACCESS_TESTING
    if (wq_test_app_backup_root) return wq_test_app_backup_root;
#endif
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"AppBackups"];
}

BOOL wq_is_backup_storage_path(NSString *path)
{
    NSString *original = WQCanonicalVarPath(path);
    NSMutableArray<NSString *> *roots = [NSMutableArray new];
    NSString *fileRoot = WQCanonicalVarPath(wq_backup_root());
    NSString *appRoot = WQCanonicalVarPath(wq_app_backup_root());
    if (fileRoot.length) [roots addObject:fileRoot];
    if (appRoot.length) [roots addObject:appRoot];
    for (NSString *root in roots) {
        if ([original isEqualToString:root] || [original hasPrefix:[root stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static int wq_open(NSString *path, int flags, mode_t mode);
static int wq_open_directory_flags(NSString *path, int flags);

// Copies everything from fd `in` to fd `out` in chunks; fsyncs `out`.
static BOOL wq_stream(int in, int out, NSString **errorText)
{
    static const size_t kChunk = 1 << 20;
    uint8_t *buf = malloc(kChunk);
    if (!buf) { if (errorText) *errorText = WQLocalized(@"Out of memory"); return NO; }
    BOOL ok = YES;
    for (;;) {
        ssize_t n = read(in, buf, kChunk);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = NO; if (errorText) *errorText = wq_errno(errno); break; }
        if (n == 0) break;
        for (ssize_t done = 0; done < n; ) {
            ssize_t w = write(out, buf + done, (size_t)(n - done));
            if (w < 0 && errno == EINTR) continue;
            if (w <= 0) { ok = NO; if (errorText) *errorText = wq_errno(w == 0 ? EIO : errno); break; }
            done += w;
        }
        if (!ok) break;
    }
    free(buf);
    if (ok && fsync(out) != 0) { ok = NO; if (errorText) *errorText = wq_errno(errno); }
    return ok;
}

// Always durable, including own files. Safety artifacts themselves are protected
// from generic overwrite/delete: recursively backing up Backups is unbounded.
// A new backup unit name: "20261111-175959-512-1".
static NSString *wq_new_backup_stamp(void)
{
    static NSDateFormatter *fmt;
    static uint64_t counter;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        fmt.dateFormat = @"yyyyMMdd-HHmmss-SSS";
        lock = [NSLock new];
    });
    [lock lock];
    NSString *stamp = counter == UINT64_MAX ? nil :
        [NSString stringWithFormat:@"%@-%llu", [fmt stringFromDate:NSDate.date], (unsigned long long)++counter];
    [lock unlock];
    return stamp;
}

// Backs up the open file into Backups/<stamp>/<original path>. `unitStamp`
// puts several files into one unit (a deleted folder); nil makes a new one.
static BOOL wq_backup_fd(NSString *path, int fd, NSString *unitStamp, NSString **backupPath, NSString **errorText)
{
    if (errorText) *errorText = nil;
    NSString *original = WQCanonicalVarPath(path);
    NSString *root = WQCanonicalVarPath(wq_backup_root());
    if (!WQAbsolutePathGrammar(original) || wq_is_backup_storage_path(original)) {
        wq_log(@"backup: refusing invalid path or mutation of backup storage: %@", path);
        if (errorText) *errorText = WQLocalized(@"The path is invalid or belongs to backup storage.");
        return NO;
    }
    NSString *stamp = unitStamp ?: wq_new_backup_stamp();
    if (!stamp) {
        if (errorText) *errorText = WQLocalized(@"Cannot allocate a backup name.");
        return NO;
    }
    NSString *dest = [[root stringByAppendingPathComponent:stamp] stringByAppendingString:original];
    int parent = WQCreateDirectoriesNoLinks(dest.stringByDeletingLastPathComponent);
    if (parent < 0) {
        if (errorText) *errorText = wq_errno(errno);
        return NO;
    }
    const char *name = dest.lastPathComponent.fileSystemRepresentation;
    NSString *error = nil;
    BOOL ok = NO;
    // APFS clone first: a copy-on-write snapshot is independent, durable, and
    // does not require a full-size duplicate for every edited file.
    if (fclonefileat(fd, parent, name, 0) == 0) {
        int cloned = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat clonedStat = {0}, sourceStat = {0};
        if (cloned >= 0 && fstat(cloned, &clonedStat) == 0 && fstat(fd, &sourceStat) == 0 &&
            clonedStat.st_size == sourceStat.st_size && fsync(cloned) == 0) {
            ok = YES;
        } else {
            error = wq_errno(errno);
        }
        if (cloned >= 0) close(cloned);
        if (!ok) {
            unlinkat(parent, name, 0);
            wq_log(@"backup: clone verification failed for %@ (%@)", path, error ?: @"unknown error");
        }
    } else {
        int cloneError = errno;
        wq_log(@"backup: clone unavailable for %@ (%@); streaming", path, wq_errno(cloneError));
        struct stat sourceStat = {0};
        struct statfs space = {0};
        if (fstat(fd, &sourceStat) == 0 && fstatfs(parent, &space) == 0) {
            unsigned long long available = (unsigned long long)space.f_bavail * (unsigned long long)space.f_bsize;
            if ((unsigned long long)sourceStat.st_size > available) {
                error = WQLocalized(@"Not enough free space for a full backup copy");
                wq_log(@"backup: %@ (%@)", path, error);
                if (errorText) *errorText = error;
                close(parent);
                return NO;
            }
        }
        int out = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (out >= 0) {
            ok = lseek(fd, 0, SEEK_SET) >= 0 && wq_stream(fd, out, &error);
            if (close(out) != 0) ok = NO;
        } else {
            error = wq_errno(errno);
        }
        if (ok && fsync(parent) != 0) ok = NO;
        if (!ok) unlinkat(parent, name, 0);
    }
    if (ok && fsync(parent) != 0) { ok = NO; error = wq_errno(errno); }
    if (!ok) unlinkat(parent, name, 0);
    close(parent);
    wq_log(@"backup: %@ -> %@", path, ok ? dest : error ?: @"FAILED");
    if (ok && backupPath) *backupPath = dest;
    if (!ok && errorText) *errorText = error ?: WQLocalized(@"Backup copy failed.");
    return ok;
}

NSString *wq_backup_original_path(NSString *backupPath)
{
    // Validate raw components before normalization, so traversal is never hidden.
    if (!WQAbsolutePathGrammar(backupPath)) return nil;
    NSString *rootPath = WQCanonicalVarPath(wq_backup_root());
    if (!rootPath.length) return nil;
    NSString *root = [rootPath stringByAppendingString:@"/"];
    NSString *p = WQCanonicalVarPath(backupPath);
    if (![p hasPrefix:root]) return nil;
    NSArray *parts = [[p substringFromIndex:root.length] componentsSeparatedByString:@"/"];
    if (parts.count < 2 || !WQBackupStampValid(parts[0])) return nil;
    NSString *original = [@"/" stringByAppendingString:[[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"/"]];
    return WQAbsolutePathGrammar(original) ? original : nil;
}

#pragma mark - File operations

static NSDictionary<NSString *, NSNumber *> *wq_version_for_stat(const struct stat *st)
{
    return @{ @"device": @(st->st_dev), @"inode": @(st->st_ino), @"size": @(st->st_size),
              @"modifiedSeconds": @(st->st_mtimespec.tv_sec), @"modifiedNanoseconds": @(st->st_mtimespec.tv_nsec),
              @"changedSeconds": @(st->st_ctimespec.tv_sec), @"changedNanoseconds": @(st->st_ctimespec.tv_nsec) };
}

NSDictionary<NSString *, NSNumber *> *wq_file_version(NSString *path)
{
    struct stat st;
    if (!wq_stat(path, &st) || !S_ISREG(st.st_mode)) return nil;
    return wq_version_for_stat(&st);
}

static BOOL wq_changed(NSString **errorText)
{
    if (errorText) *errorText = WQLocalized(@"The file changed after it was opened. Your edits were not written; reopen it and compare the changes.");
    return NO;
}

typedef struct {
    int fd;
    int parent;
    struct stat before;
} WQMutation;

static void wq_mutation_close(WQMutation *mutation)
{
    if (mutation->fd >= 0) close(mutation->fd);
    if (mutation->parent >= 0) close(mutation->parent);
    mutation->fd = mutation->parent = -1;
}

// Revalidate the descriptor, directory entry, and the current parent path. A
// pathname swap never redirects backup, mutation, or rollback to the new inode.
static BOOL wq_mutation_current(NSString *path, WQMutation *mutation, BOOL version, NSString **errorText)
{
    struct stat current, entry, parent, currentParent;
    int checkParent = WQOpenDirectoryNoLinksFlags(path.stringByDeletingLastPathComponent, O_SEARCH);
    BOOL ok = checkParent >= 0 && fstat(checkParent, &currentParent) == 0 &&
        fstat(mutation->parent, &parent) == 0 && WQSameObject(&parent, &currentParent) &&
        fstat(mutation->fd, &current) == 0 && S_ISREG(current.st_mode) &&
        fstatat(mutation->parent, path.lastPathComponent.fileSystemRepresentation, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISREG(entry.st_mode) && WQSameObject(&entry, &current) && WQSameObject(&current, &mutation->before);
    if (checkParent >= 0) close(checkParent);
    if (ok && version) ok = [wq_version_for_stat(&current) isEqualToDictionary:wq_version_for_stat(&mutation->before)];
    return ok ? YES : wq_changed(errorText);
}

static BOOL wq_mutation_open(NSString *path, NSDictionary *expected, WQMutation *mutation, int flags, NSString **errorText)
{
    *mutation = (WQMutation){ .fd = -1, .parent = -1 };
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path))) { if (errorText) *errorText = WQLocalized(@"Invalid file path"); return NO; }
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = WQLocalized(@"Backup storage cannot be overwritten or deleted through the file browser.");
        return NO;
    }
    NSString *parent = path.stringByDeletingLastPathComponent;
    mutation->parent = WQOpenDirectoryNoLinksFlags(parent, O_SEARCH);
    if (mutation->parent < 0 && wq_is_denied(errno) && wq_grant(parent)) mutation->parent = WQOpenDirectoryNoLinksFlags(parent, O_SEARCH);
    if (mutation->parent >= 0) {
        mutation->fd = WQOpenRegularAt(mutation->parent, path.lastPathComponent.fileSystemRepresentation, flags, 0);
        if (mutation->fd < 0 && wq_is_denied(errno) && wq_grant(path))
            mutation->fd = WQOpenRegularAt(mutation->parent, path.lastPathComponent.fileSystemRepresentation, flags, 0);
    }
    if (mutation->fd < 0) { if (errorText) *errorText = wq_errno(errno); wq_mutation_close(mutation); return NO; }
    if (flock(mutation->fd, LOCK_EX | LOCK_NB) != 0) {
        int err = errno;
        // Some providers do not implement locks. Keep descriptor/version checks;
        // this is advisory serialization, not atomicity against other writers.
        if (err != ENOTSUP && err != EOPNOTSUPP && err != ENOSYS) {
            if (errorText) *errorText = wq_errno(err);
            wq_mutation_close(mutation); return NO;
        }
        wq_log(@"advisory locking unsupported: %@", path);
    }
    if (fstat(mutation->fd, &mutation->before) != 0 ||
        (expected && ![wq_version_for_stat(&mutation->before) isEqualToDictionary:expected]) ||
        !wq_mutation_current(path, mutation, YES, errorText)) {
        wq_changed(errorText); wq_mutation_close(mutation); return NO;
    }
    WQ_MUTATION_HOOK(@"verified", path);
    return YES;
}

static BOOL wq_mutation_backup_into(NSString *path, WQMutation *mutation, NSString *unitStamp, NSString **backup, NSString **errorText)
{
    if (!wq_mutation_current(path, mutation, YES, errorText)) return NO;
    NSString *backupError = nil;
    if (!wq_backup_fd(path, mutation->fd, unitStamp, backup, &backupError)) {
        if (errorText) *errorText = WQLocalizedFormat(@"Backup of the current file failed, nothing was written: %@", backupError ?: WQLocalized(@"unknown error"));
        return NO;
    }
    WQ_MUTATION_HOOK(@"backedUp", path);
    return wq_mutation_current(path, mutation, YES, errorText);
}

static BOOL wq_mutation_backup(NSString *path, WQMutation *mutation, NSString **backup, NSString **errorText)
{
    return wq_mutation_backup_into(path, mutation, nil, backup, errorText);
}

static BOOL wq_restore_backup_fd(WQMutation *mutation, NSString *backup, NSString **errorText)
{
    int in = WQOpenRegularAt(AT_FDCWD, backup.fileSystemRepresentation, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    // This is still the original, locked descriptor, never a reopened pathname.
    BOOL ok = lseek(mutation->fd, 0, SEEK_SET) >= 0 && ftruncate(mutation->fd, 0) == 0 &&
        wq_stream(in, mutation->fd, errorText);
    close(in);
    return ok;
}

static BOOL wq_pread_exact(int fd, void *buffer, size_t length, off_t offset)
{
    size_t done = 0;
    while (done < length) {
        ssize_t n = pread(fd, (uint8_t *)buffer + done, length - done, offset + (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return NO; }
        done += (size_t)n;
    }
    return YES;
}

// Compare a complete intended document, or the complete backup with patches
// overlaid in write order. Buffers stay bounded even for a very large hex file.
static NSDictionary *wq_verified_saved_version(WQMutation *mutation, NSData *data,
                                               NSDictionary<NSNumber *, NSData *> *runs)
{
    struct stat before, after;
    if (fstat(mutation->fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size < 0) return nil;
    uint8_t expected[65536], actual[65536];
    BOOL ok = YES;
    if (data) {
        if ((unsigned long long)before.st_size != data.length) return nil;
        for (unsigned long long offset = 0; offset < data.length && ok; ) {
            size_t count = (size_t)MIN((unsigned long long)sizeof(expected), (unsigned long long)data.length - offset);
            memcpy(expected, (const uint8_t *)data.bytes + (NSUInteger)offset, count);
            ok = wq_pread_exact(mutation->fd, actual, count, (off_t)offset) &&
                 memcmp(expected, actual, count) == 0;
            offset += count;
        }
    } else {
        // A patch leaves every unedited byte untouched. The descriptor was
        // pinned and version-checked; verifying the changed runs is sufficient
        // and avoids reading the entire file for a one-byte edit.
        if (!runs || (unsigned long long)before.st_size != (unsigned long long)mutation->before.st_size) return nil;
        for (NSNumber *key in runs) {
            NSData *run = runs[key];
            unsigned long long start = key.unsignedLongLongValue;
            if (!WQPatchRangeValid(start, run.length, (unsigned long long)before.st_size)) return nil;
            for (NSUInteger done = 0; done < run.length && ok; ) {
                size_t count = (size_t)MIN((NSUInteger)sizeof(expected), run.length - done);
                ok = wq_pread_exact(mutation->fd, actual, count, (off_t)(start + done)) &&
                     memcmp((const uint8_t *)run.bytes + done, actual, count) == 0;
                done += (NSUInteger)count;
            }
            if (!ok) break;
        }
    }
    if (!ok || fstat(mutation->fd, &after) != 0 ||
        ![wq_version_for_stat(&before) isEqualToDictionary:wq_version_for_stat(&after)]) return nil;
    return wq_version_for_stat(&after);
}

static BOOL wq_mutation_finish(NSString *path, WQMutation *mutation, NSString *backup, BOOL ok,
                               NSString *failure, NSString **errorText, NSDictionary **savedVersion,
                               NSData *expectedData, NSDictionary<NSNumber *, NSData *> *expectedRuns)
{
    if (savedVersion) *savedVersion = nil;
    NSDictionary *verifiedVersion = nil;
    BOOL rollbackAllowed = YES;
    if (ok && fsync(mutation->fd) != 0) { ok = NO; failure = wq_errno(errno); }
    WQ_MUTATION_HOOK(@"written", path);
    if (ok && !wq_mutation_current(path, mutation, NO, errorText)) {
        ok = NO; failure = WQLocalized(@"The target path was replaced during writing");
    }
    if (ok && (expectedData || expectedRuns)) {
        verifiedVersion = wq_verified_saved_version(mutation, expectedData, expectedRuns);
        if (!verifiedVersion || !wq_mutation_current(path, mutation, NO, errorText)) {
            ok = NO;
            rollbackAllowed = NO; // A concurrent writer may own the newer contents.
            failure = WQLocalized(@"Saved contents could not be verified; possible concurrent modification");
        }
    }
    if (!ok) {
        NSString *rollbackError = nil;
        BOOL restored = rollbackAllowed && backup && wq_restore_backup_fd(mutation, backup, &rollbackError);
        if (errorText) *errorText = [NSString stringWithFormat:@"%@; %@. Backup: %@", failure ?: WQLocalized(@"Write failed"),
            restored ? @"the original descriptor contents were restored" :
            (rollbackAllowed ? [@"rollback failed: " stringByAppendingString:rollbackError ?: WQLocalized(@"unknown error")] :
             @"no rollback was attempted to avoid overwriting concurrent changes"), backup ?: @"none"];
    }
    // Rollback must finish before close releases the lock. A close failure has
    // no safe reopen/rollback path; retain the durable backup and report it.
    if (close(mutation->fd) != 0 && ok) {
        ok = NO;
        if (errorText) *errorText = WQLocalizedFormat(@"Close failed: %@. Backup: %@", wq_errno(errno), backup);
    }
    mutation->fd = -1;
    wq_mutation_close(mutation);
    if (ok && savedVersion) *savedVersion = verifiedVersion;
    return ok;
}

NSArray<NSString *> *wq_list(NSString *dir, NSString **errorText)
{
    NSError *error = nil;
    NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
    if (!items && wq_grant(dir)) items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
    if (!items && errorText) *errorText = error.localizedDescription ?: WQLocalized(@"Cannot list this folder");
    if (!items) {
        // Keep the reason in errno, so callers can tell a refusal from a failure.
        int err = [error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoPermissionError ? EACCES : EIO;
        for (NSError *e = error; e; e = e.userInfo[NSUnderlyingErrorKey]) {
            if ([e.domain isEqualToString:NSPOSIXErrorDomain] && e.code > 0) { err = (int)e.code; break; }
        }
        errno = err;
    }
    return items;
}

static int wq_open(NSString *path, int flags, mode_t mode)
{
    if (flags & O_TRUNC) { errno = EINVAL; return -1; }
    int fd = WQOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
    if (fd >= 0 || !wq_is_denied(errno)) return fd;
    // The file's own folder first, then the file itself.
    if (wq_grant(path.stringByDeletingLastPathComponent)) {
        fd = WQOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
        if (fd >= 0 || !wq_is_denied(errno)) return fd;
    }
    if (!(flags & O_CREAT) && wq_grant(path)) fd = WQOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
    if (fd < 0) {
        // Say why: a sandbox refusal (EPERM) and plain Unix permissions
        // (EACCES: owner/mode don't allow it) need different fixes.
        int err = errno;
        struct stat st;
        BOOL have = lstat(path.fileSystemRepresentation, &st) == 0;
        wq_log(@"open %@ for %@ -> %@; file uid %d mode %o, we are uid %d", path,
               (flags & O_ACCMODE) == O_RDONLY ? @"reading" : @"writing", wq_errno(err),
               have ? (int)st.st_uid : -1, have ? (int)(st.st_mode & 07777) : 0, (int)getuid());
        errno = err;
    }
    return fd;
}

NSData *wq_read(NSString *path, NSUInteger maxBytes, NSString **errorText)
{
    int fd = wq_open(path, O_RDONLY, 0);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        return nil;
    }
    NSMutableData *data = [NSMutableData new];
    uint8_t buf[65536];
    for (;;) {
        size_t want = sizeof(buf);
        if (maxBytes && data.length + want > maxBytes) want = maxBytes - data.length;
        if (want == 0) break;
        ssize_t n = read(fd, buf, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errorText) *errorText = wq_errno(errno);
            close(fd);
            return nil;
        }
        if (n == 0) break;
        [data appendBytes:buf length:(NSUInteger)n];
    }
    close(fd);
    return data;
}

static BOOL wq_write_all(int fd, NSData *data)
{
    const uint8_t *p = data.bytes;
    NSUInteger left = data.length;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) { errno = EIO; return NO; }
        p += n;
        left -= (NSUInteger)n;
    }
    return YES;
}

// Writes, then flushes and closes, reporting the first failure of the three.
static BOOL wq_finish_fd(int fd, BOOL ok, int *err)
{
    if (ok && fsync(fd) != 0) { ok = NO; *err = errno; }
    if (close(fd) != 0 && ok) { ok = NO; *err = errno; }
    return ok;
}

static BOOL wq_write_checked(NSString *path, NSData *data, NSDictionary *expected,
                             NSDictionary **savedVersion, BOOL verify, NSString **errorText)
{
    if (savedVersion) *savedVersion = nil;
    WQMutation mutation;
    if (!wq_mutation_open(path, expected, &mutation, O_RDWR, errorText)) return NO;
    NSString *backup = nil;
    if (!wq_mutation_backup(path, &mutation, &backup, errorText)) { wq_mutation_close(&mutation); return NO; }
    BOOL ok = lseek(mutation.fd, 0, SEEK_SET) >= 0 && ftruncate(mutation.fd, 0) == 0 && wq_write_all(mutation.fd, data);
    NSString *failure = ok ? nil : wq_errno(errno);
    return wq_mutation_finish(path, &mutation, backup, ok, failure, errorText, savedVersion, verify ? data : nil, nil);
}

BOOL wq_write_if_unchanged_get_version(NSString *path, NSData *data, NSDictionary *expected,
                                      NSDictionary **savedVersion, NSString **errorText)
{
    return wq_write_checked(path, data, expected, savedVersion, YES, errorText);
}

BOOL wq_write_if_unchanged(NSString *path, NSData *data, NSDictionary *expected, NSString **errorText)
{
    return wq_write_checked(path, data, expected, nil, NO, errorText);
}

BOOL wq_write(NSString *path, NSData *data, NSString **errorText)
{
    return wq_write_if_unchanged(path, data, nil, errorText);
}

BOOL wq_write_from_file(NSString *path, NSString *source, NSString **errorText)
{
    return wq_write_from_file_with_backup(path, source, NULL, errorText);
}

static BOOL wq_write_from_file_checked(NSString *path, NSString *source, NSDictionary *expected,
                                       NSString **backupUnit, NSString **errorText);

BOOL wq_write_from_file_with_backup(NSString *path, NSString *source, NSString **backupUnit, NSString **errorText)
{
    return wq_write_from_file_checked(path, source, nil, backupUnit, errorText);
}

BOOL wq_write_from_file_if_unchanged(NSString *path, NSString *source, NSDictionary *expected, NSString **errorText)
{
    return wq_write_from_file_checked(path, source, expected, NULL, errorText);
}

static BOOL wq_write_from_file_checked(NSString *path, NSString *source, NSDictionary *expected,
                                       NSString **backupUnit, NSString **errorText)
{
    if (backupUnit) *backupUnit = nil;
    int in = WQOpenRegularAt(AT_FDCWD, source.fileSystemRepresentation, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    WQMutation mutation;
    if (!wq_mutation_open(path, expected, &mutation, O_RDWR, errorText)) { close(in); return NO; }
    struct stat src;
    if (fstat(in, &src) != 0 || WQSameObject(&src, &mutation.before)) {
        if (errorText) *errorText = WQLocalized(@"Source and destination are the same file");
        close(in); wq_mutation_close(&mutation); return NO;
    }
    NSDictionary *sourceVersion = wq_version_for_stat(&src);
    NSString *backup = nil;
    if (!wq_mutation_backup(path, &mutation, &backup, errorText)) { close(in); wq_mutation_close(&mutation); return NO; }
    WQ_STREAM_HOOK(@"ready", source);
    NSString *error = nil;
    BOOL ok = lseek(mutation.fd, 0, SEEK_SET) >= 0 && ftruncate(mutation.fd, 0) == 0 && wq_stream(in, mutation.fd, &error);
    struct stat srcAfter = {0};
    if (ok && (fstat(in, &srcAfter) != 0 ||
               ![sourceVersion isEqualToDictionary:wq_version_for_stat(&srcAfter)])) {
        ok = NO;
        error = WQLocalized(@"The source changed while it was being copied");
    }
    if (!ok && !error) error = wq_errno(errno);
    close(in);
    BOOL finished = wq_mutation_finish(path, &mutation, backup, ok, error, errorText, nil, nil, nil);
    if (finished && backupUnit && backup.length) {
        // Backups/<stamp>/<original path>: the unit is the stamp folder.
        NSString *root = WQCanonicalVarPath(wq_backup_root());
        NSString *canonical = WQCanonicalVarPath(backup);
        if (root.length && [canonical hasPrefix:[root stringByAppendingString:@"/"]]) {
            NSString *stamp = [[canonical substringFromIndex:root.length + 1] componentsSeparatedByString:@"/"].firstObject;
            if (stamp.length) *backupUnit = [root stringByAppendingPathComponent:stamp];
        }
    }
    return finished;
}

BOOL wq_backup_local_copy(NSString *originalPath, NSString *source, NSString **backupUnit, NSString **errorText)
{
    NSString *root = WQCanonicalVarPath(wq_backup_root());
    NSString *stamp = nil;
    if (*backupUnit) {
        NSString *unit = WQCanonicalVarPath(*backupUnit);
        stamp = unit.lastPathComponent;
        if (!root.length || ![unit isEqualToString:[root stringByAppendingPathComponent:stamp]] || !WQBackupStampValid(stamp)) {
            if (errorText) *errorText = WQLocalized(@"The path is invalid or belongs to backup storage.");
            return NO;
        }
    } else {
        stamp = wq_new_backup_stamp();
        if (!stamp || !root.length) {
            if (errorText) *errorText = WQLocalized(@"Cannot allocate a backup name.");
            return NO;
        }
    }
    int in = WQOpenRegularAt(AT_FDCWD, source.fileSystemRepresentation, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    BOOL ok = wq_backup_fd(originalPath, in, stamp, NULL, errorText);
    close(in);
    if (ok) *backupUnit = [root stringByAppendingPathComponent:stamp];
    return ok;
}

BOOL wq_create_file_from(NSString *path, NSString *source, NSString **errorText)
{
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = WQLocalized(@"Backup storage cannot be modified through the file browser.");
        return NO;
    }
    NSString *canonical = WQCanonicalVarPath(path);
    if (!WQAbsolutePathGrammar(canonical)) {
        if (errorText) *errorText = WQLocalized(@"Invalid file path");
        return NO;
    }
    int in = wq_open(source, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) {
        if (errorText) *errorText = wq_errno(errno);
        close(in);
        return NO;
    }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    int fd = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0 && wq_is_denied(errno) && wq_grant(parentPath))
        fd = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        close(parent); close(in);
        return NO;
    }
    struct stat srcBefore = {0};
    if (fstat(in, &srcBefore) != 0) {
        close(fd); close(in); close(parent);
        unlinkat(parent, name, 0);
        if (errorText) *errorText = WQLocalized(@"Cannot inspect the copy source");
        return NO;
    }
    NSDictionary *sourceVersion = wq_version_for_stat(&srcBefore);
    WQ_STREAM_HOOK(@"ready", source);
    NSString *error = nil;
    BOOL ok = wq_stream(in, fd, &error);
    struct stat srcAfter = {0};
    if (ok && (fstat(in, &srcAfter) != 0 ||
               ![sourceVersion isEqualToDictionary:wq_version_for_stat(&srcAfter)])) {
        ok = NO;
        error = WQLocalized(@"The source changed while it was being copied");
    }
    close(in);
    if (close(fd) != 0 && ok) { ok = NO; error = wq_errno(errno); }
    if (ok && fsync(parent) != 0) { ok = NO; error = wq_errno(errno); }
    if (!ok) unlinkat(parent, name, 0);
    close(parent);
    wq_log(@"create: %@ from %@ -> %@", path, source.lastPathComponent, ok ? @"OK" : error);
    if (!ok && errorText) *errorText = error;
    return ok;
}

BOOL wq_copy_to_local(NSString *path, NSString *dest, NSString **errorText)
{
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path)) || !WQAbsolutePathGrammar(WQCanonicalVarPath(dest))) {
        if (errorText) *errorText = WQLocalized(@"Invalid copy path");
        return NO;
    }
    if (wq_is_backup_storage_path(dest)) {
        if (errorText) *errorText = WQLocalized(@"Backup storage cannot be modified through the file browser.");
        return NO;
    }
    int in = wq_open(path, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    struct stat source, destination;
    if (fstat(in, &source) != 0) { close(in); return NO; }
    // stat intentionally follows a destination alias for this identity check.
    if (stat(dest.fileSystemRepresentation, &destination) == 0 && WQSameObject(&source, &destination)) {
        close(in); if (errorText) *errorText = WQLocalized(@"Source and destination are the same file"); return NO;
    }
    int parent = WQOpenDirectoryNoLinks(dest.stringByDeletingLastPathComponent);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); close(in); return NO; }
    NSString *stage = [@".wq-local-copy-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int out = WQOpenRegularAt(parent, stage.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (out < 0) { if (errorText) *errorText = wq_errno(errno); close(parent); close(in); return NO; }
    BOOL ok = wq_stream(in, out, errorText);
    struct stat after;
    if (ok && (fstat(in, &after) != 0 || ![wq_version_for_stat(&source) isEqualToDictionary:wq_version_for_stat(&after)])) {
        ok = NO; if (errorText) *errorText = WQLocalized(@"The source changed while it was copied");
    }
    close(in);
    if (close(out) != 0 && ok) { ok = NO; if (errorText) *errorText = wq_errno(errno); }
    // Recheck aliases after the potentially long stream, still before replacing.
    if (ok && fstatat(parent, dest.lastPathComponent.fileSystemRepresentation, &destination, 0) == 0 && WQSameObject(&source, &destination)) {
        ok = NO; if (errorText) *errorText = WQLocalized(@"Source and destination are the same file");
    }
    if (ok) {
        struct stat entry;
        if (fstatat(parent, dest.lastPathComponent.fileSystemRepresentation, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
            !S_ISREG(entry.st_mode) && !S_ISLNK(entry.st_mode)) {
            ok = NO; if (errorText) *errorText = WQLocalized(@"Destination is not a regular file");
        }
    }
    if (ok && renameat(parent, stage.fileSystemRepresentation, parent, dest.lastPathComponent.fileSystemRepresentation) != 0) {
        ok = NO; if (errorText) *errorText = wq_errno(errno);
    }
    if (ok && fsync(parent) != 0) { ok = NO; if (errorText) *errorText = wq_errno(errno); }
    if (!ok) unlinkat(parent, stage.fileSystemRepresentation, 0);
    close(parent);
    return ok;
}

NSString *wq_permission_hint(NSString *path, BOOL forWriting)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return nil;
    uid_t me = getuid();
    mode_t need = forWriting ? 2 : 4;   // w / r
    BOOL allowed = st.st_uid == me ? (st.st_mode >> 6 & need) != 0
                 : (st.st_gid == getgid() ? (st.st_mode >> 3 & need) != 0 : (st.st_mode & need) != 0);
    if (allowed) return nil;
    NSString *owner = st.st_uid == 0 ? @"root" : [NSString stringWithFormat:@"uid %d", (int)st.st_uid];
    return WQLocalizedFormat(@"This file belongs to %@ (mode %o) and only its owner may %@ it. WQ Files reaches the folder, but runs as mobile (uid %d), so no app can %@ this file.",
            owner, st.st_mode & 07777, forWriting ? WQLocalized(@"change") : WQLocalized(@"read"), (int)me, forWriting ? WQLocalized(@"change") : WQLocalized(@"open"));
}

NSData *wq_read_range(NSString *path, unsigned long long offset, NSUInteger length, NSString **errorText)
{
    int fd = wq_open(path, O_RDONLY, 0);
    if (fd < 0) { if (errorText) *errorText = wq_errno(errno); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:length];
    NSUInteger got = 0;
    while (got < length) {
        ssize_t n = pread(fd, (uint8_t *)data.mutableBytes + got, length - got, (off_t)(offset + got));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { if (errorText) *errorText = wq_errno(errno); close(fd); return nil; }
        if (n == 0) break;
        got += (NSUInteger)n;
    }
    close(fd);
    data.length = got;
    return data;
}

static BOOL wq_patch_checked(NSString *path, NSDictionary<NSNumber *, NSData *> *runs,
                             NSDictionary *expected, NSDictionary **savedVersion, BOOL verify, NSString **errorText)
{
    if (savedVersion) *savedVersion = nil;
    WQMutation mutation;
    if (!wq_mutation_open(path, expected, &mutation, O_RDWR, errorText)) return NO;
    unsigned long long size = (unsigned long long)mutation.before.st_size;
    for (NSNumber *off in runs) {
        if (!WQPatchRangeValid(off.unsignedLongLongValue, runs[off].length, size)) {
            if (errorText) *errorText = WQLocalized(@"A change lies past the end of the file");
            wq_mutation_close(&mutation); return NO;
        }
    }
    NSString *backup = nil;
    if (!wq_mutation_backup(path, &mutation, &backup, errorText)) { wq_mutation_close(&mutation); return NO; }
    BOOL ok = YES;
    int err = 0;
    for (NSNumber *off in [runs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *run = runs[off];
        for (NSUInteger done = 0; done < run.length; ) {
            ssize_t n = pwrite(mutation.fd, (const uint8_t *)run.bytes + done, run.length - done, (off_t)(off.unsignedLongLongValue + done));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ok = NO; err = n == 0 ? EIO : errno; break; }
            done += (NSUInteger)n;
        }
        if (!ok) break;
    }
    return wq_mutation_finish(path, &mutation, backup, ok, ok ? nil : wq_errno(err), errorText,
                              savedVersion, nil, verify ? runs : nil);
}

BOOL wq_patch_if_unchanged_get_version(NSString *path, NSDictionary<NSNumber *, NSData *> *runs,
                                      NSDictionary *expected, NSDictionary **savedVersion, NSString **errorText)
{
    return wq_patch_checked(path, runs, expected, savedVersion, YES, errorText);
}

BOOL wq_patch_if_unchanged(NSString *path, NSDictionary<NSNumber *, NSData *> *runs,
                           NSDictionary *expected, NSString **errorText)
{
    return wq_patch_checked(path, runs, expected, nil, NO, errorText);
}

BOOL wq_patch(NSString *path, NSDictionary<NSNumber *, NSData *> *runs, NSString **errorText)
{
    return wq_patch_if_unchanged(path, runs, nil, errorText);
}

BOOL wq_backup_unit_deletable(NSString *path)
{
    NSString *canonical = WQCanonicalVarPath(path);
    if (!WQAbsolutePathGrammar(canonical) || [canonical.lastPathComponent hasPrefix:@"."]) return NO;
    NSString *parentPath = canonical.stringByDeletingLastPathComponent;
    NSString *grandparentPath = parentPath.stringByDeletingLastPathComponent;
    NSString *fileRoot = WQCanonicalVarPath(wq_backup_root());
    NSString *appRoot = WQCanonicalVarPath(wq_app_backup_root());
    if (fileRoot.length &&
        [canonical hasPrefix:[fileRoot stringByAppendingString:@"/"]] &&
        [parentPath isEqualToString:fileRoot]) return YES;
    if (appRoot.length &&
        [canonical hasPrefix:[appRoot stringByAppendingString:@"/"]] &&
        ([parentPath isEqualToString:appRoot] || [grandparentPath isEqualToString:appRoot])) return YES;
    return NO;
}

static BOOL wq_purge_root_matches(NSString *path, int fd);
static BOOL wq_purge_fd(int fd, NSString *path, unsigned long long *freed, WQScanCancellation *cancellation);
static BOOL wq_entry_is(int dir, const char *name, const struct stat *st);
static BOOL wq_selection_changed(NSString **errorText);

BOOL wq_delete_backup(NSString *path, NSString **errorText)
{
    if (!wq_backup_unit_deletable(path)) {
        if (errorText) *errorText = WQLocalized(@"Only a complete backup unit can be deleted here.");
        return NO;
    }
    NSString *canonical = WQCanonicalVarPath(path);
    NSString *parentPath = canonical.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    const char *name = canonical.lastPathComponent.fileSystemRepresentation;
    struct stat st;
    if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errorText) *errorText = wq_errno(errno);
        close(parent);
        return NO;
    }
    int rc;
    if (S_ISDIR(st.st_mode)) {
        // Purge the unit through a descriptor pinned to the examined folder;
        // a unit replaced meanwhile is left alone.
        unsigned long long ignored = 0;
        int unit = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        struct stat unitSt;
        BOOL same = unit >= 0 && fstat(unit, &unitSt) == 0 && WQSameObject(&unitSt, &st);
        WQ_TREE_HOOK(@"deleteBackupPurge", canonical);
        BOOL purged = same && wq_purge_root_matches(canonical, unit) && wq_purge_fd(unit, canonical, &ignored, nil);
        if (unit >= 0) close(unit);
        if (!same) { close(parent); return wq_selection_changed(errorText); }
        if (!purged) {
            if (errorText) *errorText = WQLocalized(@"Could not remove everything inside the backup.");
            close(parent);
            return NO;
        }
        if (!wq_entry_is(parent, name, &st)) { close(parent); return wq_selection_changed(errorText); }
        rc = unlinkat(parent, name, AT_REMOVEDIR);
    } else {
        if (!wq_entry_is(parent, name, &st)) { close(parent); return wq_selection_changed(errorText); }
        rc = unlinkat(parent, name, 0);
    }
    int err = errno;
    close(parent);
    wq_log(@"delete backup: %@ -> %@", path, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = wq_errno(err);
    return rc == 0;
}

static int wq_open_directory_flags(NSString *path, int flags)
{
    int fd = WQOpenDirectoryNoLinksFlags(path, flags);
    if (fd < 0 && wq_is_denied(errno) && wq_grant(path)) fd = WQOpenDirectoryNoLinksFlags(path, flags);
    return fd;
}

static int wq_open_directory(NSString *path)
{
    return wq_open_directory_flags(path, O_RDONLY);
}

BOOL wq_create_file(NSString *path, NSData *data, NSString **errorText)
{
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = WQLocalized(@"Backup storage cannot be modified through the file browser.");
        return NO;
    }
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path))) {
        if (errorText) *errorText = WQLocalized(@"Invalid file path");
        return NO;
    }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    int fd = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0 && wq_is_denied(errno) && wq_grant(parentPath))
        fd = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        close(parent);
        return NO;
    }
    BOOL ok = wq_write_all(fd, data);
    int err = errno;
    ok = wq_finish_fd(fd, ok, &err);
    if (ok && fsync(parent) != 0) { ok = NO; err = errno; }
    if (!ok) unlinkat(parent, name, 0);
    close(parent);
    wq_log(@"create: %@ (%lu bytes) -> %@", path, (unsigned long)data.length, ok ? @"OK" : wq_errno(err));
    if (!ok && errorText) *errorText = wq_errno(err);
    return ok;
}

BOOL wq_create_dir(NSString *path, NSString **errorText)
{
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = WQLocalized(@"Backup storage cannot be modified through the file browser.");
        return NO;
    }
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path))) {
        if (errorText) *errorText = WQLocalized(@"Invalid folder path");
        return NO;
    }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    int rc = mkdirat(parent, name, 0755);
    if (rc != 0 && wq_is_denied(errno) && wq_grant(parentPath))
        rc = mkdirat(parent, name, 0755);
    int err = errno;
    if (rc == 0 && fsync(parent) != 0) { rc = -1; err = errno; }
    close(parent);
    wq_log(@"mkdir: %@ -> %@", path, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = wq_errno(err);
    return rc == 0;
}

NSDictionary<NSString *, NSNumber *> *wq_identity_for_stat(const struct stat *st)
{
    return @{ @"device": @(st->st_dev), @"inode": @(st->st_ino), @"type": @(st->st_mode & S_IFMT) };
}

NSDictionary<NSString *, NSNumber *> *wq_item_identity(NSString *path)
{
    struct stat st;
    return wq_stat(path, &st) ? wq_identity_for_stat(&st) : nil;
}

// YES when no identity was given, or st is the object it describes.
static BOOL wq_identity_matches(NSDictionary<NSString *, NSNumber *> *identity, const struct stat *st)
{
    return !identity || [wq_identity_for_stat(st) isEqualToDictionary:identity];
}

static BOOL wq_selection_changed(NSString **errorText)
{
    if (errorText) *errorText = WQLocalized(@"The item was moved, replaced or changed after it was selected. It was left as it is.");
    return NO;
}

// The entry `name` in `dir` is still the object st describes (same identity
// and type). Never follows a link.
static BOOL wq_entry_is(int dir, const char *name, const struct stat *st)
{
    struct stat now;
    return fstatat(dir, name, &now, AT_SYMLINK_NOFOLLOW) == 0 && WQSameObject(&now, st) &&
        (now.st_mode & S_IFMT) == (st->st_mode & S_IFMT);
}

// Backs a regular file up (into `unitStamp`, or a new unit) and removes it.
static BOOL wq_delete_regular(NSString *path, const struct stat *st, NSString *unitStamp, NSString **errorText)
{
    WQMutation mutation;
    if (!wq_mutation_open(path, wq_version_for_stat(st), &mutation, O_RDONLY, errorText)) return NO;
    NSString *backup = nil;
    if (!wq_mutation_backup_into(path, &mutation, unitStamp, &backup, errorText)) { wq_mutation_close(&mutation); return NO; }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    // The name must still be the backed-up file right before it is unlinked.
    if (!wq_entry_is(mutation.parent, name, &mutation.before)) { wq_mutation_close(&mutation); return wq_selection_changed(errorText); }
    int rc = unlinkat(mutation.parent, name, 0);
    int err = errno;
    wq_mutation_close(&mutation);
    if (rc != 0 && errorText) *errorText = wq_errno(err);
    return rc == 0;
}

// As wq_delete_regular, but relative to a pinned folder descriptor `dir`
// (a recursive delete): the file is opened through `dir`, the pathname must
// still lead to `dir` (wq_mutation_current) before and after the backup, and
// the entry must still be the backed-up file right before it is unlinked.
static BOOL wq_delete_regular_at(int dir, NSString *path, const struct stat *st, NSString *unitStamp, NSString **errorText)
{
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    WQMutation mutation = { .fd = -1, .parent = fcntl(dir, F_DUPFD_CLOEXEC, 0) };
    if (mutation.parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    mutation.fd = WQOpenRegularAt(dir, name, O_RDONLY, 0);
    if (mutation.fd < 0 && wq_is_denied(errno) && wq_grant(path)) mutation.fd = WQOpenRegularAt(dir, name, O_RDONLY, 0);
    if (mutation.fd < 0) {
        int err = errno;
        wq_mutation_close(&mutation);
        if (err == EINVAL) return wq_selection_changed(errorText);   // no longer a regular file
        if (errorText) *errorText = wq_errno(err);
        return NO;
    }
    if (flock(mutation.fd, LOCK_EX | LOCK_NB) != 0) {
        int err = errno;
        if (err != ENOTSUP && err != EOPNOTSUPP && err != ENOSYS) {
            wq_mutation_close(&mutation);
            if (errorText) *errorText = wq_errno(err);
            return NO;
        }
    }
    if (fstat(mutation.fd, &mutation.before) != 0 ||
        ![wq_version_for_stat(&mutation.before) isEqualToDictionary:wq_version_for_stat(st)] ||
        !wq_mutation_current(path, &mutation, YES, NULL)) {
        wq_mutation_close(&mutation);
        return wq_selection_changed(errorText);
    }
    NSString *backupError = nil;
    if (!wq_backup_fd(path, mutation.fd, unitStamp, NULL, &backupError)) {
        wq_mutation_close(&mutation);
        if (errorText) *errorText = WQLocalizedFormat(@"Backup of the current file failed, nothing was written: %@", backupError ?: WQLocalized(@"unknown error"));
        return NO;
    }
    WQ_MUTATION_HOOK(@"backedUp", path);
    if (!wq_mutation_current(path, &mutation, YES, NULL) || !wq_entry_is(dir, name, &mutation.before)) {
        wq_mutation_close(&mutation);
        return wq_selection_changed(errorText);
    }
    int rc = unlinkat(dir, name, 0);
    int err = errno;
    wq_mutation_close(&mutation);
    if (rc != 0 && errorText) *errorText = wq_errno(err);
    return rc == 0;
}

// Container roots and everything above them: deleting one would remove a
// whole app's (or the system's) data, so folder deletes refuse them.
BOOL wq_is_protected_folder(NSString *path)
{
    NSString *p = WQCanonicalVarPath(path);
    NSArray<NSString *> *parents = @[
        @"/private/var/mobile/Containers/Data/Application", @"/private/var/mobile/Containers/Data/PluginKitPlugin",
        @"/private/var/mobile/Containers/Data/InternalDaemon", @"/private/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/containers/Data/System", @"/private/var/containers/Shared/SystemGroup",
        @"/private/var/containers/Bundle/Application",
    ];
    for (NSString *parent in parents) {
        if ([parent hasPrefix:[p stringByAppendingString:@"/"]] || [p isEqualToString:parent]) return YES;   // the parent or above
        if ([p.stringByDeletingLastPathComponent isEqualToString:parent]) return YES;                       // a container root
    }
    // Shallow system paths (/, /private, /private/var, /private/var/mobile…).
    return p.pathComponents.count <= 5;
}

// One pinned folder of a recursive delete: its descriptor (opened without
// following links), its identity, its path, and the children still to remove.
@interface WQTreeFrame : NSObject {
@public
    int fd;
    struct stat st;
    NSString *path;
    NSArray<NSString *> *children;
    NSUInteger next;
}
@end
@implementation WQTreeFrame
- (instancetype)init { if ((self = [super init])) fd = -1; return self; }
- (void)dealloc { if (fd >= 0) close(fd); }
@end

typedef struct {
    NSString *stamp;
    BOOL (^cancelled)(void);
    void (^progress)(NSUInteger deleted);
    NSUInteger deleted;
    NSString *error;
} WQTreeDelete;

static BOOL wq_tree_fail(WQTreeDelete *ctx, NSString *path, NSString *error)
{
    ctx->error = [NSString stringWithFormat:@"%@: %@", path.lastPathComponent, error ?: @"failed"];
    return NO;
}

static BOOL wq_tree_changed(WQTreeDelete *ctx, NSString *path)
{
    NSString *text = nil;
    wq_selection_changed(&text);
    return wq_tree_fail(ctx, path, text);
}

// The pathname still names the pinned folder (a cheap swap detector; every
// removal itself stays descriptor-relative).
static BOOL wq_tree_frame_current(NSString *path, const struct stat *st)
{
    struct stat now;
    return wq_stat(path, &now) && S_ISDIR(now.st_mode) && WQSameObject(&now, st);
}

// Names in an open folder, read through a fresh descriptor of that folder.
static NSArray<NSString *> *wq_tree_list(int fd, NSString *path, int *error)
{
    int listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (listing < 0 && wq_is_denied(errno) && wq_grant(path)) listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (listing < 0) { *error = errno; return nil; }
    DIR *dir = fdopendir(listing);
    if (!dir) { *error = errno; close(listing); return nil; }
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    int err = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { err = errno; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) { err = EILSEQ; break; }
        [names addObject:name];
    }
    closedir(dir);
    if (err) { *error = err; return nil; }
    return names;
}

// Opens the folder `name` in `parent`, checks it is the object st describes,
// and lists it.
static WQTreeFrame *wq_tree_open(int parent, NSString *path, const struct stat *st, WQTreeDelete *ctx)
{
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    WQTreeFrame *frame = [WQTreeFrame new];
    frame->fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (frame->fd < 0 && wq_is_denied(errno) && wq_grant(path))
        frame->fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (frame->fd < 0) {
        if (errno == ENOTDIR || errno == ELOOP || errno == ENOENT) { wq_tree_changed(ctx, path); return nil; }
        wq_tree_fail(ctx, path, wq_errno(errno));
        return nil;
    }
    if (fstat(frame->fd, &frame->st) != 0 || !WQSameObject(&frame->st, st) || !S_ISDIR(frame->st.st_mode)) {
        wq_tree_changed(ctx, path);
        return nil;
    }
    frame->path = path;
    int err = 0;
    frame->children = wq_tree_list(frame->fd, path, &err);
    if (!frame->children) { wq_tree_fail(ctx, path, wq_errno(err)); return nil; }
    return frame;
}

// Removes one non-folder entry `name` of the pinned folder `dir` (at dirPath,
// identity dirSt). Regular files are backed up first; links and special files
// are removed as they are (never followed).
static BOOL wq_tree_remove_leaf(int dir, NSString *dirPath, const struct stat *dirSt, NSString *path,
                                const struct stat *st, WQTreeDelete *ctx)
{
    NSString *error = nil;
    BOOL ok;
    if (S_ISREG(st->st_mode)) {
        ok = wq_delete_regular_at(dir, path, st, ctx->stamp, &error);
    } else {
        const char *name = path.lastPathComponent.fileSystemRepresentation;
        WQ_TREE_HOOK(@"deleteTreeUnlink", path);
        if (!wq_tree_frame_current(dirPath, dirSt) || !wq_entry_is(dir, name, st)) return wq_tree_changed(ctx, path);
        ok = unlinkat(dir, name, 0) == 0;
        if (!ok) error = wq_errno(errno);
    }
    if (!ok) return wq_tree_fail(ctx, path, error);
    ctx->deleted++;
    if (ctx->progress) ctx->progress(ctx->deleted);
    return YES;
}

// Iterative, descriptor-relative walk. Every folder is pinned by a descriptor
// opened without following links; every child is opened or removed relative
// to it. Before each removal the folder's pathname must still lead to the
// pinned folder and the entry must still be the object that was examined, so
// a folder moved or replaced mid-way stops the delete (fail closed) instead
// of continuing into the replacement.
static BOOL wq_tree_remove(int parent, NSString *parentPath, const struct stat *parentSt, NSString *path,
                           const struct stat *rootSt, WQTreeDelete *ctx)
{
    if (!S_ISDIR(rootSt->st_mode)) return wq_tree_remove_leaf(parent, parentPath, parentSt, path, rootSt, ctx);
    WQTreeFrame *root = wq_tree_open(parent, path, rootSt, ctx);
    if (!root) return NO;
    NSMutableArray<WQTreeFrame *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        if (ctx->cancelled && ctx->cancelled()) { ctx->error = WQLocalized(@"Cancelled"); return NO; }
        WQTreeFrame *frame = stack.lastObject;
        if (frame->next < frame->children.count) {
            NSString *childPath = [frame->path stringByAppendingPathComponent:frame->children[frame->next++]];
            WQ_TREE_HOOK(@"deleteTreeChild", childPath);
            if (!wq_tree_frame_current(frame->path, &frame->st)) return wq_tree_changed(ctx, frame->path);
            struct stat st;
            if (fstatat(frame->fd, childPath.lastPathComponent.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW) != 0) {
                if (errno == ENOENT) continue;   // gone meanwhile
                return wq_tree_fail(ctx, childPath, wq_errno(errno));
            }
            if (S_ISDIR(st.st_mode)) {
                if (stack.count > 128) { ctx->error = WQLocalized(@"Folders are nested too deeply"); return NO; }
                WQTreeFrame *child = wq_tree_open(frame->fd, childPath, &st, ctx);
                if (!child) return NO;
                [stack addObject:child];
            } else if (!wq_tree_remove_leaf(frame->fd, frame->path, &frame->st, childPath, &st, ctx)) {
                return NO;
            }
            continue;
        }
        // Everything inside is gone: remove the folder itself from its parent.
        [stack removeLastObject];
        WQTreeFrame *up = stack.lastObject;
        int dir = up ? up->fd : parent;
        const char *name = frame->path.lastPathComponent.fileSystemRepresentation;
        WQ_TREE_HOOK(@"deleteTreeRemoveDir", frame->path);
        if (!wq_tree_frame_current(up ? up->path : parentPath, up ? &up->st : parentSt) ||
            !wq_tree_frame_current(frame->path, &frame->st) || !wq_entry_is(dir, name, &frame->st))
            return wq_tree_changed(ctx, frame->path);
        if (unlinkat(dir, name, AT_REMOVEDIR) != 0) return wq_tree_fail(ctx, frame->path, wq_errno(errno));
    }
    return YES;
}

BOOL wq_delete_tree_expecting(NSString *path, NSDictionary<NSString *, NSNumber *> *identity, BOOL (^cancelled)(void),
                              void (^progress)(NSUInteger deleted), NSUInteger *deleted, NSString **backupUnit, NSString **errorText)
{
    if (deleted) *deleted = 0;
    if (backupUnit) *backupUnit = nil;
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = WQLocalized(@"Backup storage cannot be overwritten or deleted through the file browser.");
        return NO;
    }
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path)) || wq_is_protected_folder(path)) {
        if (errorText) *errorText = WQLocalized(@"This folder can't be deleted: it holds an app's or the system's data.");
        return NO;
    }
    WQTreeDelete ctx = { .stamp = wq_new_backup_stamp(), .cancelled = cancelled, .progress = progress };
    if (!ctx.stamp) { if (errorText) *errorText = WQLocalized(@"Cannot allocate a backup name."); return NO; }
    // Pin the parent, then the selected item inside it (no links followed).
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    struct stat parentSt, st;
    BOOL ok;
    if (fstat(parent, &parentSt) != 0) {
        ok = wq_tree_fail(&ctx, parentPath, wq_errno(errno));
    } else if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) != 0 &&
               !(wq_is_denied(errno) && wq_grant(parentPath) && fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0)) {
        // Already gone: nothing to delete, unless a specific item was expected.
        int err = errno;
        ok = err == ENOENT && !identity;
        if (!ok) {
            if (err == ENOENT) wq_tree_changed(&ctx, path);
            else wq_tree_fail(&ctx, path, wq_errno(err));
        }
    } else if (!wq_identity_matches(identity, &st)) {
        ok = wq_tree_changed(&ctx, path);
    } else {
        ok = wq_tree_remove(parent, parentPath, &parentSt, path, &st, &ctx);
    }
    close(parent);
    if (deleted) *deleted = ctx.deleted;
    NSString *unit = [wq_backup_root() stringByAppendingPathComponent:ctx.stamp];
    struct stat ust;
    if (backupUnit) *backupUnit = lstat(unit.fileSystemRepresentation, &ust) == 0 ? unit : nil;
    wq_log(@"delete folder: %@ -> %@, %lu items removed (unit %@)", path, ok ? @"OK" : ctx.error,
           (unsigned long)ctx.deleted, ctx.stamp);
    if (!ok && errorText) *errorText = ctx.error;
    return ok;
}

BOOL wq_delete_tree(NSString *path, BOOL (^cancelled)(void), void (^progress)(NSUInteger deleted),
                    NSUInteger *deleted, NSString **backupUnit, NSString **errorText)
{
    return wq_delete_tree_expecting(path, nil, cancelled, progress, deleted, backupUnit, errorText);
}

WQTreeCount wq_tree_count(NSString *path, NSUInteger limit)
{
    WQTreeCount count = { 0, 0, 0, WQTreeCountExact };
    struct stat st;
    if (!wq_stat(path, &st)) {
        if (errno != ENOENT) count.state = WQTreeCountUnreadable;
        return count;
    }
    if (!S_ISDIR(st.st_mode)) {
        if (S_ISREG(st.st_mode)) { count.regular = 1; count.bytes = (unsigned long long)st.st_size; }
        else count.other = 1;
        return count;
    }
    NSMutableArray<NSString *> *pending = [NSMutableArray arrayWithObject:path];
    while (pending.count) {
        if (count.regular + count.other >= limit) { count.state = WQTreeCountLimited; break; }
        NSString *dir = pending.lastObject;
        [pending removeLastObject];
        NSArray<NSString *> *children = wq_list(dir, NULL);
        if (!children) { count.state = WQTreeCountUnreadable; continue; }
        for (NSString *child in children) {
            NSString *p = [dir stringByAppendingPathComponent:child];
            if (!wq_stat(p, &st)) { if (errno != ENOENT) count.state = WQTreeCountUnreadable; continue; }
            if (S_ISDIR(st.st_mode)) [pending addObject:p];
            else if (S_ISREG(st.st_mode)) { count.regular++; count.bytes += (unsigned long long)st.st_size; }
            else count.other++;
        }
    }
    // An unreadable part outranks the limit: the totals are not even a lower
    // bound for what the delete will meet there.
    return count;
}

BOOL wq_delete_expecting(NSString *path, NSDictionary<NSString *, NSNumber *> *identity, NSString **errorText)
{
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = WQLocalized(@"Backup storage cannot be overwritten or deleted through the file browser.");
        return NO;
    }
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path))) {
        if (errorText) *errorText = WQLocalized(@"Invalid file path");
        return NO;
    }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    struct stat st;
    if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) != 0 &&
        !(wq_is_denied(errno) && wq_grant(parentPath) &&
          fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0)) {
        if (errorText) *errorText = errno == ENOENT ? WQLocalized(@"Not found") : wq_errno(errno);
        close(parent);
        return NO;
    }
    if (!wq_identity_matches(identity, &st)) {
        close(parent);
        wq_log(@"delete: %@ -> changed since it was selected", path);
        return wq_selection_changed(errorText);
    }
    if (S_ISREG(st.st_mode)) {
        close(parent);
        BOOL ok = wq_delete_regular(path, &st, nil, errorText);
        wq_log(@"delete: %@ -> %@", path, ok ? @"OK" : (errorText && *errorText ? *errorText : @"failed"));
        return ok;
    }
    int flags = S_ISDIR(st.st_mode) ? AT_REMOVEDIR : 0;
    WQ_TREE_HOOK(@"deleteReady", path);
    // Links and special files have no backup: the name must still be the
    // examined object right before it is removed.
    int rc = -1;
    if (wq_entry_is(parent, name, &st)) {
        rc = unlinkat(parent, name, flags);
        if (rc != 0 && wq_is_denied(errno) && wq_grant(parentPath) && wq_entry_is(parent, name, &st))
            rc = unlinkat(parent, name, flags);
    } else {
        close(parent);
        wq_log(@"delete: %@ -> changed before removal", path);
        return wq_selection_changed(errorText);
    }
    int err = errno;
    close(parent);
    wq_log(@"delete: %@ -> %@", path, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = err == ENOTEMPTY ? WQLocalized(@"Only empty folders can be deleted") : wq_errno(err);
    return rc == 0;
}

BOOL wq_delete(NSString *path, NSString **errorText)
{
    return wq_delete_expecting(path, nil, errorText);
}

// Source-identity guard for rename and move: `name` in `from` must be the
// selected object before the no-replace rename, and the renamed entry must
// be that same object afterwards. A replacement that slipped in between is
// put back (no-replace) and the operation fails.
static BOOL wq_rename_checked(int from, const char *name, int to, const char *newName, NSString *sourcePath,
                              NSArray<NSString *> *grants, NSDictionary<NSString *, NSNumber *> *identity,
                              NSString *hookStage, NSString *hookPath, BOOL *changed)
{
    *changed = NO;
    (void)hookStage; (void)hookPath;   // test hooks only
    struct stat before, after;
    if (fstatat(from, name, &before, AT_SYMLINK_NOFOLLOW) != 0) {
        if (!wq_is_denied(errno)) return NO;
        for (NSString *grant in grants) wq_grant(grant);
        if (fstatat(from, name, &before, AT_SYMLINK_NOFOLLOW) != 0) return NO;
    }
    if (!wq_identity_matches(identity, &before)) { *changed = YES; return NO; }
    WQ_TREE_HOOK(hookStage, hookPath);
    // RENAME_EXCL: never replaces an item that is already there.
    int rc = renameatx_np(from, name, to, newName, RENAME_EXCL);
    if (rc != 0 && wq_is_denied(errno)) {
        for (NSString *grant in grants) wq_grant(grant);
        rc = renameatx_np(from, name, to, newName, RENAME_EXCL);
    }
    if (rc != 0) return NO;
    if (fstatat(to, newName, &after, AT_SYMLINK_NOFOLLOW) == 0 && WQSameObject(&after, &before) &&
        (after.st_mode & S_IFMT) == (before.st_mode & S_IFMT)) return YES;
    *changed = YES;
    int back = renameatx_np(to, newName, from, name, RENAME_EXCL);
    wq_log(@"rename/move: %@ was replaced during the operation; %@", sourcePath,
           back == 0 ? @"put back" : [@"could not put it back: " stringByAppendingString:wq_errno(errno)]);
    errno = EAGAIN;
    return NO;
}

BOOL wq_rename_expecting(NSString *path, NSString *newName, NSDictionary<NSString *, NSNumber *> *identity, NSString **errorText)
{
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path)) || newName.length == 0 || [newName containsString:@"/"] ||
        [newName isEqualToString:@"."] || [newName isEqualToString:@".."] || [newName rangeOfString:@"\0"].location != NSNotFound) {
        if (errorText) *errorText = WQLocalized(@"Invalid name");
        return NO;
    }
    if (wq_is_backup_storage_path(path) ||
        wq_is_backup_storage_path([path.stringByDeletingLastPathComponent stringByAppendingPathComponent:newName])) {
        if (errorText) *errorText = WQLocalized(@"Backup storage cannot be renamed through the file browser.");
        return NO;
    }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    BOOL changed = NO;
    BOOL ok = wq_rename_checked(parent, path.lastPathComponent.fileSystemRepresentation, parent, newName.fileSystemRepresentation,
                                path, @[parentPath], identity, @"renameReady", [parentPath stringByAppendingPathComponent:newName], &changed);
    int err = errno;
    close(parent);
    wq_log(@"rename: %@ -> %@: %@", path, newName, ok ? @"OK" : changed ? @"changed since it was selected" : wq_errno(err));
    if (!ok && changed) return wq_selection_changed(errorText);
    if (!ok && errorText) *errorText = err == EEXIST ? WQLocalized(@"An item with that name already exists") : wq_errno(err);
    return ok;
}

BOOL wq_rename(NSString *path, NSString *newName, NSString **errorText)
{
    return wq_rename_expecting(path, newName, nil, errorText);
}

BOOL wq_move_expecting(NSString *path, NSString *destDir, NSDictionary<NSString *, NSNumber *> *identity, NSString **errorText)
{
    NSString *source = WQCanonicalVarPath(path), *target = WQCanonicalVarPath(destDir);
    NSString *name = source.lastPathComponent;
    if (!WQAbsolutePathGrammar(source) || !WQAbsolutePathGrammar(target) || !name.length) {
        if (errorText) *errorText = WQLocalized(@"Invalid path");
        return NO;
    }
    NSString *sourceParent = source.stringByDeletingLastPathComponent;
    if ([sourceParent isEqualToString:target]) {
        if (errorText) *errorText = WQLocalized(@"It is already in this folder");
        return NO;
    }
    if ([target isEqualToString:source] || [target hasPrefix:[source stringByAppendingString:@"/"]]) {
        if (errorText) *errorText = WQLocalized(@"A folder can't be moved into itself");
        return NO;
    }
    if (wq_is_backup_storage_path(source) || wq_is_backup_storage_path([target stringByAppendingPathComponent:name])) {
        if (errorText) *errorText = WQLocalized(@"Backup storage cannot be changed through the file browser.");
        return NO;
    }
    int from = wq_open_directory_flags(sourceParent, O_SEARCH);
    if (from < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    int to = wq_open_directory_flags(target, O_SEARCH);
    if (to < 0) { if (errorText) *errorText = wq_errno(errno); close(from); return NO; }
    const char *n = name.fileSystemRepresentation;
    BOOL changed = NO;
    BOOL ok = wq_rename_checked(from, n, to, n, source, @[sourceParent, target, source], identity, @"moveReady", source, &changed);
    int err = errno;
    if (ok) { fsync(to); fsync(from); }
    close(from);
    close(to);
    wq_log(@"move: %@ -> %@: %@", path, destDir, ok ? @"OK" : changed ? @"changed since it was selected" : wq_errno(err));
    if (!ok && changed) return wq_selection_changed(errorText);
    if (!ok && errorText) {
        *errorText = err == EEXIST ? WQLocalizedFormat(@"An item named \"%@\" is already there", name)
                   : err == EXDEV ? WQLocalized(@"Items can't be moved to another volume")
                   : wq_errno(err);
    }
    return ok;
}

BOOL wq_move(NSString *path, NSString *destDir, NSString **errorText)
{
    return wq_move_expecting(path, destDir, nil, errorText);
}

int wq_open_for_reading(NSString *path)
{
    return wq_open(path, O_RDONLY, 0);
}

// fsgetpath: resolve a filesystem object id to a path. Not in the public SDK.
extern ssize_t fsgetpath(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

// Highest object id in use on the volume, roughly: APFS hands out ids in
// increasing order, so a file created now gets one of the newest. Containers
// of apps installed long after setup sit far above the ids of Apple's own
// apps; a fixed limit misses them on a well-used device.
static const int64_t kWQInodeMargin = 100000;

static int64_t wq_volume_max_inode(fsid_t fsid, int64_t *probeInode)
{
    if (probeInode) *probeInode = 0;
#ifdef WQ_ACCESS_TESTING
    if (wq_test_volume_limit >= 0) return wq_test_volume_limit;
#endif
    NSArray<NSString *> *directories = @[
        NSTemporaryDirectory() ?: @"",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],
        [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] ?: @"",
    ];
    for (NSString *directory in directories) {
        if (!directory.length) continue;
        NSString *probe = [directory stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"wq-inode-%u", arc4random()]];
        int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fd < 0) {
            wq_log(@"inode probe: cannot create %@ (%@)", probe, wq_errno(errno));
            continue;
        }
        struct stat st = {0};
        struct statfs sfs = {0};
        BOOL ok = fstat(fd, &st) == 0 && fstatfs(fd, &sfs) == 0;
        int err = errno;
        close(fd);
        unlink(probe.fileSystemRepresentation);
        if (!ok) {
            wq_log(@"inode probe: cannot inspect %@ (%@)", probe, wq_errno(err));
            continue;
        }
        if (memcmp(&sfs.f_fsid, &fsid, sizeof(fsid)) != 0) {
            wq_log(@"inode probe: %@ is on a different volume", probe);
            continue;
        }
        if ((uint64_t)st.st_ino > (uint64_t)INT64_MAX - (uint64_t)kWQInodeMargin) return 0;
        if (probeInode) *probeInode = (int64_t)st.st_ino;
        return (int64_t)st.st_ino + kWQInodeMargin;
    }
    return 0;
}

// Scans object ids first...last once and collects the direct children of every
// base in `bases` (each a /private/var/... path), as path -> object id. Uses at
// most 4 worker threads (half the cores) at `qos`: a full scan of a well-used
// device is millions of ids, and running it on every core made phones hot.
// progress gets the ids done, the range size and the hits per base. Returns
// one dictionary per base, or nil when cancelled.
typedef void (^WQScanProgress)(int64_t done, int64_t total, const NSUInteger *counts);
static NSArray<NSMutableDictionary<NSString *, NSNumber *> *> *wq_scan_children(fsid_t fsid, int64_t firstId, int64_t lastId,
                                                                               NSArray<NSString *> *bases,
                                                                               WQScanCancellation *cancellation,
                                                                               qos_class_t qos, BOOL allCores,
                                                                               WQScanProgress progress)
{
    NSUInteger baseCount = MIN(bases.count, (NSUInteger)8);
    // Heap tables: blocks can't capture C arrays.
    char **prefixes = calloc(8, sizeof(char *));
    size_t *prefixLens = calloc(8, sizeof(size_t));
    NSUInteger *counts = calloc(8, sizeof(NSUInteger));
    if (!prefixes || !prefixLens || !counts) { free(prefixes); free(prefixLens); free(counts); return nil; }
    NSMutableArray<NSMutableDictionary<NSString *, NSNumber *> *> *found = [NSMutableArray new];
    for (NSUInteger i = 0; i < baseCount; i++) {
        prefixes[i] = strdup(bases[i].fileSystemRepresentation);
        prefixLens[i] = strlen(prefixes[i]);
        [found addObject:[NSMutableDictionary new]];
    }
    if (firstId < 1) firstId = 1;
    int64_t total = lastId >= firstId ? lastId - firstId + 1 : 0;
    NSLock *lock = [NSLock new];
    const int64_t chunk = 32768;
    int64_t chunks = (total + chunk - 1) / chunk;
    __block int64_t nextChunk = 0, done = 0;
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    // A full scan the user agreed to wait for uses all but two cores; the
    // short incremental scans stay at half the cores.
    size_t workers = allCores ? (size_t)MAX((NSUInteger)2, MIN((NSUInteger)8, cores > 2 ? cores - 2 : 1))
                              : (size_t)MAX((NSUInteger)1, MIN((NSUInteger)4, cores / 2));
    dispatch_apply(workers, dispatch_get_global_queue(qos, 0), ^(size_t __unused w) {
        fsid_t id = fsid;
        char buf[1200];
        for (;;) {
            if (cancellation.isCancelled) return;
            [lock lock];
            int64_t c = nextChunk++;
            [lock unlock];
            if (c >= chunks) return;
            int64_t first = firstId + c * chunk, last = MIN(first + chunk - 1, lastId);
            NSMutableDictionary *local[8] = {nil};
            for (int64_t ino = first; ino <= last; ino++) {
                if ((ino & 127) == 0 && cancellation.isCancelled) return;
                ssize_t n = fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino);
                if (n <= 0) continue;
                // fsgetpath returns /private/var/...; bases are normalized the same way.
                for (NSUInteger i = 0; i < baseCount; i++) {
                    if (strncmp(buf, prefixes[i], prefixLens[i]) == 0 && buf[prefixLens[i]] == '/' &&
                        strchr(buf + prefixLens[i] + 1, '/') == NULL) {
                        if (!local[i]) local[i] = [NSMutableDictionary new];
                        local[i][[NSString stringWithUTF8String:buf]] = @(ino);
                        break;
                    }
                }
            }
            NSUInteger snapshot[8] = {0};
            [lock lock];
            for (NSUInteger i = 0; i < baseCount; i++) {
                if (local[i]) [found[i] addEntriesFromDictionary:local[i]];
                snapshot[i] = counts[i] = found[i].count;
            }
            done += last - first + 1;
            int64_t nowDone = done;
            [lock unlock];
            if (progress && !cancellation.isCancelled) progress(nowDone, total, snapshot);
        }
    });
    for (NSUInteger i = 0; i < baseCount; i++) free(prefixes[i]);
    free(prefixes);
    free(prefixLens);
    free(counts);
    if (cancellation.isCancelled) return nil;
    return found;
}

static NSArray<NSString *> *wq_sorted_paths(NSDictionary<NSString *, NSNumber *> *hits)
{
    return [hits.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

static void wq_check_scan_completion(fsid_t fsid, int64_t probeInode, NSString *what)
{
    if (probeInode <= 0) return;
    int64_t afterProbe = 0;
    if (wq_volume_max_inode(fsid, &afterProbe) <= 0 || afterProbe <= 0) {
        // A completion probe failure must not turn a usable partial list
        // into "no apps at all". The initial bound still found what it
        // scanned; callers can refresh later.
        wq_log(@"enumerate %@: completion probe unavailable; returning the scanned subset", what);
    } else if (afterProbe > probeInode + kWQInodeMargin) {
        wq_log(@"enumerate %@: inode IDs advanced beyond the scanned bound; the list may be incomplete until refreshed", what);
    }
}

// The three container parents that can only be listed by scanning. One scan
// collects all three and is reused for a while: the Cache Cleaner alone used to
// scan the whole id range three times (apps, extensions, and the daemon scan
// that finds the app name database).
static NSArray<NSString *> *wq_shared_scan_roots(void)
{
    return @[ @"/private/var/mobile/Containers/Data/Application",
              @"/private/var/mobile/Containers/Data/PluginKitPlugin",
              @"/private/var/mobile/Containers/Data/InternalDaemon" ];
}

#pragma mark - Persistent container scan
//
// APFS hands out object ids in increasing order and never reuses them, so a
// container created after a scan has an id above that scan's probe id. The
// result is kept on disk with the probe id: the next scan only checks the
// ids created since, and confirms each remembered container by resolving
// its id again (gone or moved containers are dropped). A full scan still
// runs once a week, or when the volume or its ids don't match.

static const NSTimeInterval kWQFullScanInterval = 7 * 24 * 3600;
static const NSInteger kWQScanCacheVersion = 1;

static NSString *wq_scan_cache_path(void)
{
#ifdef WQ_ACCESS_TESTING
    return nil;
#else
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return dir.length ? [dir stringByAppendingPathComponent:@"wq-container-scan.plist"] : nil;
#endif
}

static NSDictionary *wq_scan_cache_load(fsid_t fsid, int64_t probeInode, NSTimeInterval now, NSString **whyFull)
{
    NSString *path = wq_scan_cache_path();
    if (!path) return nil;
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![cache isKindOfClass:NSDictionary.class]) { *whyFull = @"no saved scan"; return nil; }
    NSNumber *version = cache[@"version"], *f0 = cache[@"fsid0"], *f1 = cache[@"fsid1"], *probe = cache[@"probe"], *fullAt = cache[@"fullAt"];
    NSDictionary *roots = cache[@"roots"];
    for (id value in @[version ?: NSNull.null, f0 ?: NSNull.null, f1 ?: NSNull.null, probe ?: NSNull.null, fullAt ?: NSNull.null])
        if (![value isKindOfClass:NSNumber.class]) { *whyFull = @"saved scan unreadable"; return nil; }
    if (version.integerValue != kWQScanCacheVersion || ![roots isKindOfClass:NSDictionary.class]) { *whyFull = @"saved scan unreadable"; return nil; }
    if (f0.intValue != fsid.val[0] || f1.intValue != fsid.val[1]) { *whyFull = @"different volume"; return nil; }
    if (probe.longLongValue <= 0 || probe.longLongValue > probeInode) { *whyFull = @"volume ids were reset"; return nil; }
    NSTimeInterval age = now - fullAt.doubleValue;
    if (age < 0 || age >= kWQFullScanInterval) { *whyFull = @"weekly full scan"; return nil; }
    for (NSString *root in wq_shared_scan_roots())
        if (![roots[root] isKindOfClass:NSDictionary.class]) { *whyFull = @"saved scan unreadable"; return nil; }
    return cache;
}

static void wq_scan_cache_save(fsid_t fsid, int64_t probeInode, NSTimeInterval fullAt, NSDictionary *roots)
{
    NSString *path = wq_scan_cache_path();
    if (!path) return;
    NSDictionary *cache = @{ @"version": @(kWQScanCacheVersion), @"fsid0": @(fsid.val[0]), @"fsid1": @(fsid.val[1]),
                             @"probe": @(probeInode), @"fullAt": @(fullAt), @"roots": roots };
    if (![cache writeToFile:path atomically:YES]) wq_log(@"scan: cannot save the container list to %@", path);
}

// Drops remembered containers whose id no longer resolves to the same path.
static NSMutableDictionary<NSString *, NSNumber *> *wq_scan_verify(fsid_t fsid, NSDictionary *remembered, NSUInteger *dropped)
{
    NSMutableDictionary *kept = [NSMutableDictionary new];
    char buf[1200];
    for (NSString *path in remembered) {
        NSNumber *ino = remembered[path];
        if (![path isKindOfClass:NSString.class] || ![ino isKindOfClass:NSNumber.class]) { (*dropped)++; continue; }
        fsid_t id = fsid;
        ssize_t n = fsgetpath(buf, sizeof(buf), &id, ino.unsignedLongLongValue);
        if (n > 0 && strcmp(buf, path.fileSystemRepresentation) == 0) kept[path] = ino;
        else (*dropped)++;
    }
    return kept;
}

// One shared scan runs at a time, detached from the screen that started it:
// leaving the screen no longer throws the work away. Waiters stop waiting when
// cancelled; the scan finishes and is reused by the next caller.
static const NSTimeInterval kWQSharedScanTTL = 600;
static NSObject *gSharedScanGuard;
static void (^gScanProgress)(int64_t, int64_t, NSUInteger);
static NSUInteger gScanProgressIndex;
static id gScanProgressOwner;

static void wq_shared_scan_setup(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSharedScanGuard = [NSObject new]; });
}

static void wq_scan_slots_clear(void);
static void wq_label_caches_invalidate(void);

void wq_enumerate_invalidate(void)
{
    wq_shared_scan_setup();
    @synchronized (gSharedScanGuard) { wq_scan_slots_clear(); }
    wq_label_caches_invalidate();
    // A refresh also retries the background LaunchServices database search.
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WQLaunchServicesDiscoveryMissedAt"];
}


// The first few path components, with UUIDs collapsed, so the Log shows which
// areas are visible without listing individual files.
static NSString *wq_sample_area(NSString *path)
{
    NSArray<NSString *> *parts = path.pathComponents;
    NSMutableArray *kept = [NSMutableArray new];
    for (NSString *part in parts) {
        if (kept.count >= 7) break;
        BOOL uuid = part.length == 36 && [[NSUUID alloc] initWithUUIDString:part] != nil;
        [kept addObject:uuid ? @"*" : part];
        if (uuid && kept.count >= 6) break;
    }
    return [NSString pathWithComponents:kept];
}

// LaunchServices API: each app's and plug-in's data container, where the
// system lets this app ask (it refuses on iOS 27).
// Path -> bundle id caches (this API's and the container manager's) are tied
// to the folder object they were made for: each entry keeps the (device,
// inode) seen when it was recorded, or on its first use when the folder
// couldn't be checked then, and a folder with another identity doesn't get
// the cached id. An explicit refresh drops both caches.
static NSDictionary<NSString *, NSString *> *gLSAPILabels;
static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *gLSAPIIdentities;
static _Atomic NSUInteger gWQLabelGeneration;

typedef NS_ENUM(int, WQLabelIdentity) { WQLabelIdentityUnknown, WQLabelIdentityKnown, WQLabelIdentityGone };

static WQLabelIdentity wq_label_identity(NSString *path, NSArray<NSNumber *> **identity)
{
    *identity = nil;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return errno == ENOENT ? WQLabelIdentityGone : WQLabelIdentityUnknown;
    if (!S_ISDIR(st.st_mode)) return WQLabelIdentityGone;
    *identity = @[@((uint64_t)st.st_dev), @((uint64_t)st.st_ino)];
    return WQLabelIdentityKnown;
}

// Whether a cached id for key may be used for the folder as it is now.
// Caller holds the lock of identities.
static BOOL wq_label_identity_matches(NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *identities, NSString *key,
                                      WQLabelIdentity state, NSArray<NSNumber *> *current)
{
    if (state == WQLabelIdentityGone) return NO;
    if (state == WQLabelIdentityUnknown) return YES;   // can't be checked: as before
    NSArray *recorded = identities[key];
    if (!recorded) { identities[key] = current; return YES; }
    return [recorded isEqualToArray:current];
}

static void wq_label_caches_invalidate(void)
{
    @synchronized (NSNull.null) { gLSAPILabels = nil; gLSAPIIdentities = nil; }
    atomic_fetch_add(&gWQLabelGeneration, 1);
}

static NSDictionary<NSString *, NSArray<NSString *> *> *wq_lsapi_list_containers(NSArray<NSString *> *roots, NSString **summary)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    SEL appsSel = NSSelectorFromString(@"allInstalledApplications");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSel]) { *summary = @"LaunchServices API: unavailable"; return nil; }
    NSMutableDictionary<NSString *, NSString *> *labels = [NSMutableDictionary new];
    NSUInteger proxies = 0, plugins = 0;
    @try {
        id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id workspace = send(workspaceClass, defaultSel);
        if (![workspace respondsToSelector:appsSel]) { *summary = @"LaunchServices API: no application list"; return nil; }
        NSArray *apps = send(workspace, appsSel);
        SEL containerSel = NSSelectorFromString(@"dataContainerURL"), idSel = NSSelectorFromString(@"bundleIdentifier");
        SEL pluginsSel = NSSelectorFromString(@"plugInKitPlugins");
        void (^add)(id) = ^(id proxy) {
            if (![proxy respondsToSelector:containerSel] || ![proxy respondsToSelector:idSel]) return;
            NSURL *url = send(proxy, containerSel);
            NSString *bid = send(proxy, idSel);
            if (![url isKindOfClass:NSURL.class] || ![bid isKindOfClass:NSString.class] || !url.path.length || !bid.length) return;
            NSString *path = wq_norm(url.path);
            if (!labels[path]) labels[path] = bid;
        };
        for (id app in [apps isKindOfClass:NSArray.class] ? apps : @[]) {
            proxies++;
            add(app);
            NSArray *appPlugins = [app respondsToSelector:pluginsSel] ? send(app, pluginsSel) : nil;
            for (id plugin in [appPlugins isKindOfClass:NSArray.class] ? appPlugins : @[]) { plugins++; add(plugin); }
        }
    } @catch (NSException *exception) {
        *summary = [NSString stringWithFormat:@"LaunchServices API: %@", exception.reason];
        return nil;
    }
    NSMutableDictionary<NSString *, NSMutableArray *> *found = [NSMutableDictionary new];
    for (NSString *root in roots) found[root] = [NSMutableArray new];
    for (NSString *path in labels) [found[path.stringByDeletingLastPathComponent] addObject:path];
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *root in roots) result[root] = [found[root] sortedArrayUsingSelector:@selector(compare:)];
    *summary = [NSString stringWithFormat:@"LaunchServices API: %lu apps and %lu plug-ins, %lu data containers (%lu apps, %lu extensions)",
                (unsigned long)proxies, (unsigned long)plugins, (unsigned long)labels.count,
                (unsigned long)[result[roots[0]] count], (unsigned long)[result[roots[1]] count]];
    NSMutableDictionary *identities = [NSMutableDictionary new];
    for (NSString *path in labels) {
        NSArray<NSNumber *> *identity = nil;
        if (wq_label_identity(path, &identity) == WQLabelIdentityKnown) identities[path] = identity;
    }
    @synchronized (NSNull.null) { gLSAPILabels = [labels copy]; gLSAPIIdentities = identities; }
    return result;
}

// The container manager can list containers directly (instant, no scan). On
// releases where it answers this app only with its own containers, the list
// has no other apps and the fsgetpath scan is used instead. Classes are not
// relied on: every class is asked and paths are sorted by their parent.
static NSDictionary<NSString *, NSArray<NSString *> *> *wq_mcm_list_containers(NSArray<NSString *> *roots, NSString **summary)
{
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *found = [NSMutableDictionary new];
    for (NSString *root in roots) found[root] = [NSMutableSet new];
    NSMutableArray *perClass = [NSMutableArray new];
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) { *summary = @"container manager unavailable"; return nil; }
    cq_create_fn create = (cq_create_fn)dlsym(mgr, "container_query_create");
    cq_set_u64_fn setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
    cq_iterate_fn iterate = (cq_iterate_fn)dlsym(mgr, "container_query_iterate_results_sync");
    cq_free_fn freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
    co_get_path_fn getPath = (co_get_path_fn)dlsym(mgr, "container_object_get_path");
    if (!create || !setClass || !iterate || !freeQuery || !getPath) {
        dlclose(mgr);
        *summary = @"container manager query unavailable";
        return nil;
    }
    for (uint64_t cls = 1; cls <= 14; cls++) {
        void *query = create();
        if (!query) continue;
        __block NSUInteger count = 0;
        setClass(query, cls);
        @try {
            iterate(query, ^bool(void *object) {
                const char *path = object ? getPath(object) : NULL;
                if (!path || !path[0]) return true;
                count++;
                NSString *norm = wq_norm([NSString stringWithUTF8String:path] ?: @"");
                NSString *parent = norm.stringByDeletingLastPathComponent;
                [found[parent] addObject:norm];
                return true;
            });
        } @catch (NSException *exception) {
            wq_log(@"scan: container manager class %llu: %@", cls, exception.reason);
        }
        freeQuery(query);
        if (count) [perClass addObject:[NSString stringWithFormat:@"%llu:%lu", cls, (unsigned long)count]];
    }
    dlclose(mgr);
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *root in roots) result[root] = [found[root].allObjects sortedArrayUsingSelector:@selector(compare:)];
    *summary = [NSString stringWithFormat:@"container manager: %lu apps, %lu extensions, %lu daemons (by class %@)",
                (unsigned long)[result[roots[0]] count], (unsigned long)[result[roots[1]] count],
                (unsigned long)[result[roots[2]] count], perClass.count ? [perClass componentsJoinedByString:@" "] : @"none"];
    return result;
}

// Samples ids across the volume. On some releases fsgetpath resolves only the
// caller's own files; then a full scan takes minutes and finds nothing.
static BOOL wq_fsgetpath_sees_others(fsid_t fsid, int64_t maxInode, double *idsPerSecond)
{
    NSMutableArray<NSString *> *own = [NSMutableArray arrayWithObject:wq_norm(NSHomeDirectory())];
    NSString *bundle = wq_norm(NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent);
    if (bundle.length) [own addObject:bundle];
    NSString *group = wq_app_group();
    NSURL *groupURL = group ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
    if (groupURL.path.length) [own addObject:wq_norm(groupURL.path)];
    int64_t stride = MAX((int64_t)1, maxInode / 20000);
    NSUInteger sampled = 0, resolved = 0, foreign = 0;
    NSCountedSet<NSString *> *areas = [NSCountedSet new];
    char buf[1200];
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    for (int64_t ino = 1 + (int64_t)arc4random_uniform((uint32_t)MIN(stride, (int64_t)UINT32_MAX)); ino <= maxInode; ino += stride) {
        sampled++;
        fsid_t id = fsid;
        if (fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino) <= 0) continue;
        resolved++;
        NSString *path = [NSString stringWithUTF8String:buf];
        BOOL mine = NO;
        for (NSString *prefix in own) if ([path hasPrefix:prefix]) { mine = YES; break; }
        if (!mine) {
            foreign++;
            [areas addObject:wq_sample_area(path)];
        }
    }
    wq_log(@"scan: fsgetpath sample: %lu of %lu ids resolve, %lu outside WQ Files (ids up to %lld, %.1f s)",
           (unsigned long)resolved, (unsigned long)sampled, (unsigned long)foreign, (long long)maxInode,
           CFAbsoluteTimeGetCurrent() - started);
    if (areas.count) {
        NSArray *top = [areas.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSUInteger ca = [areas countForObject:a], cb = [areas countForObject:b];
            return ca > cb ? NSOrderedAscending : ca < cb ? NSOrderedDescending : [a compare:b];
        }];
        NSMutableArray *parts = [NSMutableArray new];
        for (NSString *area in [top subarrayWithRange:NSMakeRange(0, MIN(top.count, (NSUInteger)12))])
            [parts addObject:[NSString stringWithFormat:@"%@ x%lu", area, (unsigned long)[areas countForObject:area]]];
        wq_log(@"scan: resolvable areas: %@", [parts componentsJoinedByString:@", "]);
    }
    double elapsed = CFAbsoluteTimeGetCurrent() - started;
    if (idsPerSecond) *idsPerSecond = elapsed > 0 ? sampled / elapsed : 0;
    return foreign > 0;
}

// Full scans (every file id) take minutes on a well-used device. The UI
// confirms them first and shows their progress; without a UI hook (or when
// the app isn't in front) they don't start.
static BOOL (*gFullScanConfirm)(NSString *what, int64_t ids, double seconds);
static void (*gFullScanProgress)(int64_t done, int64_t total, BOOL finished);
static WQScanCancellation *gFullScanStop;
static _Atomic BOOL gFullScanDeclined;

void wq_set_full_scan_ui(BOOL (*confirm)(NSString *what, int64_t ids, double seconds),
                         void (*progress)(int64_t done, int64_t total, BOOL finished))
{
    gFullScanConfirm = confirm;
    gFullScanProgress = progress;
}

void wq_full_scan_stop(void)
{
    @synchronized (NSNull.null) { [gFullScanStop cancel]; }
}

BOOL wq_full_scan_was_declined(void)
{
    return atomic_load(&gFullScanDeclined);
}

// Full scans run one at a time (the App Data and Internal Daemons slots can
// both need one): the stop token, the progress window, its completion and the
// background task belong to a single scan. A second full scan waits here until
// the first has ended, and only then asks.
static dispatch_semaphore_t wq_full_scan_gate(void)
{
    static dispatch_semaphore_t gate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gate = dispatch_semaphore_create(1); });
    return gate;
}

// NO when the caller was cancelled while waiting.
static BOOL wq_full_scan_acquire(NSString *what, WQScanCancellation *caller)
{
    dispatch_semaphore_t gate = wq_full_scan_gate();
    if (dispatch_semaphore_wait(gate, DISPATCH_TIME_NOW) == 0) return YES;
    wq_log(@"scan: full scan of %@ waits for the running one", what);
    while (dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        if (caller.isCancelled) return NO;
    }
    return YES;
}

static void wq_full_scan_release(void)
{
    dispatch_semaphore_signal(wq_full_scan_gate());
}

// Asks before a full scan. Returns the scan's stop token, or nil when the user
// (or the missing UI) declined. A non-nil token holds the full-scan gate until
// wq_full_scan_end.
static WQScanCancellation *wq_full_scan_begin(NSString *what, int64_t ids, double seconds, WQScanCancellation *caller)
{
    // Without an App Group no container can be opened or named, so a long
    // scan would only produce a list of unusable folders.
    if (!wq_app_group()) {
        atomic_store(&gFullScanDeclined, YES);
        wq_log(@"scan: no App Group; full scan of %@ skipped", what);
        return nil;
    }
    if (!wq_full_scan_acquire(what, caller)) return nil;
    if (!gFullScanConfirm || !gFullScanConfirm(what, ids, seconds)) {
        atomic_store(&gFullScanDeclined, YES);
        wq_log(@"scan: full scan of %@ not started (%lld ids, about %.0f s)", what, (long long)ids, seconds);
        wq_full_scan_release();
        return nil;
    }
    atomic_store(&gFullScanDeclined, NO);
    WQScanCancellation *stop = [WQScanCancellation new];
    @synchronized (NSNull.null) { gFullScanStop = stop; }
    return stop;
}

static void wq_full_scan_end(WQScanCancellation *stop)
{
    @synchronized (NSNull.null) { if (gFullScanStop == stop) gFullScanStop = nil; }
    // The window's completion is queued before the next scan can ask.
    if (gFullScanProgress) gFullScanProgress(0, 0, YES);
    if (stop.isCancelled) wq_log(@"scan: full scan stopped");
    wq_full_scan_release();
}

// Rough duration of a full scan from a single-thread sample rate.
static double wq_full_scan_estimate(int64_t ids, double sampleRate)
{
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    double workers = MAX(2.0, MIN(8.0, cores > 2 ? (double)cores - 2 : 1.0));
    double rate = (sampleRate > 0 ? sampleRate : 15000.0) * workers * 0.8;
    return ids / rate;
}

static NSArray<NSString *> *(*gContainerListProvider)(NSString *storeHint);

void wq_set_container_list_provider(NSArray<NSString *> *(*provider)(NSString *storeHint))
{
    gContainerListProvider = provider;
}

static BOOL wq_is_ls_store_name(const char *path)
{
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    size_t len = strlen(name);
    return len > 33 && strncmp(name, "com.apple.LaunchServices-", 25) == 0 && strcmp(name + len - 8, ".csstore") == 0;
}

// The LaunchServices database is rewritten on every app install or update, so
// its id is among the newest: scan down from the top and stop at the first.
static const CFTimeInterval kWQStoreSearchLimit = 20;

static NSString *wq_scan_for_ls_store(fsid_t fsid, int64_t maxInode, qos_class_t qos, WQScanProgress progress)
{
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    const int64_t chunk = 32768;
    int64_t chunks = (maxInode + chunk - 1) / chunk;
    __block int64_t nextChunk = 0, done = 0;
    __block NSString *found = nil;
    NSLock *lock = [NSLock new];
    WQScanCancellation *stop = [WQScanCancellation new];
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    size_t workers = (size_t)MAX((NSUInteger)1, MIN((NSUInteger)4, cores / 2));
    dispatch_apply(workers, dispatch_get_global_queue(qos, 0), ^(size_t __unused w) {
        fsid_t id = fsid;
        char buf[1200];
        NSUInteger none[8] = {0};
        for (;;) {
            if (stop.isCancelled) return;
            [lock lock];
            int64_t c = nextChunk++;
            [lock unlock];
            if (c >= chunks) return;
            // Normally found among the newest ids within seconds; past the
            // limit the full scan is the better way (and asks first).
            if (CFAbsoluteTimeGetCurrent() - started > kWQStoreSearchLimit) { [stop cancel]; return; }
            int64_t last = maxInode - c * chunk, first = MAX((int64_t)1, last - chunk + 1);
            for (int64_t ino = last; ino >= first; ino--) {
                if ((ino & 127) == 0 && stop.isCancelled) return;
                if (fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino) <= 0 || !wq_is_ls_store_name(buf)) continue;
                [lock lock];
                if (!found) found = [NSString stringWithUTF8String:buf];
                [lock unlock];
                [stop cancel];
                return;
            }
            [lock lock];
            done += last - first + 1;
            int64_t nowDone = done;
            [lock unlock];
            if (progress && !stop.isCancelled) progress(nowDone, maxInode, none);
        }
    });
    return found;
}

// When the container manager lists the containers, the database search in
// wq_containers_from_ls_store doesn't run, yet the name loader only reads a
// remembered database: look for it in the background (the same bounded id
// search), so app names and labels don't stay missing after a cold start.
// One search at a time; after a miss, again only after a day or a refresh.
static NSString *const kWQStoreDiscoveryMissKey = @"WQLaunchServicesDiscoveryMissedAt";
static _Atomic BOOL gStoreDiscoveryRunning;

static void wq_discover_ls_store_in_background(fsid_t fsid)
{
    if (!gContainerListProvider) return;
    NSDate *missed = [NSUserDefaults.standardUserDefaults objectForKey:kWQStoreDiscoveryMissKey];
    if ([missed isKindOfClass:NSDate.class] && fabs(missed.timeIntervalSinceNow) < 24 * 60 * 60) return;
    if (atomic_exchange(&gStoreDiscoveryRunning, YES)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            if (gContainerListProvider(nil).count >= 2) return;   // remembered and readable
            int64_t probeInode = 0;
            int64_t maxInode = wq_volume_max_inode(fsid, &probeInode);
            NSString *store = maxInode > 0 ? wq_scan_for_ls_store(fsid, maxInode, QOS_CLASS_UTILITY, nil) : nil;
            NSUInteger listed = store ? gContainerListProvider(store).count : 0;
            if (listed < 2) {
                [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:kWQStoreDiscoveryMissKey];
                wq_log(@"scan: LaunchServices database for app names %@", store ? @"found but not usable" : @"not found by id");
            } else {
                wq_log(@"scan: LaunchServices database for app names found by id (%lu containers)", (unsigned long)listed);
            }
        } @finally {
            atomic_store(&gStoreDiscoveryRunning, NO);
        }
    });
}

// The LaunchServices database keeps containers of earlier installs that no
// longer exist. Drop those (lstat says ENOENT even without access); keep
// anything that exists or can't be checked.
static NSArray<NSString *> *wq_existing_containers(NSArray<NSString *> *paths, NSUInteger *dropped)
{
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:paths.count];
    struct stat st;
    for (NSString *path in paths) {
        if (lstat(path.fileSystemRepresentation, &st) != 0 && errno == ENOENT) { (*dropped)++; continue; }
        [kept addObject:path];
    }
    return kept;
}

// The App Data and Extensions lists from the LaunchServices database.
static NSDictionary<NSString *, NSArray<NSString *> *> *wq_containers_from_ls_store(NSArray<NSString *> *roots, fsid_t fsid,
                                                                                   qos_class_t qos, WQScanProgress progress)
{
    if (!gContainerListProvider) return nil;
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSArray<NSString *> *paths = gContainerListProvider(nil);
    NSString *how = @"remembered location";
    if (paths.count < 2) {
        int64_t probeInode = 0;
        int64_t maxInode = wq_volume_max_inode(fsid, &probeInode);
        if (maxInode <= 0) return nil;
        NSString *store = wq_scan_for_ls_store(fsid, maxInode, qos, progress);
        if (!store) {
            wq_log(@"scan: no LaunchServices database found by id (%.1f s)", CFAbsoluteTimeGetCurrent() - started);
            return nil;
        }
        paths = gContainerListProvider(store);
        how = [NSString stringWithFormat:@"found by id in %.1f s", CFAbsoluteTimeGetCurrent() - started];
        if (paths.count < 2) {
            wq_log(@"scan: the LaunchServices database at %@ couldn't be read or lists no containers", store);
            return nil;
        }
    }
    NSUInteger stale = 0;
    NSMutableArray *normalized = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) [normalized addObject:wq_norm(path)];
    paths = wq_existing_containers(normalized, &stale);
    if (stale) wq_log(@"scan: %lu containers in the LaunchServices database no longer exist (earlier installs); skipped", (unsigned long)stale);
    NSMutableDictionary<NSString *, NSMutableArray *> *byRoot = [NSMutableDictionary new];
    for (NSString *root in roots) byRoot[root] = [NSMutableArray new];
    for (NSString *path in paths) [byRoot[path.stringByDeletingLastPathComponent] addObject:path];
    if ([byRoot[roots[0]] count] < 2) return nil;
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *root in roots) result[root] = [byRoot[root] sortedArrayUsingSelector:@selector(compare:)];
    wq_log(@"scan: %lu apps, %lu extensions from the LaunchServices database (%@); daemon containers aren't listed there",
           (unsigned long)[result[roots[0]] count], (unsigned long)[result[roots[1]] count], how);
    return result;
}


// inodeOnly: skip the container manager and LaunchServices shortcuts and scan
// ids (iOS 26 Internal Daemons, which no database lists).
static NSDictionary<NSString *, NSArray<NSString *> *> *wq_run_shared_scan(fsid_t fsid, qos_class_t qos, BOOL inodeOnly)
{
    NSArray<NSString *> *roots = wq_shared_scan_roots();
    atomic_store(&gFullScanDeclined, NO);
    if (inodeOnly) goto inodeScan;
    {
    NSString *mcmSummary = nil;
    NSDictionary<NSString *, NSArray<NSString *> *> *listed = wq_mcm_list_containers(roots, &mcmSummary);
    wq_log(@"scan: %@", mcmSummary);
    // Other apps' containers listed: no scan needed. A list with only this
    // app's own container is not enough.
    if ([listed[roots[0]] count] > 1) {
        wq_discover_ls_store_in_background(fsid);
        return listed;
    }
    NSString *lsSummary = nil;
    NSDictionary<NSString *, NSArray<NSString *> *> *lsListed = wq_lsapi_list_containers(roots, &lsSummary);
    wq_log(@"scan: %@", lsSummary);
    if (!wq_system_areas_reachable() && [lsListed[roots[0]] count] > 1) {
        // The API doesn't list daemon containers; those still need the scan
        // on releases where it works, so only skip it when apps are covered.
        NSMutableDictionary *merged = [lsListed mutableCopy];
        if (![merged[roots[2]] count]) merged[roots[2]] = @[];
        return merged;
    }
    {
        // A full scan is tens of millions of ids (minutes, up to most of an
        // hour); the database lists the same app and extension containers.
        WQScanProgress report = ^(int64_t done, int64_t total, const NSUInteger *__unused counts) {
            void (^progress)(int64_t, int64_t, NSUInteger) = nil;
            @synchronized (gSharedScanGuard) { progress = gScanProgress; }
            if (progress) progress(done, total, 0);
        };
        NSDictionary *fromStore = wq_containers_from_ls_store(roots, fsid, qos, report);
        if (fromStore) return fromStore;
    }
    }
inodeScan:;
    int64_t probeInode = 0;
    int64_t maxInode = wq_volume_max_inode(fsid, &probeInode);
    if (maxInode <= 0) {
        wq_log(@"enumerate containers: dynamic inode limit unavailable; refusing to present a fixed-range partial scan as complete");
        return nil;
    }
    if (maxInode > INT64_MAX - 32768) {
        wq_log(@"enumerate containers: inode bound is too large to scan safely");
        return nil;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *whyFull = nil;
    NSDictionary *cache = wq_scan_cache_load(fsid, probeInode, now, &whyFull);
    int64_t firstId = 1;
    NSTimeInterval fullAt = now;
    NSUInteger dropped = 0;
    NSMutableArray<NSMutableDictionary<NSString *, NSNumber *> *> *known = [NSMutableArray new];
    for (NSString *root in roots) {
        [known addObject:cache ? wq_scan_verify(fsid, cache[@"roots"][root], &dropped) : [NSMutableDictionary new]];
    }
    if (cache) {
        firstId = [cache[@"probe"] longLongValue] + 1;
        fullAt = [cache[@"fullAt"] doubleValue];
    }
    double sampleRate = 0;
    // A remembered scan whose app containers all vanished (for example after
    // an iOS update that stopped fsgetpath resolving other apps' ids) must
    // not quietly become an empty list: check again whether scanning works.
    if (cache && ![known[0] count]) {
        wq_log(@"scan: none of the remembered app containers resolve anymore (%lu dropped); checking whether ids still resolve", (unsigned long)dropped);
        if (!wq_fsgetpath_sees_others(fsid, maxInode, &sampleRate)) {
            wq_log(@"scan: on this iOS version fsgetpath only resolves WQ Files' own files, so containers can't be found by scanning");
            return nil;
        }
    }
    if (!cache && !wq_fsgetpath_sees_others(fsid, maxInode, &sampleRate)) {
        wq_log(@"scan: on this iOS version fsgetpath only resolves WQ Files' own files, so containers can't be found by scanning");
        return nil;
    }
    WQScanCancellation *stop = nil;
    if (!cache) {
        stop = wq_full_scan_begin(inodeOnly ? WQLocalized(@"Internal Daemons") : WQLocalized(@"the app folders"), maxInode,
                                  wq_full_scan_estimate(maxInode, sampleRate), nil);
        if (!stop) return nil;
        qos = QOS_CLASS_USER_INITIATED;
    }
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    WQScanProgress report = ^(int64_t done, int64_t total, const NSUInteger *counts) {
        void (^progress)(int64_t, int64_t, NSUInteger) = nil;
        NSUInteger index = 0;
        @synchronized (gSharedScanGuard) { progress = gScanProgress; index = gScanProgressIndex; }
        if (progress) progress(done, total, (index < roots.count ? known[index].count : 0) + (index < 8 ? counts[index] : 0));
        if (stop && gFullScanProgress) gFullScanProgress(done, total, NO);
    };
    NSArray *lists = wq_scan_children(fsid, firstId, maxInode, roots, stop, qos, stop != nil, report);
    if (stop) wq_full_scan_end(stop);
    if (!lists) return nil;
    NSMutableDictionary *saved = [NSMutableDictionary new];
    NSMutableDictionary *scan = [NSMutableDictionary new];
    for (NSUInteger i = 0; i < roots.count; i++) {
        [known[i] addEntriesFromDictionary:lists[i]];
        saved[roots[i]] = known[i];
        scan[roots[i]] = wq_sorted_paths(known[i]);
    }
    double seconds = CFAbsoluteTimeGetCurrent() - started;
    int64_t ids = maxInode >= firstId ? maxInode - firstId + 1 : 0;
    wq_log(@"scan: %@ ids %lld-%lld (%lld ids) in %.1f s (%.0f ids/s, %@); %lu apps, %lu extensions, %lu daemons%@",
           cache ? @"new" : [NSString stringWithFormat:@"full (%@)", whyFull ?: @"no saved scan"],
           (long long)firstId, (long long)maxInode, (long long)ids, seconds, seconds > 0 ? ids / seconds : 0,
           qos == QOS_CLASS_USER_INITIATED ? @"foreground" : @"background",
           (unsigned long)known[0].count, (unsigned long)known[1].count, (unsigned long)known[2].count,
           dropped ? [NSString stringWithFormat:@"; %lu removed since the last scan", (unsigned long)dropped] : @"");
    wq_check_scan_completion(fsid, probeInode, @"containers");
    wq_scan_cache_save(fsid, probeInode, fullAt, saved);
    return scan;
}

// One scan per slot runs at a time. On iOS 26 the Internal Daemons id scan
// (most of an hour the first time) has its own slot, so the lists that come
// from the LaunchServices database never wait for it.
// generation: bumped by wq_enumerate_invalidate. A worker publishes into the
// slot only when the generation it started with is still current; callers
// after an invalidation start a new worker, which first waits for the
// detached one (previous) so the two never scan at the same time.
@interface WQScanSlot : NSObject
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *scan;
@property (nonatomic) NSTimeInterval at;
@property (nonatomic, strong) dispatch_group_t group;
@property (nonatomic, strong) NSMutableDictionary *box;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, strong) dispatch_group_t previous;
@end
@implementation WQScanSlot
@end

static WQScanSlot *wq_scan_slot(BOOL inode)
{
    static WQScanSlot *slots[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ slots[0] = [WQScanSlot new]; slots[1] = [WQScanSlot new]; });
    return slots[inode ? 1 : 0];
}

static void wq_scan_slots_clear(void)
{
    for (int i = 0; i < 2; i++) {
        WQScanSlot *slot = wq_scan_slot(i == 1);
        slot.scan = nil;
        slot.at = 0;
        slot.generation++;
        // A running worker keeps its own waiters but no longer serves new
        // callers or fills the slot.
        if (slot.group) {
            slot.previous = slot.group;
            slot.group = nil;
            slot.box = nil;
        }
    }
}

static NSArray<NSString *> *wq_shared_children(NSString *base, fsid_t fsid, WQScanCancellation *cancellation,
                                               void (^progress)(int64_t, int64_t, NSUInteger))
{
    wq_shared_scan_setup();
    NSUInteger baseIndex = [wq_shared_scan_roots() indexOfObject:base];
    // iOS 26 lists apps and extensions from the LaunchServices database; only
    // Internal Daemons need the (long) id scan.
    BOOL inodeOnly = [base isEqualToString:@"/private/var/mobile/Containers/Data/InternalDaemon"];
    WQScanSlot *slot = wq_scan_slot(inodeOnly);
    id owner = [NSObject new];
    dispatch_group_t group = nil;
    NSMutableDictionary *box = nil;
    @synchronized (gSharedScanGuard) {
        if (slot.scan && NSDate.date.timeIntervalSinceReferenceDate - slot.at < kWQSharedScanTTL) {
            NSArray *cached = slot.scan[base];
            if (progress) progress(1, 1, cached.count);
            return cached;
        }
        if (progress) {
            gScanProgress = [progress copy];
            gScanProgressIndex = baseIndex;
            gScanProgressOwner = owner;
        }
        if (!slot.group) {
            // A screen waiting for the result gets foreground priority; the
            // worker count stays at half the cores either way.
            qos_class_t qos = progress ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY;
            dispatch_group_t started = dispatch_group_create();
            NSMutableDictionary *startedBox = [NSMutableDictionary new];
            NSUInteger generation = slot.generation;
            dispatch_group_t previous = slot.previous;
            slot.previous = nil;
            slot.group = started;
            slot.box = startedBox;
            dispatch_group_enter(started);
            dispatch_async(dispatch_get_global_queue(qos, 0), ^{
                // A worker detached by an invalidation finishes first.
                if (previous) dispatch_group_wait(previous, DISPATCH_TIME_FOREVER);
                NSDictionary *scan = nil;
                @try {
#ifdef WQ_ACCESS_TESTING
                    if (wq_test_shared_scan_runner) scan = wq_test_shared_scan_runner(inodeOnly);
                    else
#endif
                    scan = wq_run_shared_scan(fsid, qos, inodeOnly);
                } @catch (NSException *exception) {
                    wq_log(@"scan: exception %@", exception.reason);
                }
                @synchronized (gSharedScanGuard) {
                    if (scan) {
                        startedBox[@"scan"] = scan;   // its own waiters asked before any invalidation
                        if (slot.generation == generation) {
                            slot.scan = scan;
                            slot.at = NSDate.date.timeIntervalSinceReferenceDate;
                        } else {
                            wq_log(@"scan: result started before a refresh not kept");
                        }
                    }
                    if (slot.group == started) {
                        slot.group = nil;
                        slot.box = nil;
                    }
                }
                dispatch_group_leave(started);
            });
        }
        group = slot.group;
        box = slot.box;
    }
    BOOL cancelled = NO;
    while (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        if (cancellation.isCancelled) { cancelled = YES; break; }
    }
    NSArray<NSString *> *result = nil;
    @synchronized (gSharedScanGuard) {
        if (gScanProgressOwner == owner) { gScanProgress = nil; gScanProgressOwner = nil; }
        if (!cancelled) result = box[@"scan"][base];
    }
    return result;
}

NSArray<NSString *> *wq_enumerate(NSString *dir, int64_t maxInode, WQScanCancellation *cancellation,
                                  void (^progress)(int64_t, int64_t, NSUInteger))
{
    if (cancellation.isCancelled) return nil;
    NSString *base = wq_norm(dir);  // /private/var/... form
    struct stat baseStat = {0};
    int baseError = lstat(base.fileSystemRepresentation, &baseStat);
    if (baseError == 0 && !S_ISDIR(baseStat.st_mode)) {
        wq_log(@"enumerate %@: base is not a directory", dir);
        return nil;
    }
    if (baseError != 0 && errno != EACCES && errno != EPERM) {
        wq_log(@"enumerate %@: base is missing (%@)", dir, wq_errno(errno));
        return nil;
    }
    struct statfs sfs;
    if (statfs(base.fileSystemRepresentation, &sfs) != 0) {
        // The container parent may not even be stat-able without a token. In
        // that case fall back to the data volume's fsid and let fsgetpath do
        // the work; a denied parent is not the same thing as a missing parent.
        if (statfs("/private/var/mobile", &sfs) != 0) {
            wq_log(@"enumerate %@: statfs failed (%@)", dir, wq_errno(errno));
            return nil;
        }
    }
    fsid_t fsid = sfs.f_fsid;
    BOOL dynamicBound = maxInode <= 0;
    if (dynamicBound && [wq_shared_scan_roots() containsObject:base])
        return wq_shared_children(base, fsid, cancellation, progress);
    // iOS 26: a full scan takes about 40 minutes; the LaunchServices database
    // lists the group containers of installed apps.
    if (dynamicBound && !wq_system_areas_reachable() && gContainerListProvider &&
        [base isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup"]) {
        NSArray<NSString *> *all = gContainerListProvider(nil);
        if (all.count) {
            NSMutableArray *groups = [NSMutableArray new];
            for (NSString *path in all)
                if ([wq_norm(path).stringByDeletingLastPathComponent isEqualToString:base]) [groups addObject:wq_norm(path)];
            NSUInteger stale = 0;
            groups = [wq_existing_containers(groups, &stale) mutableCopy];
            [groups sortUsingSelector:@selector(compare:)];
            wq_log(@"enumerate %@: %lu group containers from the LaunchServices database%@", dir, (unsigned long)groups.count,
                   stale ? [NSString stringWithFormat:@" (%lu no longer exist, skipped)", (unsigned long)stale] : @"");
            if (progress) progress(1, 1, groups.count);
            return groups;
        }
    }
    int64_t probeInode = 0;
    if (dynamicBound) {
        maxInode = wq_volume_max_inode(fsid, &probeInode);
        if (maxInode <= 0) {
            wq_log(@"enumerate %@: dynamic inode limit unavailable; refusing to present a fixed-range partial scan as complete", dir);
            return nil;
        }
    }
    if (maxInode > INT64_MAX - 32768) {
        wq_log(@"enumerate %@: inode bound is too large to scan safely", dir);
        return nil;
    }
    WQScanCancellation *stop = nil;
    if (dynamicBound) {
        stop = wq_full_scan_begin(base.lastPathComponent, maxInode, wq_full_scan_estimate(maxInode, 0), cancellation);
        if (!stop) return nil;
    }
    // Either the caller's cancellation or the scan window's Stop ends it.
    WQScanCancellation *either = stop ?: cancellation;
    if (stop && cancellation) {
        either = [WQScanCancellation new];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (!either.isCancelled) {
                if (stop.isCancelled || cancellation.isCancelled) { [either cancel]; break; }
                usleep(200000);
            }
        });
    }
    NSArray *lists = wq_scan_children(fsid, 1, maxInode, @[base], either, QOS_CLASS_USER_INITIATED, stop != nil,
        ^(int64_t done, int64_t total, const NSUInteger *counts) {
            if (progress) progress(done, total, counts[0]);
            if (stop && gFullScanProgress) gFullScanProgress(done, total, NO);
        });
    if (stop) { wq_full_scan_end(stop); [either cancel]; }
    if (!lists) return nil;
    if (dynamicBound) wq_check_scan_completion(fsid, probeInode, dir);
    return wq_sorted_paths(lists.firstObject);
}

BOOL wq_stat(NSString *path, struct stat *st)
{
    if (lstat(path.fileSystemRepresentation, st) == 0) return YES;
    if (!wq_is_denied(errno)) return NO;
    if (wq_grant(path.stringByDeletingLastPathComponent) && lstat(path.fileSystemRepresentation, st) == 0) return YES;
    return NO;
}

WQMeasureResult wq_measure_tree(NSString *dir, WQScanCancellation *cancellation, unsigned long long *bytes)
{
    if (cancellation.isCancelled) return WQMeasureResultCancelled;
    struct stat st = {0};
    if (!wq_stat(dir, &st)) {
        struct stat direct = {0};
        if (lstat(dir.fileSystemRepresentation, &direct) != 0 &&
            (errno == ENOENT || errno == ENOTDIR)) return WQMeasureResultMissing;
        return WQMeasureResultLimited;
    }
    if (!S_ISDIR(st.st_mode)) return WQMeasureResultLimited;
    if (![NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) wq_grant(dir);

    NSURL *root = [NSURL fileURLWithPath:dir isDirectory:YES];
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey,
                                       NSURLFileSizeKey, NSURLIsDirectoryKey];
    __block BOOL limited = NO;
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:root includingPropertiesForKeys:keys options:0
           errorHandler:^BOOL(NSURL *errorURL, NSError *error) {
        limited = YES;
        wq_log(@"measure: cannot enumerate %@ (%@)", errorURL.path, error.localizedDescription ?: @"unknown error");
        return YES;
    }];
    if (!enumerator) return WQMeasureResultLimited;

    unsigned long long total = 0;
    for (NSURL *item in enumerator) {
        if (cancellation.isCancelled) return WQMeasureResultCancelled;
        NSNumber *isLink = nil, *isRegular = nil, *size = nil;
        NSError *error = nil;
        if (![item getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:&error] ||
            ![item getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:&error]) {
            limited = YES;
            continue;
        }
        if (isLink.boolValue || !isRegular.boolValue) continue;
        if (![item getResourceValue:&size forKey:NSURLFileSizeKey error:&error]) {
            limited = YES;
            continue;
        }
        total += size.unsignedLongLongValue;
    }
    if (cancellation.isCancelled) return WQMeasureResultCancelled;
    if (bytes) *bytes = total;
    return limited ? WQMeasureResultLimited : WQMeasureResultKnown;
}

static BOOL wq_directory_current(NSString *path, int fd)
{
    int current = WQOpenDirectoryNoLinksFlags(path, O_SEARCH);
    struct stat a, b;
    BOOL ok = current >= 0 && fstat(current, &a) == 0 && fstat(fd, &b) == 0 && WQSameObject(&a, &b);
    if (current >= 0) close(current);
    return ok;
}

static BOOL wq_remove_entry(int parent, NSString *name, NSString *path, unsigned long long *freed,
                            WQScanCancellation *cancellation);

// Purge uses fd-relative removal, so the path is only a swap detector. One
// lstat is enough; reopening every ancestor for every child is needlessly
// expensive on large caches.
static BOOL wq_purge_root_matches(NSString *path, int fd)
{
    struct stat pathStat, fdStat;
    return lstat(path.fileSystemRepresentation, &pathStat) == 0 &&
           fstat(fd, &fdStat) == 0 && WQSameObject(&pathStat, &fdStat);
}

static BOOL wq_purge_fd(int fd, NSString *path, unsigned long long *freed, WQScanCancellation *cancellation)
{
    int listing = dup(fd);
    if (listing < 0) return NO;
    DIR *dir = fdopendir(listing);
    if (!dir) { close(listing); return NO; }
    BOOL ok = YES;
    for (;;) {
        if (cancellation.isCancelled) { ok = NO; break; }
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) ok = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) { ok = NO; break; }
        WQ_TREE_HOOK(@"purgeChild", path);
        // Fail closed on changed ancestry; all removal remains fd-relative even
        // in the final race window. Symlink children are unlinked, never followed.
        if (!wq_purge_root_matches(path, fd)) { ok = NO; break; }
        if (!wq_remove_entry(fd, name, [path stringByAppendingPathComponent:name], freed, cancellation)) ok = NO;
    }
    if (closedir(dir) != 0) ok = NO;
    return ok;
}

static BOOL wq_remove_entry(int parent, NSString *name, NSString *path, unsigned long long *freed,
                            WQScanCancellation *cancellation)
{
    if (cancellation.isCancelled) return NO;
    const char *item = name.fileSystemRepresentation;
    struct stat before, current;
    if (fstatat(parent, item, &before, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT;
    BOOL directory = S_ISDIR(before.st_mode);
    if (directory) {
        int child = openat(parent, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (child < 0 && wq_is_denied(errno) && wq_grant(path))
            child = openat(parent, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (child < 0) return NO;
        BOOL ok = fstat(child, &current) == 0 && WQSameObject(&before, &current) &&
            wq_purge_root_matches(path, child) && wq_purge_fd(child, path, freed, cancellation);
        close(child);
        if (!ok) return NO;
    }
    if (fstatat(parent, item, &current, AT_SYMLINK_NOFOLLOW) != 0 || !WQSameObject(&before, &current) ||
        (current.st_mode & S_IFMT) != (before.st_mode & S_IFMT)) return NO;
    int rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
    if (rc != 0 && wq_is_denied(errno) && wq_grant(path.stringByDeletingLastPathComponent)) {
        if (fstatat(parent, item, &current, AT_SYMLINK_NOFOLLOW) != 0 || !WQSameObject(&before, &current)) return NO;
        rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
    }
    // A user-immutable or append-only flag (on the item or its folder) makes
    // unlink fail with EPERM even for the owner. The owner may clear those
    // flags, so clear them and try once more. System flags stay untouched.
    if (rc != 0 && errno == EPERM &&
        fstatat(parent, item, &current, AT_SYMLINK_NOFOLLOW) == 0 && WQSameObject(&before, &current)) {
        const uint32_t userLocks = UF_IMMUTABLE | UF_APPEND;
        struct stat parentStat = {0};
        BOOL cleared = NO;
        if (fstat(parent, &parentStat) == 0 && (parentStat.st_flags & userLocks))
            cleared = fchflags(parent, parentStat.st_flags & ~userLocks) == 0;
        if ((current.st_flags & userLocks) && !S_ISLNK(current.st_mode)) {
            int flagsFd = openat(parent, item, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC |
                                 (directory ? O_DIRECTORY : 0));
            struct stat opened;
            if (flagsFd >= 0 && fstat(flagsFd, &opened) == 0 && WQSameObject(&before, &opened) &&
                fchflags(flagsFd, opened.st_flags & ~userLocks) == 0) cleared = YES;
            if (flagsFd >= 0) close(flagsFd);
        }
        if (cleared) {
            wq_log(@"purge: cleared lock flags (item 0x%x, folder 0x%x) on %@",
                   current.st_flags, parentStat.st_flags, path);
            rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
        } else {
            errno = EPERM;
        }
    }
    if (rc == 0 && !directory && freed) *freed += (unsigned long long)before.st_size;
    if (rc != 0) {
        int err = errno;
        wq_log(@"purge: %@ -> %@ (flags 0x%x, uid %u, mode %o)", path, wq_errno(err),
               current.st_flags, current.st_uid, current.st_mode & 07777);
    }
    return rc == 0;
}

BOOL wq_purge_contents_cancellable(NSString *dir, unsigned long long *freed, WQScanCancellation *cancellation)
{
    if (cancellation.isCancelled) return NO;
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(dir))) return NO;
    int fd = wq_open_directory(dir);
    if (fd < 0) {
        if (errno == ENOENT) return YES;
        wq_log(@"purge: %@ -> unsafe ancestry or inaccessible (%@)", dir, wq_errno(errno));
        return NO;
    }
    BOOL ok = wq_purge_fd(fd, dir, freed, cancellation);
    close(fd);
    return ok;
}

BOOL wq_purge_contents(NSString *dir, unsigned long long *freed)
{
    return wq_purge_contents_cancellable(dir, freed, nil);
}

// Flush a completed staging tree without following any links or opening special
// files. This does not claim to snapshot a concurrently changing source tree.
static BOOL wq_sync_entry(int parent, NSString *name)
{
    struct stat st;
    if (fstatat(parent, name.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW) != 0) return NO;
    if (S_ISLNK(st.st_mode)) return YES;
    if (S_ISREG(st.st_mode)) {
        int fd = WQOpenRegularAt(parent, name.fileSystemRepresentation, O_RDONLY, 0);
        if (fd < 0) return NO;
        struct stat current;
        BOOL ok = fstat(fd, &current) == 0 && WQSameObject(&st, &current) && fsync(fd) == 0;
        close(fd); return ok;
    }
    if (!S_ISDIR(st.st_mode)) { errno = EINVAL; return NO; }
    int fd = openat(parent, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NO;
    int listing = dup(fd);
    DIR *dir = listing >= 0 ? fdopendir(listing) : NULL;
    if (!dir) { if (listing >= 0) close(listing); close(fd); return NO; }
    BOOL ok = YES;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) ok = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *child = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!child || !wq_sync_entry(fd, child)) { ok = NO; break; }
    }
    if (closedir(dir) != 0) ok = NO;
    if (ok && fsync(fd) != 0) ok = NO;
    close(fd);
    return ok;
}

// Sockets, FIFOs and device files can't be copied (NSFileManager fails the
// whole tree with "couldn't be copied", ENOTSUP) and hold no data: apps leave
// sockets in tmp and Library. They show as 0 KB files (issue #48). The copy
// leaves them out; every other error still stops it.
@interface WQSkipSpecialFiles : NSObject <NSFileManagerDelegate>
@property (nonatomic) NSUInteger skipped;
@end

static BOOL wq_is_special_file(NSString *path)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return NO;
    return S_ISSOCK(st.st_mode) || S_ISFIFO(st.st_mode) || S_ISCHR(st.st_mode) || S_ISBLK(st.st_mode);
}

@implementation WQSkipSpecialFiles
- (BOOL)fileManager:(NSFileManager *)fm shouldProceedAfterError:(NSError *)error
  copyingItemAtPath:(NSString *)src toPath:(NSString *)dst
{
    (void)fm; (void)error; (void)dst;
    if (!wq_is_special_file(src)) return NO;
    self.skipped++;
    return YES;
}
@end

// `replace`: a same-named destination item is swapped out (restore callers);
// otherwise installation is RENAME_EXCL and such an item fails the copy.
static BOOL wq_copy_contents_mode(NSString *srcDir, NSString *dstDir, BOOL replace,
                                  BOOL (^cancelled)(void), NSString **errorText)
{
    srcDir = WQCanonicalVarPath(srcDir);
    dstDir = WQCanonicalVarPath(dstDir);
    if (!WQAbsolutePathGrammar(srcDir) || !WQAbsolutePathGrammar(dstDir) || [srcDir isEqual:dstDir] ||
        [srcDir hasPrefix:[dstDir stringByAppendingString:@"/"]] || [dstDir hasPrefix:[srcDir stringByAppendingString:@"/"]]) {
        if (errorText) *errorText = WQLocalized(@"Source and destination trees overlap or have invalid paths");
        return NO;
    }
    NSFileManager *fm = [NSFileManager new];
    WQSkipSpecialFiles *skipper = [WQSkipSpecialFiles new];
    fm.delegate = skipper;
    int source = wq_open_directory(srcDir);
    if (source < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    int destination = WQCreateDirectoriesNoLinksMode(dstDir, 0755);
    if (destination < 0 && wq_is_denied(errno) && wq_grant(dstDir.stringByDeletingLastPathComponent))
        destination = WQCreateDirectoriesNoLinksMode(dstDir, 0755);
    struct stat srcStat, dstStat;
    if (destination < 0 || fstat(source, &srcStat) != 0 || fstat(destination, &dstStat) != 0 || WQSameObject(&srcStat, &dstStat)) {
        if (errorText) *errorText = WQLocalized(@"Cannot safely open distinct source and destination folders");
        close(source); if (destination >= 0) close(destination); return NO;
    }
    NSError *error = nil;
    NSArray *children = [fm contentsOfDirectoryAtPath:srcDir error:&error];
    if (!children) {
        if (errorText) *errorText = error.localizedDescription ?: WQLocalized(@"Cannot read the source folder");
        close(source); close(destination); return NO;
    }
    BOOL allOk = YES;
    NSString *firstFailure = nil;
    for (NSString *name in children) {
        if (cancelled && cancelled()) { allOk = NO; firstFailure = firstFailure ?: @"Cancelled"; break; }
        if (!wq_directory_current(srcDir, source) || !wq_directory_current(dstDir, destination)) {
            allOk = NO; firstFailure = firstFailure ?: WQLocalized(@"A copy root changed during copying"); break;
        }
        NSString *src = [srcDir stringByAppendingPathComponent:name];
        NSString *dst = [dstDir stringByAppendingPathComponent:name];
        if (wq_is_special_file(src)) { skipper.skipped++; continue; }
        NSString *stageName = [@".wq-copy-stage-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *stagePath = [dstDir stringByAppendingPathComponent:stageName];
        if (mkdirat(destination, stageName.fileSystemRepresentation, 0700) != 0) {
            allOk = NO; firstFailure = firstFailure ?: wq_errno(errno); continue;
        }
        int stage = openat(destination, stageName.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (stage < 0) { allOk = NO; firstFailure = firstFailure ?: wq_errno(errno); continue; }
        NSString *newPath = [stagePath stringByAppendingPathComponent:@"New"];
        WQ_TREE_HOOK(@"copyReady", src);
        NSError *copyError = nil;
        BOOL ok = wq_directory_current(stagePath, stage) && [fm copyItemAtPath:src toPath:newPath error:&copyError];
        if (!ok && wq_grant(src) && wq_directory_current(srcDir, source) && wq_directory_current(stagePath, stage)) {
            if (wq_remove_entry(stage, @"New", newPath, NULL, nil)) {
                NSError *retryError = nil;
                ok = [fm copyItemAtPath:src toPath:newPath error:&retryError];
                if (!ok) copyError = retryError ?: copyError;
            }
        }
        if (ok) ok = wq_sync_entry(stage, @"New") && fsync(stage) == 0;
        WQ_TREE_HOOK(@"copyStaged", dst);
        if (ok) ok = wq_directory_current(srcDir, source) && wq_directory_current(dstDir, destination) && wq_directory_current(stagePath, stage);
        BOOL installed = NO;
        if (ok) {
            struct stat previous;
            BOOL exists = fstatat(destination, name.fileSystemRepresentation, &previous, AT_SYMLINK_NOFOLLOW) == 0;
            if (!exists && errno != ENOENT) ok = NO;
            if (ok) {
                // Swap retains the previous destination at stage/New until the
                // copy has completed and the new namespace has been flushed.
                // Without `replace`, RENAME_EXCL fails (EEXIST) on any item
                // that appeared meanwhile, and that item stays untouched.
                installed = renameatx_np(stage, "New", destination, name.fileSystemRepresentation,
                                         exists && replace ? RENAME_SWAP : RENAME_EXCL) == 0;
                ok = installed && fsync(destination) == 0 && fsync(stage) == 0;
            }
        }
        NSString *failure = ok ? nil : copyError.localizedDescription ?: wq_errno(errno);
        // Never erase the preserved destination if installation durability failed.
        BOOL cleaned = !installed || ok;
        if (cleaned) cleaned = wq_remove_entry(stage, @"New", newPath, NULL, nil);
        close(stage);
        if (cleaned) cleaned = unlinkat(destination, stageName.fileSystemRepresentation, AT_REMOVEDIR) == 0 && fsync(destination) == 0;
        if (!ok || !cleaned) {
            allOk = NO;
            NSString *message = cleaned ? failure : [NSString stringWithFormat:@"%@; staging/recovery contents retained at %@", failure ?: wq_errno(errno), stagePath];
            firstFailure = firstFailure ?: message;
            wq_log(@"copy: %@ -> %@: %@", src, dst, message);
        }
    }
    close(source); close(destination);
    if (errorText && !allOk) *errorText = firstFailure;
    wq_log(@"copy: %@ -> %@ (%lu items) %@%@", srcDir, dstDir, (unsigned long)children.count, allOk ? @"OK" : @"with errors",
           skipper.skipped ? [NSString stringWithFormat:@"; %lu sockets or pipes left out", (unsigned long)skipper.skipped] : @"");
    return allOk;
}

BOOL wq_copy_contents(NSString *srcDir, NSString *dstDir, NSString **errorText)
{
    return wq_copy_contents_mode(srcDir, dstDir, YES, nil, errorText);
}

BOOL wq_copy_tree_new(NSString *srcDir, NSString *dstDir, BOOL (^cancelled)(void), NSString **errorText)
{
    NSString *parent = dstDir.stringByDeletingLastPathComponent;
    NSString *stage = [parent stringByAppendingPathComponent:[@".wq-new-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    struct stat st;
    if (wq_stat(dstDir, &st)) {
        if (errorText) *errorText = WQLocalized(@"An item with that name already exists");
        return NO;
    }
    if (!wq_create_dir(stage, errorText)) return NO;
    NSString *error = nil;
    BOOL ok = wq_copy_contents_mode(srcDir, stage, NO, cancelled, &error);
    WQ_TREE_HOOK(@"publishReady", dstDir);
    if (ok && cancelled && cancelled()) { ok = NO; error = @"Cancelled"; }
    // Publication: one no-replace rename, after which the copy is complete.
    if (ok) ok = wq_rename(stage, dstDir.lastPathComponent, &error);
    if (!ok) {
        // Only this call's private staging folder is removed (no backups).
        unsigned long long freed = 0;
        BOOL removed = wq_purge_contents(stage, &freed) && wq_delete(stage, NULL);
        if (!removed) {
            wq_log(@"copy tree: could not remove staging folder %@", stage);
            error = WQLocalizedFormat(@"%@ An unfinished copy remains in %@.", error ?: WQLocalized(@"Copying failed."), stage.lastPathComponent);
        }
    }
    if (!ok && errorText) *errorText = error ?: WQLocalized(@"Copying failed.");
    return ok;
}

// Container-manager enumeration is a second, permission-independent way to
// map a container path to its identifier. The enumeration pattern is the one
// used by terminal_worse (GPL-3.0); no part-domain traversal is involved. The UUID xattr and the root-only
// metadata plist are the fast paths; this query is the fallback for devices
// or containers where either is unavailable. Paths and identifiers stay in a
// short-lived cache because labels are requested for every row; it is
// rebuilt after an explicit refresh and its entries are identity-bound like
// the LaunchServices API labels.
static NSString *wq_container_identifier_lookup(NSString *key, WQLabelIdentity state, NSArray<NSNumber *> *current)
{
    static NSObject *lock;
    static NSDictionary<NSString *, NSString *> *cached;
    static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *identities;
    static NSTimeInterval cachedAt;
    static NSUInteger cachedGeneration;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        NSUInteger generation = atomic_load(&gWQLabelGeneration);
        if (!cached || now - cachedAt >= 60 || generation != cachedGeneration) {
        identities = [NSMutableDictionary new];

        NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary new];
        void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (mgr) {
            cq_create_fn create = (cq_create_fn)dlsym(mgr, "container_query_create");
            cq_set_u64_fn setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
            cq_iterate_fn iterate = (cq_iterate_fn)dlsym(mgr, "container_query_iterate_results_sync");
            cq_free_fn freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
            co_get_path_fn getPath = (co_get_path_fn)dlsym(mgr, "container_object_get_path");
            co_get_id_fn getIdentifier = (co_get_id_fn)dlsym(mgr, "container_object_get_identifier");
            if (!getIdentifier) getIdentifier = (co_get_id_fn)dlsym(mgr, "container_result_get_identifier");
            if (create && setClass && iterate && freeQuery && getPath) {
                const uint64_t classes[] = { 0, 2, 5, 7, 8, 10, 11, 13 };
                for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
                    void *query = create();
                    if (!query) continue;
                    setClass(query, classes[i]);
                    iterate(query, ^bool(void *object) {
                        if (!object) return true;
                        const char *path = getPath(object);
                        const char *ident = getIdentifier ? getIdentifier(object) : NULL;
                        if (!path || !path[0] || !ident || !ident[0]) return true;
                        NSString *p = [NSString stringWithUTF8String:path];
                        NSString *v = [NSString stringWithUTF8String:ident];
                        if (!p.length || !v.length) return true;
                        NSString *pathKey = WQCanonicalVarPath(p);
                        if (pathKey.length && !map[pathKey]) {
                            map[pathKey] = v;
                            NSArray<NSNumber *> *identity = nil;
                            if (wq_label_identity(pathKey, &identity) == WQLabelIdentityKnown) identities[pathKey] = identity;
                        }
                        return true;
                    });
                    freeQuery(query);
                }
            }
            dlclose(mgr);
        }
        cached = map;
        cachedAt = now;
        cachedGeneration = generation;
        }
        NSString *value = cached[key];
        if (!value.length) return nil;
        if (!wq_label_identity_matches(identities, key, state, current)) {
            wq_log(@"label: container manager id for %@ belongs to an earlier folder; not used", key.lastPathComponent);
            return nil;
        }
        return value;
    }
}

static NSString *(*gContainerLabelResolver)(NSString *path);

void wq_set_container_label_resolver(NSString *(*resolver)(NSString *path))
{
    gContainerLabelResolver = resolver;
}

NSString *wq_container_label(NSString *dir)
{
    char buf[512];
    ssize_t len = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
    if (len > 0) {
        buf[len] = 0;
        return [NSString stringWithUTF8String:buf];
    }
    // Reading the attribute can need a token on the container: ask, try again.
    if (wq_grant(dir)) {
        len = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
        if (len > 0) {
            buf[len] = 0;
            return [NSString stringWithUTF8String:buf];
        }
    }
    // Prefer the container-manager query over the metadata plist: it needs no
    // file permission and can also label containers whose plist is root-only.
    NSArray<NSNumber *> *identity = nil;
    WQLabelIdentity state = wq_label_identity(dir, &identity);
    NSString *fromAPI = nil;
    @synchronized (NSNull.null) {
        NSString *key = wq_norm(dir);
        fromAPI = gLSAPILabels[key];
        if (fromAPI.length && gLSAPIIdentities && !wq_label_identity_matches(gLSAPIIdentities, key, state, identity)) {
            wq_log(@"label: LaunchServices API id for %@ belongs to an earlier folder; not used", key.lastPathComponent);
            fromAPI = nil;
        }
    }
    NSString *queried = wq_container_identifier_lookup(WQCanonicalVarPath(dir), state, identity);
    // Two caches that disagree about the same folder: trust neither.
    if (fromAPI.length && queried.length && ![fromAPI isEqualToString:queried]) {
        wq_log(@"label: cached ids for %@ disagree (%@, %@); asking LaunchServices", dir.lastPathComponent, fromAPI, queried);
    } else {
        if (fromAPI.length) return fromAPI;
        if (queried.length) return queried;
    }
    // The LaunchServices database maps app and extension data containers to
    // bundle ids (set by the app; this file doesn't depend on that module).
    NSString *resolved = gContainerLabelResolver ? gContainerLabelResolver(WQCanonicalVarPath(dir)) : nil;
    if (resolved.length) return resolved;
    // The metadata plist is usually root-only (mode 600); only try it when the
    // owner and mode let this app read it, so the Log isn't flooded.
    NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    if (wq_permission_hint(meta, NO)) return nil;
    NSData *data = wq_read(meta, 256 * 1024, NULL);
    if (!data) return nil;
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    id ident = [plist isKindOfClass:NSDictionary.class] ? plist[@"MCMMetadataIdentifier"] : nil;
    return [ident isKindOfClass:NSString.class] ? ident : nil;
}
