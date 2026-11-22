//
//  WQUI.m
//  WQ Files shared UI helpers
//  GPL-3.0-or-later.
//

#import "WQUI.h"
#import "WQScanTask.h"
#import "WQTheme.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQStoreIconsSupport.h"
#import <fcntl.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

// "iPhone 17 Pro Max (iPhone18,2)\niOS 27.0.1 (24A446)"
NSString *wq_device_line(void)
{
    struct utsname u;
    NSString *machine = (uname(&u) == 0) ? @(u.machine) : @"unknown";
    char build[64] = {0};
    size_t len = sizeof(build);
    NSString *buildStr = (sysctlbyname("kern.osversion", build, &len, NULL, 0) == 0) ? @(build) : nil;
    NSDictionary *names = @{
        @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
        @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus", @"iPhone17,5": @"iPhone 16e",
        @"iPhone18,1": @"iPhone 17 Pro", @"iPhone18,2": @"iPhone 17 Pro Max",
        @"iPhone18,3": @"iPhone 17", @"iPhone18,4": @"iPhone Air",
    };
    NSString *marketing = names[machine];
    NSString *model = marketing ? [NSString stringWithFormat:@"%@ (%@)", marketing, machine] : machine;
    NSString *ver = UIDevice.currentDevice.systemVersion;
    return buildStr ? [NSString stringWithFormat:@"%@ · iOS %@ (%@)", model, ver, buildStr]
                    : [NSString stringWithFormat:@"%@ · iOS %@", model, ver];
}

// "WQ Files 0.9.4 (66)": in the strip, so screenshots show the version.
NSString *wq_app_version_line(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"WQ Files %@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
}

const CGFloat kWQDeviceStripHeight = 46;

// A small centered strip with the WQ Files version and the device/iOS line,
// for a table header.
UIView *wq_device_header(CGFloat width)
{
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, kWQDeviceStripHeight + 16)];
    UILabel *header = [UILabel new];
    header.numberOfLines = 2;
    header.textAlignment = NSTextAlignmentCenter;
    header.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    header.textColor = UIColor.secondaryLabelColor;
    header.backgroundColor = wq_prism_enabled() ? [UIColor clearColor] : UIColor.secondarySystemBackgroundColor;
    header.adjustsFontSizeToFitWidth = YES;   // keeps both lines on narrow screens
    header.minimumScaleFactor = 0.8;
    header.text = [NSString stringWithFormat:@"%@\n%@", wq_app_version_line(), wq_device_line()];
    header.frame = CGRectMake(0, 0, width, kWQDeviceStripHeight);
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [box addSubview:header];  // 16 pt of clear space below the strip
    return box;
}

// Private: app icon by bundle id (in UIKit; guarded with respondsToSelector).
@interface UIImage (WQPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end

// Small grey fingerprint of an icon, to recognise iOS's blank placeholder.
static NSData *wq_icon_fingerprint(UIImage *img)
{
    const size_t s = 12;
    uint8_t px[12 * 12 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, s, s, 8, s * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    if (img.CGImage) CGContextDrawImage(ctx, CGRectMake(0, 0, s, s), img.CGImage);
    CGContextRelease(ctx);
    return [NSData dataWithBytes:px length:sizeof(px)];
}

static UIImage *wq_raw_icon(NSString *bundleID)
{
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    CGFloat scale = 2.0; // Safe fallback for background preparation without UI context.
    if (NSThread.isMainThread) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
                scale = ((UIWindowScene *)scene).screen.scale;
                break;
            }
        }
    }
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:scale];
}

// YES when two fingerprints are near-identical (small rendering differences).
static BOOL wq_icon_fingerprints_match(NSData *a, NSData *b)
{
    if (!a || !b || a.length != b.length) return NO;
    const uint8_t *x = a.bytes, *y = b.bytes;
    unsigned long diff = 0;
    for (NSUInteger i = 0; i < a.length; i++) diff += (unsigned long)abs((int)x[i] - (int)y[i]);
    return diff / a.length < 8;
}

// iOS's placeholder is a flat grey square with a faint grid: no colour and
// almost no contrast. Real icons, even grey ones like Settings, have strong
// contrast (measured: placeholder sd 8–9, Settings 33–42).
static BOOL wq_icon_fingerprint_looks_blank(NSData *fp)
{
    const uint8_t *p = fp.bytes;
    double sum = 0, squares = 0;
    NSUInteger n = 0;
    for (NSUInteger i = 0; i + 3 < fp.length; i += 4) {
        if (p[i + 3] < 200) continue;   // rounded corners
        int r = p[i], g = p[i + 1], b = p[i + 2];
        if (MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) > 6) return NO;   // coloured
        double l = 0.299 * r + 0.587 * g + 0.114 * b;
        sum += l;
        squares += l * l;
        n++;
    }
    if (n < 40) return NO;
    double mean = sum / (double)n;
    return sqrt(MAX(0.0, squares / (double)n - mean * mean)) < 16;
}

// The real icon for bundleID, or nil when iOS only has its placeholder.
// iOS draws the placeholder light or dark depending on the appearance at the
// time, so every variant seen is remembered: a blank-looking icon that matches
// none is compared with the placeholder iOS draws right now.
static UIImage *wq_real_icon(NSString *bundleID)
{
    // Not dispatch_once: off the main thread UIKit's icon call waits for the
    // main thread, so a background icon warm-up inside a once-block while a
    // table cell on the main thread waited for the same block deadlocked
    // (frozen UI, then a watchdog kill). UIKit is only called outside the
    // lock; the lock only guards the list.
    static NSMutableArray<NSData *> *placeholders;
    static NSObject *guard;
    static dispatch_once_t guardOnce;   // only allocates, never calls UIKit
    dispatch_once(&guardOnce, ^{ guard = [NSObject new]; placeholders = [NSMutableArray new]; });
    UIImage *raw = wq_raw_icon(bundleID);
    if (!raw || !raw.CGImage) return nil;
    NSData *fp = wq_icon_fingerprint(raw);
    if (!fp) return raw;
    NSArray<NSData *> *known;
    @synchronized (guard) { known = [placeholders copy]; }
    for (NSData *placeholder in known) if (wq_icon_fingerprints_match(fp, placeholder)) return nil;
    if (known.count && !wq_icon_fingerprint_looks_blank(fp)) return raw;
    NSData *current = wq_icon_fingerprint(wq_raw_icon(@"cz.kolbi.wqfiles.no-such-app"));
    if (!current) return raw;
    @synchronized (guard) {
        BOOL seen = NO;
        for (NSData *placeholder in placeholders) if (wq_icon_fingerprints_match(current, placeholder)) { seen = YES; break; }
        if (!seen && placeholders.count < 8) [placeholders addObject:current];
    }
    return wq_icon_fingerprints_match(fp, current) ? nil : raw;
}

// The icon from the app's own bundle, for when iOS only hands out its
// placeholder (iOS 26 refuses this app's icon requests). Reads the primary
// icon names from Info.plist and loads the matching PNG files.
// The first few outcomes go to the Log, to see why icons are missing.
static void wq_icon_note(NSString *bundleID, NSString *what)
{
    static NSUInteger notes;
    @synchronized (NSNull.null) {
        if (notes >= 8) return;
        notes++;
    }
    wq_log(@"icon: %@: %@", bundleID, what);
}

static UIImage *wq_bundle_icon(NSString *bundleID)
{
    NSString *path = wq_bundle_path_for_id(bundleID);
    if (!path.length) { wq_icon_note(bundleID, @"no bundle path in the app database"); return nil; }
    NSString *plistPath = [path stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!info && wq_grant(path)) info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![info isKindOfClass:NSDictionary.class]) {
        int fd = open(plistPath.fileSystemRepresentation, O_RDONLY);
        int err = fd < 0 ? errno : 0;
        if (fd >= 0) close(fd);
        wq_icon_note(bundleID, [NSString stringWithFormat:@"can't read %@ (%s)", plistPath, err ? strerror(err) : "not a plist"]);
        return nil;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *key in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
        NSDictionary *primary = [info[key] isKindOfClass:NSDictionary.class] ? info[key][@"CFBundlePrimaryIcon"] : nil;
        if (![primary isKindOfClass:NSDictionary.class]) continue;
        if ([primary[@"CFBundleIconName"] isKindOfClass:NSString.class]) [names addObject:primary[@"CFBundleIconName"]];
        NSArray *files = [primary[@"CFBundleIconFiles"] isKindOfClass:NSArray.class] ? primary[@"CFBundleIconFiles"] : @[];
        for (id file in files.reverseObjectEnumerator) if ([file isKindOfClass:NSString.class]) [names addObject:file];
    }
    if ([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) [names addObject:info[@"CFBundleIconFile"]];
    [names addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon"]];
    // Only the PNG files apps ship next to their asset catalog. Loading from
    // the catalog (UIImage imageNamed:inBundle:) aborts inside UIKit when an
    // entry exists but can't be rendered (crash on 27.0.1, build 21).
    for (NSString *name in names) {
        NSString *base = name.stringByDeletingPathExtension;
        for (NSString *suffix in @[@"@3x.png", @"@2x.png", @"@2x~ipad.png", @"~ipad.png", @".png"]) {
            UIImage *image = [UIImage imageWithContentsOfFile:[path stringByAppendingPathComponent:[base stringByAppendingString:suffix]]];
            if (image.CGImage) {
                wq_icon_note(bundleID, [NSString stringWithFormat:@"loaded %@%@ from the app", base, suffix]);
                return image;
            }
        }
    }
    wq_icon_note(bundleID, [NSString stringWithFormat:@"no icon PNG in %@ (tried %@)", path.lastPathComponent,
                            [names componentsJoinedByString:@", "]]);
    return nil;
}

static UIImage *wq_round_icon(UIImage *raw)
{
    CGFloat s = 40;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.225] addClip];
        [raw drawInRect:CGRectMake(0, 0, s, s)];
    }];
}

// Symbol tile for system services and extensions that have no icon at all,
// picked from keywords in Apple bundle ids. Other apps' icons can't be read
// (worse_query doesn't reach them), and keywords misfire on their ids
// (com.facebook.Facebook -> "book"), so they all get the neutral gear.
static UIImage *wq_service_tile(NSString *bundleID)
{
    static NSArray<NSArray *> *rules;
    static NSCache *tiles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tiles = [NSCache new];
        UIColor *blue = UIColor.systemBlueColor, *green = UIColor.systemGreenColor, *red = UIColor.systemRedColor,
                *orange = UIColor.systemOrangeColor, *purple = UIColor.systemPurpleColor, *indigo = UIColor.systemIndigoColor,
                *teal = UIColor.systemTealColor, *pink = UIColor.systemPinkColor, *gray = UIColor.systemGrayColor;
        // keywords (lower case, any match), symbol, colour
        rules = @[
            @[@[@"emoji"], @"face.smiling.inverse", orange],
            @[@[@"keyboard", @"inputui", @"textinput", @"dictation"], @"keyboard.fill", gray],
            @[@[@"airdrop", @"sharing", @"sharesheet"], @"antenna.radiowaves.left.and.right", blue],
            @[@[@"widget", @"chrono"], @"square.grid.2x2.fill", blue],
            @[@[@"screenshot", @"screencapture", @"screenrecord"], @"camera.viewfinder", indigo],
            @[@[@"poster", @"wallpaper"], @"photo.on.rectangle.angled", purple],
            @[@[@"siri", @"assistant"], @"waveform", indigo],
            @[@[@"camera"], @"camera.fill", gray],
            @[@[@"photo"], @"photo.fill", orange],
            @[@[@"music", @"audio", @"shazam", @"musicrecognition"], @"music.note", pink],
            @[@[@"headphone", @"airpods", @"bluetooth"], @"headphones", gray],
            @[@[@"hearing"], @"ear.fill", blue],
            @[@[@"weather"], @"cloud.sun.fill", teal],
            @[@[@"location", @"maps", @"navigation"], @"location.fill", blue],
            @[@[@"health", @"fitness", @"workout"], @"heart.fill", red],
            @[@[@"pay", @"wallet", @"passbook", @"cash", @"finance"], @"creditcard.fill", green],
            @[@[@"mail"], @"envelope.fill", blue],
            @[@[@"message", @"sms", @"imessage"], @"message.fill", green],
            @[@[@"facetime", @"video"], @"video.fill", green],
            @[@[@"phone", @"call", @"telephony"], @"phone.fill", green],
            @[@[@"notification", @"usernotification", @"bulletin"], @"bell.fill", red],
            @[@[@"shortcut", @"workflow", @"intent"], @"square.on.square", indigo],
            @[@[@"safari", @"web"], @"safari.fill", blue],
            @[@[@"news", @"stocks"], @"newspaper.fill", red],
            @[@[@"calendar", @"event"], @"calendar", red],
            @[@[@"note", @"paper"], @"note.text", orange],
            @[@[@"reminder"], @"checklist", blue],
            @[@[@"game"], @"gamecontroller.fill", purple],
            @[@[@"auth", @"account", @"appsso", @"password", @"keychain", @"tcc", @"privacy"], @"lock.fill", gray],
            @[@[@"print"], @"printer.fill", gray],
            @[@[@"clarity", @"accessib"], @"accessibility", blue],
            @[@[@"home"], @"house.fill", orange],
            @[@[@"findmy", @"fmd", @"fmip"], @"location.circle.fill", green],
            @[@[@"carplay", @"carradio", @"cartrip", @"car."], @"car.fill", gray],
            @[@[@"tvremote", @"tvsetup", @"com.apple.tv"], @"tv.fill", gray],
            @[@[@"book"], @"book.fill", orange],
            @[@[@"podcast"], @"mic.fill", purple],
            @[@[@"spotlight", @"search"], @"magnifyingglass", gray],
            @[@[@"diagnostic", @"logging", @"crash", @"analytics"], @"stethoscope", gray],
            @[@[@"font"], @"textformat", gray],
            @[@[@"translate"], @"character.bubble.fill", blue],
            @[@[@"file", @"document", @"cloud"], @"folder.fill", blue],
            @[@[@"setup", @"buddy", @"onboarding"], @"gearshape.2.fill", gray],
        ];
    });
    NSString *key = bundleID.lowercaseString;
    NSString *symbol = @"gearshape.fill";
    UIColor *color = UIColor.systemGrayColor;
    BOOL apple = [key hasPrefix:@"com.apple."] || [key hasPrefix:@"group.com.apple."] || [key hasPrefix:@"systemgroup.com.apple."];
    for (NSArray *rule in apple ? rules : @[]) {
        BOOL hit = NO;
        for (NSString *word in rule[0]) if ([key containsString:word]) { hit = YES; break; }
        if (hit) { symbol = rule[1]; color = rule[2]; break; }
    }
    NSString *cacheKey = [symbol stringByAppendingString:color.description];
    UIImage *tile = [tiles objectForKey:cacheKey];
    if (tile) return tile;
    CGFloat s = 40;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    UIColor *fill = [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]];
    tile = [r imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [fill setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.225] fill];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
        UIImage *g = [[UIImage systemImageNamed:symbol withConfiguration:cfg] ?: [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        [g drawInRect:CGRectMake((s - g.size.width) / 2, (s - g.size.height) / 2, g.size.width, g.size.height)];
    }];
    [tiles setObject:tile forKey:cacheKey];
    return tile;
}

#pragma mark - App Store icons

// Settings → App Store Icons (off by default; see WQStoreIconsSupport.h).
// Icons are fetched in batches off the main thread, kept as 120 px PNGs in
// Application Support/StoreIcons, and announced with
// WQStoreIconsChangedNotification (userInfo "ids": the bundle ids that got an
// icon, none when everything changed). Apps without an entry are asked again
// after a week at the earliest.
NSString *const WQStoreIconsChangedNotification = @"WQStoreIconsChangedNotification";

static dispatch_queue_t wq_store_state(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("wqfiles.storeicons.state", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static dispatch_queue_t wq_store_fetch_queue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("wqfiles.storeicons.fetch", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSCache<NSString *, UIImage *> *wq_store_images(void)
{
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 400; });
    return cache;
}

static NSString *wq_store_dir(void)
{
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"StoreIcons"];
}

static NSString *wq_store_file(NSString *bundleID)
{
    return [wq_store_dir() stringByAppendingPathComponent:[bundleID stringByAppendingPathExtension:@"png"]];
}

static NSString *wq_store_misses_file(void) { return [wq_store_dir() stringByAppendingPathComponent:@"misses.plist"]; }

// State, only touched on wq_store_state().
static NSMutableOrderedSet<NSString *> *gStorePending;
static NSMutableSet<NSString *> *gStoreBusy;
static NSMutableDictionary<NSString *, NSDate *> *gStoreMisses;
static BOOL gStoreFlushScheduled, gStorePreloaded;

BOOL wq_store_icons_enabled(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:WQStoreIconsPref];
}

static void wq_store_announce(NSArray<NSString *> *_Nullable ids)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:WQStoreIconsChangedNotification object:nil
                                                        userInfo:ids ? @{ @"ids": ids } : nil];
    });
}

void wq_set_store_icons_enabled(BOOL enabled)
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:WQStoreIconsPref];
    dispatch_async(wq_store_state(), ^{
        [gStorePending removeAllObjects];
        gStorePreloaded = NO;
        gStoreMisses = nil;
        if (!enabled) {
            [wq_store_images() removeAllObjects];
            [NSFileManager.defaultManager removeItemAtPath:wq_store_dir() error:NULL];
        }
        wq_store_announce(nil);
    });
}

static UIImage *_Nullable wq_store_load_file(NSString *bundleID)
{
    NSData *data = [NSData dataWithContentsOfFile:wq_store_file(bundleID)];
    if (data.length == 0 || data.length > WQStoreIconsMaxIconBytes) return nil;
    UIImage *image = [UIImage imageWithData:data scale:1];
    return image.CGImage ? image : nil;
}

// Once per launch: every icon on disk into memory, so lists drawn on the main
// thread (which never reads files) show them too.
static void wq_store_preload(void)
{
    if (gStorePreloaded) return;
    gStorePreloaded = YES;
    dispatch_async(wq_store_fetch_queue(), ^{
        NSMutableArray<NSString *> *loaded = [NSMutableArray new];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:wq_store_dir() error:NULL]) {
            if (![name.pathExtension isEqualToString:@"png"]) continue;
            NSString *bid = name.stringByDeletingPathExtension;
            if (!WQStoreIconsEligible(bid) || [wq_store_images() objectForKey:bid]) continue;
            UIImage *image = wq_store_load_file(bid);
            if (image) { [wq_store_images() setObject:image forKey:bid]; [loaded addObject:bid]; }
        }
        if (loaded.count) wq_store_announce(loaded);
    });
}

static NSData *_Nullable wq_store_get(NSURL *url, NSUInteger limit)
{
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 20;
        config.HTTPCookieStorage = nil;
        config.HTTPShouldSetCookies = NO;
        config.URLCache = nil;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    __block NSData *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!error && status == 200 && data.length <= limit) result = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return result;
}

// One lookup round: ids -> icons saved; returns the ids without an entry.
static NSArray<NSString *> *wq_store_fetch_batch(NSArray<NSString *> *ids, NSString *country, NSMutableArray<NSString *> *saved)
{
    NSURL *lookup = WQStoreIconsLookupURL(ids, country);
    NSData *json = lookup ? wq_store_get(lookup, WQStoreIconsMaxResponseBytes) : nil;
    if (!json) return nil;   // network or server trouble: nothing is marked missing
    NSDictionary<NSString *, NSURL *> *art = WQStoreIconsArtwork(json, ids);
    NSMutableArray<NSString *> *missing = [NSMutableArray new];
    for (NSString *bid in ids) {
        NSURL *url = art[bid];
        if (!url) { [missing addObject:bid]; continue; }
        if (!wq_store_icons_enabled()) continue;   // switched off meanwhile: no more requests
        NSData *png = wq_store_get(url, WQStoreIconsMaxIconBytes);
        UIImage *image = png ? [UIImage imageWithData:png scale:1] : nil;
        if (!image.CGImage) continue;   // try again next launch
        NSData *stored = UIImagePNGRepresentation(image);
        if (stored.length && stored.length <= WQStoreIconsMaxIconBytes && [stored writeToFile:wq_store_file(bid) atomically:YES]) {
            [wq_store_images() setObject:image forKey:bid];
            [saved addObject:bid];
        }
    }
    return missing;
}

static void wq_store_flush(void)
{
    gStoreFlushScheduled = NO;
    if (!wq_store_icons_enabled() || !gStorePending.count) return;
    NSArray<NSString *> *all = [gStorePending.array copy];   // .array is a live view of the set
    [gStorePending removeAllObjects];
    [gStoreBusy addObjectsFromArray:all];
    NSString *country = WQStoreIconsCountry([NSLocale.currentLocale objectForKey:NSLocaleCountryCode]);
    dispatch_async(wq_store_fetch_queue(), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *dir = [NSURL fileURLWithPath:wq_store_dir() isDirectory:YES];
        [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [dir setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
        NSMutableArray<NSString *> *missed = [NSMutableArray new];
        NSUInteger asked = 0, found = 0;
        for (NSUInteger i = 0; i < all.count && wq_store_icons_enabled(); i += WQStoreIconsBatch) {
            NSArray<NSString *> *batch = [all subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)WQStoreIconsBatch, all.count - i))];
            NSMutableArray<NSString *> *saved = [NSMutableArray new];
            NSArray<NSString *> *missing = wq_store_fetch_batch(batch, country, saved);
            // Not in this region's store: the US store has most apps.
            if (missing.count && ![country isEqualToString:@"us"] && wq_store_icons_enabled())
                missing = wq_store_fetch_batch(missing, @"us", saved);
            else if (!wq_store_icons_enabled()) missing = nil;   // unknown, not "not in the App Store"
            asked += batch.count;
            found += saved.count;
            if (missing) [missed addObjectsFromArray:missing];
            if (saved.count) wq_store_announce(saved);
        }
        wq_log(@"store icons: %lu asked (%@), %lu found, %lu not in the App Store",
               (unsigned long)asked, country, (unsigned long)found, (unsigned long)missed.count);
        dispatch_async(wq_store_state(), ^{
            [gStoreBusy minusSet:[NSSet setWithArray:all]];
            if (!missed.count) return;
            NSDate *now = NSDate.date;
            for (NSString *bid in missed) gStoreMisses[bid] = now;
            NSMutableDictionary *plist = [NSMutableDictionary new];
            [gStoreMisses enumerateKeysAndObjectsUsingBlock:^(NSString *bid, NSDate *when, BOOL *__unused stop) {
                if (-when.timeIntervalSinceNow < WQStoreIconsMissRetry) plist[bid] = when;
            }];
            [plist writeToFile:wq_store_misses_file() atomically:YES];
        });
    });
}

static void wq_store_request(NSString *bundleID)
{
    dispatch_async(wq_store_state(), ^{
        if (!gStorePending) {
            gStorePending = [NSMutableOrderedSet new];
            gStoreBusy = [NSMutableSet new];
        }
        if (!gStoreMisses) {
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:wq_store_misses_file()];
            gStoreMisses = [NSMutableDictionary new];
            [plist enumerateKeysAndObjectsUsingBlock:^(id bid, id when, BOOL *__unused stop) {
                if ([bid isKindOfClass:NSString.class] && [when isKindOfClass:NSDate.class]) gStoreMisses[bid] = when;
            }];
        }
        NSDate *missed = gStoreMisses[bundleID];
        if (missed && -missed.timeIntervalSinceNow < WQStoreIconsMissRetry) return;
        if ([gStoreBusy containsObject:bundleID] || [wq_store_images() objectForKey:bundleID]) return;
        if ([NSFileManager.defaultManager fileExistsAtPath:wq_store_file(bundleID)]) return;
        [gStorePending addObject:bundleID];
        if (gStoreFlushScheduled) return;
        gStoreFlushScheduled = YES;
        // Collect a whole list pass into few requests.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), wq_store_state(), ^{ wq_store_flush(); });
    });
}

// The App Store icon for bundleID when the setting is on: from memory, or (off
// the main thread) from disk; a miss off the main thread asks the App Store.
static UIImage *_Nullable wq_store_icon(NSString *bundleID, BOOL background)
{
    if (!wq_store_icons_enabled() || !WQStoreIconsEligible(bundleID)) return nil;
    UIImage *image = [wq_store_images() objectForKey:bundleID];
    if (image) return image;
    dispatch_async(wq_store_state(), ^{ wq_store_preload(); });
    if (!background) return nil;
    image = wq_store_load_file(bundleID);
    if (image) { [wq_store_images() setObject:image forKey:bundleID]; return image; }
    wq_store_request(bundleID);
    return nil;
}

void wq_reload_visible_rows(UITableView *tableView)
{
    if (!tableView.window || tableView.isEditing) return;
    NSArray<NSIndexPath *> *rows = tableView.indexPathsForVisibleRows;
    if (rows.count) [tableView reloadRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationNone];
}

// Rounded app icon for a bundle id, cached. Falls back to the closest parent
// app's icon (extensions: com.foo.app.widget -> com.foo.app), then to a
// neutral service tile. Nil only without a bundle id.
static UIImage *wq_app_icon_found(NSString *bundleID, BOOL *found);

UIImage *wq_app_icon(NSString *bundleID) { return wq_app_icon_found(bundleID, NULL); }

// *found: a real icon (not the neutral tile) is now in the cache.
static UIImage *wq_app_icon_found(NSString *bundleID, BOOL *found)
{
    if (found) *found = NO;
    if (!bundleID.length) return nil;
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        // App Store icons arrived (or the setting changed): drop the tiles.
        [NSNotificationCenter.defaultCenter addObserverForName:WQStoreIconsChangedNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            NSArray *ids = note.userInfo[@"ids"];
            if (note.userInfo[@"warmed"]) return;   // the cache was just filled for these
            if (![ids isKindOfClass:NSArray.class]) { [cache removeAllObjects]; return; }
            for (NSString *bid in ids) [cache removeObjectForKey:bid];
        }];
    });
    UIImage *cached = [cache objectForKey:bundleID];
    if (cached) return cached;
    // The bundle fallback reads files and may ask for access: never on the
    // main thread. Lists warm the cache from their background passes; a
    // main-thread miss gets the tile without caching it.
    BOOL background = !NSThread.isMainThread;
    // App Group ids ("group.net.whatsapp.WhatsApp.shared") aren't bundles:
    // look up the app id inside them (net.whatsapp.WhatsApp.shared, then its
    // parents) instead of the group id and its "group.net…" parents.
    NSString *appID = bundleID;
    for (NSString *prefix in @[@"group.", @"systemgroup."]) {
        if ([bundleID hasPrefix:prefix] && bundleID.length > prefix.length) {
            appID = [bundleID substringFromIndex:prefix.length];
            break;
        }
    }
    UIImage *system = wq_real_icon(appID);
    if (system && background) wq_icon_note(bundleID, @"iOS returned an icon");
    UIImage *raw = system ?: (background ? wq_bundle_icon(appID) : nil);
    NSArray *parts = [appID componentsSeparatedByString:@"."];
    for (NSInteger n = (NSInteger)parts.count - 1; !raw && n >= 3; n--)
    {
        NSString *parent = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."];
        raw = wq_real_icon(parent) ?: (background ? wq_bundle_icon(parent) : nil);
    }
    if (!raw && [appID isEqualToString:bundleID]) raw = wq_store_icon(bundleID, background);
    UIImage *icon = raw ? wq_round_icon(raw) : wq_service_tile(bundleID);
    if (raw || background) [cache setObject:icon forKey:bundleID];
    if (found) *found = raw != nil;
    // A main-thread miss (the cache was emptied by the App Store Icons
    // switch, or the list never warmed this id): look the icon up in the
    // background once, so the row isn't stuck with the tile and the next
    // cell doesn't repeat the lookups here.
    if (!raw && !background) {
        static NSMutableSet<NSString *> *warming;   // main thread only
        if (!warming) warming = [NSMutableSet new];
        if (![warming containsObject:bundleID]) {
            [warming addObject:bundleID];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                BOOL changed = NO;
                wq_app_icon_found(bundleID, &changed);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [warming removeObject:bundleID];
                    if (changed)
                        [NSNotificationCenter.defaultCenter postNotificationName:WQStoreIconsChangedNotification object:nil
                                                                        userInfo:@{ @"ids": @[bundleID], @"warmed": @YES }];
                });
            });
        }
    }
    return icon;
}

dispatch_queue_t wq_io(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("wqfiles.io", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

dispatch_queue_t wq_scan_queue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // User-initiated: someone is waiting for the list. Utility (0.9.11)
        // put scans on the efficiency cores with throttled disk I/O.
        queue = dispatch_queue_create("wqfiles.scans", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    });
    return queue;
}

static BOOL (*gScanKeepsRunning)(void);

void wq_scan_pause_for_background(void)
{
    wq_scan_set_paused(YES);
    [WQScanTask setPaused:YES];
}

void wq_scan_lifecycle_install(BOOL (*keepRunning)(void))
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gScanKeepsRunning = keepRunning;
        // Scans pause in the background, except while a full scan still has
        // its background time; that time's expiry pauses them instead.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *__unused note) {
            if (gScanKeepsRunning && gScanKeepsRunning()) return;
            wq_scan_pause_for_background();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *__unused note) {
            wq_scan_set_paused(NO);
            [WQScanTask setPaused:NO];
        }];
    });
}

void wq_scan_read(void (^work)(void))
{
    dispatch_sync(wq_io(), work);
}

static NSString *const kWQDeletingDisabledPref = @"WQDeletingDisabled";

BOOL wq_deleting_allowed(void)
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:kWQDeletingDisabledPref];
}

void wq_set_deleting_allowed(BOOL allowed)
{
    [NSUserDefaults.standardUserDefaults setBool:!allowed forKey:kWQDeletingDisabledPref];
}

static NSString *const kWQDiscardBeforeRestorePref = @"WQDiscardBeforeRestore";

BOOL wq_keep_before_restore(void)
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:kWQDiscardBeforeRestorePref];
}

void wq_set_keep_before_restore(BOOL keep)
{
    [NSUserDefaults.standardUserDefaults setBool:!keep forKey:kWQDiscardBeforeRestorePref];
}

BOOL wq_refuse_if_deleting_off(UIViewController *host)
{
    if (wq_deleting_allowed()) return NO;
    UIAlertController *alert = wq_alert_controller(@"Deleting is turned off",
        @"Turn on Allow Deleting on the start screen of WQ Files to delete, clear or clean.", UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, nil)];
    [host presentViewController:alert animated:YES completion:nil];
    return YES;
}

UIAlertController *wq_alert_controller(NSString *title, NSString *message, UIAlertControllerStyle style)
{
    return [UIAlertController alertControllerWithTitle:WQLocalizedNullable(title)
                                               message:WQLocalizedNullable(message)
                                        preferredStyle:style];
}

UIAlertAction *wq_alert_action(NSString *title, UIAlertActionStyle style, void (^handler)(UIAlertAction *))
{
    return [UIAlertAction actionWithTitle:WQLocalized(title) style:style handler:handler];
}

void wq_alert(UIViewController *host, NSString *title, NSString *message)
{
    if (!host || !host.isViewLoaded || !host.view.window) return;
    UIWindowScene *scene = host.view.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) return;
    UINavigationController *nav = host.navigationController;
    if (nav && nav.topViewController != host) return;
    if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) return;
    UIAlertController *alert = wq_alert_controller(title, message, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, nil)];
    [host presentViewController:alert animated:YES completion:nil];
}

NSString *wq_size_text(unsigned long long size)
{
    if (size == 0) return @"0 KB";
    return [NSByteCountFormatter stringFromByteCount:(long long)size countStyle:NSByteCountFormatterCountStyleFile];
}

static NSString *const kWQPrismBackgroundChanged = @"WQPrismBackgroundChanged";
static NSString *const kWQPlainBackgroundPref = @"WQPlainBackground";

BOOL wq_prism_plain_background(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kWQPlainBackgroundPref];
}

void wq_set_prism_plain_background(BOOL plain)
{
    [NSUserDefaults.standardUserDefaults setBool:plain forKey:kWQPlainBackgroundPref];
    [NSNotificationCenter.defaultCenter postNotificationName:kWQPrismBackgroundChanged object:nil];
}

static NSString *const kWQBackgroundColorPref = @"WQBackgroundColor";   // @[r, g, b] in sRGB

UIColor *wq_prism_background_color(void)
{
    NSArray *rgb = [NSUserDefaults.standardUserDefaults arrayForKey:kWQBackgroundColorPref];
    if (rgb.count != 3) return nil;
    for (id v in rgb) if (![v isKindOfClass:NSNumber.class]) return nil;
    return [UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue] blue:[rgb[2] doubleValue] alpha:1];
}

void wq_set_prism_background_color(UIColor *color)
{
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (color && [color getRed:&r green:&g blue:&b alpha:&a])
        [NSUserDefaults.standardUserDefaults setObject:@[@(MIN(1, MAX(0, r))), @(MIN(1, MAX(0, g))), @(MIN(1, MAX(0, b)))]
                                                forKey:kWQBackgroundColorPref];
    else
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQBackgroundColorPref];
    [NSNotificationCenter.defaultCenter postNotificationName:kWQPrismBackgroundChanged object:nil];
}

// The picked color's hue and saturation with a brightness that keeps text
// readable: deep in dark mode, pale in light mode.
static UIColor *wq_tinted(UIColor *color, BOOL dark, CGFloat level, CGFloat alpha)
{
    CGFloat h = 0, s = 0, v = 0, a = 0;
    [color getHue:&h saturation:&s brightness:&v alpha:&a];
    return dark ? [UIColor colorWithHue:h saturation:s * 0.75 brightness:MIN(v, 1.0) * level alpha:alpha]
                : [UIColor colorWithHue:h saturation:s * level brightness:1.0 alpha:alpha];
}

@implementation WQPrismPalette
@end

WQPrismPalette *wq_prism_palette(BOOL dark)
{
    WQPrismPalette *p = [WQPrismPalette new];
    BOOL plain = wq_prism_plain_background();
    // An imported theme (Settings → Theme) brings its own colors.
    WQTheme *theme = wq_active_theme();
    if (theme) {
        WQThemeAppearance *a = [theme appearanceDark:dark];
        if (plain) {
            p.baseTop = p.baseBottom = a.plain ?: a.baseTop;
            p.glows = @[];
        } else {
            p.baseTop = a.baseTop;
            p.baseBottom = a.baseBottom;
            p.glows = a.glows;
        }
        return p;
    }
    UIColor *custom = [wq_active_theme_id() isEqualToString:WQThemeCustomColor] ? wq_prism_background_color() : nil;
    if (plain) {
        // Plain black (dark) or white (light) like the classic design, or the
        // picked color kept dark or pale enough for text.
        UIColor *color = custom ? wq_tinted(custom, dark, dark ? 0.32 : 0.14, 1)
                                : (dark ? UIColor.blackColor : UIColor.whiteColor);
        p.baseTop = p.baseBottom = color;
        p.glows = @[];
        return p;
    }
    if (custom) {
        // Glows in the picked hue and two neighbours, on a base tinted the same way.
        CGFloat h = 0, s = 0, v = 0, a = 0;
        [custom getHue:&h saturation:&s brightness:&v alpha:&a];
        CGFloat hues[4] = {h, fmod(h + 0.06, 1), fmod(h + 0.94, 1), fmod(h + 0.12, 1)};
        CGFloat alphas[4] = {dark ? 0.62 : 0.48, dark ? 0.48 : 0.38, dark ? 0.32 : 0.30, 0.24};
        p.baseTop = wq_tinted(custom, dark, dark ? 0.08 : 0.06, 1);
        p.baseBottom = wq_tinted(custom, dark, dark ? 0.16 : 0.12, 1);
        NSMutableArray<UIColor *> *glows = [NSMutableArray new];
        for (NSUInteger i = 0; i < 4; i++)
            [glows addObject:dark ? [UIColor colorWithHue:hues[i] saturation:MAX(s, 0.15) * 0.85 brightness:MAX(v, 0.35) * 0.95 alpha:alphas[i]]
                                  : [UIColor colorWithHue:hues[i] saturation:MAX(s, 0.15) * 0.45 brightness:1.0 alpha:alphas[i]]];
        p.glows = glows;
        return p;
    }
    if (dark) {
        p.baseTop = [UIColor colorWithRed:0.024 green:0.033 blue:0.062 alpha:1];
        p.baseBottom = [UIColor colorWithRed:0.043 green:0.063 blue:0.125 alpha:1];
        p.glows = @[[UIColor colorWithRed:0.30 green:0.42 blue:0.95 alpha:0.62], [UIColor colorWithRed:0.55 green:0.36 blue:0.95 alpha:0.48],
                    [UIColor colorWithRed:0.12 green:0.76 blue:0.66 alpha:0.32], [UIColor colorWithRed:0.95 green:0.34 blue:0.60 alpha:0.22]];
    } else {
        p.baseTop = [UIColor colorWithRed:0.92 green:0.95 blue:1.0 alpha:1];
        p.baseBottom = [UIColor colorWithRed:0.86 green:0.91 blue:1.0 alpha:1];
        p.glows = @[[UIColor colorWithRed:0.56 green:0.69 blue:1.0 alpha:0.48], [UIColor colorWithRed:0.78 green:0.65 blue:1.0 alpha:0.38],
                    [UIColor colorWithRed:0.52 green:0.92 blue:0.84 alpha:0.30], [UIColor colorWithRed:1.0 green:0.72 blue:0.84 alpha:0.24]];
    }
    return p;
}

// WQ Prism: a soft layered backdrop shared by the redesigned screens.
@interface WQPrismBackgroundView : UIView
@end

@implementation WQPrismBackgroundView {
    CAGradientLayer *_base;
    NSArray<CAGradientLayer *> *_glows;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        _base = [CAGradientLayer layer];
        _base.startPoint = CGPointMake(0.5, 0.0);
        _base.endPoint = CGPointMake(0.5, 1.0);
        [self.layer addSublayer:_base];
        NSMutableArray *glows = [NSMutableArray new];
        for (NSInteger i = 0; i < 4; i++) {
            CAGradientLayer *g = [CAGradientLayer layer];
            g.type = kCAGradientLayerRadial;
            g.startPoint = CGPointMake(0.5, 0.5);
            g.endPoint = CGPointMake(1.0, 1.0);
            [self.layer addSublayer:g];
            [glows addObject:g];
        }
        _glows = glows;
        [self updateColors];
        [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withAction:@selector(updateColors)];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateColors)
                                                   name:kWQPrismBackgroundChanged object:nil];
    }
    return self;
}

- (void)updateColors
{
    WQPrismPalette *p = wq_prism_palette(self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight);
    for (NSUInteger i = 0; i < _glows.count; i++) {
        _glows[i].hidden = p.glows.count <= i;
        if (p.glows.count > i) _glows[i].colors = @[(id)p.glows[i].CGColor, (id)UIColor.clearColor.CGColor];
    }
    _base.colors = @[(id)p.baseTop.CGColor, (id)p.baseBottom.CGColor];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    _base.frame = self.bounds;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _glows[0].frame = CGRectMake(-w * 0.34, -h * 0.08, w * 0.92, w * 0.92);
    _glows[1].frame = CGRectMake(w * 0.42, -h * 0.10, w * 0.82, w * 0.82);
    _glows[2].frame = CGRectMake(w * 0.26, h * 0.56, w * 0.94, w * 0.94);
    _glows[3].frame = CGRectMake(-w * 0.30, h * 0.70, w * 0.72, w * 0.72);
}

@end

UIView *wq_prism_background_view(void)
{
    return [[WQPrismBackgroundView alloc] initWithFrame:CGRectZero];
}

void wq_prism_install_background(UIViewController *vc)
{
    if (!wq_prism_enabled() || !vc.isViewLoaded) return;
    if ([vc.view viewWithTag:0x57515042]) return;
    if ([vc.view isKindOfClass:UITableView.class]) {
        UITableView *table = (UITableView *)vc.view;
        table.backgroundColor = [UIColor clearColor];
        table.backgroundView = wq_prism_background_view();
        return;
    }
    UIView *bg = wq_prism_background_view();
    bg.tag = 0x57515042;
    bg.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view insertSubview:bg atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [bg.topAnchor constraintEqualToAnchor:vc.view.topAnchor],
        [bg.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
        [bg.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [bg.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
    ]];
    vc.view.backgroundColor = [UIColor clearColor];
}


static NSString *const kWQClassicDesignPref = @"WQClassicDesign";

BOOL wq_prism_enabled(void)
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:kWQClassicDesignPref];
}

void wq_set_prism_enabled(BOOL enabled)
{
    [NSUserDefaults.standardUserDefaults setBool:!enabled forKey:kWQClassicDesignPref];
}

// iPad: busy tab items with their plain titles; one timer animates them all
// and stops when none is busy.
static NSMapTable<UITabBarItem *, NSString *> *gBusyTabs;   // running → spinner
static NSHashTable<UITabBarItem *> *gWaitingTabs;              // queued → clock
static NSTimer *gBusyTabTimer;

static void wq_busy_tabs_tick(void)
{
    static NSArray<NSString *> *frames;
    static NSUInteger frame;
    if (!frames) frames = @[@"⠋", @"⠙", @"⠹", @"⠸", @"⠼", @"⠴", @"⠦", @"⠧", @"⠇", @"⠏"];
    frame = (frame + 1) % frames.count;
    for (UITabBarItem *item in gBusyTabs)
        if (![gWaitingTabs containsObject:item]) item.title = [NSString stringWithFormat:@"%@ %@", [gBusyTabs objectForKey:item], frames[frame]];
}

BOOL wq_scan_task_waiting(WQScanTask *task)
{
    // A started task publishes progress once its worker runs; until then it waits
    // behind another scan on the shared queue (or is paused).
    return task.running && (task.paused || !task.status.length
        || [task.status isEqualToString:@"Scan queued; previous results kept"]
        || [task.status isEqualToString:WQLocalized(@"Scan queued; previous results kept")]);
}

void wq_set_tab_busy(UIViewController *tabRoot, NSString *title, WQTabBusy state)
{
    UITabBarItem *item = tabRoot.tabBarItem;
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        item.badgeColor = UIColor.systemGrayColor;  // busy, not a warning
        item.badgeValue = state == WQTabBusyRunning ? @"…" : state == WQTabBusyWaiting ? @"◷" : nil;
        return;
    }
    item.badgeValue = nil;
    if (!gBusyTabs) {
        gBusyTabs = [NSMapTable weakToStrongObjectsMapTable];
        gWaitingTabs = [NSHashTable weakObjectsHashTable];
    }
    if (state == WQTabBusyWaiting) {
        [gBusyTabs removeObjectForKey:item];
        [gWaitingTabs addObject:item];
        item.title = [title stringByAppendingString:@" ◷"];
    } else if (state == WQTabBusyRunning) {
        BOOL known = [gBusyTabs objectForKey:item] != nil;
        [gWaitingTabs removeObject:item];
        [gBusyTabs setObject:title forKey:item];
        if (!known) wq_busy_tabs_tick();
    } else {
        [gWaitingTabs removeObject:item];
        [gBusyTabs removeObjectForKey:item];
        item.title = title;
    }
    if (gBusyTabs.count && !gBusyTabTimer) {
        gBusyTabTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * __unused t) { wq_busy_tabs_tick(); }];
        [NSRunLoop.mainRunLoop addTimer:gBusyTabTimer forMode:NSRunLoopCommonModes];
    } else if (!gBusyTabs.count && gBusyTabTimer) {
        [gBusyTabTimer invalidate];
        gBusyTabTimer = nil;
    }
}

@implementation WQProgressHeaderView {
    UILabel *_label;
    UIProgressView *_bar;
}

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithReuseIdentifier:reuseIdentifier])) {
        _label = [UILabel new];
        _label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _label.adjustsFontForContentSizeCategory = YES;
        _label.textColor = UIColor.secondaryLabelColor;
        _label.numberOfLines = 0;
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_label, _bar]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 8;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        NSLayoutConstraint *bottom = [stack.bottomAnchor constraintEqualToAnchor:m.bottomAnchor];
        bottom.priority = UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:m.topAnchor],
            bottom,
        ]];
    }
    return self;
}

- (void)setText:(NSString *)text fraction:(float)fraction
{
    _label.text = text;
    _bar.hidden = fraction < 0;
    if (fraction >= 0) [_bar setProgress:MIN(1.0f, fraction) animated:NO];
}

@end
