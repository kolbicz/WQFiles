//
//  WQLaunchServicesTests.m
//  Portable LaunchServices parser/cache regression tests.
//

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "WQAccess.h"
#import "WQLaunchServices.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void Put32(NSMutableData *data, NSUInteger offset, uint32_t value)
{
    memcpy((uint8_t *)data.mutableBytes + offset, &value, sizeof(value));
}

static NSData *StoreWithName(NSString *displayName)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000;
    const NSUInteger nameOffset = 0x1040;
    const NSUInteger displayOffset = 0x1080;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);
    Put32(data, recordOffset + 8 + 0x6c, 2u << 2);
    Put32(data, recordOffset + 8 + 0x74, 3u << 2);

    NSArray<NSString *> *values = @[@"com.example.international", @"Example", displayName];
    NSArray<NSNumber *> *offsets = @[@(idOffset), @(nameOffset), @(displayOffset)];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSData *utf8 = [values[i] dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger offset = offsets[i].unsignedIntegerValue;
        Put32(data, offset, (uint32_t)(i + 1));
        Put32(data, offset + 4, (uint32_t)utf8.length);
        memcpy(bytes + offset + 8, utf8.bytes, utf8.length);
        bytes[offset + 8 + utf8.length] = 0;
    }
    return data;
}

static NSData *StoreWithTruncatedDisplayName(void)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000;
    const NSUInteger truncatedOffset = 0x1ff0;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);
    Put32(data, recordOffset + 8 + 0x6c, 3u << 2);
    Put32(data, recordOffset + 8 + 0x74, 3u << 2);

    NSData *bundleID = [@"com.example.international" dataUsingEncoding:NSUTF8StringEncoding];
    Put32(data, idOffset, 1u);
    Put32(data, idOffset + 4, (uint32_t)bundleID.length);
    memcpy(bytes + idOffset + 8, bundleID.bytes, bundleID.length);
    bytes[idOffset + 8 + bundleID.length] = 0;

    const char *truncated = "Truncate";
    Put32(data, truncatedOffset, 3u);
    Put32(data, truncatedOffset + 4, 8u);
    memcpy(bytes + truncatedOffset + 8, truncated, 8);
    return data;
}

static NSString *TemporaryStorePath(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"WQLaunchServicesTests-%d.csstore", getpid()]];
}

static void WriteData(NSData *data, NSString *path)
{
    NSError *error = nil;
    WQCheck([data writeToFile:path options:NSDataWritingAtomic error:&error]);
    WQCheck(!error);
}

static void TestRetryAfterDiscoveryFailure(NSString *path)
{
    NSMutableData *invalid = [NSMutableData dataWithLength:0x0fff];
    memcpy(invalid.mutableBytes, "bdsl", 4);
    WriteData(invalid, path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    WQCheck(wq_display_name(@"com.example.international") == nil);

    WriteData(StoreWithName(@"Retry 日本"), path);
    sleep(2); // The bounded retry backoff starts at one second.
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Retry 日本"]);
}

static void TestRefreshAndUnicodeSafety(NSString *path)
{
    WriteData(StoreWithName(@"Cafe\u0301 日本 \u202Eevil"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Café 日本 �evil"]);

    // Invisible marks are dropped (WhatsApp's name starts with U+200E),
    // reordering controls only wrapped around the whole name too.
    WriteData(StoreWithName(@"\u200EWA Business"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"WA Business"]);
    WriteData(StoreWithName(@"\u202B\u0648\u0627\u062A\u0633\u0627\u0628\u202C"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"\u0648\u0627\u062A\u0633\u0627\u0628"]);
    WriteData(StoreWithName(@"Mail\u200D\U0001F468\u200B"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Mail\u200D\U0001F468"]);

    WriteData(StoreWithTruncatedDisplayName(), path);
    WQCheck(wq_display_name(@"com.example.international") == nil);

    WriteData(StoreWithName(@"Fresh name"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Fresh name"]);
}

static void PutString(NSMutableData *data, NSUInteger offset, uint32_t sid, NSString *value)
{
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    Put32(data, offset, sid);
    Put32(data, offset + 4, (uint32_t)utf8.length);
    memcpy((uint8_t *)data.mutableBytes + offset + 8, utf8.bytes, utf8.length);
    // No terminator when the length is a multiple of 4, like the real store;
    // fill the next word so a missing-terminator bug would read garbage.
    if (utf8.length % 4 == 0) ((uint8_t *)data.mutableBytes)[offset + 8 + utf8.length] = 0x30;
    else ((uint8_t *)data.mutableBytes)[offset + 8 + utf8.length] = 0;
}

static NSString *const kAppPath = @"/private/var/mobile/Containers/Data/Application/4CE791DB-6B04-4A39-8F59-AF32BA61D494";
static NSString *const kPluginPath = @"/private/var/mobile/Containers/Data/PluginKitPlugin/42D859EB-1323-451C-88F6-01AEE4F45958";
static NSString *const kSharedPath = @"/private/var/mobile/Containers/Data/PluginKitPlugin/051B043F-07C6-4AB6-9B43-F70BFA8B1A81";
static NSString *const kBundleContainer = @"/private/var/containers/Bundle/Application/9A1E2B4C-8D3F-4E5A-B6C7-D8E9F0A1B2C3";

// Bundle record: +0x0c id, +0x68 container path, +0x6c name, +0x74 display
// name. Plugin records (0x118 bytes): +0x00 id, +0x54 container path.
static NSData *StoreWithContainers(void)
{
    NSMutableData *data = [NSMutableData dataWithLength:0x3000];
    memcpy(data.mutableBytes, "bdsl", 4);
    const NSUInteger bundle = 0x200, plugin = 0x500, other = 0x700, third = 0x900;
    Put32(data, bundle + 4, 0x250);
    Put32(data, bundle + 8 + 0x0c, 1u << 2);
    Put32(data, bundle + 8 + 0x68, 2u << 2);
    Put32(data, bundle + 8 + 0x6c, 3u << 2);
    Put32(data, bundle + 8 + 0x74, 3u << 2);
    Put32(data, bundle + 8 + 0x00, 8u << 2);   // .app path (stored with /var/ and a trailing slash)
    Put32(data, plugin + 4, 0x118);
    Put32(data, plugin + 8 + 0x00, 4u << 2);
    Put32(data, plugin + 8 + 0x54, 5u << 2);
    // Two extensions claiming the same container: neither is trusted.
    Put32(data, other + 4, 0x118);
    Put32(data, other + 8 + 0x00, 4u << 2);
    Put32(data, other + 8 + 0x54, 6u << 2);
    Put32(data, third + 4, 0x118);
    Put32(data, third + 8 + 0x00, 7u << 2);
    Put32(data, third + 8 + 0x54, 6u << 2);
    PutString(data, 0x1000, 1, @"com.example.app");
    PutString(data, 0x1080, 2, kAppPath);                       // 84 bytes
    PutString(data, 0x1100, 3, @"AppName8");                    // 8 bytes
    PutString(data, 0x1180, 4, @"com.example.app.widget");
    PutString(data, 0x1200, 5, kPluginPath);                    // 88 bytes
    PutString(data, 0x1280, 6, kSharedPath);
    PutString(data, 0x1300, 7, @"com.example.other");
    PutString(data, 0x1380, 8, [[kBundleContainer substringFromIndex:8] stringByAppendingString:@"/Example.app/"]);
    return data;
}

static void TestContainerMapping(NSString *path)
{
    WriteData(StoreWithContainers(), path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    WQCheck([wq_bundle_id_for_container(kAppPath) isEqualToString:@"com.example.app"]);
    WQCheck([wq_bundle_id_for_container([kAppPath substringFromIndex:8]) isEqualToString:@"com.example.app"]);  // /var/...
    WQCheck([wq_bundle_id_for_container(kPluginPath) isEqualToString:@"com.example.app.widget"]);
    WQCheck(wq_bundle_id_for_container(kSharedPath) == nil);
    WQCheck(wq_bundle_id_for_container(@"/private/var/mobile/Containers/Data/Application/not-a-uuid") == nil);
    // App bundle containers: the folder holding the .app maps to its app.
    WQCheck([wq_bundle_path_for_id(@"com.example.app") isEqualToString:[kBundleContainer stringByAppendingString:@"/Example.app"]]);
    WQCheck([wq_bundle_id_for_container(kBundleContainer) isEqualToString:@"com.example.app"]);
    WQCheck([wq_bundle_id_for_container([kBundleContainer substringFromIndex:8]) isEqualToString:@"com.example.app"]);
    WQCheck([wq_ls_bundle_containers() isEqualToArray:@[kBundleContainer]]);
    WQCheck(wq_bundle_id_for_container([kBundleContainer stringByAppendingString:@"/Example.app"]) == nil);
    // A display name whose length is a multiple of 4 has no terminator.
    WQCheck([wq_display_name(@"com.example.app") isEqualToString:@"AppName8"]);
}

// iOS 27.3 (issue #50): app records as on 27.2 (0x25c: +0x0c id, +0x6c
// container, +0x70 name, +0x78 display name), plugin records 0x134 bytes
// with +0x00 id and +0x58 container.
static NSData *Store27_3(void)
{
    NSMutableData *data = [NSMutableData dataWithLength:0x3000];
    memcpy(data.mutableBytes, "bdsl", 4);
    const NSUInteger bundle = 0x200, plugin = 0x500;
    Put32(data, bundle + 4, 0x25c);
    Put32(data, bundle + 8 + 0x0c, 1u << 2);
    Put32(data, bundle + 8 + 0x6c, 2u << 2);
    Put32(data, bundle + 8 + 0x70, 3u << 2);
    Put32(data, bundle + 8 + 0x78, 3u << 2);
    Put32(data, plugin + 4, 0x134);
    Put32(data, plugin + 8 + 0x00, 4u << 2);
    Put32(data, plugin + 8 + 0x58, 5u << 2);
    PutString(data, 0x1000, 1, @"com.example.app");
    PutString(data, 0x1080, 2, kAppPath);
    PutString(data, 0x1100, 3, @"Name27.3");
    PutString(data, 0x1180, 4, @"com.example.app.ext273");
    PutString(data, 0x1200, 5, kPluginPath);
    return data;
}

static void Test27_3Layout(NSString *path)
{
    WriteData(Store27_3(), path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    WQCheck([wq_bundle_id_for_container(kAppPath) isEqualToString:@"com.example.app"]);
    WQCheck([wq_bundle_id_for_container(kPluginPath) isEqualToString:@"com.example.app.ext273"]);
    WQCheck([wq_display_name(@"com.example.app") isEqualToString:@"Name27.3"]);
}

#ifdef WQ_LS_TESTING
extern BOOL wq_ls_test_known_layouts_off;

// An unknown layout: 0x60-byte records with the bundle id at +0x0c, a type
// field that repeats one value at +0x04, the container at +0x18 and the
// display name at +0x20. Names are worked out (three Apple apps confirm the
// name field); container identities are not taken from a worked-out layout.
static NSData *StoreWithUnknownLayout(void)
{
    NSMutableData *data = [NSMutableData dataWithLength:0x20000];
    memcpy(data.mutableBytes, "bdsl", 4);
    NSArray *apps = @[@"com.apple.mobilesafari", @"com.apple.Preferences", @"com.apple.camera"];
    NSArray *names = @[@"Safari", @"Settings", @"Camera"];
    uint32_t sid = 1;
    PutString(data, 0x10000, sid, @"public.mime-type");
    uint32_t typeRef = sid++ << 2;
    NSUInteger strings = 0x10080;
    for (NSUInteger i = 0; i < 30; i++) {
        NSUInteger record = 0x200 + i * 0x80;
        NSString *bid = i < apps.count ? apps[i] : [NSString stringWithFormat:@"com.example.app%lu", (unsigned long)i];
        NSString *name = i < names.count ? names[i] : [NSString stringWithFormat:@"Example %lu", (unsigned long)i];
        NSString *container = [NSString stringWithFormat:@"/private/var/mobile/Containers/Data/Application/%@", NSUUID.UUID.UUIDString];
        Put32(data, record + 4, 0x60);
        Put32(data, record + 8 + 0x04, typeRef);
        PutString(data, strings, sid, bid); Put32(data, record + 8 + 0x0c, sid++ << 2); strings += 0x80;
        PutString(data, strings, sid, container); Put32(data, record + 8 + 0x18, sid++ << 2); strings += 0x80;
        PutString(data, strings, sid, name); Put32(data, record + 8 + 0x20, sid++ << 2); strings += 0x80;
    }
    return data;
}

static void TestUnknownLayoutGivesNamesOnly(NSString *path)
{
    WriteData(StoreWithUnknownLayout(), path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    WQCheck([wq_display_name(@"com.example.app7") isEqualToString:@"Example 7"]);
    WQCheck([wq_display_name(@"com.apple.mobilesafari") isEqualToString:@"Safari"]);
    // No container identity from a worked-out layout.
    WQCheck(wq_ls_container_paths(nil).count == 0);
}
#endif

static void TestOversizedStoreFailsClosed(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    WQCheck(fd >= 0);
    if (fd < 0) return;
    off_t size = (off_t)(64u * 1024u * 1024u + 1u);
    WQCheck(ftruncate(fd, size) == 0);
    WQCheck(write(fd, "bdsl", 4) == 4);
    close(fd);
    WQCheck(wq_display_name(@"com.example.international") == nil);
}

#ifdef WQ_LS_TESTING
extern void (^wq_ls_test_after_read)(NSString *path);
NSUInteger wq_ls_test_layout_vote_steps(NSData *data, BOOL *cutOff, NSUInteger *keys, NSUInteger *paths);

// A store hint publishes one coherent snapshot (names, maps and remembered
// location together), read with the same stable before/after check as the
// name loader; the published snapshot is reused instead of parsed again.
static void TestStoreHintPublishesSnapshot(NSString *path)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    WriteData(StoreWithName(@"Old name"), path);
    [defaults setObject:path forKey:@"WQLaunchServicesStore"];
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Old name"]);

    NSString *hint = [path stringByAppendingString:@".hint"];
    WriteData(StoreWithContainers(), hint);
    __block BOOL mutate = YES;
    __block int reads = 0;
    wq_ls_test_after_read = ^(NSString *readPath) {
        if (![readPath isEqualToString:hint]) return;
        reads++;
        if (!mutate) return;
        NSMutableData *grown = [StoreWithContainers() mutableCopy];
        [grown increaseLengthBy:0x100];
        WriteData(grown, hint);
    };
    WQCheck(wq_ls_container_paths(hint) == nil);   // rewritten while it was read
    WQCheck([[defaults stringForKey:@"WQLaunchServicesStore"] isEqualToString:path]);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Old name"]);

    mutate = NO;
    WriteData(StoreWithContainers(), hint);
    NSArray<NSString *> *paths = wq_ls_container_paths(hint);
    WQCheck([paths containsObject:kAppPath] && [paths containsObject:kPluginPath]);
    WQCheck([[defaults stringForKey:@"WQLaunchServicesStore"] isEqualToString:hint]);
    WQCheck([wq_display_name(@"com.example.app") isEqualToString:@"AppName8"]);
    WQCheck([wq_bundle_id_for_container(kAppPath) isEqualToString:@"com.example.app"]);
    WQCheck(wq_display_name(@"com.example.international") == nil);   // old snapshot replaced

    reads = 0;
    WQCheck([wq_ls_container_paths(nil) count] == paths.count && reads == 0);   // snapshot reused
    wq_ls_test_after_read = nil;
    [[NSFileManager defaultManager] removeItemAtPath:hint error:nil];
    [defaults setObject:path forKey:@"WQLaunchServicesStore"];
}

// The low-mapping layout diagnostics stop at a fixed work budget however
// many references a malformed store repeats.
static void TestLayoutDiagnosticsBudget(void)
{
    NSMutableData *data = [NSMutableData dataWithLength:2u * 1024u * 1024u];
    memcpy(data.mutableBytes, "bdsl", 4);
    NSMutableArray<NSNumber *> *refs = [NSMutableArray new];
    for (uint32_t i = 0; i < 30; i++) {
        NSString *container = [NSString stringWithFormat:@"/private/var/mobile/Containers/Data/Application/%@",
                               NSUUID.UUID.UUIDString];
        PutString(data, 0x1000 + i * 0x80, i + 1, container);
        [refs addObject:@((i + 1) << 2)];
    }
    for (NSUInteger o = 0x4000; o + 4 <= data.length; o += 4) Put32(data, o, refs[(o / 4) % refs.count].unsignedIntValue);
    BOOL cutOff = NO;
    NSUInteger keys = 0, pathCount = 0;
    NSUInteger steps = wq_ls_test_layout_vote_steps(data, &cutOff, &keys, &pathCount);
    WQCheck(pathCount == 30);
    WQCheck(cutOff);
    WQCheck(steps <= (1u << 23) + 1);
    WQCheck(keys <= 1024);
}
#endif

int main(void)
{
    @autoreleasepool {
        NSString *path = TemporaryStorePath();
        id oldPreference = [NSUserDefaults.standardUserDefaults objectForKey:@"WQLaunchServicesStore"];
        @try {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WQLaunchServicesStore"];
            TestRetryAfterDiscoveryFailure(path);
            TestRefreshAndUnicodeSafety(path);
#ifdef WQ_LS_TESTING
            TestStoreHintPublishesSnapshot(path);
            TestLayoutDiagnosticsBudget();
            TestUnknownLayoutGivesNamesOnly(path);
#endif
            TestContainerMapping(path);
            Test27_3Layout(path);
            TestOversizedStoreFailsClosed(path);
        } @finally {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            if (oldPreference) [NSUserDefaults.standardUserDefaults setObject:oldPreference forKey:@"WQLaunchServicesStore"];
            else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WQLaunchServicesStore"];
        }
        if (failures) {
            fprintf(stderr, "%d LaunchServices regression check(s) failed\n", failures);
            return 1;
        }
        puts("All LaunchServices regression tests passed.");
    }
    return 0;
}

#pragma mark - Portable WQAccess test doubles

void wq_log(NSString *__unused format, ...)
{
}

BOOL wq_stat(NSString *path, struct stat *st)
{
    return lstat(path.fileSystemRepresentation, st) == 0;
}

NSData *wq_read(NSString *path, NSUInteger maxBytes, NSString **errorText)
{
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (!data) {
        if (errorText) *errorText = error.localizedDescription ?: @"read failed";
        return nil;
    }
    if (maxBytes && data.length > maxBytes) return [data subdataWithRange:NSMakeRange(0, maxBytes)];
    return data;
}

NSArray<NSString *> *wq_enumerate(NSString *__unused dir, int64_t __unused maxInode,
                                   WQScanCancellation *__unused cancellation,
                                   void (^__unused progress)(int64_t, int64_t, NSUInteger))
{
    return nil;
}

BOOL wq_system_areas_reachable(void)
{
    return YES;   // the fixtures model iOS 27, where the daemon containers are listed
}

NSArray<NSString *> *wq_list(NSString *__unused dir, NSString *__unused *errorText)
{
    return nil;
}
