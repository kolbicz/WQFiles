#import <UIKit/UIKit.h>

@interface WQCacheCleanerViewController : UITableViewController <UISearchResultsUpdating>
@end

// Folders and files added to the Cache Cleaner from the file browser (touch
// and hold → Add to Cache Cleaner): inside an app's data container, stored as
// bundle ID + container-relative path. Never selected by default; a folder is
// emptied, a file deleted.
BOOL wq_cache_custom_target_contains(NSString *bundleID, NSString *relative);
// The stored target for a full path (matched by its container), or nil.
NSDictionary *wq_cache_custom_target_for_path(NSString *path);
void wq_cache_custom_target_add(NSString *bundleID, NSString *appName, NSString *container, NSString *relative, BOOL isFile);
void wq_cache_custom_target_remove(NSString *bundleID, NSString *relative);
