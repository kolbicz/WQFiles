//
//  WQPlistEditor.m
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import "WQPlistEditor.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQUI.h"
#import "WQPlistEditorSupport.h"

typedef NS_ENUM(NSInteger, WQPType) {
    WQPTypeString, WQPTypeInteger, WQPTypeReal, WQPTypeBoolean, WQPTypeDate, WQPTypeData,
    WQPTypeDictionary, WQPTypeArray, WQPTypeUID, WQPTypeUnknown,
};

static WQPType wqp_type(id v)
{
    if ([v isKindOfClass:NSString.class]) return WQPTypeString;
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) return WQPTypeBoolean;
        return CFNumberIsFloatType((__bridge CFNumberRef)v) ? WQPTypeReal : WQPTypeInteger;
    }
    if ([v isKindOfClass:NSDate.class]) return WQPTypeDate;
    if ([v isKindOfClass:NSData.class]) return WQPTypeData;
    if ([v isKindOfClass:NSDictionary.class]) return WQPTypeDictionary;
    if ([v isKindOfClass:NSArray.class]) return WQPTypeArray;
    if (WQPlistIsKeyedArchiveUID(v)) return WQPTypeUID;
    return WQPTypeUnknown;
}

// The English key for a type. Localize it exactly once: pass the key to a
// key-taking helper (wq_alert_action), or use wqp_type_name for embedding.
// Localizing a translated name again collapses types: in Italian, Polish and
// Portuguese "Date" translates to "Data", the key of the Data type.
static NSString *wqp_type_key(WQPType t)
{
    switch (t) {
        case WQPTypeString: return @"String";
        case WQPTypeInteger: return @"Number";
        case WQPTypeReal: return @"Real";
        case WQPTypeBoolean: return @"Boolean";
        case WQPTypeDate: return @"Date";
        case WQPTypeData: return @"Data";
        case WQPTypeDictionary: return @"Dictionary";
        case WQPTypeArray: return @"Array";
        case WQPTypeUID: return @"Reference";
        case WQPTypeUnknown: return WQVerbatim(@"?");
    }
    return WQVerbatim(@"?");
}

// Localized, final text (marked verbatim so no helper looks it up again).
static NSString *wqp_type_name(WQPType t)
{
    return WQVerbatim(WQLocalized(wqp_type_key(t)));
}

static NSString *wqp_hex(NSData *data, NSUInteger max)
{
    const uint8_t *b = data.bytes;
    NSUInteger n = MIN(data.length, max);
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 3];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:i ? @" %02x" : @"%02x", b[i]];
    if (data.length > max) [s appendString:@" …"];
    return s;
}

static NSString *wqp_summary(id v)
{
    switch (wqp_type(v)) {
        case WQPTypeString: return [v length] ? WQPBoundedStringPreview(v) : WQLocalized(@"(empty)");
        case WQPTypeInteger: case WQPTypeReal: return [v stringValue];
        case WQPTypeBoolean: return [v boolValue] ? WQLocalized(@"YES") : WQLocalized(@"NO");
        case WQPTypeDate: return WQPDateText(v);
        case WQPTypeData: return WQLocalizedFormat(@"%lu bytes · %@", (unsigned long)[v length], wqp_hex(v, 24));
        case WQPTypeDictionary: return WQLocalizedFormat(@"%lu keys", (unsigned long)[v count]);
        case WQPTypeArray: return WQLocalizedFormat(@"%lu items", (unsigned long)[v count]);
        case WQPTypeUID: return WQLocalized(@"keyed-archive reference");
        case WQPTypeUnknown: return WQPBoundedStringPreview([v description]);
    }
    return @"";
}

static NSString *wqp_scalar_text(id value, WQPType t)
{
    if (t == WQPTypeData) return wqp_hex(value, WQPMaxDataBytes);
    if (t == WQPTypeDate) return WQPDateText(value);
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return @"";
}

static id wqp_default(WQPType t)
{
    switch (t) {
        case WQPTypeString: return @"";
        case WQPTypeInteger: return @0;
        case WQPTypeReal: return @0.0;
        case WQPTypeBoolean: return @NO;
        // Whole seconds: an XML property list can't store a fraction.
        case WQPTypeDate: return [NSDate dateWithTimeIntervalSinceReferenceDate:floor(NSDate.date.timeIntervalSinceReferenceDate)];
        case WQPTypeData: return [NSData data];
        case WQPTypeDictionary: return [NSMutableDictionary dictionary];
        case WQPTypeArray: return [NSMutableArray array];
        case WQPTypeUID: return @"";
        case WQPTypeUnknown: return @"";
    }
    return @"";
}

static void wqp_alert(UIViewController *host, NSString *title, NSString *message)
{
    UIAlertController *a = wq_alert_controller(title, message, UIAlertControllerStyleAlert);
    [a addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, nil)];
    [host presentViewController:a animated:YES completion:nil];
}

#pragma mark - Document

@interface WQPlistDocument : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) id root;
@property (nonatomic) NSPropertyListFormat format;
@property (nonatomic) BOOL readOnly;
@property (nonatomic, strong) WQEditState *edit;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *version;
@end

@implementation WQPlistDocument
@end

#pragma mark - Editor

@interface WQPlistEditorViewController ()
@property (nonatomic, strong) WQPlistDocument *doc;
@property (nonatomic, strong) id container;   // NSMutableDictionary or NSMutableArray
@property (nonatomic, copy) NSArray *keys;    // sorted keys (dictionary) or nil (array)
@property (nonatomic, copy) NSString *status; // loading / error text
@property (nonatomic) BOOL isRoot;
@end

@implementation WQPlistEditorViewController {
    NSArray *_sortedKeyCache;
    BOOL _keysDirty;
}

- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _doc = [WQPlistDocument new];
        _doc.path = path;
        _doc.readOnly = readOnly;
        _doc.edit = [WQEditState new];
        _isRoot = YES;
        _status = WQLocalized(@"Loading…");
        self.title = path.lastPathComponent;
    }
    return self;
}

- (instancetype)initWithDocument:(WQPlistDocument *)doc container:(id)container title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _doc = doc;
        _container = container;
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    __weak typeof(self) weakSelf = self;
    if (self.isRoot) {
        self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
        [self load];
    } else {
        self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) {
            if ([weakSelf blockWhileSaving]) return;
            [weakSelf.navigationController popViewControllerAnimated:YES];
        }];
    }
    [self updateBar];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)load
{
    NSString *path = self.doc.path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSDictionary *__unused before = wq_file_version(path);
        // One byte over the limit: a larger file is refused, not read in
        // part (a valid XML prefix would parse and later overwrite it; DR-39).
        NSData *data = wq_read(path, WQPMaxSerializedBytes + 1, &error);
        if (data.length > WQPMaxSerializedBytes) {
            data = nil;
            error = WQLocalizedFormat(@"The property list is too large to edit (maximum %lu MiB).", (unsigned long)(WQPMaxSerializedBytes / (1024 * 1024)));
        }
        NSDictionary *version = wq_file_version(path);
        if (data && (!before || ![before isEqualToDictionary:version])) {
            data = nil;
            error = WQLocalized(@"The file changed while it was being read. Open it again.");
        }
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        NSError *parseError = nil;
        id root = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                  options:NSPropertyListMutableContainersAndLeaves
                                                                   format:&format error:&parseError] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.doc.version = version;
            if (!root) {
                self.status = data ? WQLocalizedFormat(@"Not a property list: %@", parseError.localizedDescription)
                                   : (wq_permission_hint(path, NO) ?: WQLocalizedFormat(@"Cannot read this file: %@", error));
            } else if (![root isKindOfClass:NSMutableDictionary.class] && ![root isKindOfClass:NSMutableArray.class]) {
                // A plist whose root is a single value: wrap it for display only.
                self.doc.format = format;
                self.doc.root = root;
                self.doc.readOnly = YES;
                self.container = [NSMutableArray arrayWithObject:root];
                self.status = nil;
            } else {
                if (wq_permission_hint(path, YES)) self.doc.readOnly = YES;   // readable, but only the owner may write
                if (!WQPlistFormatIsWritable(format)) self.doc.readOnly = YES; // OpenStep/unknown format
                self.doc.root = root;
                self.doc.format = format;
                self.container = root;
                self.status = nil;
            }
            [self refresh];
        });
    });
}

- (void)refresh
{
    if ([self.container isKindOfClass:NSDictionary.class]) {
        if (!_sortedKeyCache || _keysDirty) {
            _sortedKeyCache = [[self.container allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
            _keysDirty = NO;
        }
        self.keys = _sortedKeyCache;
    } else {
        self.keys = nil;
        _sortedKeyCache = nil;
        _keysDirty = NO;
    }
    [self updateBar];
    [self.tableView reloadData];
}

- (BOOL)isArray
{
    return [self.container isKindOfClass:NSArray.class];
}

- (void)updateBar
{
    NSMutableArray *items = [NSMutableArray array];
    if (!self.doc.readOnly && self.container) {
        UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Save") style:wq_primary_button_style()
                                                                target:self action:@selector(save)];
        save.enabled = self.doc.edit.dirty && !self.doc.edit.saving;
        [items addObject:save];
        UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                              target:self action:@selector(add)];
        add.enabled = !self.doc.edit.saving;
        [items addObject:add];
    }
    NSMutableArray *menu = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    if (self.isArray && !self.doc.readOnly && !self.doc.edit.saving && self.container) {
        [menu addObject:[UIAction actionWithTitle:WQLocalizedNullable(self.tableView.editing ? @"Done Reordering" : @"Reorder Items")
                                            image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil
                                          handler:^(UIAction *__unused a) {
            [weakSelf.tableView setEditing:!weakSelf.tableView.editing animated:YES];
            [weakSelf updateBar];
        }]];
    }
    if (self.openAsText) [menu addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Open as XML Text") image:[UIImage systemImageNamed:@"doc.plaintext"]
                                                         identifier:nil handler:^(UIAction *__unused a) { [weakSelf leaveThen:weakSelf.openAsText]; }]];
    if (self.openAsHex) [menu addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Open in Hex Viewer") image:[UIImage systemImageNamed:@"number"]
                                                        identifier:nil handler:^(UIAction *__unused a) { [weakSelf leaveThen:weakSelf.openAsHex]; }]];
    if (menu.count)
        [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                           menu:[UIMenu menuWithChildren:menu]]];
    self.navigationItem.rightBarButtonItems = items;
}

#pragma mark Leaving and saving

- (BOOL)wq_needsLeaveConfirmation
{
    // Ordinary dirty child navigation keeps the shared edits, but no editor
    // may leave while the shared document is being written.
    return self.doc.edit.saving || (self.isRoot && self.doc.edit.dirty);
}

- (void)leave
{
    [self leaveThen:nil];
}

- (BOOL)blockWhileSaving
{
    if (!self.doc.edit.saving) return NO;
    wqp_alert(self, @"Save in progress", @"Wait for the current save to finish before leaving or making more changes.");
    return YES;
}

// Asks before throwing away unsaved changes, then pops to the folder and runs `then`.
- (void)leaveThen:(void (^)(void))then
{
    if ([self blockWhileSaving]) return;
    UINavigationController *nav = self.navigationController;
    NSUInteger rootIndex = [nav.viewControllers indexOfObjectPassingTest:^BOOL(UIViewController *vc, NSUInteger __unused i, BOOL *__unused stop) {
        return [vc isKindOfClass:WQPlistEditorViewController.class] && ((WQPlistEditorViewController *)vc).isRoot &&
               ((WQPlistEditorViewController *)vc).doc == self.doc;
    }];
    void (^go)(void) = ^{
        if (rootIndex != NSNotFound && rootIndex > 0)
            [nav popToViewController:nav.viewControllers[rootIndex - 1] animated:then == nil];
        if (then) then();
    };
    [self discardIfConfirmedThen:go];
}

// Runs `proceed` at once without unsaved edits, else after the user agreed
// to throw them away.
- (void)discardIfConfirmedThen:(void (^)(void))proceed
{
    if (!self.doc.edit.dirty) { proceed(); return; }
    UIAlertController *a = wq_alert_controller(@"Discard changes?", @"Your edits to this property list have not been saved.", UIAlertControllerStyleAlert);
    [a addAction:wq_alert_action(@"Keep Editing", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Discard", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused x) {
        [self.doc.edit discard];
        proceed();
    })];
    [self presentViewController:a animated:YES completion:nil];
}

// Home button: ask before throwing away unsaved changes.
- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    [self discardIfConfirmedThen:proceed];
}

- (void)save
{
    if ([self blockWhileSaving] || self.doc.readOnly || !self.doc.edit.dirty) return;
    WQPlistDocument *doc = self.doc;
    if (!WQPlistFormatIsWritable(doc.format)) {
        wqp_alert(self, @"Read-only format", @"This property list uses an OpenStep/unknown format that cannot be saved by the editor. Use Open as XML Text and choose a supported format explicitly.");
        return;
    }
    if (!doc.version) {
        wqp_alert(self, @"Cannot save safely", @"The current file version is unavailable. Reopen the file before saving again.");
        return;
    }
    NSString *fmt = WQLocalized(WQPlistFormatName(doc.format));
    UIAlertController *a = wq_alert_controller(@"Save changes?", WQVerbatim(WQLocalizedFormat(@"%@ is overwritten in place (%@ format). The current version is backed up first.", doc.path, fmt)), UIAlertControllerStyleAlert);
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Save", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused x) {
        NSUInteger savedRevision = [doc.edit beginSave];
        NSDictionary *expectedVersion = [doc.version copy];
        NSString *path = [doc.path copy];
        NSPropertyListFormat format = doc.format;
        id root = doc.root;
        UINavigationController *navigationController = self.navigationController;
        __weak WQPlistEditorViewController *weakSelf = self;
        [self refresh];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *serializationError = nil;
            NSString *writeError = nil;
            BOOL ok = NO;
            NSDictionary *savedVersion = nil;
            NSString *copyError = nil;
            id snapshot = WQPlistImmutableCopy(root, &copyError);
            NSData *data = snapshot ? [NSPropertyListSerialization dataWithPropertyList:snapshot
                                                                                     format:format
                                                                                    options:0
                                                                                      error:&serializationError] : nil;
            if (!snapshot) {
                writeError = copyError ?: WQLocalized(@"The edited property list contains an unsupported value.");
            } else if (format == NSPropertyListXMLFormat_v1_0 && WQPHasFractionalDate(snapshot)) {
                writeError = WQLocalized(@"This XML property list can only store dates to the second, and a date here has a fraction of a second. Remove the fraction from the date, then save again. Nothing was saved.");
            } else if (!data) {
                writeError = serializationError.localizedDescription ?: WQLocalized(@"The edited property list is not valid.");
            } else if (!WQPSerializedDataWithinLimit(data)) {
                writeError = WQLocalizedFormat(@"The serialized property list is too large (maximum %lu MiB).", (unsigned long)(WQPMaxSerializedBytes / (1024 * 1024)));
            } else {
                NSError *validationError = nil;
                id check = [NSPropertyListSerialization propertyListWithData:data
                                                                        options:NSPropertyListImmutable
                                                                         format:NULL
                                                                          error:&validationError];
                if (!check) {
                    writeError = validationError.localizedDescription ?: WQLocalized(@"The serialized property list could not be validated.");
                } else {
                    ok = wq_write_if_unchanged_get_version(path, data, expectedVersion, &savedVersion, &writeError);
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [doc.edit finishSave:ok revision:savedRevision];
                // Returned while the saved bytes were verified on the locked
                // descriptor; a later external change is rejected next save.
                if (ok) doc.version = savedVersion;

                WQPlistEditorViewController *origin = weakSelf;
                UINavigationController *nav = navigationController ?: origin.navigationController;
                WQPlistEditorViewController *visible = nil;
                for (UIViewController *controller in nav.viewControllers) {
                    if (![controller isKindOfClass:WQPlistEditorViewController.class]) continue;
                    WQPlistEditorViewController *editor = (WQPlistEditorViewController *)controller;
                    if (editor.doc != doc) continue;
                    [editor refresh];
                    if (controller == nav.visibleViewController) visible = editor;
                }
                if (!visible && origin.doc == doc) {
                    [origin refresh];
                    if (origin.viewIfLoaded.window) visible = origin;
                }
                if (!ok && visible.viewIfLoaded.window) {
                    NSString *hint = wq_permission_hint(path, YES);
                    NSString *reason = hint ?: writeError;
                    wqp_alert(visible, @"Save failed", reason ? WQVerbatim(reason) : @"Unknown error");
                }
            });
        });
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)changed
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    // Callers have already changed the data. Record it even during a save: the
    // newer revision keeps the document dirty when that save finishes. The
    // guard above also protects stale UI callbacks from changing readonly or
    // frozen documents.
    _keysDirty = YES;
    [self.doc.edit noteChange];
    [self refresh];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.status ? 0 : (NSInteger)[self.container count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (self.status) return self.status;
    if (!self.isRoot) return nil;
    NSString *fmt = WQLocalized(WQPlistFormatName(self.doc.format));
    if (self.doc.readOnly) {
        NSString *reason = WQPlistFormatIsWritable(self.doc.format) ? WQLocalized(@"read only") : WQLocalized(@"read only · writing is not supported");
        return WQLocalizedFormat(@"%@ property list · %@", fmt, reason);
    }
    return WQLocalizedFormat(@"%@ property list. Tap a value to edit it, swipe to delete or rename, + to add.", fmt);
}

- (id)keyAt:(NSInteger)row
{
    return self.isArray ? @(row) : self.keys[(NSUInteger)row];
}

- (id)valueAt:(NSInteger)row
{
    return self.isArray ? self.container[(NSUInteger)row] : self.container[self.keys[(NSUInteger)row]];
}

- (void)setValue:(id)value at:(NSInteger)row
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    if (self.isArray) self.container[(NSUInteger)row] = value;
    else self.container[self.keys[(NSUInteger)row]] = value;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"plist"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"plist"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    id value = [self valueAt:indexPath.row];
    WQPType t = wqp_type(value);
    c.text = self.isArray ? WQLocalizedFormat(@"Item %ld", (long)indexPath.row) : [self keyAt:indexPath.row];
    c.secondaryText = WQLocalizedFormat(@"%@ · %@", wqp_type_name(t), wqp_summary(value));
    c.secondaryTextProperties.numberOfLines = 3;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    if (t == WQPTypeDictionary || t == WQPTypeArray) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (t == WQPTypeBoolean) {
        UISwitch *sw = [UISwitch new];
        sw.on = [value boolValue];
        sw.enabled = !self.doc.readOnly && !self.doc.edit.saving;
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(boolChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)boolChanged:(UISwitch *)sw
{
    if (self.doc.readOnly || self.doc.edit.saving) {
        sw.on = [[self valueAt:sw.tag] boolValue];
        return;
    }
    [self setValue:@(sw.on) at:sw.tag];
    [self changed];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.doc.edit.saving) return;
    id value = [self valueAt:indexPath.row];
    WQPType t = wqp_type(value);
    // A raw plist key or an already rendered "Item n": shown as is, never
    // looked up as a localization key.
    NSString *name = WQVerbatim(self.isArray ? WQLocalizedFormat(@"Item %ld", (long)indexPath.row) : [self keyAt:indexPath.row]);
    if (t == WQPTypeDictionary || t == WQPTypeArray) {
        WQPlistEditorViewController *child = [[WQPlistEditorViewController alloc] initWithDocument:self.doc container:value title:name];
        [self.navigationController pushViewController:child animated:YES];
        return;
    }
    if (t == WQPTypeUID) {
        wqp_alert(self, @"Reference value", @"Keyed-archive references are read-only in this editor. Edit the archived data through its owning key instead.");
        return;
    }
    if (t == WQPTypeBoolean || self.doc.readOnly || self.doc.edit.saving) return;
    NSInteger row = indexPath.row;
    [self editValueOfType:t current:value title:name done:^(id newValue) {
        [self setValue:newValue at:row];
        [self changed];
    }];
}

// Asks for a scalar value of type `t`; `done` gets the parsed value.
- (void)editValueOfType:(WQPType)t current:(id)current title:(NSString *)title done:(void (^)(id value))done
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    if (t == WQPTypeUID) return;
    if (t == WQPTypeData && [current length] > WQPMaxDataBytes) {
        wqp_alert(self, @"Too large to edit here", @"Data over 4 KB can't be edited in this editor.");
        return;
    }
    if (t == WQPTypeString && [current length] > WQPMaxStringInputCharacters) {
        wqp_alert(self, @"Too large to edit here", @"Strings over 64 KB can't be edited in this editor.");
        return;
    }
    NSString *hint = nil;
    switch (t) {
        case WQPTypeInteger: hint = WQLocalized(@"Whole number"); break;
        case WQPTypeReal: hint = WQLocalized(@"Number"); break;
        case WQPTypeDate: hint = WQLocalized(@"ISO 8601, e.g. 2026-11-09T15:00:00Z"); break;
        case WQPTypeData: hint = WQLocalized(@"Hex bytes, e.g. 01 ab ff"); break;
        default: break;
    }
    UIAlertController *a = wq_alert_controller(title, WQVerbatim([wqp_type_name(t) stringByAppendingString:hint ? [@" · " stringByAppendingString:hint] : @""]), UIAlertControllerStyleAlert);
    NSString *initialText = wqp_scalar_text(current, t);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = initialText;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeAlways;
        if (t == WQPTypeInteger) f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        // Not the decimal pad: it has no minus and no "e".
        if (t == WQPTypeReal) f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    __weak UIAlertController *weakAlert = a;   // the action belongs to the alert
    [a addAction:wq_alert_action(@"Set", UIAlertActionStyleDefault, ^(UIAlertAction *__unused x) {
        NSString *text = weakAlert.textFields.firstObject.text ?: @"";
        id value = nil;
        if (t != WQPTypeData && !WQPStringInputWithinLimit(text)) {
            wqp_alert(self, @"Value too large", @"Scalar values are limited to 64 KB in this editor.");
            return;
        }
        if (t == WQPTypeData && !WQPDataInputWithinLimit(text)) {
            wqp_alert(self, @"Value too large", @"Hex input is limited to 16 KB in this editor.");
            return;
        }
        // Unchanged text keeps the original value exactly (sub-millisecond
        // date precision, integer representation, data bytes).
        if (current && [text isEqualToString:initialText]) { done(current); return; }
        switch (t) {
            case WQPTypeString: value = text; break;
            case WQPTypeInteger: value = WQPParseInteger(text); break;   // rejects overflow, keeps unsigned 64-bit
            case WQPTypeReal: value = WQPParseReal(text); break;   // accepts "1,5"; rejects 1e999
            case WQPTypeDate: value = WQPParseDate(text); break;
            case WQPTypeData: {
                NSData *data = WQParseHex(text, YES);
                if (data.length > WQPMaxDataBytes) {
                    wqp_alert(self, @"Value too large", @"Data values are limited to 4 KB in this editor.");
                    return;
                }
                value = data;
                break;
            }
            default: break;
        }
        if (!value) { wqp_alert(self, @"Not a valid value", WQVerbatim(WQLocalizedFormat(@"Expected: %@", hint ?: wqp_type_name(t)))); return; }
        done(value);
    })];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Adding, deleting, renaming, moving

- (void)add
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    UIAlertController *sheet = wq_alert_controller(@"Add", @"Type of the new value", UIAlertControllerStyleActionSheet);
    for (WQPType t = WQPTypeString; t <= WQPTypeArray; t++) {
        [sheet addAction:wq_alert_action(wqp_type_key(t), UIAlertActionStyleDefault, ^(UIAlertAction *__unused x) {
            [self addValueOfType:t];
        })];
    }
    [sheet addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.count > 1
        ? self.navigationItem.rightBarButtonItems[1] : self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)addValueOfType:(WQPType)t
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    void (^insert)(NSString *key) = ^(NSString *key) {
        if (self.doc.readOnly || self.doc.edit.saving) return;
        id value = wqp_default(t);
        void (^put)(id) = ^(id v) {
            if (self.doc.readOnly || self.doc.edit.saving) return;
            if (self.isArray) {
                [self.container addObject:v];
            } else {
                if (!key.length) return;  // dictionary insertion always has a validated key
                NSMutableDictionary *dictionary = self.container;
                dictionary[key] = v;
            }
            [self changed];
        };
        if (t == WQPTypeDictionary || t == WQPTypeArray || t == WQPTypeBoolean) { put(value); return; }
        [self editValueOfType:t current:value title:key ? WQVerbatim(key) : @"New Item" done:put];
    };
    if (self.isArray) { insert(nil); return; }
    [self askKey:nil title:@"Key" done:insert];
}

- (void)askKey:(NSString *)current title:(NSString *)title done:(void (^)(NSString *key))done
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    UIAlertController *a = wq_alert_controller(title, nil, UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = current;
        f.placeholder = WQLocalizedNullable(@"Key");
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, ^(UIAlertAction *__unused x) {
        NSString *key = a.textFields.firstObject.text ?: @"";
        if (key.length == 0) return;
        if (![key isEqualToString:current] && self.container[key]) {
            wqp_alert(self, @"Key exists", WQVerbatim(WQLocalizedFormat(@"There is already a key named \"%@\".", key)));
            return;
        }
        done(key);
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.doc.readOnly || self.doc.edit.saving) return nil;
    NSInteger row = indexPath.row;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:WQLocalizedNullable(@"Delete")
        handler:^(UIContextualAction *__unused action, UIView *__unused view, void (^completion)(BOOL)) {
        if (self.doc.readOnly || self.doc.edit.saving) { completion(NO); return; }
        if (self.isArray) [self.container removeObjectAtIndex:(NSUInteger)row];
        else [self.container removeObjectForKey:self.keys[(NSUInteger)row]];
        [self changed];
        completion(YES);
    }];
    if (self.isArray) return [UISwipeActionsConfiguration configurationWithActions:@[del]];
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:WQLocalizedNullable(@"Rename")
        handler:^(UIContextualAction *__unused action, UIView *__unused view, void (^completion)(BOOL)) {
        if (self.doc.readOnly || self.doc.edit.saving) { completion(NO); return; }
        NSString *old = self.keys[(NSUInteger)row];
        [self askKey:old title:@"Rename Key" done:^(NSString *key) {
            if (self.doc.readOnly || self.doc.edit.saving) return;
            if ([key isEqualToString:old]) return;
            id v = self.container[old];
            [self.container removeObjectForKey:old];
            self.container[key] = v;
            [self changed];
        }];
        completion(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, rename]];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return self.isArray && !self.doc.readOnly && !self.doc.edit.saving;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    id v = self.container[(NSUInteger)from.row];
    [self.container removeObjectAtIndex:(NSUInteger)from.row];
    [self.container insertObject:v atIndex:(NSUInteger)to.row];
    [self.doc.edit noteChange];
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

@end
