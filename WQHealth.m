//
//  WQHealth.m
//  WQ Files
//

#import "WQHealth.h"
#import "WQAccess.h"
#import "WQAppsSupport.h"
#import "WQLaunchServices.h"
#import "WQLocalization.h"
#import "WQAccessSafety.h"
#include <sys/stat.h>
#include <sys/sysctl.h>

@implementation WQHealthCheck
@end

static WQHealthCheck *wq_check(NSString *title, WQHealthState state, NSString *detail)
{
    WQHealthCheck *c = [WQHealthCheck new];
    c.title = WQLocalized(title);
    c.key = title;
    c.state = state;
    c.detail = detail ?: @"";
    return c;
}

static BOOL gBundlesReachable;
BOOL wq_app_bundles_reachable(void) { return gBundlesReachable; }

WQHealthState wq_health_worst(NSArray<WQHealthCheck *> *checks)
{
    WQHealthState worst = WQHealthOK;
    for (WQHealthCheck *c in checks) if (c.state > worst) worst = c.state;
    return worst;
}

WQHealthState wq_health_access_state(NSUInteger opened, NSUInteger sampled)
{
    if (!sampled) return WQHealthSkipped;
    if (!opened) return WQHealthFailed;
    // Some apps' folders refuse for their own reasons; most must open.
    return opened * 2 >= sampled ? WQHealthOK : WQHealthWarning;
}

WQHealthState wq_health_names_state(BOOL namesLoaded, BOOL knownName, NSUInteger labeled, NSUInteger sampled)
{
    if (!namesLoaded || !knownName) return WQHealthWarning;
    if (sampled && labeled * 2 < sampled) return WQHealthWarning;
    return WQHealthOK;
}

// Up to `count` folders spread over the list, not WQ Files' own.
static NSArray<NSString *> *wq_health_sample(NSArray<NSString *> *containers, NSString *home, NSUInteger count)
{
    NSMutableArray *others = [NSMutableArray new];
    for (NSString *c in containers)
        if (![[c stringByResolvingSymlinksInPath] isEqualToString:home]) [others addObject:c];
    if (others.count <= count) return others;
    NSMutableArray *picked = [NSMutableArray new];
    for (NSUInteger i = 0; i < count; i++) [picked addObject:others[i * others.count / count]];
    return picked;
}

static NSString *wq_health_build(void)
{
#if TARGET_OS_SIMULATOR
    // The simulator reports the Mac's build (e.g. 26B131), not an iOS one.
    return @"";
#endif
    char build[32] = {0};
    size_t len = sizeof build - 1;
    return sysctlbyname("kern.osversion", build, &len, NULL, 0) == 0 ? @(build) : @"";
}

BOOL wq_worse_query_patched(void)
{
    return WQWorseQueryPatchedBuild(wq_health_build());
}

NSArray<WQHealthCheck *> *wq_health_run(void (^stage)(NSString *))
{
    NSMutableArray<WQHealthCheck *> *checks = [NSMutableArray new];
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *osText = [NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion];
    NSString *build = wq_health_build();
    BOOL patched = WQWorseQueryPatchedBuild(build);
    if (patched) wq_log(@"health: build %@ is iOS 27.3 beta 2 or later, where Apple patched worse_query", build);

    // 1. App Group: without it no token can be asked for.
    if (stage) stage(WQLocalized(@"Checking the App Group…"));
    NSString *group = wq_app_group();
    [checks addObject:wq_check(@"App Group", group ? WQHealthOK : WQHealthFailed,
        group ?: WQLocalized(@"Missing: the tool that signed WQ Files removed it. Re-install with AltStore, SideStore or Impactor.")) ];

    // 2. Other apps' folders.
    if (stage) stage(WQLocalized(@"Finding other apps' folders…"));
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    NSArray<NSString *> *containers = group ? wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, nil, nil) : nil;
    NSArray<NSString *> *sample = wq_health_sample(containers ?: @[], home, 8);
    WQHealthCheck *folders;
    if (!group) folders = wq_check(@"Other apps' folders", WQHealthSkipped, WQLocalized(@"Needs the App Group."));
    else if (!containers && wq_full_scan_was_declined())
        folders = wq_check(@"Other apps' folders", WQHealthSkipped, WQLocalized(@"The scan for them was declined; Apps and the Cache Cleaner stay empty until it runs."));
    else if (!containers)
        folders = wq_check(@"Other apps' folders", WQHealthFailed, WQLocalized(@"They can't be found on this device (see Log for the reason)."));
    else if (!sample.count)
        folders = wq_check(@"Other apps' folders", WQHealthFailed, WQLocalizedFormat(@"Only WQ Files' own folder was found (%lu in total).", (unsigned long)containers.count));
    else
        folders = wq_check(@"Other apps' folders", WQHealthOK, WQLocalizedFormat(@"%lu found.", (unsigned long)containers.count));
    [checks addObject:folders];

    // 3. Sandbox access: tokens that really open those folders.
    if (stage) stage(WQLocalized(@"Checking access…"));
    NSUInteger opened = 0, labeled = 0;
    NSMutableArray *refused = [NSMutableArray new];
    for (NSString *c in sample) {
        NSString *error = nil;
        if (wq_grant(c) && wq_list(c, &error)) opened++;
        else [refused addObject:[NSString stringWithFormat:@"%@ (%@)", c.lastPathComponent, error ?: @"no token"]];
        NSString *label = wq_container_label(c);
        if (label && WQAppsSupportBundleIDValid(label)) labeled++;
    }
    WQHealthState access = wq_health_access_state(opened, sample.count);
    if (refused.count) wq_log(@"health: %lu of %lu sampled folders refused: %@", (unsigned long)refused.count,
                              (unsigned long)sample.count, [refused componentsJoinedByString:@", "]);
    [checks addObject:wq_check(@"Sandbox access", access,
        access == WQHealthSkipped ? WQLocalized(@"Nothing to check.")
        // On a supported iOS the technique works; a failure there is local
        // (access cache, another app in the same App Group), not "iOS".
        : access == WQHealthFailed && patched
            ? WQLocalizedFormat(@"None of %lu sampled app folders could be opened. Apple patched worse_query, the sandbox escape WQ Files is built on, in iOS 27.3 beta 2, so it can't work on this build (%@). It works up to iOS 27.3 beta 1 and on iOS 26.", (unsigned long)sample.count, build)
        : access == WQHealthFailed && (os.majorVersion == 26 || os.majorVersion == 27)
            ? WQLocalizedFormat(@"None of %lu sampled app folders could be opened, even after repairing the access cache. Another app that shares WQ Files' App Group (for example in LiveContainer) can get in the way: close it, then tap Reset Access Cache and Try Again. If it stays like this, send the Log.", (unsigned long)sample.count)
        : access == WQHealthFailed ? WQLocalizedFormat(@"None of %lu sampled app folders could be opened: the sandbox escape doesn't work on iOS %@.", (unsigned long)sample.count, osText)
        : WQLocalizedFormat(@"%lu of %lu sampled app folders open.", (unsigned long)opened, (unsigned long)sample.count))];

    // 4. App database: names and container labels (layout offsets).
    if (stage) stage(WQLocalized(@"Reading app names…"));
    if (group && access != WQHealthFailed && !wq_display_names_loaded()) wq_load_display_names();
    BOOL namesLoaded = wq_display_names_loaded();
    BOOL knownName = namesLoaded && wq_display_name(@"com.apple.mobilesafari").length > 0;
    WQHealthState names = access == WQHealthFailed || !group ? WQHealthSkipped
                        : wq_health_names_state(namesLoaded, knownName, labeled, sample.count);
    [checks addObject:wq_check(@"App names", names,
        names == WQHealthSkipped ? WQLocalized(@"Needs sandbox access.")
        : names == WQHealthOK ? WQLocalizedFormat(@"%lu of %lu sampled folders identified.", (unsigned long)labeled, (unsigned long)sample.count)
        : WQLocalizedFormat(@"The app database can't be read properly on iOS %@ (%lu of %lu sampled folders identified). Apps show folder IDs instead of names; backups and restores need the right app, so check before restoring.", osText, (unsigned long)labeled, (unsigned long)sample.count))];

    // App bundles open on some iOS versions only (not on 26 or 27.0.1):
    // App Bundles and Open App Bundle are shown when one does.
    BOOL bundles = NO;
    if (access == WQHealthOK) {
        NSArray<NSString *> *all = wq_ls_bundle_containers();
        for (NSNumber *index in WQSpreadSampleIndexes(all.count, 3)) {
            NSString *b = all[index.unsignedIntegerValue];
            bundles = wq_grant(b) && wq_list(b, NULL) != nil;
            if (bundles) break;
        }
        wq_log(@"health: app bundle folders %@", bundles ? @"open" : @"don't open (App Bundles hidden)");
    }
    gBundlesReachable = bundles;

    // 5. iOS version.
    BOOL tested = (os.majorVersion == 26 || os.majorVersion == 27) && !patched;
    [checks addObject:wq_check(@"iOS version", tested ? WQHealthOK : WQHealthWarning,
        tested ? osText
        : patched ? WQLocalizedFormat(@"iOS %@ (%@): Apple patched worse_query in iOS 27.3 beta 2. Folders that still open here may stop opening.", osText, build)
        : WQLocalizedFormat(@"iOS %@ hasn't been tested with this version of WQ Files.", osText))];

    NSMutableArray *summary = [NSMutableArray new];
    for (WQHealthCheck *c in checks) [summary addObject:[NSString stringWithFormat:@"%@=%@", c.key,
        @[@"ok", @"skipped", @"warning", @"FAILED"][(NSUInteger)c.state]]];
    wq_log(@"health: iOS %@: %@", osText, [summary componentsJoinedByString:@", "]);
    return checks;
}
