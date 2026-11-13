//
//  WQApps.m
//  WQ Files app backup and restore manager
//  GPL-3.0-or-later.
//

#import "WQApps.h"
#import "WQDir.h"
#import "WQUI.h"
#import "WQSharing.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQHealth.h"
#import "WQCore.h"
#import "WQAppsSupport.h"
#import "WQArchive.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <errno.h>
#import <sys/mount.h>
#import <sys/stat.h>

#pragma mark - Apps manager

@interface WQAppItem : NSObject
@property (nonatomic, copy) NSString *container;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) BOOL sizeKnown;
@property (nonatomic) BOOL hasAccess;
@property (nonatomic) BOOL hasIdentity;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic, copy) NSArray<NSDictionary *> *backups;
@property (nonatomic) NSInteger installState;   // WQInstallState
@end
@implementation WQAppItem
@end

@interface WQAppsViewController () <UIDocumentPickerDelegate>
@end

@implementation WQAppsViewController {
    NSArray<WQAppItem *> *_apps;
    NSArray<WQAppItem *> *_visibleApps;
    NSString *_query;
    NSString *_status;
    BOOL _busy;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
    BOOL _scanning;
    NSArray<NSString *> *_indexTitles;
    NSDictionary<NSString *, NSNumber *> *_indexRows;
    NSString *_restoreBundleID;
    WQAppItem *_importApp;
    NSTimeInterval _lastScanFinished;
}

- (instancetype)initRestoringBundleID:(NSString *)bundleID
{
    if ((self = [self init])) _restoreBundleID = [bundleID copy];
    return self;
}

static NSString *const kWQAppsSortByNamePref = @"WQAppsSortByName";
// 0 all apps, 1 Apple's, 2 everyone else's, 3 apps with a backup.
static NSString *const kWQAppsFilterPref = @"WQAppsFilter";
// 4 installed, 5 offloaded (issue #28).

typedef NS_ENUM(NSInteger, WQInstallState) { WQInstallUnknown = 0, WQInstallInstalled, WQInstallOffloaded };

// An offloaded app keeps a placeholder bundle (Info.plist and icons) but its
// executable is removed. The bundle path comes from the LaunchServices
// database; *why gets the reason for the Log.
static WQInstallState wq_app_install_state(NSString *bundleID, NSString **why)
{
    NSString *path = bundleID.length ? wq_bundle_path_for_id(bundleID) : nil;
    if (!path.length) { *why = @"no bundle path: not in the app database"; return WQInstallUnknown; }
    // Built-in apps live on the read-only system volume, which this app can't
    // read; they can't be offloaded (removable Apple apps live in bundle
    // containers like everyone else's).
    if ([path hasPrefix:@"/Applications/"] || [path hasPrefix:@"/System/"]) {
        *why = @"built-in: system volume";
        return WQInstallInstalled;
    }
    // Checking whether a path exists works even where reading is refused
    // (iOS 26): the program is almost always named like the bundle
    // (Drive.app/Drive), so finding it there settles "installed" without
    // Info.plist.
    struct stat guessed;
    NSString *guess = [path stringByAppendingPathComponent:path.lastPathComponent.stringByDeletingPathExtension];
    if (lstat(guess.fileSystemRepresentation, &guessed) == 0 && S_ISREG(guessed.st_mode)) {
        *why = @"installed: executable present";
        return WQInstallInstalled;
    }
    NSString *plistPath = [path stringByAppendingPathComponent:@"Info.plist"];
    // Installed apps' bundles refuse reading (iOS 26 and 27.0.1), while an
    // offloaded app's placeholder bundle can be read. A plain read first (no
    // Log line); a token only while tokens for bundles have ever helped.
    NSError *plainError = nil;
    NSData *data = [NSData dataWithContentsOfFile:plistPath options:0 error:&plainError];
    int plainErrno = (int)[plainError.userInfo[NSUnderlyingErrorKey] code];
    static NSInteger tokenAttempts, tokenSuccesses;
    BOOL tryToken = NO;
    @synchronized ([WQAppItem class]) { tryToken = !data && (tokenSuccesses > 0 || tokenAttempts < 3); }
    NSString *readError = nil;
    if (tryToken) {
        data = (wq_grant(path.stringByDeletingLastPathComponent) || wq_grant(path)) ? wq_read(plistPath, 4 * 1024 * 1024, &readError) : nil;
        @synchronized ([WQAppItem class]) { tokenAttempts++; if (data) tokenSuccesses++; }
    }
    id info = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
    if (![info isKindOfClass:NSDictionary.class]) {
        struct stat st;
        BOOL bundleThere = lstat(path.fileSystemRepresentation, &st) == 0;
        BOOL denied = plainErrno == EPERM || plainErrno == EACCES || plainError.code == NSFileReadNoPermissionError;
        if (!data && bundleThere && denied) {
            *why = [NSString stringWithFormat:@"refused: %@ can't be read", path.lastPathComponent];
            return WQInstallUnknown;
        }
        *why = [NSString stringWithFormat:@"%@: %@ (%@)", data ? @"Info.plist not a dictionary" : @"Info.plist unreadable",
                plistPath, data ? @"bad plist" : (readError ?: plainError.localizedDescription ?: @"no reason")];
        if (!data && !bundleThere) *why = [*why stringByAppendingString:@", bundle not visible"];
        return WQInstallUnknown;
    }
    NSString *executable = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : nil;
    if (!executable.length || [executable containsString:@"/"]) { *why = @"no CFBundleExecutable: in Info.plist"; return WQInstallUnknown; }
    NSString *exePath = [path stringByAppendingPathComponent:executable];
    struct stat st;
    if (lstat(exePath.fileSystemRepresentation, &st) == 0) { *why = @"installed: executable present"; return WQInstallInstalled; }
    int err = errno;
    if (wq_stat(exePath, &st)) { *why = @"installed: executable present"; return WQInstallInstalled; }
    if (err == ENOENT) { *why = [NSString stringWithFormat:@"offloaded: %@ missing from %@", executable, path]; return WQInstallOffloaded; }
    *why = [NSString stringWithFormat:@"executable unchecked: %@ (%s)", exePath, strerror(err)];
    return WQInstallUnknown;
}

static BOOL wq_app_is_apple(WQAppItem *app)
{
    return [app.bundleID hasPrefix:@"com.apple."];
}

static NSString *wq_apps_index_letter(NSString *name)
{
    if (!name.length) return @"#";
    NSString *first = [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]]
                       stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil].uppercaseString;
    unichar c = first.length ? [first characterAtIndex:0] : 0;
    return (c >= 'A' && c <= 'Z') ? [NSString stringWithCharacters:&c length:1] : @"#";
}

static NSArray<NSString *> *kAppDataParts(void) { return @[@"Documents", @"Library", @"tmp"]; }
static NSArray<NSString *> *kAppBackupParts(void) { return @[@"Documents", @"Library"]; }

static NSString *wq_app_backup_root_for_bundle(NSString *bundleID)
{
    if (!WQAppsSupportBundleIDValid(bundleID)) return nil;
    return [wq_app_backup_root() stringByAppendingPathComponent:bundleID];
}

// An app backup is AppBackups/<bundle id>/<date>/{Documents,Library} plus a
// manifest. It is built in a hidden staging folder and only renamed into
// place, with the manifest, once every file was copied: a failed or
// interrupted backup never shows up as one that can be restored.
static NSString *const kBackupManifest = @".wqbackup.plist";
static NSString *const kBackupStagingPrefix = @".incomplete-";
static NSString *const kBackupReasonBeforeRestore = @"Before restore";

static NSDictionary *wq_backup_manifest(NSString *backup)
{
    struct stat st;
    NSString *path = [backup stringByAppendingPathComponent:kBackupManifest];
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return nil;
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:path];
    return [manifest isKindOfClass:NSDictionary.class] ? manifest : nil;
}

static BOOL wq_backup_root_child(NSString *path, NSString *bundleID)
{
    NSString *root = [wq_app_backup_root_for_bundle(bundleID) stringByStandardizingPath];
    if (!root.length) return NO;
    NSString *parent = [path.stringByDeletingLastPathComponent stringByStandardizingPath];
    NSString *name = path.lastPathComponent;
    return [parent isEqualToString:root] && name.length && ![name hasPrefix:@"."];
}

static BOOL wq_backup_parts_on_disk(NSString *backup, NSArray<NSString *> *expectedParts,
                                    BOOL hasManifest, NSString **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listError = nil;
    NSArray *children = [fm contentsOfDirectoryAtPath:backup error:&listError];
    if (!children) {
        if (error) *error = listError.localizedDescription ?: WQLocalized(@"The backup folder cannot be read");
        return NO;
    }
    NSMutableSet *actual = [NSMutableSet set];
    for (NSString *name in children) {
        if (hasManifest && [name isEqualToString:kBackupManifest]) continue;
        if (![(@[@"Documents", @"Library"]) containsObject:name]) {
            if (error) *error = WQLocalizedFormat(@"The backup contains an unexpected item: %@", name);
            return NO;
        }
        NSString *part = [backup stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(part.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
            if (error) *error = WQLocalizedFormat(@"The backup part %@ is not a directory", name);
            return NO;
        }
        NSError *partError = nil;
        if (![fm contentsOfDirectoryAtPath:part error:&partError]) {
            if (error) *error = WQLocalizedFormat(@"The backup part %@ cannot be read: %@", name,
                                 partError.localizedDescription ?: WQLocalized(@"unknown error"));
            return NO;
        }
        [actual addObject:name];
    }
    if (![actual isEqualToSet:[NSSet setWithArray:expectedParts]]) {
        if (error) *error = WQLocalized(@"The backup manifest does not match the on-disk parts");
        return NO;
    }
    return YES;
}

// Strict validation is used for current backups and recovery material. A
// no-manifest directory is accepted only as an explicitly unverified legacy
// backup; it never supplies implicit purge instructions for recovery.
static BOOL wq_validate_backup(NSString *backup, NSString *bundleID, BOOL allowLegacy,
                               NSArray<NSString *> **partsOut, NSDictionary **manifestOut,
                               BOOL *verifiedOut, NSString **error)
{
    if (!wq_backup_root_child(backup, bundleID)) {
        if (error) *error = WQLocalized(@"The backup path is outside this app's backup folder");
        return NO;
    }
    struct stat backupStat;
    if (lstat(backup.fileSystemRepresentation, &backupStat) != 0 || !S_ISDIR(backupStat.st_mode)) {
        if (error) *error = WQLocalized(@"The backup folder is missing");
        return NO;
    }
    NSString *manifestPath = [backup stringByAppendingPathComponent:kBackupManifest];
    struct stat manifestStat;
    int manifestResult = lstat(manifestPath.fileSystemRepresentation, &manifestStat);
    if (manifestResult != 0 && errno != ENOENT) {
        if (error) *error = [NSString stringWithFormat:@"Cannot inspect the backup manifest (errno %d)", errno];
        return NO;
    }
    BOOL hasManifest = manifestResult == 0;
    if (hasManifest && !S_ISREG(manifestStat.st_mode)) {
        if (error) *error = WQLocalized(@"The backup manifest is not a regular file");
        return NO;
    }
    NSDictionary *manifest = hasManifest ? wq_backup_manifest(backup) : nil;
    NSArray<NSString *> *parts = nil;
    BOOL verified = NO;
    if (hasManifest) {
        NSString *manifestError = nil;
        if (!WQAppsSupportManifestFields(manifest, bundleID, &parts, &manifestError)) {
            if (error) *error = manifestError ? WQLocalized(manifestError) : WQLocalized(@"The backup manifest is invalid");
            return NO;
        }
        verified = YES;
    } else {
        if (!allowLegacy) {
            if (error) *error = WQLocalized(@"The safety backup has no typed manifest");
            return NO;
        }
        NSMutableArray *legacyParts = [NSMutableArray new];
        NSError *listError = nil;
        NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:backup error:&listError];
        if (!children) {
            if (error) *error = listError.localizedDescription ?: WQLocalized(@"The legacy backup cannot be read");
            return NO;
        }
        for (NSString *name in children) {
            if (![(@[@"Documents", @"Library"]) containsObject:name]) {
                if (error) *error = WQLocalizedFormat(@"The legacy backup contains an unexpected item: %@", name);
                return NO;
            }
            [legacyParts addObject:name];
        }
        parts = [legacyParts sortedArrayUsingSelector:@selector(compare:)];
    }
    if (!wq_backup_parts_on_disk(backup, parts, hasManifest, error)) return NO;
    if (partsOut) *partsOut = parts;
    if (manifestOut) *manifestOut = manifest;
    if (verifiedOut) *verifiedOut = verified;
    return YES;
}

// Newest first. Current backups are ordered by their manifest timestamp and
// numeric collision sequence, never by the display name's text ordering.
static NSArray<NSDictionary *> *wq_app_backups(NSString *bundleID)
{
    NSString *root = wq_app_backup_root_for_bundle(bundleID);
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *path = [root stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        NSString *validationError = nil;
        NSArray *parts = nil;
        NSDictionary *manifest = nil;
        BOOL verified = NO;
        BOOL valid = wq_validate_backup(path, bundleID, YES, &parts, &manifest, &verified, &validationError);
        BOOL hasManifest = lstat([[path stringByAppendingPathComponent:kBackupManifest] fileSystemRepresentation], &st) == 0;
        if (!valid && !hasManifest) continue;
        NSDate *created = [manifest[@"Created"] isKindOfClass:NSDate.class] ? manifest[@"Created"] :
            [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate] ?: NSDate.distantPast;
        NSUInteger sequence = WQAppsSupportBackupSequence(name);
        if (WQAppsSupportIsInteger(manifest[@"Sequence"]) && [manifest[@"Sequence"] unsignedIntegerValue])
            sequence = [manifest[@"Sequence"] unsignedIntegerValue];
        [out addObject:@{ @"path": path, @"name": name, @"verified": @(valid && verified),
                          @"reason": valid ? (manifest[@"Reason"] ?: @"") : (validationError ?: WQLocalized(@"invalid manifest")),
                          @"created": created, @"sequence": @(sequence) }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return WQAppsSupportCompareBackupMetadata(b[@"created"], [b[@"sequence"] unsignedIntegerValue], b[@"name"],
                                                    a[@"created"], [a[@"sequence"] unsignedIntegerValue], a[@"name"]);
    }];
    return out;
}

static NSString *wq_backup_label(NSDictionary *__unused backup)
{
    NSString *label = backup[@"name"];
    if ([backup[@"reason"] length]) label = [label stringByAppendingFormat:@" (%@)", WQLocalized(backup[@"reason"])];
    if (![backup[@"verified"] boolValue]) label = [label stringByAppendingString:WQLocalized(@" (older, unverified)")];
    return label;
}

static BOOL wq_validate_container(NSString *container, NSString *bundleID, dev_t expectedDevice,
                                  ino_t expectedInode, NSString **error)
{
    struct stat st;
    if (lstat(container.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
        if (error) *error = WQLocalized(@"The app container no longer exists or is not a directory");
        return NO;
    }
    if (expectedDevice && expectedInode && (st.st_dev != expectedDevice || st.st_ino != expectedInode)) {
        if (error) *error = WQLocalized(@"The app container was replaced after it was scanned");
        return NO;
    }
    NSString *label = wq_container_label(container);
    if (!label.length || ![label isEqualToString:bundleID]) {
        if (error) *error = WQLocalized(@"The app container identity no longer matches the selected app");
        return NO;
    }
    return YES;
}

// Sockets, FIFOs and device files are not copied and not compared (see
// WQAppsSupportTreeSignatureOmitting); *omitted gets how many were left out.
static BOOL wq_copy_part_and_verify(NSString *src, NSString *dst, NSUInteger *omitted, NSString **error)
{
    if (omitted) *omitted = 0;
    BOOL sourceBeforeExists = NO;
    NSString *sourceBefore = WQAppsSupportTreeSignature(src, YES, &sourceBeforeExists, error);
    if (!sourceBefore) return NO;
    if (!wq_copy_contents(src, dst, error)) return NO;
    BOOL srcExists = NO, dstExists = NO;
    NSString *sourceAfter = WQAppsSupportTreeSignature(src, YES, &srcExists, error);
    NSUInteger sourceOmitted = 0;
    NSString *sourceShape = WQAppsSupportTreeSignatureOmitting(src, NO, NULL, &sourceOmitted, error);
    NSString *destinationShape = WQAppsSupportTreeSignature(dst, NO, &dstExists, error);
    if (!sourceAfter || !sourceShape || !destinationShape || !sourceBeforeExists || !srcExists || !dstExists ||
        ![sourceBefore isEqualToString:sourceAfter] ||
        ![sourceShape isEqualToString:destinationShape]) {
        if (error && !*error) *error = WQLocalized(@"The copied tree could not be verified (the source changed or the copy is incomplete)");
        return NO;
    }
    if (sourceOmitted) wq_log(@"copy %@: %lu sockets, pipes or device files left out", src, (unsigned long)sourceOmitted);
    if (omitted) *omitted = sourceOmitted;
    return YES;
}

static BOOL wq_purge_and_verify(NSString *dir, unsigned long long *freed, NSString **error)
{
    if (!wq_purge_contents(dir, freed)) return NO;
    struct stat st;
    if (!wq_stat(dir, &st)) return YES;   // a missing part is an acceptable empty result
    if (!S_ISDIR(st.st_mode)) {
        if (error) *error = [NSString stringWithFormat:@"%@ is not a directory", dir.lastPathComponent];
        return NO;
    }
    NSError *listError = nil;
    NSArray *remaining = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&listError];
    if (!remaining) {
        if (error) *error = listError.localizedDescription ?: WQLocalizedFormat(@"Cannot read %@", dir.lastPathComponent);
        return NO;
    }
    if (remaining.count) {
        if (error) *error = WQLocalizedFormat(@"Some items remain in %@; keep the app closed and try again", dir.lastPathComponent);
        return NO;
    }
    return YES;
}

// Copies the app's Documents and Library into a new complete backup. Returns
// its path, or nil with *error (nothing is left behind then).
// Copies Documents and Library from `container` (an app's data container,
// or for imports a local folder) into a new verified backup of bundleID.
// `stillValid` (optional) re-checks the source before and after publishing.
// `extraManifest` (optional) adds entries to the manifest (e.g. an import's
// confirmed identity conflict).
static NSString *wq_make_backup_from(NSString *bundleID, NSString *container, NSString *reason,
                                     NSDictionary *extraManifest,
                                     BOOL (^stillValid)(NSString **error), NSString **error)
{
    if (!WQAppsSupportBundleIDValid(bundleID)) {
        if (error) *error = WQLocalized(@"The app identifier is not a valid bundle identifier");
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (stillValid && !stillValid(error)) return nil;
    NSString *root = wq_app_backup_root_for_bundle(bundleID);
    if (!root.length) {
        if (error) *error = WQLocalized(@"Cannot locate the app backup folder");
        return nil;
    }
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil])   // leftovers of interrupted runs
        if ([name hasPrefix:kBackupStagingPrefix]) [fm removeItemAtPath:[root stringByAppendingPathComponent:name] error:nil];

    NSString *staging = [root stringByAppendingPathComponent:
                         [kBackupStagingPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:nil error:nil]) {
        if (error) *error = WQLocalized(@"Cannot create the backup folder");
        return nil;
    }
    // Access first: without a token for the container, lstat of its parts can
    // report "no such file" and the backup would come out empty. An app's
    // data container always holds at least Library, so a container that
    // can't be listed, or seems to hold neither part, fails the backup.
    wq_grant(container);
    NSString *listError = nil;
    NSArray<NSString *> *top = wq_list(container, &listError);
    if (!top) {
        [fm removeItemAtPath:staging error:nil];
        if (error) *error = WQLocalizedFormat(@"WQ Files has no access to the app's data right now (%@). Nothing was backed up; try again.",
                                              listError ?: @"no token");
        return nil;
    }
    if (![top containsObject:@"Documents"] && ![top containsObject:@"Library"]) {
        [fm removeItemAtPath:staging error:nil];
        if (error) *error = WQLocalized(@"The app's data folder holds neither Documents nor Library, so there is nothing to back up.");
        return nil;
    }
    NSMutableArray *parts = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSString *> *sourceStates = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *partHashes = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSNumber *> *omittedSpecial = [NSMutableDictionary new];
    BOOL ok = YES;
    for (NSString *part in kAppBackupParts()) {
        NSString *src = [container stringByAppendingPathComponent:part];
        struct stat st;
        if (![top containsObject:part]) continue;   // the app has none (decided from the container listing)
        if (!wq_stat(src, &st)) { ok = NO; if (error) *error = WQLocalizedFormat(@"Cannot access %@", part); break; }
        BOOL sourceExists = NO;
        NSString *sourceState = WQAppsSupportTreeSignature(src, YES, &sourceExists, error);
        if (!sourceState) { ok = NO; break; }
        sourceStates[part] = sourceState;
        NSString *stagedPart = [staging stringByAppendingPathComponent:part];
        NSUInteger omitted = 0;
        if (!wq_copy_part_and_verify(src, stagedPart, &omitted, error)) { ok = NO; break; }
        if (omitted) omittedSpecial[part] = @(omitted);
        BOOL stagedExists = NO;
        NSString *contentHash = WQAppsSupportTreeContentSignature(stagedPart, &stagedExists, error);
        if (!contentHash || !stagedExists) {
            ok = NO;
            if (error && !*error) *error = WQLocalized(@"Cannot hash the staged backup part");
            break;
        }
        partHashes[part] = contentHash;
        [parts addObject:part];
    }
    if (ok) {
        for (NSString *part in kAppBackupParts()) {
            NSString *src = [container stringByAppendingPathComponent:part];
            BOOL sourceExists = NO;
            NSString *sourceState = WQAppsSupportTreeSignature(src, YES, &sourceExists, error);
            NSString *before = sourceStates[part] ?: @"<missing>";
            if (!sourceState || ![before isEqualToString:sourceState]) {
                ok = NO;
                if (error && !*error) *error = WQLocalized(@"The app data changed while it was being backed up; no snapshot-consistent copy was made");
                break;
            }
        }
    }
    NSDate *created = NSDate.date;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *stamp = [fmt stringFromDate:created];
    NSString *final = [root stringByAppendingPathComponent:stamp];
    NSUInteger sequence = 1;
    for (NSUInteger n = 2; [fm fileExistsAtPath:final]; n++) {
        sequence = n;
        final = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%lu)", stamp, (unsigned long)n]];
    }
    NSMutableDictionary *manifest = [NSMutableDictionary dictionaryWithDictionary:extraManifest ?: @{}];
    [manifest addEntriesFromDictionary:@{ @"Complete": @YES, @"BundleID": bundleID, @"Created": created,
                                          @"Parts": parts, @"PartHashes": partHashes,
                                          @"Reason": reason ?: @"", @"Format": @1,
                                          @"Sequence": @(sequence) }];
    // Sockets, pipes and device files hold no data and are never copied.
    if (omittedSpecial.count) manifest[@"OmittedSpecialFiles"] = omittedSpecial;
    if (ok && ![manifest writeToFile:[staging stringByAppendingPathComponent:kBackupManifest] atomically:YES]) {
        ok = NO;
        if (error) *error = WQLocalized(@"Cannot write the backup manifest");
    }
    BOOL published = NO;
    if (ok) {
        if (stillValid && !stillValid(error)) ok = NO;
    }
    if (ok) {
        if (rename(staging.fileSystemRepresentation, final.fileSystemRepresentation) != 0) {
            ok = NO;
            if (error) *error = WQLocalizedFormat(@"Cannot finish the backup (errno %d)", errno);
        } else {
            published = YES;
            NSString *validationError = nil;
            if (!wq_validate_backup(final, bundleID, NO, NULL, NULL, NULL, &validationError) ||
                (stillValid && !stillValid(&validationError))) {
                ok = NO;
                if (error) *error = validationError ?: WQLocalized(@"The app container changed while the backup was being finalized");
            }
        }
    }
    if (!ok) {
        [fm removeItemAtPath:published ? final : staging error:nil];
        wq_log(@"app backup %@: FAILED (%@)", bundleID, error && *error ? *error : @"?");
        return nil;
    }
    wq_log(@"app backup %@ -> %@ (%@)", bundleID, final.lastPathComponent, [parts componentsJoinedByString:@", "]);
    return final;
}

#pragma mark - Import as Backup

static NSString *const kBackupReasonImported = @"Imported";

static NSString *wq_make_app_backup(NSString *bundleID, NSString *container, dev_t expectedDevice,
                                    ino_t expectedInode, NSString *reason, NSString **error)
{
    return wq_make_backup_from(bundleID, container, reason, nil, ^BOOL(NSString **validationError) {
        return wq_validate_container(container, bundleID, expectedDevice, expectedInode, validationError);
    }, error);
}

static BOOL wq_dir_size_cancellable(NSString *dir, WQScanCancellation *cancellation,
                                     unsigned long long *sizeOut, BOOL *completeOut)
{
    if (completeOut) *completeOut = NO;
    if (sizeOut) *sizeOut = 0;
    if (cancellation.isCancelled) return NO;
    unsigned long long total = 0;
    WQMeasureResult result = wq_measure_tree(dir, cancellation, &total);
    if (result == WQMeasureResultCancelled) return NO;
    if (sizeOut) *sizeOut = total;
    if (completeOut) *completeOut = result != WQMeasureResultLimited;
    return YES;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"Apps");
    wq_prism_install_background(self);
    self.tableView.backgroundColor = [UIColor clearColor];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = WQLocalizedNullable(@"Search apps");
    self.navigationItem.rightBarButtonItem = [self sortButton];
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.tableView.tableHeaderView = wq_device_header(self.view.bounds.size.width);
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    [self scan];
}

// Pull to refresh: rescan the containers instead of reusing the shared scan,
// and look for the app name database again if it wasn't found before.
- (void)userRefresh
{
    wq_enumerate_invalidate();
    wq_display_names_reset_miss();
    [self scan];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (_scanning && _scanCancellation.isCancelled) { [self scan]; return; }
    if (_scanning || !_apps) return;
    // The start screen keeps this screen between visits: rescan on its own
    // only when the list is old (pull to refresh rescans any time). Backups
    // may have been made or deleted elsewhere, so reread those (cheap).
    if (NSDate.date.timeIntervalSinceReferenceDate - _lastScanFinished > 600.0) { [self scan]; return; }
    [self refreshBackups];
}

- (void)refreshBackups
{
    NSArray<WQAppItem *> *apps = _apps;
    NSUInteger generation = _scanGeneration;
    dispatch_async(wq_io(), ^{
        NSMutableArray *lists = [NSMutableArray arrayWithCapacity:apps.count];
        for (WQAppItem *app in apps) [lists addObject:app.bundleID.length ? wq_app_backups(app.bundleID) : @[]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || self->_scanning) return;
            BOOL changed = NO;
            for (NSUInteger i = 0; i < apps.count; i++) {
                if ([apps[i].backups isEqualToArray:lists[i]]) continue;
                apps[i].backups = lists[i];
                changed = YES;
            }
            if (!changed) return;
            [self rebuildVisibleApps];
            [self.tableView reloadData];
        });
    });
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (_scanning) [_scanCancellation cancel];
}

- (void)setBusy:(BOOL)busy status:(NSString *)status
{
    _busy = busy;
    _status = status;
    [self.tableView reloadData];
}

// Watchdog for the app scan: each step records what it's doing; a timer logs
// any step that stays unchanged for 10 s, so a hang shows up in the Log.
static NSObject *gAppScanStepLock;
static NSString *gAppScanStep;
static CFAbsoluteTime gAppScanStepAt;
static NSUInteger gAppScanStepSerial;

static void WQAppScanStep(NSString *step)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gAppScanStepLock = [NSObject new]; });
    @synchronized (gAppScanStepLock) {
        gAppScanStep = [step copy];
        gAppScanStepAt = CFAbsoluteTimeGetCurrent();
        gAppScanStepSerial++;
    }
}

static void WQAppScanWatch(WQScanCancellation *cancellation, NSUInteger lastSerial, NSUInteger reported)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *step = nil;
        NSUInteger serial = 0;
        double age = 0;
        @synchronized (gAppScanStepLock) {
            step = gAppScanStep;
            serial = gAppScanStepSerial;
            age = CFAbsoluteTimeGetCurrent() - gAppScanStepAt;
        }
        if (!step) return;   // scan finished
        NSUInteger nowReported = serial == lastSerial ? reported : 0;
        if (age >= 10 && nowReported < 6) {
            wq_log(@"app scan: still %@ after %.0f s%@", step, age, cancellation.isCancelled ? @" (screen left)" : @"");
            nowReported++;
        }
        WQAppScanWatch(cancellation, serial, nowReported);
    });
}

- (void)scan
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanning = YES;
    [self setBusy:YES status:WQLocalizedNullable(@"Finding apps…")];
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    WQAppScanStep(@"finding app containers");
    WQAppScanWatch(cancellation, 0, 0);
    dispatch_async(wq_io(), ^{
        CFAbsoluteTime scanStarted = CFAbsoluteTimeGetCurrent();
        NSArray *containers = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, cancellation,
            ^(int64_t done, int64_t total, NSUInteger __unused f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_status = WQLocalizedFormat(@"Finding apps… %lld%%", total ? (long long)(done * 100 / total) : 0);
                    [self.tableView reloadData];
                });
            });
        if (!cancellation.isCancelled && !wq_display_names_loaded()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_status = WQLocalized(@"Reading app names…");
                [self.tableView reloadData];
            });
            WQAppScanStep(@"reading app names");
            CFAbsoluteTime namesStarted = CFAbsoluteTimeGetCurrent();
            wq_load_display_names();
            wq_log(@"app scan: app names %@ in %.1f s", wq_display_names_loaded() ? @"loaded" : @"not loaded",
                   CFAbsoluteTimeGetCurrent() - namesStarted);
        }
        if (containers) wq_log(@"app scan: %lu containers found in %.1f s; measuring", (unsigned long)containers.count,
                               CFAbsoluteTimeGetCurrent() - scanStarted);
        if (!containers && !cancellation.isCancelled) wq_log(@"app scan: container enumeration failed; see the preceding enumerate log");
        else if (containers && containers.count == 0) wq_log(@"app scan: enumeration returned no container paths; check the base path and inode bound");
        NSMutableArray<WQAppItem *> *apps = [NSMutableArray new];
        NSMutableArray<NSString *> *refused = [NSMutableArray new];
        NSUInteger i = 0, missingLabels = 0, limited = 0, sizeLimited = 0;
        NSUInteger installCounts[3] = {0}, installNotes = 0;
        NSMutableDictionary<NSString *, NSNumber *> *installReasons = [NSMutableDictionary new];
        NSMutableArray<WQAppItem *> *refusedBundles = [NSMutableArray new];
        for (NSString *c in containers) {
            if (cancellation.isCancelled) { WQAppScanStep(nil); return; }
            i++;
            if ([[c stringByResolvingSymlinksInPath] isEqualToString:home]) continue;  // ourselves
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_status = WQLocalizedFormat(@"Measuring %lu/%lu…", (unsigned long)i, (unsigned long)containers.count);
                [self.tableView reloadData];
            });
            NSString *shortName = c.lastPathComponent;
            WQAppScanStep([NSString stringWithFormat:@"getting access to %@ (%lu/%lu)", shortName, (unsigned long)i, (unsigned long)containers.count]);
            BOOL granted = wq_grant(c);
            if (!granted) {
                [refused addObject:[NSString stringWithFormat:@"%@ (%@)", c.lastPathComponent,
                                    wq_bundle_id_for_container(c) ?: @"unknown app"]];
            }
            WQAppScanStep([NSString stringWithFormat:@"reading the identifier of %@", shortName]);
            NSString *bid = wq_container_label(c);
            if (!bid.length) {
                missingLabels++;
                if (missingLabels <= 3) wq_log(@"app scan: no container identifier for %@", c);
            }
            struct stat identity;
            BOOL validBundle = WQAppsSupportBundleIDValid(bid);
            BOOL hasIdentity = validBundle && wq_stat(c, &identity) && S_ISDIR(identity.st_mode);
            if (!granted || !validBundle || !hasIdentity) limited++;
            WQAppItem *app = [WQAppItem new];
            app.container = c;
            app.bundleID = bid;
            app.hasAccess = granted;
            app.hasIdentity = hasIdentity;
            app.containerDevice = hasIdentity ? identity.st_dev : 0;
            app.containerInode = hasIdentity ? identity.st_ino : 0;
            if (bid.length) (void)wq_app_icon(bid);   // warm the icon off the main thread
            app.name = bid.length ? (wq_display_name(bid) ?: bid)
                                  : WQLocalizedFormat(@"Unknown container (%@)", c.lastPathComponent);
            app.bytes = 0;
            app.sizeKnown = NO;
            unsigned long long appSize = 0;
            BOOL sizeKnown = NO;
            WQAppScanStep([NSString stringWithFormat:@"measuring %@ (%@)", shortName, bid ?: @"no identifier"]);
            if (granted && hasIdentity && !wq_dir_size_cancellable(c, cancellation, &appSize, &sizeKnown)) { WQAppScanStep(nil); return; }
            app.bytes = appSize;
            app.sizeKnown = sizeKnown;
            if (granted && hasIdentity && !sizeKnown) sizeLimited++;
            app.backups = bid.length ? wq_app_backups(bid) : @[];
            NSString *why = nil;
            app.installState = bid.length ? wq_app_install_state(bid, &why) : WQInstallUnknown;
            installCounts[app.installState]++;
            NSString *reasonKind = [why componentsSeparatedByString:@":"].firstObject ?: @"no identifier";
            if ([reasonKind isEqualToString:@"refused"]) [refusedBundles addObject:app];
            installReasons[reasonKind] = @([installReasons[reasonKind] unsignedIntegerValue] + 1);
            // Every offloaded app (there are few, and they're the claim to check),
            // and a few of the unknown ones.
            if (app.installState == WQInstallOffloaded || (app.installState == WQInstallUnknown && installNotes < 6)) {
                if (app.installState == WQInstallUnknown) installNotes++;
                wq_log(@"install state: %@: %@", bid ?: c.lastPathComponent, why ?: @"no identifier");
            }
            [apps addObject:app];
        }
        WQAppScanStep(nil);
        if (cancellation.isCancelled) return;
        // Offloaded apps' placeholder bundles can be read while installed
        // apps' bundles refuse: once a placeholder was read on this device, a
        // refused bundle is an installed app.
        if (installCounts[WQInstallOffloaded] && refusedBundles.count) {
            for (WQAppItem *app in refusedBundles) app.installState = WQInstallInstalled;
            installCounts[WQInstallInstalled] += refusedBundles.count;
            installCounts[WQInstallUnknown] -= refusedBundles.count;
            wq_log(@"install state: %lu refused bundles counted as installed (offloaded placeholders are readable here)",
                   (unsigned long)refusedBundles.count);
        }
        wq_log(@"app scan: %lu apps measured in %.1f s", (unsigned long)apps.count, CFAbsoluteTimeGetCurrent() - scanStarted);
        wq_log(@"app scan: %lu installed, %lu offloaded, %lu unknown", (unsigned long)installCounts[WQInstallInstalled],
               (unsigned long)installCounts[WQInstallOffloaded], (unsigned long)installCounts[WQInstallUnknown]);
        NSMutableArray *reasonParts = [NSMutableArray new];
        for (NSString *kind in [installReasons keysSortedByValueUsingSelector:@selector(compare:)].reverseObjectEnumerator)
            [reasonParts addObject:[NSString stringWithFormat:@"%@ %@", installReasons[kind], kind]];
        if (reasonParts.count) wq_log(@"install state by reason: %@", [reasonParts componentsJoinedByString:@", "]);
        if (refused.count) wq_log(@"app scan: %lu containers refused access: %@", (unsigned long)refused.count,
                                  [refused componentsJoinedByString:@", "]);
        [apps sortUsingComparator:^NSComparisonResult(WQAppItem *a, WQAppItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSString *note = nil;
        if (!wq_app_group()) note = WQLocalized(@"WQ Files has no App Group, so it can't open other apps' folders. Re-sign it with a tool that keeps the App Group (see Signing in the README).");
        else if (!containers && wq_full_scan_was_declined()) note = WQLocalized(@"Apps aren't listed yet: this needs a scan of all files. Pull down to start it.");
        else if (!containers) note = WQLocalized(@"Container enumeration failed. See Log for the statfs/inode reason.");
        else if (!containers.count) note = WQLocalized(@"No app containers were found. Refresh, and check Log for the enumeration reason.");
        else if (limited || sizeLimited) note = WQLocalizedFormat(@"%lu containers · %lu with limited access, identity, size, or no identifier. See Log.", (unsigned long)apps.count, (unsigned long)(limited + sizeLimited));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || cancellation.isCancelled) return;
            self->_scanning = NO;
            self->_lastScanFinished = NSDate.date.timeIntervalSinceReferenceDate;
            self->_apps = apps;
            [self rebuildVisibleApps];
            [self.refreshControl endRefreshing];
            [self setBusy:NO status:note];
            [self offerPendingRestore];
        });
    });
}

- (NSArray<WQAppItem *> *)visibleApps
{
    return _visibleApps ?: @[];
}

- (void)rebuildVisibleApps
{
    NSArray<WQAppItem *> *shown = _apps ?: @[];
    NSInteger filter = [NSUserDefaults.standardUserDefaults integerForKey:kWQAppsFilterPref];
    if (filter > 0) {
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQAppItem *a, NSDictionary *__unused b) {
            if (filter == 1) return wq_app_is_apple(a);
            if (filter == 2) return !wq_app_is_apple(a);
            if (filter == 4) return a.installState == WQInstallInstalled;
            if (filter == 5) return a.installState == WQInstallOffloaded;
            return a.backups.count > 0;
        }]];
    }
    if (_query.length) {
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQAppItem *a, NSDictionary *__unused b) {
            return [a.name localizedCaseInsensitiveContainsString:self->_query] ||
                   [a.bundleID localizedCaseInsensitiveContainsString:self->_query];
        }]];
    }
    BOOL byName = [NSUserDefaults.standardUserDefaults boolForKey:kWQAppsSortByNamePref];
    _visibleApps = [shown sortedArrayUsingComparator:^NSComparisonResult(WQAppItem *a, WQAppItem *b) {
        NSComparisonResult names = [(a.name ?: @"") localizedStandardCompare:(b.name ?: @"")];
        if (byName || a.bytes == b.bytes) return names;
        return a.bytes > b.bytes ? NSOrderedAscending : NSOrderedDescending;
    }];
    // Alphabet sidebar when sorted by name.
    NSMutableArray *titles = [NSMutableArray new];
    NSMutableDictionary *rows = [NSMutableDictionary new];
    if (byName && _visibleApps.count >= 25) {
        [_visibleApps enumerateObjectsUsingBlock:^(WQAppItem *app, NSUInteger row, BOOL *__unused stop) {
            NSString *letter = wq_apps_index_letter(app.name);
            if (!rows[letter]) { rows[letter] = @(row); [titles addObject:letter]; }
        }];
    }
    _indexTitles = titles.count > 1 ? titles : nil;
    _indexRows = rows;
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    return (_busy && !_apps.count) ? nil : _indexTitles;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index
{
    NSNumber *row = _indexRows[title];
    if (row && row.unsignedIntegerValue < self.visibleApps.count)
        [tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row.integerValue inSection:0]
                         atScrollPosition:UITableViewScrollPositionTop animated:NO];
    return -1;   // already scrolled to the row; the list has one section
}

- (UIBarButtonItem *)sortButton
{
    __weak typeof(self) weakSelf = self;
    UIDeferredMenuElement *items = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        BOOL byName = [NSUserDefaults.standardUserDefaults boolForKey:kWQAppsSortByNamePref];
        UIAction *size = [UIAction actionWithTitle:WQLocalizedNullable(@"Size") image:nil identifier:nil handler:^(UIAction *__unused a) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:kWQAppsSortByNamePref];
            [weakSelf resortApps];
        }];
        UIAction *name = [UIAction actionWithTitle:WQLocalizedNullable(@"Name") image:nil identifier:nil handler:^(UIAction *__unused a) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:kWQAppsSortByNamePref];
            [weakSelf resortApps];
        }];
        size.state = byName ? UIMenuElementStateOff : UIMenuElementStateOn;
        name.state = byName ? UIMenuElementStateOn : UIMenuElementStateOff;
        size.subtitle = WQLocalized(@"Largest first");
        name.subtitle = WQLocalized(@"A–Z");
        UIMenu *sort = [UIMenu menuWithTitle:WQLocalizedNullable(@"Sort By") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[size, name]];
        NSInteger current = [NSUserDefaults.standardUserDefaults integerForKey:kWQAppsFilterPref];
        NSArray *titles = @[WQLocalized(@"All Apps"), WQLocalized(@"Apple Apps"), WQLocalized(@"Other Apps"), WQLocalized(@"Backed Up"),
                            WQLocalized(@"Installed"), WQLocalized(@"Offloaded")];
        // Installed/Offloaded only where bundles could be checked (not on iOS 26).
        WQAppsViewController *strongSelf = weakSelf;
        // Only offer Installed/Offloaded when nearly every app's state is
        // known; otherwise those filters would quietly hide the unknown ones.
        NSArray<WQAppItem *> *all = strongSelf ? strongSelf->_apps : @[];
        NSUInteger unknown = 0;
        for (WQAppItem *app in all) if (app.installState == WQInstallUnknown) unknown++;
        BOOL installKnown = all.count > 0 && unknown * 10 <= all.count;
        NSMutableArray *filters = [NSMutableArray new];
        for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
            if (i >= 4 && !installKnown && i != current) continue;
            UIAction *f = [UIAction actionWithTitle:WQLocalizedNullable(titles[(NSUInteger)i]) image:nil identifier:nil handler:^(UIAction *__unused a) {
                [NSUserDefaults.standardUserDefaults setInteger:i forKey:kWQAppsFilterPref];
                [weakSelf resortApps];
            }];
            f.state = i == current ? UIMenuElementStateOn : UIMenuElementStateOff;
            [filters addObject:f];
        }
        UIMenu *show = [UIMenu menuWithTitle:WQLocalizedNullable(@"Show") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:filters];
        completion(@[sort, show]);
    }];
    return [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
                                             menu:[UIMenu menuWithChildren:@[items]]];
}

- (void)resortApps
{
    [self rebuildVisibleApps];
    [self.tableView reloadData];
    [self.tableView reloadSectionIndexTitles];
}

// Long-press: copy the bundle ID or container path, open the data folder.
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (_busy || (NSUInteger)indexPath.row >= self.visibleApps.count) return nil;
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        NSMutableArray *actions = [NSMutableArray new];
        if (app.bundleID.length) {
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Copy Bundle ID") image:[UIImage systemImageNamed:@"tag"] identifier:nil
                                                  handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = app.bundleID; }]];
        }
        [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Copy Container Path") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                                              handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = app.container; }]];
        if (app.hasAccess) {
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Open Data Folder") image:[UIImage systemImageNamed:@"folder"] identifier:nil
                                                  handler:^(UIAction *__unused a) {
                [weakSelf.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:app.container title:app.name]
                                                         animated:YES];
            }]];
        }
        // Only where bundle containers open (see the startup check).
        NSString *bundlePath = app.bundleID.length && wq_app_bundles_reachable() && wq_display_names_loaded()
            ? wq_bundle_path_for_id(app.bundleID) : nil;
        if (bundlePath.length) {
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Open App Bundle") image:[UIImage systemImageNamed:@"app.badge"] identifier:nil
                                                  handler:^(UIAction *__unused a) {
                [weakSelf.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:bundlePath title:app.name]
                                                         animated:YES];
            }]];
        }
        return [UIMenu menuWithChildren:actions];
    }];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self rebuildVisibleApps];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (_busy && !_apps.count) ? 1 : (NSInteger)self.visibleApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_status) return _status;
    unsigned long long total = 0;
    for (WQAppItem *a in _apps) total += a.bytes;
    if (_query.length || [NSUserDefaults.standardUserDefaults integerForKey:kWQAppsFilterPref] > 0)
        return WQLocalizedFormat(@"%lu of %lu apps", (unsigned long)self.visibleApps.count, (unsigned long)_apps.count);
    return WQLocalizedFormat(@"%lu apps · %@ of app data", (unsigned long)_apps.count, wq_size_text(total));
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return WQLocalized(@"Tap an app to back up, restore or clear its Documents and Library. Close the app first (swipe it away in the app switcher); operations are not snapshot-consistent while it runs. Backups are stored in WQFiles/AppBackups and are visible in the Files app. tmp is cleared when requested but is not backed up or restored.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_busy && !_apps.count) {
        c.text = WQLocalizedNullable(@"Scanning…");
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    c.text = app.name;
    NSString *identifier = app.bundleID.length ? app.bundleID : app.container.lastPathComponent;
    BOOL hasBackup = app.backups.count > 0;
    if (!app.hasAccess) {
        c.secondaryText = WQLocalizedFormat(@"Access unavailable · %@", identifier);
    } else if (!app.bundleID.length) {
        c.secondaryText = WQLocalizedFormat(@"%@ · %@ · no identifier", wq_size_text(app.bytes), identifier);
    } else if (!app.hasIdentity) {
        c.secondaryText = WQLocalizedFormat(@"%@ · %@ · container identity unavailable", wq_size_text(app.bytes), app.bundleID);
    } else if (!app.sizeKnown) {
        c.secondaryText = WQLocalizedFormat(@"size unavailable · %@%@", app.bundleID, hasBackup ? WQLocalized(@" · backed up") : @"");
    } else {
        c.secondaryText = WQLocalizedFormat(@"%@ · %@%@", wq_size_text(app.bytes), app.bundleID, hasBackup ? WQLocalized(@" · backed up") : @"");
    }
    if (app.installState == WQInstallOffloaded) c.secondaryText = [c.secondaryText stringByAppendingString:WQLocalized(@" · offloaded")];
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.image = wq_app_icon(app.bundleID) ?: [UIImage systemImageNamed:@"app.dashed"];
    c.imageProperties.maximumSize = CGSizeMake(36, 36);
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_busy || !self.visibleApps.count) return;
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    if (!app.hasAccess || !app.bundleID.length || !app.hasIdentity) {
        NSString *why = app.hasAccess && app.bundleID.length && !app.hasIdentity
            ? WQLocalized(@"The container identity is unavailable or changed. Backup, restore and clear are disabled for this entry.")
            : app.hasAccess
            ? WQLocalized(@"The container identifier is unavailable. Backup, restore and clear are disabled for this entry.")
            : WQLocalized(@"Sandbox access is unavailable. Check the App Group and see Log; only the container path can be copied.");
        UIAlertController *sheet = wq_alert_controller(WQVerbatim(app.name), WQVerbatim([NSString stringWithFormat:@"%@\n\n%@", app.container, why]), UIAlertControllerStyleActionSheet);
        if (app.hasAccess) {
            [sheet addAction:wq_alert_action(WQLocalized(@"Open Data Folder"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:app.container title:app.name] animated:YES];
            })];
        }
        [sheet addAction:wq_alert_action(WQLocalized(@"Copy Container Path"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            UIPasteboard.generalPasteboard.string = app.container;
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = wq_alert_controller(WQVerbatim(app.name), [NSString stringWithFormat:@"%@\n%@", app.bundleID,
                 app.sizeKnown ? WQLocalizedFormat(@"%@ of data", wq_size_text(app.bytes)) : WQLocalized(@"size unavailable")], UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Back Up Data"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self backUp:app then:nil];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Import as Backup…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self pickImportFor:app];
    })];
    NSArray *backups = app.backups;
    NSString *latest = backups.firstObject[@"path"];
    if (latest) {
        NSString *title = backups.count == 1 ? WQLocalizedFormat(@"Restore Backup (%@)", wq_backup_label(backups.firstObject))
                                             : WQLocalizedFormat(@"Restore a Backup… (%lu)", (unsigned long)backups.count);
        [sheet addAction:wq_alert_action(title, UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self pickBackupToRestore:app from:[tableView cellForRowAtIndexPath:indexPath]];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Share Latest Backup (AirDrop…)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
            wq_share_folder(self, latest, [NSString stringWithFormat:@"%@ %@", app.name, latest.lastPathComponent], c);
        })];
    }
    if (wq_deleting_allowed()) {
        [sheet addAction:wq_alert_action(WQLocalized(@"Clear Data…"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
            [self confirmClear:app];
        })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Open Data Folder"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:app.container title:app.name] animated:YES];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Copy Bundle ID"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        UIPasteboard.generalPasteboard.string = app.bundleID;
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)finish:(NSString *)title message:(NSString *)message
{
    [self setBusy:NO status:nil];
    wq_alert(self, title, message);
    [self scan];
}

// Import as Backup: a folder or ZIP with Documents and/or Library (from the
// Files app, another device's shared backup or another tool) becomes a
// normal, verified backup of this app, ready to restore.
- (void)pickImportFor:(WQAppItem *)app
{
    _importApp = app;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder, UTTypeZIP] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    WQAppItem *app = _importApp;
    _importApp = nil;
    if (app && urls.firstObject) [self importBackupFrom:urls.firstObject for:app confirmedDeclarations:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    _importApp = nil;
}

// `confirmed`: the declared bundle IDs the user already agreed to import
// anyway; the import asks again if the data now declares anything else.
- (void)importBackupFrom:(NSURL *)url for:(WQAppItem *)app confirmedDeclarations:(NSArray<NSString *> *)confirmed
{
    [self setBusy:YES status:WQLocalizedFormat(@"Importing a backup of %@…", app.name)];
    NSString *bundleID = app.bundleID;
    dispatch_async(wq_io(), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        __block NSString *error = nil, *dest = nil;
        __block NSArray<NSString *> *declared = @[];
        __block NSArray *ignored = @[];
        NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [@"wq-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *coordinationError = nil;
        // Coordinated, so a folder in iCloud Drive is downloaded first.
        [[NSFileCoordinator new] coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges
                                                      error:&coordinationError byAccessor:^(NSURL *readURL) {
            NSString *source = readURL.path;
            BOOL isDir = NO;
            [fm fileExistsAtPath:source isDirectory:&isDir];
            if (!isDir) {
                // A ZIP: unpack it locally first, with the usual safety checks.
                struct statfs fs;
                unsigned long long available = statfs(NSTemporaryDirectory().fileSystemRepresentation, &fs) == 0
                    ? (unsigned long long)fs.f_bavail * fs.f_bsize : 0;
                unsigned long long reserve = 256ull * 1024 * 1024;
                unsigned long long limit = available > reserve ? (available - reserve) / 2 : 0;
                [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
                NSUInteger files = 0, skipped = 0;
                if (!wq_zip_extract(source, work, wq_archive_posix_io(), limit, nil, nil, &files, &skipped, &error)) {
                    error = WQLocalizedFormat(@"The ZIP couldn't be unpacked: %@", error ?: WQLocalized(@"unknown error"));
                    return;
                }
                source = work;
            }
            NSString *root = WQAppsSupportImportRoot(source, &error);
            if (!root) return;
            // Every identity declaration counts: a manifest naming this app
            // must not hide container metadata naming another one.
            NSString *invalid = nil;
            declared = WQAppsSupportImportDeclaredBundles(root, &invalid);
            if (invalid) {
                error = WQLocalizedFormat(@"The data names an invalid app identifier (%@).", invalid);
                return;
            }
            BOOL foreign = declared.count > 1 || (declared.count == 1 && ![declared.firstObject isEqualToString:bundleID]);
            if (foreign && ![[NSSet setWithArray:confirmed ?: @[]] isEqualToSet:[NSSet setWithArray:declared]]) return;   // ask first
            ignored = WQAppsSupportImportIgnored(root);
            NSDictionary *extra = foreign ? @{ @"ImportDeclaredBundleIDs": declared } : nil;
            dest = wq_make_backup_from(bundleID, root, kBackupReasonImported, extra, nil, &error);
        }];
        if (coordinationError && !error && !dest) error = coordinationError.localizedDescription;
        if (scoped) [url stopAccessingSecurityScopedResource];
        [fm removeItemAtPath:work error:nil];
        wq_log(@"import backup %@ from %@ (declares %@): %@%@", bundleID, url.lastPathComponent,
               declared.count ? [declared componentsJoinedByString:@", "] : @"nothing",
               dest ? dest.lastPathComponent : (error ?: @"needs confirmation"),
               ignored.count ? [NSString stringWithFormat:@" (left out: %@)", [ignored componentsJoinedByString:@", "]] : @"");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBusy:NO status:nil];
            if (!dest && !error && declared.count) {
                NSString *names = [declared componentsJoinedByString:@", "];
                NSString *text = declared.count == 1
                    ? WQLocalizedFormat(@"This data says it belongs to %@, not %@ (%@). Importing it as a backup of %@ and restoring it can break the app.",
                                        names, app.name, bundleID, app.name)
                    : WQLocalizedFormat(@"This data names more than one app (%@). Importing it as a backup of %@ (%@) and restoring it can break the app.",
                                        names, app.name, bundleID);
                UIAlertController *ask = wq_alert_controller(@"Different app?", text, UIAlertControllerStyleAlert);
                [ask addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
                [ask addAction:wq_alert_action(@"Import Anyway", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
                    [self importBackupFrom:url for:app confirmedDeclarations:declared];
                })];
                [self presentViewController:ask animated:YES completion:nil];
                return;
            }
            if (!dest) {
                wq_alert(self, @"Not imported", WQLocalizedFormat(@"%@ Nothing was changed.", error ?: WQLocalized(@"The import failed.")));
                return;
            }
            NSString *message = WQLocalizedFormat(@"Saved as backup %@ of %@. It's verified like any other backup and can be restored from Apps.%@",
                dest.lastPathComponent, app.name,
                ignored.count ? WQLocalizedFormat(@"\n\nLeft out (only Documents and Library are backed up): %@.",
                                                  [ignored componentsJoinedByString:@", "]) : @"");
            UIAlertController *done = wq_alert_controller(@"Imported", message, UIAlertControllerStyleAlert);
            [done addAction:wq_alert_action(@"Done", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) {
                [self scan];
            })];
            [done addAction:wq_alert_action(@"Restore Now…", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                self->_restoreBundleID = bundleID;   // offered once the list is read again
                [self scan];
            })];
            [self presentViewController:done animated:YES completion:nil];
        });
    });
}

- (void)backUp:(WQAppItem *)app then:(void (^)(BOOL ok))next
{
    [self setBusy:YES status:WQLocalizedFormat(@"Backing up %@…", app.name)];
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSString *dest = wq_make_app_backup(app.bundleID, app.container, app.containerDevice,
                                             app.containerInode, nil, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (next) { next(dest != nil); return; }
            [self finish:dest ? WQLocalized(@"Backed up") : WQLocalized(@"Backup failed")
                 message:dest ? WQLocalizedFormat(@"Saved to AppBackups/%@/%@", app.bundleID, dest.lastPathComponent)
                              : WQLocalizedFormat(@"Nothing was saved: %@", error ?: @"see Log")];
        });
    });
}

- (void)clear:(WQAppItem *)app
{
    [self setBusy:YES status:WQLocalizedFormat(@"Clearing %@…", app.name)];
    dispatch_async(wq_io(), ^{
        unsigned long long freed = 0;
        NSString *error = nil;
        BOOL ok = wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error);
        for (NSString *part in kAppDataParts()) {
            if (!ok) break;
            if (!wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error) ||
                !wq_purge_and_verify([app.container stringByAppendingPathComponent:part], &freed, &error)) ok = NO;
        }
        if (ok && !wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) ok = NO;
        wq_log(@"clear data: %@ freed %llu ok=%d", app.bundleID, freed, ok);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finish:ok ? WQLocalized(@"Data cleared") : WQLocalized(@"Partly cleared")
                 message:WQLocalizedFormat(@"Freed about %@.%@ Open %@ to start fresh.", wq_size_text(freed),
                          ok ? @"" : WQLocalizedFormat(@" %@. Keep the app closed and try again.", error ?: WQLocalized(@"Some items could not be removed (see Log)")), app.name)];
        });
    });
}

- (void)confirmClear:(WQAppItem *)app
{
    if (wq_refuse_if_deleting_off(self)) return;
    UIAlertController *alert = wq_alert_controller(WQLocalizedFormat(@"Clear %@?", app.name),
        @"Deletes everything in the app's Documents, Library and tmp, like a fresh install. "
                "The optional backup covers Documents and Library only; tmp is discarded and cannot be restored. "
                "Logins, settings and offline content are lost. Close the app first.", UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(WQLocalized(@"Back Up, Then Clear"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self backUp:app then:^(BOOL ok) {
            if (ok) [self clear:app];
            else [self finish:WQLocalized(@"Not cleared") message:WQLocalized(@"The backup did not complete, so nothing was deleted.")];
        }];
    })];
    [alert addAction:wq_alert_action(WQLocalized(@"Clear Without Backup"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self clear:app];
    })];
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (_apps && !_scanning) [self offerPendingRestore];   // the list was read before the push finished
}

- (void)offerPendingRestore
{
    NSString *bid = _restoreBundleID;
    if (!bid || !self.view.window || self.presentedViewController) return;
    _restoreBundleID = nil;
    WQAppItem *app = nil;
    for (WQAppItem *candidate in _apps) if ([candidate.bundleID isEqualToString:bid]) { app = candidate; break; }
    if (!app) {
        wq_alert(self, @"App not found", WQLocalizedFormat(@"%@ isn't installed, or WQ Files can't reach its data. "
                 "A backup can only be restored into the installed app: install it, open it once, then try again.", bid));
    } else if (!app.backups.count) {
        wq_alert(self, @"No backup", WQLocalizedFormat(@"There is no complete backup of %@ to restore.", app.name));
    } else {
        [self pickBackupToRestore:app from:nil];
    }
}

- (void)pickBackupToRestore:(WQAppItem *)app from:(UIView *)source
{
    NSArray *backups = app.backups;
    if (backups.count == 1) { [self confirmRestore:app from:backups.firstObject]; return; }
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Restore which backup?"), WQVerbatim(app.name), UIAlertControllerStyleActionSheet);
    for (NSDictionary *__unused b in backups) {
        [sheet addAction:wq_alert_action(wq_backup_label(b), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { [self confirmRestore:app from:b]; })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = (source ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRestore:(WQAppItem *)app from:(NSDictionary *)backup
{
    NSString *path = backup[@"path"];
    NSString *warning = [backup[@"verified"] boolValue] ? @""
        : WQLocalizedFormat(@"\n\nThis backup is unverified (%@). WQ Files will re-check its parts before changing anything.", backup[@"reason"] ?: WQLocalized(@"no typed manifest"));
    NSString *body = wq_keep_before_restore()
        ? WQLocalizedFormat(@"Replaces the app's current Documents and Library with the backup from %@; tmp is left untouched. The current data is backed up first, and put back if anything fails. Close the app first: a running app can make the operation non-snapshot-consistent.%@", wq_backup_label(backup), warning)
        : WQLocalizedFormat(@"Replaces the app's current Documents and Library with the backup from %@; tmp is left untouched. The current data is backed up first, and put back if anything fails; after a successful restore that backup is deleted (Keep Data Before Restore is off). Close the app first: a running app can make the operation non-snapshot-consistent.%@", wq_backup_label(backup), warning);
    UIAlertController *alert = wq_alert_controller(WQLocalizedFormat(@"Restore %@?", app.name), body, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(WQLocalized(@"Restore"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self setBusy:YES status:WQLocalizedFormat(@"Restoring %@…", app.name)];
        dispatch_async(wq_io(), ^{
            // A backup whose files were swapped (e.g. from another backup
            // tool) no longer matches its manifest: ask before using it.
            NSString *checkError = nil;
            NSDictionary *approved = nil;
            NSDictionary *edited = [backup[@"verified"] boolValue] ? wq_backup_edited_parts(path, app.bundleID, &approved, &checkError) : @{};
            if (!edited) {
                NSString *message = WQLocalizedFormat(@"The backup is not safe to restore (%@). Nothing was changed.",
                                                       checkError ?: WQLocalized(@"The selected backup changed before restore"));
                dispatch_async(dispatch_get_main_queue(), ^{ [self finish:WQLocalized(@"Not restored") message:message]; });
                return;
            }
            if (edited.count) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setBusy:NO status:nil];
                    [self confirmEditedRestore:app from:path edited:edited approved:approved];
                });
                return;
            }
            NSString *title = nil, *message = nil;
            [self restore:app from:path title:&title message:&message];
            dispatch_async(dispatch_get_main_queue(), ^{ [self finish:title message:message]; });
        });
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmEditedRestore:(WQAppItem *)app from:(NSString *)path edited:(NSDictionary<NSString *, NSString *> *)edited
                 approved:(NSDictionary<NSString *, NSString *> *)approved
{
    NSString *parts = [[edited.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "];
    wq_log(@"restore %@: backup %@ was edited after it was made (%@)", app.bundleID, path.lastPathComponent, parts);
    UIAlertController *alert = wq_alert_controller(@"Backup was edited",
        WQLocalizedFormat(@"The files in %@ of this backup changed after WQ Files made it, for example because files from another backup were put in. Restore the backup as it is now? The app's current data is still backed up first.", parts),
        UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(WQLocalized(@"Restore Anyway"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self setBusy:YES status:WQLocalizedFormat(@"Restoring %@…", app.name)];
        dispatch_async(wq_io(), ^{
            NSString *title = nil, *message = nil;
            [self restore:app from:path accepting:approved title:&title message:&message];
            dispatch_async(dispatch_get_main_queue(), ^{ [self finish:title message:message]; });
        });
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

// Replaces one part (Documents/Library) of the container with `src`.
static BOOL wq_replace_part(NSString *src, NSString *dst, NSString **error)
{
    // Stage the source before purging the live destination. If a named safety
    // part disappears or becomes unreadable, no live data may be purged first.
    NSString *staging = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"WQAppsRestore-%@", NSUUID.UUID.UUIDString]];
    BOOL staged = wq_copy_part_and_verify(src, staging, NULL, error);
    if (!staged) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        return NO;
    }
    unsigned long long ignored = 0;
    BOOL ok = wq_purge_and_verify(dst, &ignored, error);
    if (ok) {
        ok = wq_copy_part_and_verify(staging, dst, NULL, error);
        if (!ok && error && !*error) *error = [NSString stringWithFormat:@"Could not restore %@", dst.lastPathComponent];
    }
    [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
    return ok;
}

static NSString *wq_restore_journal_path(void)
{
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"active-restore.plist"];
}

static BOOL wq_read_restore_journal(NSMutableDictionary **journalOut, BOOL *existsOut, NSString **error)
{
    if (journalOut) *journalOut = nil;
    if (existsOut) *existsOut = NO;
    NSString *path = wq_restore_journal_path();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
    NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![journal isKindOfClass:NSDictionary.class]) {
        if (error) *error = @"The restore recovery journal is unreadable";
        return NO;
    }
    if (existsOut) *existsOut = YES;
    if (journalOut) *journalOut = [journal mutableCopy];
    return YES;
}

static BOOL wq_write_restore_journal(NSDictionary *journal, NSString **error)
{
    NSString *path = wq_restore_journal_path();
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:nil]) {
        if (error) *error = @"Cannot create the restore recovery folder";
        return NO;
    }
    if (![journal writeToFile:path atomically:YES]) {
        if (error) *error = @"Cannot write the restore recovery journal";
        return NO;
    }
    return YES;
}

static BOOL wq_remove_restore_journal(NSString **error);

static BOOL wq_begin_restore_journal(WQAppItem *app, NSString *backup, NSString *safety, NSString **error)
{
    if (!wq_backup_root_child(backup, app.bundleID) || !wq_backup_root_child(safety, app.bundleID)) {
        if (error) *error = WQLocalized(@"The restore paths are not inside this app's backup folder");
        return NO;
    }
    BOOL exists = NO;
    NSMutableDictionary *existing = nil;
    NSString *readError = nil;
    if (!wq_read_restore_journal(&existing, &exists, &readError)) {
        if (error) *error = readError;
        return NO;
    }
    if (exists) {
        WQAppsSupportJournalState state = WQAppsSupportJournalStateForDictionary(existing);
        NSString *policyError = nil;
        if (!WQAppsSupportJournalAllowsNewRestore(state, &policyError)) {
            if (error) *error = policyError ? WQLocalized(policyError) : nil;
            return NO;
        }
        if (state == WQAppsSupportJournalCommitted &&
            !wq_remove_restore_journal(&readError)) {
            if (error) *error = readError ?: @"Cannot remove the completed restore journal";
            return NO;
        }
    }
    NSDictionary *journal = @{ @"Format": @2, @"State": @"Active", @"BundleID": app.bundleID,
                               @"Container": app.container, @"Backup": backup, @"Safety": safety,
                               @"ContainerDevice": @(app.containerDevice), @"ContainerInode": @(app.containerInode),
                               @"Started": NSDate.date };
    return wq_write_restore_journal(journal, error);
}

// Marking committed is the point of no return for a completed restore. It is
// deliberately separate from removal: a committed journal must never cause a
// later rollback, even if the file itself cannot be deleted right now.
static BOOL wq_mark_restore_journal_committed(NSString **error)
{
    BOOL exists = NO;
    NSMutableDictionary *journal = nil;
    NSString *readError = nil;
    if (!wq_read_restore_journal(&journal, &exists, &readError)) {
        if (error) *error = readError;
        return NO;
    }
    if (!exists) return YES;
    journal[@"State"] = @"Committed";
    return wq_write_restore_journal(journal, error);
}

static BOOL wq_remove_restore_journal(NSString **error)
{
    NSString *path = wq_restore_journal_path();
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) return YES;
    NSError *removeError = nil;
    if (![fm removeItemAtPath:path error:&removeError]) {
        if (error) *error = removeError.localizedDescription ?: @"Cannot remove the restore recovery journal";
        return NO;
    }
    return YES;
}

static BOOL wq_finish_restore_journal(NSString **error)
{
    if (!wq_mark_restore_journal_committed(error)) return NO;
    return wq_remove_restore_journal(error);
}

// `accepted` (optional): part -> content hash the user confirmed for a backup
// that was edited after it was made (files swapped in from another backup).
// The backup must still match what was confirmed, so nothing changes unseen
// between the confirmation and the restore.
static BOOL wq_validate_backup_hashes_accepting(NSString *backup, NSArray<NSString *> *parts,
                                                NSDictionary *manifest, NSDictionary<NSString *, NSString *> *accepted,
                                                NSString **error)
{
    NSDictionary *hashes = manifest[@"PartHashes"];
    if (!hashes && !accepted) return YES;   // backups made before content hashes existed
    if (accepted && ![[NSSet setWithArray:accepted.allKeys] isEqualToSet:[NSSet setWithArray:parts]]) {
        if (error) *error = WQLocalized(@"The selected backup changed before restore");
        return NO;
    }
    for (NSString *part in parts) {
        NSString *expected = accepted[part] ?: hashes[part];
        if (![expected isKindOfClass:NSString.class] || !expected.length) {
            if (error) *error = WQLocalizedFormat(@"The backup has no hash for %@", part);
            return NO;
        }
        BOOL exists = NO;
        NSString *actual = WQAppsSupportTreeContentSignature([backup stringByAppendingPathComponent:part],
                                                              &exists, error);
        if (!actual || !exists || ![actual isEqualToString:expected]) {
            if (error) *error = WQLocalizedFormat(@"The backup's %@ contents changed after it was created", part);
            return NO;
        }
    }
    return YES;
}

static BOOL wq_validate_backup_hashes(NSString *backup, NSArray<NSString *> *parts,
                                      NSDictionary *manifest, NSString **error)
{
    return wq_validate_backup_hashes_accepting(backup, parts, manifest, nil, error);
}

// Parts whose contents differ from the manifest (part -> current hash), or
// nil with an error. Empty when the backup is as it was made.
static NSDictionary<NSString *, NSString *> *wq_backup_edited_parts(NSString *backup, NSString *bundleID, NSDictionary **approved, NSString **error)
{
    NSArray<NSString *> *parts = nil;
    NSDictionary *manifest = nil;
    if (!wq_validate_backup(backup, bundleID, YES, &parts, &manifest, NULL, error)) return nil;
    NSDictionary *hashes = manifest[@"PartHashes"];
    NSMutableDictionary *edited = [NSMutableDictionary new];
    NSMutableDictionary *current = [NSMutableDictionary new];
    if (![hashes isKindOfClass:NSDictionary.class]) return edited;
    for (NSString *part in parts) {
        BOOL exists = NO;
        NSString *actual = WQAppsSupportTreeContentSignature([backup stringByAppendingPathComponent:part], &exists, error);
        if (!actual || !exists) return nil;
        current[part] = actual;
        if (![actual isEqual:hashes[part]]) edited[part] = actual;
    }
    *approved = [current copy];
    return edited;
}

static BOOL wq_rollback_safety(NSString *container, NSString *bundleID, NSString *safety,
                               dev_t expectedDevice, ino_t expectedInode, NSString **error)
{
    NSArray<NSString *> *parts = nil;
    NSDictionary *safetyManifest = nil;
    if (!wq_validate_container(container, bundleID, expectedDevice, expectedInode, error) ||
        !wq_validate_backup(safety, bundleID, NO, &parts, &safetyManifest, NULL, error) ||
        !wq_validate_backup_hashes(safety, parts, safetyManifest, error)) return NO;
    // Revalidate everything immediately before the first mutation. In
    // particular, a missing named safety part is never interpreted as an
    // instruction to purge the live part.
    if (!wq_validate_container(container, bundleID, expectedDevice, expectedInode, error) ||
        !wq_validate_backup(safety, bundleID, NO, &parts, &safetyManifest, NULL, error) ||
        !wq_validate_backup_hashes(safety, parts, safetyManifest, error)) return NO;
    BOOL ok = YES;
    for (NSString *part in kAppBackupParts()) {
        NSString *saved = [safety stringByAppendingPathComponent:part];
        NSString *dst = [container stringByAppendingPathComponent:part];
        if (!wq_validate_container(container, bundleID, expectedDevice, expectedInode, error)) {
            ok = NO;
            break;
        }
        if ([parts containsObject:part]) {
            if (!wq_replace_part(saved, dst, error)) ok = NO;
        } else {
            unsigned long long ignored = 0;
            if (!wq_purge_and_verify(dst, &ignored, error)) {
                ok = NO;
            }
        }
        if (!ok) break;
    }
    if (ok && !wq_validate_container(container, bundleID, expectedDevice, expectedInode, error)) ok = NO;
    return ok;
}

// Called on the serial I/O queue at launch. An active journal means termination
// may have left only some restored parts in place, so reapply the safety state.
NSString *wq_recover_interrupted_restore(void)
{
    NSString *path = wq_restore_journal_path();
    NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!journal) return nil;
    NSString *state = [journal[@"State"] isKindOfClass:NSString.class] ? journal[@"State"] : nil;
    if ([state isEqualToString:@"Committed"]) {
        NSString *removeError = nil;
        if (!wq_remove_restore_journal(&removeError)) {
            wq_log(@"restore recovery: committed journal cleanup failed: %@", removeError);
        }
        return nil;
    }
    if (![state isEqualToString:@"Active"]) {
        wq_log(@"restore recovery: unknown journal state at %@", path);
        return WQLocalized(@"An interrupted restore was found with an unknown recovery state. The journal was retained for manual recovery.");
    }
    NSString *bundleID = journal[@"BundleID"], *container = journal[@"Container"], *safety = journal[@"Safety"];
    NSString *backup = journal[@"Backup"];
    id deviceValue = journal[@"ContainerDevice"];
    id inodeValue = journal[@"ContainerInode"];
    NSString *journalError = nil;
    BOOL stringFields = [bundleID isKindOfClass:NSString.class] && [container isKindOfClass:NSString.class] &&
        [safety isKindOfClass:NSString.class] && [backup isKindOfClass:NSString.class];
    BOOL identityFields = WQAppsSupportIsInteger(deviceValue) && WQAppsSupportIsInteger(inodeValue) &&
        [deviceValue compare:@1] != NSOrderedAscending && [inodeValue compare:@1] != NSOrderedAscending;
    dev_t device = identityFields ? [deviceValue unsignedLongLongValue] : 0;
    ino_t inode = identityFields ? [inodeValue unsignedLongLongValue] : 0;
    BOOL journalTyped = stringFields && WQAppsSupportIsInteger(journal[@"Format"]) && [journal[@"Format"] unsignedIntegerValue] == 2 &&
        identityFields && bundleID.length && container.length && safety.length && backup.length && device && inode &&
        wq_backup_root_child(backup, bundleID) && wq_backup_root_child(safety, bundleID) &&
        wq_validate_container(container, bundleID, device, inode, &journalError);
    if (!journalTyped) {
        wq_log(@"restore recovery: invalid journal or incomplete safety backup at %@", path);
        return [NSString stringWithFormat:WQLocalized(@"An interrupted restore was found, but its recovery journal is invalid. The journal was retained for manual recovery%@."),
                journalError.length ? [NSString stringWithFormat:@" (%@)", journalError] : @""];
    }
    NSString *error = nil;
    if (!wq_rollback_safety(container, bundleID, safety, device, inode, &error)) {
        wq_log(@"restore recovery for %@: FAILED (%@)", bundleID, error);
        return [NSString stringWithFormat:WQLocalized(@"Automatic recovery of %@ failed: %@. The safety backup is %@; see Log."),
                bundleID, error ?: WQLocalized(@"unknown error"), safety.lastPathComponent];
    }
    NSString *commitError = nil;
    NSString *removeError = nil;
    if (!wq_mark_restore_journal_committed(&commitError)) {
        wq_log(@"restore recovery for %@: recovered, journal commit failed (%@)", bundleID, commitError);
        return [NSString stringWithFormat:WQLocalized(@"An interrupted restore of %@ was recovered, but its journal could not be committed (%@). It will be checked again at the next launch."),
                bundleID, commitError ?: WQLocalized(@"unknown error")];
    }
    if (!wq_remove_restore_journal(&removeError)) {
        wq_log(@"restore recovery for %@: recovered, cleanup pending (%@)", bundleID, removeError);
        return [NSString stringWithFormat:WQLocalized(@"An interrupted restore of %@ was recovered. Its committed journal will be cleaned up at the next launch (%@)."),
                bundleID, removeError ?: @"cleanup failed"];
    }
    wq_log(@"restore recovery for %@: OK", bundleID);
    return [NSString stringWithFormat:WQLocalized(@"An interrupted restore of %@ was recovered from its safety backup."), bundleID];
}

- (void)restore:(WQAppItem *)app from:(NSString *)backup title:(NSString **)title message:(NSString **)message
{
    [self restore:app from:backup accepting:nil title:title message:message];
}

- (void)restore:(WQAppItem *)app from:(NSString *)backup accepting:(NSDictionary<NSString *, NSString *> *)accepted
          title:(NSString **)title message:(NSString **)message
{
    // 1. Validate all typed manifest fields and all required parts before any
    // safety backup, journal, purge, or replacement is allowed.
    NSArray<NSString *> *parts = nil;
    NSDictionary *manifest = nil;
    BOOL verified = NO;
    NSString *error = nil;
    if (!wq_validate_backup(backup, app.bundleID, YES, &parts, &manifest, &verified, &error)) {
        *title = WQLocalized(@"Not restored");
        *message = WQLocalizedFormat(@"The backup is not safe to restore (%@). Nothing was changed.", error ?: WQLocalized(@"invalid manifest"));
        return;
    }
    if (!parts.count) {
        // Restoring nothing would empty the app's Documents and Library.
        // Older versions could save such an empty backup when access failed.
        *title = WQLocalized(@"Not restored");
        *message = verified ? WQLocalized(@"This backup is empty (it was made while WQ Files had no access to the app). Restoring it would delete the app's data, so nothing was changed.")
                            : WQLocalized(@"The legacy backup is empty. Nothing was changed.");
        return;
    }
    if (!wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) {
        *title = WQLocalized(@"Not restored");
        *message = WQLocalizedFormat(@"The selected app container is no longer safe to use (%@). Nothing was changed.", error);
        return;
    }
    // 2. Keep the current data and a durable recovery journal before touching
    // anything, so both ordinary failures and process termination are covered.
    NSString *safety = wq_make_app_backup(app.bundleID, app.container, app.containerDevice,
                                           app.containerInode, kBackupReasonBeforeRestore, &error);
    if (!safety) {
        *title = WQLocalized(@"Not restored");
        *message = WQLocalizedFormat(@"The current data couldn't be backed up first (%@). Nothing was changed.", error ?: WQLocalized(@"see Log"));
        return;
    }
    // Copy every part into private staging and verify the exact copies that
    // will be installed before starting a journal or touching live data.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *staging = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [@"WQAppsRestore-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *stageError = nil;
    BOOL staged = [fm createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:nil error:&stageError];
    for (NSString *part in parts) {
        if (!staged) break;
        staged = wq_copy_part_and_verify([backup stringByAppendingPathComponent:part],
                                        [staging stringByAppendingPathComponent:part], NULL, &error);
    }
    if (!staged ||
        !wq_validate_backup_hashes_accepting(staging, parts, manifest, accepted, &error) ||
        !wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error) ||
        !wq_begin_restore_journal(app, backup, safety, &error)) {
        [fm removeItemAtPath:staging error:nil];
        *title = WQLocalized(@"Not restored");
        *message = WQLocalizedFormat(@"The backup is not safe to restore (%@). Nothing was changed.",
                                     error ?: stageError.localizedDescription ?: WQLocalized(@"The selected backup changed before restore"));
        return;
    }
    BOOL ok = YES;
    NSDictionary *restorePlan = WQRestorePlan([parts containsObject:@"Documents"],
                                               [parts containsObject:@"Library"]);
    for (NSString *part in kAppBackupParts()) {
        if (!ok) break;
        NSString *src = [staging stringByAppendingPathComponent:part];
        NSString *dst = [app.container stringByAppendingPathComponent:part];
        if (!wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) {
            ok = NO;
            break;
        }
        if ([restorePlan[part] boolValue]) {
            unsigned long long ignored = 0;
            if (!wq_purge_and_verify(dst, &ignored, &error) ||
                !wq_copy_part_and_verify(src, dst, NULL, &error)) { ok = NO; break; }
        } else {
            unsigned long long ignored = 0;
            if (!wq_purge_and_verify(dst, &ignored, &error)) {
                ok = NO;
                break;
            }
        }
    }
    [fm removeItemAtPath:staging error:nil];
    if (ok && !wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error))
        ok = NO;
    if (ok) {
        NSString *commitError = nil;
        NSString *removeError = nil;
        if (wq_mark_restore_journal_committed(&commitError)) {
            BOOL removed = wq_remove_restore_journal(&removeError);
            if (!removed) wq_log(@"restore %@: journal cleanup pending (%@)", app.bundleID, removeError);
            wq_log(@"restore %@ from %@: OK", app.bundleID, backup.lastPathComponent);
            *title = WQLocalized(@"Restored");
            NSString *cleanup = removed ? @"" : WQLocalized(@" The recovery journal is committed and will be cleaned up at the next launch.");
            // Keep Data Before Restore off: the safety backup was only needed
            // while the restore could still fail. Kept while the journal still
            // points at it.
            NSString *discardError = nil;
            if (!wq_keep_before_restore() && removed) {
                if (wq_delete_backup(safety, &discardError)) {
                    wq_log(@"restore %@: removed the before-restore backup %@ (Keep Data Before Restore is off)",
                           app.bundleID, safety.lastPathComponent);
                    *message = WQLocalizedFormat(@"Open %@ to use the restored Documents and Library; tmp was not changed. The data from before was not kept (Keep Data Before Restore is off).", app.name);
                    return;
                }
                wq_log(@"restore %@: couldn't remove the before-restore backup %@ (%@)", app.bundleID,
                       safety.lastPathComponent, discardError);
            }
            *message = WQLocalizedFormat(@"Open %@ to use the restored Documents and Library. The data from before is kept as backup %@; tmp was not changed. Keep the app closed during this operation.%@", app.name, safety.lastPathComponent, cleanup);
            return;
        }
        // The journal is still Active. Rolling back is the only safe outcome
        // if it cannot be marked committed, because a completed restore must
        // not be rolled back by the next launch.
        error = WQLocalizedFormat(@"The restore finished, but its recovery journal could not be committed (%@)", commitError);
    }
    wq_log(@"restore %@ from %@: FAILED (%@), rolling back", app.bundleID, backup.lastPathComponent, error);
    NSString *rollbackError = nil;
    BOOL rolledBack = wq_rollback_safety(app.container, app.bundleID, safety,
                                          app.containerDevice, app.containerInode, &rollbackError);
    // Keep the journal when the rollback failed, so the next launch tries the
    // recovery again instead of leaving the app half restored.
    NSString *cleanupError = nil;
    BOOL cleared = NO;
    if (rolledBack) cleared = wq_finish_restore_journal(&cleanupError);
    if (!rolledBack) cleanupError = @"kept for recovery at the next launch";
    wq_log(@"restore %@: rollback %@, journal %@", app.bundleID,
           rolledBack ? @"OK" : @"FAILED", cleared ? @"cleared" : cleanupError);
    *title = WQLocalized(@"Restore failed");
    *message = rolledBack
        ? [NSString stringWithFormat:@"%@. The previous data was put back.%@", error ?: WQLocalized(@"Some files couldn't be written"),
           cleared ? @"" : WQLocalized(@" Recovery will run again at the next launch because the journal could not be removed.")]
        : [NSString stringWithFormat:@"%@, and putting the previous data back also failed (%@). It is in backup %@; see the Log.%@",
           error ?: WQLocalized(@"Some files couldn't be written"), rollbackError ?: WQLocalized(@"see Log"), safety.lastPathComponent,
           cleared ? @"" : WQLocalized(@" Recovery will run again at the next launch.")];
}

@end
