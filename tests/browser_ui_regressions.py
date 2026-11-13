#!/usr/bin/env python3
"""Static regression checks for UIKit-only browser and sharing paths."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
main = (ROOT / "main.m").read_text()
sharing = (ROOT / "WQSharing.m").read_text()
ui = (ROOT / "WQUI.m").read_text()
header = (ROOT / "WQSharing.h").read_text()


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"missing {label}: {needle}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise AssertionError(f"stale {label}: {needle}")


require(main, "BOOL _scanNeedsRefresh;", "scan refresh state")
require(main, "_scanNeedsRefresh || _lastReloadFinished <= 0", "restart after canceled scan or stale metadata")
require(main, "self->_scanStatus = nil;", "canceled scan status cleanup")
require(main, "self->_scanInFlight = NO;", "scan completion state cleanup")
require(main, "self->_error = (names || childPaths != nil) ? nil", "empty enumeration success")
require(main, "item.isRegular = S_ISREG(st.st_mode);", "regular-file metadata")
require(main, "Only regular files can be viewed.", "special-file view refusal")
require(main, "wq_backup_original_path(item.path)", "typed backup path derivation")
require(main, "initWithPath:wq_backup_root() title:WQLocalizedNullable(@\"File Backups\")", "Backups root navigation")
require(main, "if (!_version)", "nil editor version refusal")
forbid(main, "childPaths.count) ? nil : error", "count-based enumeration success check")
health_present = main.split("- (void)presentPendingHealthFailure", 1)[1].split("// Each set of warnings", 1)[0]
require(health_present, "if (![self healthFailureCanPresent])", "startup failure waits for an idle start screen")
forbid(health_present, "while (host.presentedViewController)", "startup failure presented over open actions")
forbid(main, "wq_backup_root().stringByDeletingLastPathComponent title:@\"Backups\"", "parent-path Backups navigation")
forbid(main, "item.isDir = S_ISDIR(target.st_mode);", "symlink target directory override")
require(main, "WQ Files does not follow symbolic links", "symlink UI contract")
require(main, "latest.bundleID ?: latest.label", "copy identifier uses the identifier")
require(main, "@\"App Backups\"", "App Backups shortcut")
require(main, "wq_delete_backup", "explicit backup management deletion")
require(main, "wq_backup_unit_deletable", "backup units are selectable")
require(main, "@\"Select Backups\"", "backup multi-selection mode")
require(main, "deleteSelectedBackups", "multi-backup deletion action")
require(main, "@\"Delete Backup…\"", "single backup deletion action")
require(main, "wq_move_expecting(path, dest, wq_identity_at(identities, i)", "Move Here revalidates the picked identity")
require(main, "wq_delete_tree_expecting(path, wq_identity_at(identities, i)", "folder delete revalidates the selected identity")
require(main, "wq_rename_expecting(item.path, name, item.identity", "rename revalidates the listed identity")
require(main, "links or special files (pipes, sockets) are removed without a backup", "delete confirmation discloses unbacked entries")
forbid(main, "wq_tree_count(path, 1000000, &files, &bytes)", "delete count that lumps links with backed-up files")
text_save = main.split("- (void)toggleEdit:", 1)[1].split("- (void)share:", 1)[0]
require(text_save, "wq_write_if_unchanged_get_version", "descriptor-verified text save result")
forbid(text_save, "wq_file_version(", "post-write pathname version adoption")

require(header, "void wq_share_cancel(UIViewController *host);", "share cancellation API")
cache = (ROOT / "WQCache.m").read_text()
require(cache, "_cleanRequiresRescan", "clean requires rescan after a validation failure")
require(cache, "item.selected = !item.limited", "limited cache rows are not selected")
require(cache, "if (item.crashLogs)", "crash-log context menu branch")
require(cache, "NSUInteger appCount = 0;", "cache header excludes crash logs from app count")
require(cache, "self.refreshControl = [UIRefreshControl new];", "cache refresh control")
require(cache, "_lastScanFinished > 0", "cache rescans stale data on appearance")
require(cache, "_cleanCancellation", "cache clean cancellation")
require(cache, "action:@selector(stopClean)", "cache clean stop button")
cache_buttons = cache.split("- (void)updateButtons", 1)[1].split("    if (_scanning) {", 1)[0]
require(cache_buttons, "if (_cleaning)", "cache Stop button checked before the scanning state")
cache_refresh = cache.split("- (void)userRefresh", 1)[1].split("- (void)scan\n", 1)[0]
require(cache_refresh, "_refreshAfterClean = YES;", "pull to refresh is queued while cleaning")
cache_scan = cache.split("- (void)scan\n", 1)[1].split("[_scanCancellation cancel];", 1)[0]
require(cache_scan, "if (_cleaning)", "no cache scan starts while cleaning")
require(cache, "[self rescanAfterClean:YES];", "one serialized refresh after cleaning")
require(cache, "Close running apps first.", "cache clean warning")
require(sharing, "__weak UIViewController *weakHost", "weak sharing host")
require(sharing, "preparation.cancelled", "abandoned folder preparation")
require(sharing, "wq_remove_export(outDir)", "abandoned export cleanup")
require(sharing, "Only regular files can be shared.", "special-file share refusal")
require(ui, "host.presentedViewController && !host.presentedViewController.isBeingDismissed", "validated alert host")
require(sharing, "Share in progress", "share in-flight guard")
require(sharing, "wq_clear_in_flight", "share in-flight cleanup")
require(sharing, "wq_alert_action(@\"Cancel\"", "folder share cancel action")
clear_preparation = sharing.split("static void wq_clear_preparation", 1)[1].split("static BOOL wq_present_share", 1)[0]
require(clear_preparation, "if (!host) return;", "nil weak host association guard")

print("browser UI regression checks: PASS")

# App backups never come out empty because access wasn't there yet, and an
# empty backup is never restored (it would empty the app's data).
apps = (ROOT / "WQApps.m").read_text()
require(apps, "NSArray<NSString *> *top = wq_list(container, &listError);", "backup lists the container before choosing parts")
forbid(apps, "errno == ENOENT) continue;   // the app has none", "part skipped on an ENOENT that may be a missing token")
require(apps, "if (!parts.count) {", "empty backups are refused on restore")
