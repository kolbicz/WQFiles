#import <UIKit/UIKit.h>

@interface WQCacheCleanerViewController : UITableViewController <UISearchResultsUpdating>
@end

// Folders and files added to the Cache Cleaner from the file browser (touch
// and hold → Add to Cache Cleaner): inside an app's data container, stored as
// bundle ID + container-relative path. A folder is emptied, a file deleted;
// selected like caches ("auto") or only by hand, as chosen when adding.
BOOL wq_cache_custom_target_contains(NSString *bundleID, NSString *relative);
// The stored target for a full path (matched by its container), or nil.
NSDictionary *wq_cache_custom_target_for_path(NSString *path);
void wq_cache_custom_target_add(NSString *bundleID, NSString *appName, NSString *container, NSString *relative, BOOL isFile,
                                BOOL autoSelect);
void wq_cache_custom_target_set_auto_select(NSString *bundleID, NSString *relative, BOOL autoSelect);
void wq_cache_custom_target_remove(NSString *bundleID, NSString *relative);
