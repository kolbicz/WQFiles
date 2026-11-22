//
//  WQSharing.m
//  WQ Files temporary exports and share sheets
//  GPL-3.0-or-later.
//

#import "WQSharing.h"
#import "WQUI.h"
#import "WQAccess.h"
#import "WQArchive.h"
#import <objc/runtime.h>
#import <sys/stat.h>

@interface WQSharePreparation : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIAlertController *hud;
@property (nonatomic, copy) NSString *exportDir;
@property (atomic, getter=isCancelled) BOOL cancelled;
@end

@implementation WQSharePreparation
@end

static char kWQSharePreparationKey;
static char kWQShareInFlightKey;

static NSString *wq_unique_export_directory(void)
{
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [@"WQShare-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    return [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:&error] ? dir : nil;
}

static void wq_remove_export(NSString *exportDir)
{
    if (exportDir.length) [NSFileManager.defaultManager removeItemAtPath:exportDir error:nil];
}

void wq_share_sweep_stale_exports(void)
{
    dispatch_async(wq_io(), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *tmp = NSTemporaryDirectory();
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-3600];
        // Handed to other apps (share sheet): another app may still read a
        // recent one, so these go after an hour.
        NSArray<NSString *> *shared = @[@"WQShare-", @"WQTheme-", @"wq-sqlite-export"];
        // Only this process used these, and this runs once at launch: whatever
        // is left comes from a run that was killed. Some are full copies of
        // other apps' databases or multi-GB ZIPs, so they go at once.
        NSArray<NSString *> *own = @[@"wq-sqlite-", @"WQUpload-", @"WQWeb-", @"wq-import-", @"WQAppsRestore-", @"wq-zip-", @"wq-unzip-"];
        NSUInteger removed = 0;
        for (NSString *name in [fm contentsOfDirectoryAtPath:tmp error:nil]) {
            BOOL aged = NO, known = NO;
            for (NSString *prefix in shared) if ([name hasPrefix:prefix]) aged = known = YES;
            for (NSString *prefix in own) if (!known && [name hasPrefix:prefix]) known = YES;
            if (!known) continue;
            NSString *item = [tmp stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:item error:nil];   // lstat: a link is never followed
            NSString *type = attrs.fileType;
            if (![type isEqualToString:NSFileTypeDirectory] && ![type isEqualToString:NSFileTypeRegular]) continue;
            NSDate *modified = attrs.fileModificationDate;
            if (aged && modified && [modified compare:cutoff] == NSOrderedDescending) continue;   // may still be in use
            if ([fm removeItemAtPath:item error:nil]) removed++;
        }
        if (removed) wq_log(@"temporary files: removed %lu stale item(s) left by earlier runs", (unsigned long)removed);
    });
}

static BOOL wq_share_host_is_active(UIViewController *host)
{
    if (!host || !host.isViewLoaded || !host.view.window) return NO;
    UIWindowScene *scene = host.view.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) return NO;
    UINavigationController *nav = host.navigationController;
    if (nav && nav.topViewController != host) return NO;
    if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) return NO;
    return YES;
}

static BOOL wq_shareable_regular_file(NSString *path)
{
    if (!path.length) return NO;
    struct stat st;
    // Do not follow a final symlink: wq_copy_to_local uses O_NOFOLLOW too.
    if (lstat(path.fileSystemRepresentation, &st) == 0) return S_ISREG(st.st_mode);
    if (wq_grant(path) && lstat(path.fileSystemRepresentation, &st) == 0) return S_ISREG(st.st_mode);
    return NO;
}

static void wq_clear_preparation(UIViewController *host, WQSharePreparation *preparation)
{
    if (!host) return;
    if (objc_getAssociatedObject(host, &kWQSharePreparationKey) == preparation) {
        objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL wq_share_in_flight(UIViewController *host)
{
    return host && (objc_getAssociatedObject(host, &kWQSharePreparationKey) ||
                    objc_getAssociatedObject(host, &kWQShareInFlightKey));
}

static void wq_clear_in_flight(UIViewController *host)
{
    if (!host) return;
    objc_setAssociatedObject(host, &kWQShareInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL wq_present_share(UIViewController *host, NSString *file, NSString *exportDir, UIView *source)
{
    if (!wq_share_host_is_active(host)) {
        wq_remove_export(exportDir);
        return NO;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:file]] applicationActivities:nil];
    UIView *anchor = source.window ? source : host.view;
    share.popoverPresentationController.sourceView = anchor;
    share.popoverPresentationController.sourceRect = anchor.bounds;
    share.completionWithItemsHandler = ^(UIActivityType __unused activityType, BOOL __unused completed,
                                         NSArray *__unused returnedItems, NSError *__unused activityError) {
        wq_remove_export(exportDir);
    };
    [host presentViewController:share animated:YES completion:^{
        // A presentation rejected after the visibility check must not strand the export.
        if (!share.presentingViewController) wq_remove_export(exportDir);
    }];
    return YES;
}

// Cancel folder preparation when its browser is popped or otherwise abandoned.
// The export is removed by the worker's completion, after any in-progress copy has stopped.
void wq_share_cancel(UIViewController *host)
{
    if (!host) return;
    wq_clear_in_flight(host);
    WQSharePreparation *preparation = objc_getAssociatedObject(host, &kWQSharePreparationKey);
    preparation.cancelled = YES;
    if (host) objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIAlertController *hud = preparation.hud;
    if (hud && host.presentedViewController == hud) {
        [host dismissViewControllerAnimated:NO completion:nil];
    }
}

// Copies a file into a unique temporary directory so concurrent shares cannot
// overwrite one another. The export is removed when the share sheet finishes.
void wq_share(UIViewController *host, NSString *path, UIView *source)
{
    if (!host) return;
    if (wq_share_in_flight(host)) {
        wq_alert(host, @"Share in progress", @"Wait for the current share to finish before starting another.");
        return;
    }
    objc_setAssociatedObject(host, &kWQShareInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakHost = host;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSString *outDir = nil;
        NSString *tmp = nil;
        BOOL ok = NO;
        if (!wq_shareable_regular_file(path)) {
            error = @"Only regular files can be shared.";
        } else {
            outDir = wq_unique_export_directory();
            tmp = outDir ? [outDir stringByAppendingPathComponent:path.lastPathComponent] : nil;
            ok = tmp && wq_copy_to_local(path, tmp, &error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongHost = weakHost;
            if (!ok) {
                wq_remove_export(outDir);
                wq_clear_in_flight(strongHost);
                if (wq_share_host_is_active(strongHost)) {
                    wq_alert(strongHost, @"Cannot share", error ?: @"Could not create a temporary export folder");
                }
                return;
            }
            if (!wq_share_host_is_active(strongHost) ||
                !wq_present_share(strongHost, tmp, outDir, source)) {
                wq_remove_export(outDir);
            }
            wq_clear_in_flight(strongHost);
        });
    });
}

static NSString *wq_zip_name(NSString *dir);

// Zips a folder (WQ Files' own ZIP writer) and opens the
// share sheet, so a backup can go out over AirDrop, Files, Mail…
void wq_share_folder(UIViewController *host, NSString *dir, NSString *zipName, UIView *source)
{
    if (!wq_share_host_is_active(host)) return;
    if (wq_share_in_flight(host)) {
        wq_alert(host, @"Share in progress", @"Wait for the current share to finish before starting another.");
        return;
    }
    WQSharePreparation *preparation = [WQSharePreparation new];
    preparation.host = host;
    UIAlertController *hud = wq_alert_controller(@"Preparing…", @"Compressing the folder", UIAlertControllerStyleAlert);
    [hud addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, ^(UIAlertAction *__unused action) {
        preparation.cancelled = YES;
        objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host dismissViewControllerAnimated:YES completion:nil];
    })];
    preparation.hud = hud;
    objc_setAssociatedObject(host, &kWQSharePreparationKey, preparation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host presentViewController:hud animated:YES completion:nil];
    // Its own queue: compressing a large folder on the shared I/O queue made
    // every listing and the Apps and Cache scans wait until it was done.
    static dispatch_queue_t zipQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        zipQueue = dispatch_queue_create("wq.share-zip", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    });
    dispatch_async(zipQueue, ^{
        if (preparation.isCancelled) return;
        NSString *resolvedName = zipName ?: wq_zip_name(dir);
        NSString *safe = [[resolvedName componentsSeparatedByCharactersInSet:
                           [NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"-"];
        NSString *outDir = wq_unique_export_directory();
        preparation.exportDir = outDir;
        NSString *zip = outDir ? [outDir stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"zip"]] : nil;
        // WQ Files' own ZIP writer, reading through access tokens. iOS's
        // folder zipper (NSFileCoordinator) gives up on the whole folder when
        // one file refuses reading, and every app folder holds a root-only
        // metadata plist; those files are left out here instead.
        wq_grant(dir);
        WQArchiveIO *io = [WQArchiveIO new];
        io.stat = ^BOOL(NSString *path, struct stat *st) { return wq_stat(path, st); };
        io.list = ^NSArray<NSString *> *(NSString *path) { return wq_list(path, NULL); };
        io.openRead = ^int(NSString *path) { return wq_open_for_reading(path); };
        io.skipUnreadable = YES;
        io.expectedUnreadableNames = [NSSet setWithObject:@".com.apple.mobile_container_manager.metadata.plist"];
        NSUInteger skipped = 0;
        NSString *zipError = nil;
        BOOL ok = zip && !preparation.isCancelled &&
            wq_zip_write(@[dir], zip, io, ^BOOL { return preparation.isCancelled; }, nil, &skipped, &zipError);
        NSString *why = zipError ?: @"Could not create the ZIP";
        wq_log(@"share zip: %@ -> %@ %@ (%lu unreadable, %lu container metadata, %lu links or special files left out)", dir,
               zip.lastPathComponent, ok ? @"OK" : why, (unsigned long)io.unreadable, (unsigned long)io.expectedUnreadable, (unsigned long)skipped);
        NSUInteger unreadable = io.unreadable;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongHost = preparation.host;
            BOOL hudPresented = strongHost && strongHost.presentedViewController == hud;
            void (^finish)(void) = ^{
                BOOL stale = preparation.isCancelled || !wq_share_host_is_active(strongHost);
                wq_clear_preparation(strongHost, preparation);
                if (!ok || stale) {
                    wq_remove_export(outDir);
                    if (!stale && wq_share_host_is_active(strongHost)) {
                        wq_alert(strongHost, @"Cannot share", why);
                    }
                    return;
                }
                if (unreadable == 0) {
                    if (!wq_present_share(strongHost, zip, outDir, source)) wq_remove_export(outDir);
                    return;
                }
                // Say that the ZIP is incomplete before it goes anywhere.
                NSString *note = unreadable == 1
                    ? WQLocalized(@"1 item couldn't be read (no permission) and is not in the ZIP.")
                    : WQLocalizedFormat(@"%lu items couldn't be read (no permission) and are not in the ZIP.", (unsigned long)unreadable);
                UIAlertController *ask = wq_alert_controller(@"Some items left out", note, UIAlertControllerStyleAlert);
                [ask addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) {
                    wq_remove_export(outDir);
                })];
                [ask addAction:wq_alert_action(@"Share", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    if (!wq_present_share(strongHost, zip, outDir, source)) wq_remove_export(outDir);
                })];
                [strongHost presentViewController:ask animated:YES completion:nil];
            };
            if (hudPresented) [strongHost dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}

// "Santander 2026-11-09 14.02.11" for AppBackups/<bundle id>/<date>, else the folder name.
static NSString *wq_zip_name(NSString *dir)
{
    NSArray *parts = dir.pathComponents;
    NSUInteger i = [parts indexOfObject:@"AppBackups"];
    if (i != NSNotFound && i + 2 == parts.count - 1) {
        NSString *bid = parts[i + 1];
        return [NSString stringWithFormat:@"%@ %@", wq_display_name(bid) ?: bid, parts.lastObject];
    }
    if (i != NSNotFound && i + 1 == parts.count - 1) {
        NSString *bid = parts.lastObject;
        return [NSString stringWithFormat:@"%@ backups", wq_display_name(bid) ?: bid];
    }
    return dir.lastPathComponent;
}
