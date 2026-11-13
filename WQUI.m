//
//  WQUI.m
//  WQ Files shared UI helpers
//  GPL-3.0-or-later.
//

#import "WQUI.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
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
    header.backgroundColor = [UIColor clearColor];
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

// The real icon for bundleID, or nil when iOS only has its placeholder.
static UIImage *wq_real_icon(NSString *bundleID)
{
    static NSData *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ placeholder = wq_icon_fingerprint(wq_raw_icon(@"cz.kolbi.wqfiles.no-such-app")); });
    UIImage *raw = wq_raw_icon(bundleID);
    if (!raw || !raw.CGImage) return nil;
    NSData *fp = wq_icon_fingerprint(raw);
    if (!placeholder || fp.length != placeholder.length) return raw;
    // Near-identical to the placeholder (allow small rendering differences).
    const uint8_t *a = fp.bytes, *b = placeholder.bytes;
    unsigned long diff = 0;
    for (NSUInteger i = 0; i < fp.length; i++) diff += (unsigned long)abs((int)a[i] - (int)b[i]);
    return diff / fp.length < 8 ? nil : raw;
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
// picked from keywords in the bundle id.
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
    for (NSArray *rule in rules) {
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

// Rounded app icon for a bundle id, cached. Falls back to the closest parent
// app's icon (extensions: com.foo.app.widget -> com.foo.app), then to a
// neutral service tile. Nil only without a bundle id.
UIImage *wq_app_icon(NSString *bundleID)
{
    if (!bundleID.length) return nil;
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    UIImage *cached = [cache objectForKey:bundleID];
    if (cached) return cached;
    // The bundle fallback reads files and may ask for access: never on the
    // main thread. Lists warm the cache from their background passes; a
    // main-thread miss gets the tile without caching it.
    BOOL background = !NSThread.isMainThread;
    UIImage *system = wq_real_icon(bundleID);
    if (system && background) wq_icon_note(bundleID, @"iOS returned an icon");
    UIImage *raw = system ?: (background ? wq_bundle_icon(bundleID) : nil);
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    for (NSInteger n = (NSInteger)parts.count - 1; !raw && n >= 3; n--)
    {
        NSString *parent = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."];
        raw = wq_real_icon(parent) ?: (background ? wq_bundle_icon(parent) : nil);
    }
    UIImage *icon = raw ? wq_round_icon(raw) : wq_service_tile(bundleID);
    if (raw || background) [cache setObject:icon forKey:bundleID];
    return icon;
}

dispatch_queue_t wq_io(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("wqfiles.io", DISPATCH_QUEUE_SERIAL); });
    return queue;
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
    }
    return self;
}

- (void)updateColors
{
    BOOL dark = self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight;
    if (dark) {
        _base.colors = @[(id)[UIColor colorWithRed:0.024 green:0.033 blue:0.062 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:0.043 green:0.063 blue:0.125 alpha:1].CGColor];
        _glows[0].colors = @[(id)[UIColor colorWithRed:0.30 green:0.42 blue:0.95 alpha:0.62].CGColor, (id)[UIColor clearColor].CGColor];
        _glows[1].colors = @[(id)[UIColor colorWithRed:0.55 green:0.36 blue:0.95 alpha:0.48].CGColor, (id)[UIColor clearColor].CGColor];
        _glows[2].colors = @[(id)[UIColor colorWithRed:0.12 green:0.76 blue:0.66 alpha:0.32].CGColor, (id)[UIColor clearColor].CGColor];
        _glows[3].colors = @[(id)[UIColor colorWithRed:0.95 green:0.34 blue:0.60 alpha:0.22].CGColor, (id)[UIColor clearColor].CGColor];
    } else {
        _base.colors = @[(id)[UIColor colorWithRed:0.92 green:0.95 blue:1.0 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:0.86 green:0.91 blue:1.0 alpha:1].CGColor];
        _glows[0].colors = @[(id)[UIColor colorWithRed:0.56 green:0.69 blue:1.0 alpha:0.48].CGColor, (id)[UIColor clearColor].CGColor];
        _glows[1].colors = @[(id)[UIColor colorWithRed:0.78 green:0.65 blue:1.0 alpha:0.38].CGColor, (id)[UIColor clearColor].CGColor];
        _glows[2].colors = @[(id)[UIColor colorWithRed:0.52 green:0.92 blue:0.84 alpha:0.30].CGColor, (id)[UIColor clearColor].CGColor];
        _glows[3].colors = @[(id)[UIColor colorWithRed:1.0 green:0.72 blue:0.84 alpha:0.24].CGColor, (id)[UIColor clearColor].CGColor];
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self updateColors];
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
    if (!vc.isViewLoaded) return;
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

