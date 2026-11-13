//
//  main.m
//  WQ Files
//
//  Proof-of-concept file browser for iOS 27 that reaches other containers
//  through the worse_query sandbox escape by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//  This app is GPL-3.0-or-later as well (see LICENSE).
//

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQUI.h"
#import "WQSharing.h"
#import "WQDir.h"
#import "WQApps.h"
#import "WQCache.h"
#import "WQCore.h"
#import "WQAccessSafety.h"
#import <CommonCrypto/CommonDigest.h>
#import "WQPlistEditor.h"
#import "WQPlistEditorSupport.h"
#import "WQHexViewer.h"
#import "WQSQLiteViewer.h"
#import "WQHealth.h"
#import "WQTrash.h"
#import "WQArchive.h"
#import "WQSyntax.h"
#import "WQMediaStream.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <sys/mount.h>

static BOOL wq_looks_like_uuid(NSString *name)
{
    return name.length == 36 && [[NSUUID alloc] initWithUUIDString:name] != nil;
}

static BOOL wq_regular_file_for_ui(NSString *path)
{
    struct stat st;
    if (!wq_stat(path, &st)) return NO;
    // Symbolic links are deliberately not followed: the file APIs use
    // O_NOFOLLOW and the UI must offer the same contract.
    return S_ISREG(st.st_mode);
}

#pragma mark - Item

@interface WQItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *bundleID;  // for the app icon
@property (nonatomic) BOOL isDir;
@property (nonatomic) BOOL isLink;
@property (nonatomic) BOOL isRegular;
@property (nonatomic) unsigned long long size;
@property (nonatomic) mode_t mode;
@property (nonatomic) uid_t uid;
@property (nonatomic, strong) NSDate *modified;
@property (nonatomic, strong) NSDate *created;
@property (nonatomic) NSInteger childCount;   // folders, with Show Item Counts on; -1 unknown
// Device, inode and type when listed: delete/rename/move act only on this object.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSNumber *> *identity;
@end

@implementation WQItem
- (instancetype)init
{
    if ((self = [super init])) _childCount = -1;
    return self;
}
@end

// Settings → Show Item Counts (off by default): lists every subfolder, which
// is slow in other apps' containers.
static NSString *const kWQShowItemCountsPref = @"WQShowItemCounts";
// Reopen Last Folder (issue #41) and Check for Updates: both on by default.
static NSString *const kWQReopenOffPref = @"WQReopenLastFolderOff";
static NSString *const kWQLastFolderPref = @"WQLastFolder";
static NSString *const kWQUpdateCheckOffPref = @"WQUpdateCheckOff";
static NSString *const kWQUpdateCheckedPref = @"WQUpdateCheckedAt";
static BOOL wq_show_item_counts(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kWQShowItemCountsPref];
}

#pragma mark - File viewer

typedef NS_ENUM(NSInteger, WQOpenMode) { WQOpenAuto, WQOpenPlist, WQOpenText, WQOpenHex, WQOpenSQLite, WQOpenMedia };
// Opens a file in the fitting viewer (Auto: chosen from its first bytes).
static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode);

typedef NS_ENUM(NSInteger, WQViewKind) { WQViewText, WQViewPlist, WQViewImage, WQViewHex };

static const NSUInteger kViewLimit = 4 * 1024 * 1024;
static const NSUInteger kHexLimit = 64 * 1024;

// Parsing and image creation happen on the I/O queue; the main thread only
// installs the prepared display.
@interface WQFileDisplay : NSObject
@property (nonatomic) BOOL truncated;
@property (nonatomic, strong) NSString *plistText;
@property (nonatomic) NSPropertyListFormat plistFormat;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) NSString *text;
@property (nonatomic, strong) NSString *hexText;
@end
@implementation WQFileDisplay
@end

static NSString *wq_file_hex_dump(NSData *data, BOOL truncated)
{
    NSUInteger len = MIN(data.length, kHexLimit);
    const uint8_t *b = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:len * 4];
    for (NSUInteger off = 0; off < len; off += 16) {
        [out appendFormat:@"%08lx  ", (unsigned long)off];
        NSMutableString *ascii = [NSMutableString new];
        for (NSUInteger i = 0; i < 16; i++) {
            if (off + i < len) {
                uint8_t c = b[off + i];
                [out appendFormat:@"%02x ", c];
                [ascii appendFormat:@"%c", (c >= 0x20 && c < 0x7f) ? c : '.'];
            } else {
                [out appendString:@"   "];
            }
        }
        [out appendFormat:@" %@\n", ascii];
    }
    if (data.length > len || truncated) [out appendString:@"\n… (only the beginning is shown)\n"];
    return out;
}

@interface WQFileViewController : UIViewController <UITextViewDelegate, WQUnsavedEditing>
@property (nonatomic) BOOL readOnly;
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation WQFileViewController {
    NSString *_path;
    UITextView *_textView;
    UIImageView *_imageView;
    UIBarButtonItem *_editButton;
    WQViewKind _kind;
    NSPropertyListFormat _plistFormat;
    BOOL _truncated;
    WQEditState *_editState;
    NSDictionary<NSString *, NSNumber *> *_version;
    NSString *_syntaxLanguage;
    NSUInteger _syntaxGeneration;
}

static UIColor *wq_syntax_color(WQSyntaxKind kind)
{
    switch (kind) {
        case WQSyntaxComment: return UIColor.systemGrayColor;
        case WQSyntaxString: return UIColor.systemRedColor;
        case WQSyntaxKey: return UIColor.systemTealColor;
        case WQSyntaxKeyword: return UIColor.systemPinkColor;
        case WQSyntaxNumber: return UIColor.systemPurpleColor;
        case WQSyntaxTag: return UIColor.systemBlueColor;
        case WQSyntaxAttribute: return UIColor.systemOrangeColor;
        case WQSyntaxPreprocessor: return UIColor.systemBrownColor;
    }
    return UIColor.labelColor;
}

// Colors the text in the background; edits recolor after a short pause.
- (void)highlightAfter:(NSTimeInterval)delay
{
    NSString *language = _syntaxLanguage;
    if (!language) return;
    NSUInteger generation = ++_syntaxGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WQFileViewController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_syntaxGeneration) return;
        NSString *text = [strongSelf->_textView.text copy];
        if (text.length > kWQSyntaxMaxLength) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *tokens = wq_syntax_tokens(text, language, ^BOOL {
                WQFileViewController *s = weakSelf;
                return !s || generation != s->_syntaxGeneration;
            });
            if (!tokens) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                WQFileViewController *s = weakSelf;
                if (!s || generation != s->_syntaxGeneration) return;
                UITextView *view = s->_textView;
                // Not while the keyboard is composing (marked text), or if the text moved on.
                if (view.markedTextRange) { [s highlightAfter:0.5]; return; }
                if (![view.text isEqualToString:text]) return;
                NSTextStorage *storage = view.textStorage;
                NSRange all = NSMakeRange(0, storage.length);
                [storage beginEditing];
                [storage addAttribute:NSForegroundColorAttributeName value:UIColor.labelColor range:all];
                const WQSyntaxToken *t = tokens.bytes;
                for (NSUInteger i = 0; i < tokens.length / sizeof(WQSyntaxToken); i++)
                    if (NSMaxRange(t[i].range) <= storage.length)
                        [storage addAttribute:NSForegroundColorAttributeName value:wq_syntax_color(t[i].kind) range:t[i].range];
                [storage endEditing];
                NSMutableDictionary *typing = [view.typingAttributes mutableCopy];
                typing[NSForegroundColorAttributeName] = UIColor.labelColor;
                view.typingAttributes = typing;
            });
        });
    });
}


- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _path = [path copy];
        _editState = [WQEditState new];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    // File contents stay left-to-right in right-to-left languages, like code editors.
    _textView.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    _textView.textAlignment = NSTextAlignmentLeft;
    _textView.editable = NO;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.smartQuotesType = UITextSmartQuotesTypeNo;
    _textView.smartDashesType = UITextSmartDashesTypeNo;
    _textView.alwaysBounceVertical = YES;
    _textView.delegate = self;
    [self.view addSubview:_textView];
    __weak typeof(self) weakSelf = self;
    self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
    _imageView = [UIImageView new];
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.hidden = YES;
    [self.view addSubview:_imageView];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    for (UIView *v in @[_textView, _imageView]) {
        [NSLayoutConstraint activateConstraints:@[
            [v.topAnchor constraintEqualToAnchor:g.topAnchor],
            [v.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
            [v.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [v.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        ]];
    }
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                           target:self action:@selector(share:)];
    UIMenu *openAs = [UIMenu menuWithTitle:WQLocalizedNullable(@"Open As") children:@[
        [UIAction actionWithTitle:WQLocalizedNullable(@"Plist Editor") image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenPlist]; }],
        [UIAction actionWithTitle:WQLocalizedNullable(@"Hex Viewer") image:[UIImage systemImageNamed:@"number"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenHex]; }],
        [UIAction actionWithTitle:WQLocalizedNullable(@"SQLite Viewer") image:[UIImage systemImageNamed:@"tablecells"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenSQLite]; }],
        [UIAction actionWithTitle:WQLocalizedNullable(@"Media Player") image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenMedia]; }],
    ]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:openAs];
    self.navigationItem.rightBarButtonItems = @[share, more];
    _textView.text = WQLocalizedNullable(@"Loading…");
    [self load];
}

- (void)load
{
    NSString *path = _path;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        struct stat st;
        BOOL exists = wq_stat(path, &st);
        NSDictionary *__unused before = wq_file_version(path);
        NSData *data = wq_read(path, kViewLimit + 1, &error);
        NSDictionary *version = wq_file_version(path);
        if (data && (!before || !version || ![before isEqualToDictionary:version])) {
            data = nil;
            error = version ? @"The file changed while it was being read. Open it again."
                            : @"Could not establish a stable file version. Open it again.";
        }
        WQFileDisplay *display = nil;
        if (data) {
            display = [WQFileDisplay new];
            display.truncated = data.length > kViewLimit;
            NSData *view = display.truncated ? [data subdataWithRange:NSMakeRange(0, kViewLimit)] : data;
            if (!display.truncated) {
                NSPropertyListFormat format = 0;
                id plist = [NSPropertyListSerialization propertyListWithData:view options:0 format:&format error:nil];
                if (plist) {
                    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                            format:NSPropertyListXMLFormat_v1_0
                                                                           options:0 error:nil];
                    NSString *text = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : nil;
                    if (text) {
                        display.plistFormat = format;
                        display.plistText = text;
                    }
                }
            }
            if (!display.plistText) {
                display.image = [UIImage imageWithData:view];
                if (!display.image) {
                    NSString *text = [[NSString alloc] initWithData:view encoding:NSUTF8StringEncoding];
                    if (text && ![text containsString:@"\0"]) display.text = text;
                    else display.hexText = wq_file_hex_dump(view, display.truncated);
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_version = version;
            if (!display) {
                NSString *hint = wq_permission_hint(path, NO);
                self->_textView.text = WQLocalizedFormat(@"Cannot read this file.\n\n%@", hint ?: error);
                return;
            }
            NSString *info = exists
                ? [NSString stringWithFormat:@"%@ · mode %o · uid %u", wq_size_text((unsigned long long)st.st_size),
                   st.st_mode & 07777, st.st_uid]
                : @"";
            self.navigationItem.prompt = info.length ? info : nil;
            if (wq_permission_hint(path, YES)) self->_readOnly = YES;   // only the owner may write it
            [self showDisplay:display];
        });
    });
}

- (void)showDisplay:(WQFileDisplay *)display
{
    _truncated = display.truncated;
    if (display.plistText) {
        _kind = WQViewPlist;
        _plistFormat = display.plistFormat;
        _textView.text = display.plistText;
        _syntaxLanguage = @"xml";
        [self highlightAfter:0];
        if (!WQPlistFormatIsWritable(display.plistFormat)) {
            _readOnly = YES;
            NSString *prompt = self.navigationItem.prompt;
            NSString *reason = WQLocalizedFormat(@"%@ · read only", WQLocalized(WQPlistFormatName(display.plistFormat)));
            self.navigationItem.prompt = prompt.length ? [prompt stringByAppendingFormat:@" · %@", reason] : reason;
        }
        if (!_readOnly) [self enableEditing];
        return;
    }
    if (display.image) {
        _kind = WQViewImage;
        _imageView.image = display.image;
        _imageView.hidden = NO;
        _textView.hidden = YES;
        return;
    }
    if (display.text) {
        _kind = WQViewText;
        _textView.text = display.text;
        _syntaxLanguage = _truncated ? nil : wq_syntax_language(_path.lastPathComponent, display.text);
        [self highlightAfter:0];
        if (!_truncated && !_readOnly) [self enableEditing];
        return;
    }
    _kind = WQViewHex;
    _textView.text = display.hexText ?: @"";
}

- (void)updateEditButton
{
    _editButton.title = _textView.editable ? WQLocalized(@"Save") : WQLocalized(@"Edit");
    _editButton.style = _textView.editable ? wq_primary_button_style() : UIBarButtonItemStylePlain;
    _editButton.enabled = !_editState.saving;
}

- (void)enableEditing
{
    if (_editButton) return;
    _editButton = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Edit") style:UIBarButtonItemStylePlain
                                                  target:self action:@selector(toggleEdit:)];
    NSArray *items = self.navigationItem.rightBarButtonItems;
    self.navigationItem.rightBarButtonItems = [items arrayByAddingObject:_editButton];
}

- (void)textViewDidChange:(UITextView *)textView
{
    if (_editState.saving) return;
    [_editState noteChange];
    [self highlightAfter:0.4];
}

- (BOOL)blockWhileSaving
{
    if (!_editState.saving) return NO;
    wq_alert(self, @"Save in progress", @"Wait for the current save to finish before leaving or making more changes.");
    return YES;
}

- (BOOL)wq_needsLeaveConfirmation
{
    return _editState.dirty || _editState.saving;
}

- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!_editState.dirty) { proceed(); return; }
    UIAlertController *alert = wq_alert_controller(@"Discard changes?", @"Your text changes have not been saved.", UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Keep Editing", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Discard", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self->_editState discard];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        proceed();
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)leave
{
    [self confirmLeaveThen:^{ [self.navigationController popViewControllerAnimated:YES]; }];
}

- (void)toggleEdit:(UIBarButtonItem *)sender
{
    if ([self blockWhileSaving]) return;
    if (!_textView.editable) {
        _textView.editable = YES;
        [self updateEditButton];
        [_textView becomeFirstResponder];
        return;
    }
    if (!_editState.dirty) {
        _textView.editable = NO;
        [_textView resignFirstResponder];
        [self updateEditButton];
        return;
    }
    if (!_version) {
        wq_alert(self, @"Cannot save", @"The file has no verified version snapshot. Reopen it before saving.");
        return;
    }
    NSData *newData = nil;
    if (_kind == WQViewPlist) {
        NSData *xml = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id plist = xml ? [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:&error] : nil;
        if (!plist) {
            wq_alert(self, @"Not a valid property list", error.localizedDescription ?: @"Check the XML.");
            return;
        }
        newData = [NSPropertyListSerialization dataWithPropertyList:plist format:_plistFormat options:0 error:&error];
        if (!newData) {
            wq_alert(self, @"Cannot encode", error.localizedDescription ?: @"");
            return;
        }
    } else {
        newData = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!newData) {
        wq_alert(self, @"Cannot encode", @"The text could not be encoded as UTF-8.");
        return;
    }
    NSString *message = WQLocalizedFormat(@"%@ will be overwritten in place. The current version is backed up to Backups first.", _path);
    UIAlertController *confirm = wq_alert_controller(@"Save changes?", message, UIAlertControllerStyleAlert);
    [confirm addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [confirm addAction:wq_alert_action(@"Save", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        NSUInteger savedRevision = [self->_editState beginSave];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        NSString *path = self->_path;
        NSDictionary *expectedVersion = [self->_version copy];
        dispatch_async(wq_io(), ^{
            NSString *error = nil;
            NSDictionary *newVersion = nil;
            BOOL ok = wq_write_if_unchanged_get_version(path, newData, expectedVersion, &newVersion, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_editState finishSave:ok revision:savedRevision];
                if (ok) self->_version = newVersion;
                self->_textView.editable = self->_editState.dirty;
                [self updateEditButton];
                if (!ok) wq_alert(self, @"Save failed", error ?: wq_permission_hint(path, YES) ?: @"Unknown error");
            });
        });
    })];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)share:(UIBarButtonItem *)sender
{
    wq_share(self, _path, nil);
}

- (void)reopenAs:(WQOpenMode)mode
{
    [self confirmLeaveThen:^{
        UINavigationController *nav = self.navigationController;
        NSString *path = self->_path;
        BOOL readOnly = self->_readOnly;
        [nav popViewControllerAnimated:NO];
        wq_open_file(nav, path, readOnly, mode);
    }];
}

@end

#pragma mark - Choosing a viewer

static WQOpenMode wq_sniff(NSData *head)
{
    const uint8_t *b = head.bytes;
    NSUInteger n = head.length;
    if (n >= 7 && memcmp(b, "bplist0", 7) == 0) return WQOpenPlist;
    if (wq_is_sqlite_header(head)) return WQOpenSQLite;
    if ((n >= 8 && memcmp(b, "\x89PNG", 4) == 0) || (n >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
        (n >= 4 && memcmp(b, "GIF8", 4) == 0) || (n >= 12 && memcmp(b + 4, "ftyp", 4) == 0))
        return WQOpenText;   // images: the file viewer renders them
    if (n == 0) return WQOpenText;
    if (memchr(b, 0, n)) return WQOpenHex;
    NSString *text = nil;
    for (NSUInteger cut = 0; cut < 4 && !text && cut < n; cut++)   // the sample may end mid-character
        text = [[NSString alloc] initWithBytes:b length:n - cut encoding:NSUTF8StringEncoding];
    if (!text) return WQOpenHex;
    if ([text containsString:@"<plist"] || [text containsString:@"<!DOCTYPE plist"]) return WQOpenPlist;
    return WQOpenText;
}

static NSUInteger wq_open_generation;

// Audio and video by extension; local HLS playlists open as text (see
// WQMediaStream).
static BOOL wq_is_media_name(NSString *name)
{
    return [WQMediaStream opensAsMediaByDefault:name];
}

// Fallback copies live in their own folder, tmp/wq-media/<UUID>/, owned by
// one object. The player that plays the copy keeps the owner; when the player
// goes away (or a late copy finds no player), the owner deletes exactly that
// folder, so one player's copy never removes another's.
@interface WQMediaCopyDir : NSObject
@property (nonatomic, readonly, copy) NSString *path;
@end

@implementation WQMediaCopyDir

+ (NSString *)root
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"wq-media"];
}

- (instancetype)init
{
    if ((self = [super init])) _path = [WQMediaCopyDir.root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    return self;
}

- (void)dealloc
{
    NSString *path = _path;
    dispatch_async(wq_io(), ^{ [NSFileManager.defaultManager removeItemAtPath:path error:nil]; });
}

@end

static char kWQMediaCopyDirsKey;

static void wq_media_keep_copy_dir(UIViewController *owner, WQMediaCopyDir *dir)
{
    NSMutableArray *dirs = objc_getAssociatedObject(owner, &kWQMediaCopyDirsKey);
    if (!dirs) {
        dirs = [NSMutableArray new];
        objc_setAssociatedObject(owner, &kWQMediaCopyDirsKey, dirs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [dirs addObject:dir];
}

// At launch: every copy left in tmp/wq-media belongs to an earlier run. Runs
// on the serial I/O queue ahead of any new copy.
static void wq_media_sweep_stale(void)
{
    dispatch_async(wq_io(), ^{
        NSString *root = WQMediaCopyDir.root;
        if ([NSFileManager.defaultManager removeItemAtPath:root error:nil]) wq_log(@"media: removed stale copies");
    });
}

// Copies the file into a new folder of its own and calls back on the main
// queue with the local URL (and the folder's owner) or an error.
static void wq_media_copy(NSString *path, void (^done)(NSURL *_Nullable local, WQMediaCopyDir *_Nullable dir, NSString *_Nullable error))
{
    dispatch_async(wq_io(), ^{
        WQMediaCopyDir *dir = [WQMediaCopyDir new];
        NSString *error = nil;
        NSString *local = [dir.path stringByAppendingPathComponent:path.lastPathComponent];
        BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:dir.path withIntermediateDirectories:YES
                                                           attributes:@{NSFilePosixPermissions: @0700} error:nil];
        if (ok) ok = wq_copy_to_local(path, local, &error);
        else error = WQLocalized(@"The file could not be read.");
        wq_log(@"media: copy %@ -> %@", path.lastPathComponent, ok ? @"OK" : error);
        dispatch_async(dispatch_get_main_queue(), ^{
            done(ok ? [NSURL fileURLWithPath:local] : nil, dir, ok ? nil : (error ?: WQLocalized(@"The file could not be read.")));
        });
    });
}

// Plays audio and video. It streams the file through WQ Files (the media
// process can't read other apps' folders itself), so playback starts at once
// and seeking reads only what's needed. Every range comes from one descriptor
// opened here; if the file changes underneath, the stream fails and the file
// is copied once instead. Types that can't stream that way, and files whose
// stream fails, are copied to a temporary folder of their own and played from
// there.
static void wq_open_media(UINavigationController *nav, NSString *path, BOOL (^stillWanted)(void))
{
    UIViewController *host = nav.topViewController;
    dispatch_async(wq_io(), ^{
        WQMediaFileReader *reader = [[WQMediaFileReader alloc] initWithDescriptor:wq_open_for_reading(path)];
        BOOL regular = reader != nil;
        unsigned long long size = reader.size;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!stillWanted()) return;
            [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
            AVPlayerViewController *player = [AVPlayerViewController new];
            player.title = path.lastPathComponent;
            __weak AVPlayerViewController *weakPlayer = player;
            // Fallback: copy, then swap the copy into the same player. The
            // player owns the copy's folder from then on.
            void (^playCopy)(NSString *) = ^(NSString *why) {
                wq_log(@"media: %@: %@; copying it first", path.lastPathComponent, why);
                AVPlayerViewController *p = weakPlayer;
                if (p && !p.player) p.player = [AVPlayer new];
                UIAlertController *hud = wq_alert_controller(@"Preparing…", path.lastPathComponent, UIAlertControllerStyleAlert);
                UIViewController *presenter = p.viewIfLoaded.window ? p : host;
                [presenter presentViewController:hud animated:YES completion:nil];
                wq_media_copy(path, ^(NSURL *local, WQMediaCopyDir *dir, NSString *error) {
                    void (^finish)(void) = ^{
                        AVPlayerViewController *q = weakPlayer;
                        if (!local) {
                            wq_alert(q.viewIfLoaded.window ? q : host, @"Cannot play", error);
                            return;
                        }
                        // No player any more: dir is released with this
                        // block and removes the copy.
                        if (!q) return;
                        wq_media_keep_copy_dir(q, dir);
                        [q.player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:local]];
                        [q.player play];
                    };
                    if (presenter.presentedViewController == hud) [presenter dismissViewControllerAnimated:YES completion:finish];
                    else finish();
                });
            };
            AVPlayerItem *item = nil;
            if (regular) {
                item = [WQMediaStream playerItemForName:path.lastPathComponent size:size
                    read:^NSData *(unsigned long long offset, NSUInteger length, NSString **error) {
                        return [reader readOffset:offset length:length error:error];
                    } onFailure:^(NSString *reason) {
                        if (weakPlayer) playCopy([@"streaming failed: " stringByAppendingString:reason]);
                    }];
            }
            [nav pushViewController:player animated:YES];
            if (item) {
                wq_log(@"media: streaming %@ (%@, %@)", path.lastPathComponent,
                       [WQMediaStream contentTypeForFileName:path.lastPathComponent], wq_size_text(size));
                player.player = [AVPlayer playerWithPlayerItem:item];
                [player.player play];
            } else {
                playCopy(regular ? @"type can't be streamed" : @"not a regular file or not readable");
            }
        });
    });
}

static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode)
{
    if (!nav || !path.length) return;
    // All calls originate on the main thread. A newer explicit or automatic
    // open invalidates older sniff requests, and leaving the originating screen
    // also prevents a late push.
    NSUInteger request = ++wq_open_generation;
    UIViewController *origin = nav.topViewController;
    void (^push)(WQOpenMode) = ^(WQOpenMode m) {
        if (request != wq_open_generation || nav.topViewController != origin) return;
        if (m == WQOpenMedia) {
            wq_open_media(nav, path, ^BOOL { return request == wq_open_generation && nav.topViewController == origin; });
            return;
        }
        UIViewController *vc;
        if (m == WQOpenPlist) {
            WQPlistEditorViewController *editor = [[WQPlistEditorViewController alloc] initWithPath:path readOnly:readOnly];
            __weak UINavigationController *weakNav = nav;
            editor.openAsText = ^{ wq_open_file(weakNav, path, readOnly, WQOpenText); };
            editor.openAsHex = ^{ wq_open_file(weakNav, path, readOnly, WQOpenHex); };
            vc = editor;
        } else if (m == WQOpenHex) {
            vc = [[WQHexViewController alloc] initWithPath:path readOnly:readOnly];
        } else if (m == WQOpenSQLite) {
            vc = [[WQSQLiteViewController alloc] initWithPath:path readOnly:readOnly];
        } else {
            WQFileViewController *file = [[WQFileViewController alloc] initWithPath:path];
            file.readOnly = readOnly;
            vc = file;
        }
        [nav pushViewController:vc animated:YES];
    };
    if (!wq_regular_file_for_ui(path)) {
        UIViewController *host = nav.topViewController;
        struct stat st;
        BOOL link = wq_stat(path, &st) && S_ISLNK(st.st_mode);
        if (host) wq_alert(host, link ? @"Symbolic link" : @"Cannot open this item",
                           link ? @"WQ Files does not follow symbolic links for viewing, sharing or editing."
                                : @"Only regular files can be viewed.");
        return;
    }
    if (mode == WQOpenAuto && wq_is_media_name(path)) mode = WQOpenMedia;
    if (mode != WQOpenAuto) { push(mode); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *head = wq_permission_hint(path, NO) ? nil : wq_read_range(path, 0, 4096, NULL);
        WQOpenMode m = head ? wq_sniff(head) : WQOpenText;   // unreadable: the file viewer shows why
        dispatch_async(dispatch_get_main_queue(), ^{ push(m); });
    });
}

#pragma mark - Folder

static NSString *wq_folder_date_text(NSDate *date)
{
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.locale = NSLocale.autoupdatingCurrentLocale;
    });
    return date ? [formatter stringFromDate:date] : @"";
}

#pragma mark - Folder sorting

// One sort order for all folders, remembered. Each key starts in its natural
// direction (A–Z, newest first, largest first); picking it again reverses it.
typedef NS_ENUM(NSInteger, WQSortKey) { WQSortName, WQSortModified, WQSortCreated, WQSortSize };
// Container lists (App Data, App Groups…): 0 all, 1 Apple, 2 other, 3 backed up.
static NSString *const kWQContainerFilterPref = @"WQContainerFilter";

static BOOL wq_id_is_apple(NSString *identifier)
{
    for (NSString *prefix in @[@"com.apple.", @"group.com.apple.", @"systemgroup.com.apple."])
        if ([identifier hasPrefix:prefix]) return YES;
    return NO;
}

static NSString *const kWQSortKeyPref = @"WQFolderSortKey";
static NSString *const kWQSortAscendingPref = @"WQFolderSortAscending";
static NSString *const kWQFoldersFirstPref = @"WQFolderSortFoldersFirst";

static WQSortKey wq_sort_key(void)
{
    NSInteger key = [NSUserDefaults.standardUserDefaults integerForKey:kWQSortKeyPref];
    return key >= WQSortName && key <= WQSortSize ? (WQSortKey)key : WQSortName;
}

static BOOL wq_sort_ascending(void)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kWQSortAscendingPref];
    return value ? [value boolValue] : YES;
}

static BOOL wq_folders_first(void)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kWQFoldersFirstPref];
    return value ? [value boolValue] : YES;
}

static void wq_choose_sort(WQSortKey key)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL ascending = key == wq_sort_key() ? !wq_sort_ascending() : key == WQSortName;
    [d setInteger:key forKey:kWQSortKeyPref];
    [d setBool:ascending forKey:kWQSortAscendingPref];
}

static NSString *wq_sort_direction_text(WQSortKey key, BOOL ascending)
{
    switch (key) {
        case WQSortName: return ascending ? WQLocalized(@"A–Z") : WQLocalized(@"Z–A");
        case WQSortSize: return ascending ? WQLocalized(@"Smallest first") : WQLocalized(@"Largest first");
        default: return ascending ? WQLocalized(@"Oldest first") : WQLocalized(@"Newest first");
    }
}

static NSArray<WQItem *> *wq_sorted_items(NSArray<WQItem *> *items)
{
    WQSortKey key = wq_sort_key();
    BOOL ascending = wq_sort_ascending(), foldersFirst = wq_folders_first();
    return [items sortedArrayUsingComparator:^NSComparisonResult(WQItem *a, WQItem *b) {
        if (foldersFirst && a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult r = NSOrderedSame;
        switch (key) {
            case WQSortName: break;
            case WQSortModified: r = [(a.modified ?: NSDate.distantPast) compare:(b.modified ?: NSDate.distantPast)]; break;
            case WQSortCreated: r = [(a.created ?: NSDate.distantPast) compare:(b.created ?: NSDate.distantPast)]; break;
            case WQSortSize: r = a.size < b.size ? NSOrderedAscending : a.size > b.size ? NSOrderedDescending : NSOrderedSame; break;
        }
        NSComparisonResult byName = [(a.label ?: a.name ?: @"") localizedStandardCompare:(b.label ?: b.name ?: @"")];
        if (key == WQSortName) r = byName;
        if (r == NSOrderedSame) return byName;
        return ascending ? r : (NSComparisonResult)-r;
    }];
}

// Sidebar letter for an entry: its first letter without accents, "#" for the rest.
static NSString *wq_index_letter(NSString *name)
{
    if (!name.length) return @"#";
    NSString *first = [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]]
                       stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil].uppercaseString;
    unichar c = first.length ? [first characterAtIndex:0] : 0;
    return (c >= 'A' && c <= 'Z') ? [NSString stringWithCharacters:&c length:1] : @"#";
}

static NSString *const kWQFavorites = @"WQFavorites";

static NSArray<NSDictionary *> *wq_favorites(void)
{
    return [NSUserDefaults.standardUserDefaults arrayForKey:kWQFavorites] ?: @[];
}

static NSUInteger wq_favorite_index(NSArray<NSDictionary *> *favorites, NSString *path)
{
    return [favorites indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger __unused index, BOOL *__unused stop) {
        return [entry[@"path"] isEqualToString:path];
    }];
}

static void wq_set_favorite(NSString *path, NSString *title, BOOL readOnly, BOOL add)
{
    NSMutableArray *favorites = [wq_favorites() mutableCopy];
    NSUInteger index = wq_favorite_index(favorites, path);
    if (add && index == NSNotFound)
        [favorites addObject:@{@"path": path, @"title": title ?: path, @"readOnly": @(readOnly)}];
    else if (!add && index != NSNotFound)
        [favorites removeObjectAtIndex:index];
    [NSUserDefaults.standardUserDefaults setObject:favorites forKey:kWQFavorites];
}

// Items picked with Move, waiting for "Move Here" in another folder, with the
// identity (device, inode, type) each had when picked, or NSNull if unknown.
static NSArray<NSString *> *gWQMovePaths;
static NSArray *gWQMoveIdentities;
static BOOL gWQCopyPending;
static NSString *const kWQMoveChanged = @"WQMoveChanged";

static void wq_set_move_paths(NSArray<NSString *> *paths, NSArray *identities, BOOL copying)
{
    gWQCopyPending = paths.count > 0 && copying;
    gWQMovePaths = paths.count ? [paths copy] : nil;
    gWQMoveIdentities = paths.count && identities.count == paths.count ? [identities copy] : nil;
    [NSNotificationCenter.defaultCenter postNotificationName:kWQMoveChanged object:nil];
}

static NSDictionary<NSString *, NSNumber *> *wq_identity_at(NSArray *identities, NSUInteger index)
{
    id identity = index < identities.count ? identities[index] : nil;
    return [identity isKindOfClass:NSDictionary.class] ? identity : nil;
}

// ZIP reading and writing through WQAccess, so other apps' files work too.
static WQArchiveIO *wq_app_archive_io(void)
{
    WQArchiveIO *io = [WQArchiveIO new];
    io.stat = ^BOOL(NSString *path, struct stat *st) { return wq_stat(path, st); };
    io.list = ^NSArray<NSString *> *(NSString *dir) { return wq_list(dir, NULL); };
    io.openRead = ^int(NSString *path) { return wq_open_for_reading(path); };
    return io;
}

static NSString *wq_temp_work_dir(NSString *prefix)
{
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@-%@", prefix, NSUUID.UUID.UUIDString]];
    return [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil] ? dir : nil;
}

// Get Info: what WQ Files knows about one item. Sizes of folders, item
// counts and a file's SHA-256 are worked out in the background; leaving the
// screen stops that work.
@interface WQInfoViewController : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation WQInfoViewController {
    NSString *_path;
    NSMutableArray<NSArray<NSString *> *> *_rows;   // @[title, value]
    WQScanCancellation *_cancellation;
}

- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _path = [path copy];
        _rows = [NSMutableArray new];
        self.title = WQVerbatim(path.lastPathComponent);
    }
    return self;
}

static NSString *wq_info_mode_text(mode_t mode)
{
    char text[11] = "----------";
    text[0] = S_ISDIR(mode) ? 'd' : S_ISLNK(mode) ? 'l' : S_ISREG(mode) ? '-' : '?';
    const char *bits = "rwxrwxrwx";
    for (int i = 0; i < 9; i++) if (mode & (1 << (8 - i))) text[i + 1] = bits[i];
    return [NSString stringWithFormat:@"%s (%03o)", text, mode & 0777];
}

static NSString *wq_info_date(struct timespec ts)
{
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)ts.tv_sec + ts.tv_nsec / 1e9];
    return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterMediumStyle];
}

- (void)setValue:(NSString *)value forRow:(NSString *)title
{
    for (NSUInteger i = 0; i < _rows.count; i++)
        if ([_rows[i][0] isEqualToString:title]) { _rows[i] = @[title, value]; [self.tableView reloadData]; return; }
    [_rows addObject:@[title, value]];
    [self.tableView reloadData];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    NSString *path = _path;
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _cancellation = cancellation;
    __weak typeof(self) weakSelf = self;
    [self setValue:WQVerbatim(path) forRow:WQLocalized(@"Path")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct stat st;
        BOOL found = wq_stat(path, &st);
        void (^show)(NSString *, NSString *) = ^(NSString *title, NSString *value) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf setValue:value forRow:title]; });
        };
        if (!found) { show(WQLocalized(@"Kind"), WQLocalized(@"Not found")); return; }
        NSString *kind = S_ISDIR(st.st_mode) ? WQLocalized(@"Folder") : S_ISREG(st.st_mode) ? WQLocalized(@"File")
                       : S_ISLNK(st.st_mode) ? WQLocalized(@"Symbolic link") : WQLocalized(@"Special file");
        show(WQLocalized(@"Kind"), kind);
        if (S_ISREG(st.st_mode)) show(WQLocalized(@"Size"), WQVerbatim([NSString stringWithFormat:@"%@ (%lld bytes)",
                                                                         wq_size_text((unsigned long long)st.st_size), (long long)st.st_size]));
        if (S_ISDIR(st.st_mode)) show(WQLocalized(@"Size"), WQLocalized(@"Calculating…"));
        show(WQLocalized(@"Created"), WQVerbatim(wq_info_date(st.st_birthtimespec)));
        show(WQLocalized(@"Modified"), WQVerbatim(wq_info_date(st.st_mtimespec)));
        show(WQLocalized(@"Owner"), WQVerbatim([NSString stringWithFormat:@"uid %u, gid %u", st.st_uid, st.st_gid]));
        show(WQLocalized(@"Permissions"), WQVerbatim(wq_info_mode_text(st.st_mode)));
        show(WQLocalized(@"Inode"), WQVerbatim([NSString stringWithFormat:@"%llu (device %d)", (unsigned long long)st.st_ino, st.st_dev]));
        if (S_ISLNK(st.st_mode)) {
            char target[PATH_MAX];
            ssize_t n = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
            if (n >= 0) { target[n] = 0; show(WQLocalized(@"Points to"), WQVerbatim(@(target) ?: @"?")); }
        }
        if (S_ISDIR(st.st_mode)) {
            WQTreeCount count = wq_tree_count(path, 1000000);
            if (cancellation.isCancelled) return;
            unsigned long long bytes = 0;
            WQMeasureResult measured = wq_measure_tree(path, cancellation, &bytes);
            if (measured == WQMeasureResultCancelled) return;
            NSString *size = wq_size_text(bytes);
            if (measured != WQMeasureResultKnown || count.state != WQTreeCountExact)
                size = WQLocalizedFormat(@"at least %@ (some items couldn't be read)", size);
            show(WQLocalized(@"Size"), WQVerbatim(size));
            show(WQLocalized(@"Files"), WQVerbatim([NSString stringWithFormat:@"%lu%@", (unsigned long)(count.regular + count.other),
                                                   count.state == WQTreeCountLimited ? @"+" : @""]));
        }
        if (S_ISREG(st.st_mode)) {
            show(@"SHA-256", WQLocalized(@"Calculating…"));
            int fd = wq_open_for_reading(path);
            if (fd < 0) { show(@"SHA-256", WQLocalized(@"The file could not be read.")); return; }
            CC_SHA256_CTX ctx;
            CC_SHA256_Init(&ctx);
            uint8_t buffer[256 * 1024];
            BOOL ok = YES;
            for (;;) {
                if (cancellation.isCancelled) { ok = NO; break; }
                ssize_t n = read(fd, buffer, sizeof(buffer));
                if (n < 0 && errno == EINTR) continue;
                if (n < 0) { ok = NO; break; }
                if (n == 0) break;
                CC_SHA256_Update(&ctx, buffer, (CC_LONG)n);
            }
            close(fd);
            if (cancellation.isCancelled) return;
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256_Final(digest, &ctx);
            NSMutableString *hex = [NSMutableString new];
            for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
            show(@"SHA-256", ok ? WQVerbatim(hex) : WQLocalized(@"The file could not be read."));
        }
    });
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController || !self.navigationController) [_cancellation cancel];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_rows.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return WQLocalized(@"Tap a row to copy its value.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"info"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"info"];
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.prefersSideBySideTextAndSecondaryText = NO;
    c.text = _rows[(NSUInteger)indexPath.row][0];
    c.secondaryText = _rows[(NSUInteger)indexPath.row][1];
    c.secondaryTextProperties.numberOfLines = 0;
    c.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIPasteboard.generalPasteboard.string = _rows[(NSUInteger)indexPath.row][1];
}

@end

@interface WQFolderSearchViewController : UITableViewController
// `query` nil: the largest files under `path` instead of matching names.
- (instancetype)initWithPath:(NSString *)path query:(nullable NSString *)query readOnly:(BOOL)readOnly;
@end

@implementation WQFolderSearchViewController {
    NSString *_root, *_query, *_status;
    BOOL _readOnly;
    NSArray<WQItem *> *_matches;
    WQScanCancellation *_cancellation;
}

- (instancetype)initWithPath:(NSString *)path query:(NSString *)query readOnly:(BOOL)readOnly
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _root = [path copy];
        _query = [query copy];
        _readOnly = readOnly;
        self.title = query ?: WQLocalized(@"Largest Files");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    _status = WQLocalized(@"Searching…");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalized(@"Stop")
        style:UIBarButtonItemStylePlain target:self action:@selector(stopSearch)];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _cancellation = cancellation;
    NSString *root = _root, *query = _query;
    __weak typeof(self) weakSelf = self;
    // Its own queue: a long walk must not hold up file loads and saves on wq_io.
    static dispatch_queue_t searchQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ searchQueue = dispatch_queue_create("wqfiles.folder-search", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(searchQueue, ^{
        CFAbsoluteTime lastProgress = 0;
        NSMutableArray<NSString *> *pending = [NSMutableArray arrayWithObject:root];
        NSMutableArray<WQItem *> *matches = [NSMutableArray new];
        NSUInteger visited = 0;
        BOOL unreadable = NO, limited = NO;
        // Largest files: every regular file is a candidate; the top 100 are kept.
        BOOL largest = query == nil;
        const NSUInteger entryLimit = largest ? 300000 : 100000, matchLimit = largest ? NSUIntegerMax : 1000, largestShown = 100;
        while (pending.count && !cancellation.isCancelled && !limited) {
            @autoreleasepool {
                NSString *folder = pending.lastObject;
                [pending removeLastObject];
                struct stat parent;
                if (!wq_stat(folder, &parent) || !S_ISDIR(parent.st_mode)) {
                    unreadable = YES;
                    continue;
                }
                NSArray<NSString *> *names = wq_list(folder, NULL);
                if (!names) unreadable = YES;
                for (NSString *name in names) {
                    if (cancellation.isCancelled) break;
                    if (visited++ >= entryLimit || matches.count >= matchLimit) { limited = YES; break; }
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (now - lastProgress > 0.3) {
                        lastProgress = now;
                        NSString *text = largest
                            ? WQLocalizedFormat(@"Measuring… %lu items checked", (unsigned long)visited)
                            : WQLocalizedFormat(@"Searching… %lu items checked, %lu found",
                                                (unsigned long)visited, (unsigned long)matches.count);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            WQFolderSearchViewController *screen = weakSelf;
                            if (!screen || !screen->_cancellation) return;
                            screen->_status = text;
                            [screen.tableView reloadData];
                        });
                    }
                    @autoreleasepool {
                        NSString *path = [folder stringByAppendingPathComponent:name];
                        struct stat st;
                        if (!wq_stat(path, &st)) { unreadable = YES; continue; }
                        if (S_ISDIR(st.st_mode)) [pending addObject:path];
                        if (largest ? !S_ISREG(st.st_mode)
                                    : (!(S_ISDIR(st.st_mode) || S_ISREG(st.st_mode)) || ![name localizedStandardContainsString:query])) continue;
                        WQItem *item = [WQItem new];
                        item.path = path;
                        item.name = name;
                        item.isDir = S_ISDIR(st.st_mode);
                        item.isRegular = S_ISREG(st.st_mode);
                        item.size = (unsigned long long)st.st_size;
                        item.identity = wq_identity_for_stat(&st);
                        [matches addObject:item];
                        // Keep memory bounded: trim to the largest few now and then.
                        if (largest && matches.count >= largestShown * 20) {
                            [matches sortUsingComparator:^NSComparisonResult(WQItem *a, WQItem *b) {
                                return a.size == b.size ? NSOrderedSame : (a.size > b.size ? NSOrderedAscending : NSOrderedDescending);
                            }];
                            [matches removeObjectsInRange:NSMakeRange(largestShown, matches.count - largestShown)];
                        }
                    }
                }
            }
        }
        [matches sortUsingComparator:^NSComparisonResult(WQItem *a, WQItem *b) {
            if (largest && a.size != b.size) return a.size > b.size ? NSOrderedAscending : NSOrderedDescending;
            NSComparisonResult order = [a.name localizedStandardCompare:b.name];
            return order == NSOrderedSame ? [a.path localizedStandardCompare:b.path] : order;
        }];
        if (largest && matches.count > largestShown) [matches removeObjectsInRange:NSMakeRange(largestShown, matches.count - largestShown)];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQFolderSearchViewController *screen = weakSelf;
            if (!screen) return;
            screen->_cancellation = nil;
            screen->_matches = matches;
            screen.navigationItem.rightBarButtonItem = nil;
            if (cancellation.isCancelled) screen->_status = WQLocalized(@"Search stopped. Results may be incomplete.");
            else if (limited) screen->_status = largest ? WQLocalized(@"Item limit reached: only part of the folder was measured. Try a smaller folder.")
                                                        : WQLocalized(@"Search limit reached. Try a smaller folder or a more specific name.");
            else if (unreadable) screen->_status = WQLocalized(@"Some items could not be searched.");
            else if (largest) screen->_status = matches.count ? WQLocalizedFormat(@"The %lu largest of %lu items checked.", (unsigned long)matches.count, (unsigned long)visited)
                                                              : WQLocalized(@"No files.");
            else screen->_status = matches.count ? nil : WQLocalized(@"No matching names.");
            [screen.tableView reloadData];
        });
    });
}

- (void)stopSearch
{
    [_cancellation cancel];
    self.navigationItem.rightBarButtonItem.enabled = NO;
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController || !self.navigationController)
        [_cancellation cancel];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)_matches.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return _status;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    WQItem *item = _matches[(NSUInteger)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"match"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"match"];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = item.name;
    NSUInteger prefix = [_root hasSuffix:@"/"] ? _root.length : _root.length + 1;
    NSString *relative = item.path.length > prefix ? [item.path substringFromIndex:prefix] : item.path;
    content.secondaryText = _query ? relative
        : [NSString stringWithFormat:@"%@ · %@", wq_size_text(item.size), relative.stringByDeletingLastPathComponent.length ? relative.stringByDeletingLastPathComponent : @"."];
    content.secondaryTextProperties.numberOfLines = 2;
    content.image = [UIImage systemImageNamed:item.isDir ? @"folder" : @"doc"];
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WQItem *item = _matches[(NSUInteger)indexPath.row];
    dispatch_async(wq_io(), ^{
        BOOL current = [item.identity isEqualToDictionary:wq_item_identity(item.path)];
        dispatch_async(dispatch_get_main_queue(), ^{
            UINavigationController *nav = self.navigationController;
            if (nav.topViewController != self) return;
            if (!current) { wq_alert(self, @"Not found", WQVerbatim(item.path)); return; }
            if (item.isDir) {
                WQDirViewController *folder = [[WQDirViewController alloc] initWithPath:item.path title:item.name];
                folder.readOnly = self->_readOnly;
                [nav pushViewController:folder animated:YES];
            } else {
                wq_open_file(nav, item.path, self->_readOnly, WQOpenAuto);
            }
        });
    });
}

@end

@interface WQDirViewController ()
- (BOOL)wq_wantsToolbar;
@end

@implementation WQDirViewController {
    NSString *_path;
    NSArray<WQItem *> *_all;     // everything in the folder
    NSArray<WQItem *> *_items;   // what the search lets through (shown)
    NSString *_query;
    UILabel *_pathLabel;
    UIView *_headerBox;
    NSString *_scanStatus;
    CGFloat _headerWidth;
    NSString *_error;
    BOOL _labels;
    BOOL _backupManager;
    BOOL _backupStorage;
    BOOL _selectingBackups;
    NSMutableSet<NSString *> *_selectedBackups;
    UIBarButtonItem *_selectItem;
    UIBarButtonItem *_menuItem;
    UIBarButtonItem *_doneItem;
    UIBarButtonItem *_deleteItem;
    UIBarButtonItem *_allItem;
    NSString *_baseTitle;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
    BOOL _scanInFlight;
    BOOL _scanNeedsRefresh;
    NSTimeInterval _lastReloadFinished;
    NSArray<NSString *> *_indexTitles;          // sidebar letters, when sorted by name
    NSDictionary<NSString *, NSNumber *> *_indexRows;   // letter -> first row
    BOOL _selectingFiles;
    BOOL _importingFolder;
    NSMutableOrderedSet<NSString *> *_selectedFiles;
    UIBarButtonItem *_fileSelectItem;
    UIBarButtonItem *_fileDoneItem;
    UIBarButtonItem *_fileAllItem;
}

- (instancetype)initWithPath:(NSString *)path title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = [path copy];
        self.title = title ?: (path.lastPathComponent.length ? path.lastPathComponent : @"/");
        _baseTitle = self.title;
        _selectedBackups = [NSMutableSet new];
        _selectedFiles = [NSMutableOrderedSet new];
        // Container parents: show bundle/group identifiers instead of UUIDs.
        NSString *parent = path.lastPathComponent;
        _labels = [@[@"Application", @"AppGroup", @"PluginKitPlugin", @"InternalDaemon", @"System"] containsObject:parent];
        NSString *appBackups = wq_app_backup_root();
        NSString *fileBackups = wq_backup_root();
        _backupManager = appBackups.length &&
            ([_path isEqualToString:appBackups] || [_path hasPrefix:[appBackups stringByAppendingString:@"/"]]);
        _backupStorage = _backupManager ||
            (fileBackups.length && ([_path isEqualToString:fileBackups] || [_path hasPrefix:[fileBackups stringByAppendingString:@"/"]]));
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.hidesBottomBarWhenPushed = YES;
    wq_prism_install_background(self);
    self.tableView.backgroundColor = [UIColor clearColor];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    __weak typeof(self) weakSelf = self;
    NSString *path = _path;
    NSMutableArray<UIMenuElement *> *menuItems = [NSMutableArray new];
    if (!self.readOnly && !_backupStorage) {
        [menuItems addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"New Folder") image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf promptNewFolder]; }]];
        [menuItems addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Import Files") image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf importFile]; }]];
        [menuItems addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Import Folder") image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf importFolder]; }]];
    }
    [menuItems addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Copy Path") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                          handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = path; }]];
    [menuItems addObject:[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        WQDirViewController *folder = weakSelf;
        if (!folder) { completion(@[]); return; }
        NSString *favoritePath = WQCanonicalVarPath(path);
        BOOL saved = wq_favorite_index(wq_favorites(), favoritePath) != NSNotFound;
        UIAction *favorite = [UIAction actionWithTitle:WQLocalized(saved ? @"Remove from Favorites" : @"Add to Favorites")
                                                image:[UIImage systemImageNamed:saved ? @"star.slash" : @"star"] identifier:nil
                                              handler:^(UIAction *__unused action) {
            WQDirViewController *current = weakSelf;
            if (current) wq_set_favorite(favoritePath, current->_baseTitle, current.readOnly, !saved);
        }];
        completion(@[favorite]);
    }]];
    if (!_labels) {
        [menuItems addObject:[UIAction actionWithTitle:WQLocalized(@"Search Inside Folders…") image:[UIImage systemImageNamed:@"magnifyingglass"]
                                          identifier:nil handler:^(UIAction *__unused action) { [weakSelf promptFolderSearch]; }]];
        [menuItems addObject:[UIAction actionWithTitle:WQLocalized(@"Largest Files") image:[UIImage systemImageNamed:@"chart.bar.doc.horizontal"]
                                          identifier:nil handler:^(UIAction *__unused action) {
            WQDirViewController *folder = weakSelf;
            if (!folder) return;
            WQFolderSearchViewController *largest = [[WQFolderSearchViewController alloc] initWithPath:folder->_path query:nil
                readOnly:folder.readOnly || folder->_backupStorage];
            [folder.navigationController pushViewController:largest animated:YES];
        }]];
    }
    // Built when the menu opens, so the checkmarks show the current order.
    [menuItems addObject:[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        WQSortKey current = wq_sort_key();
        BOOL ascending = wq_sort_ascending();
        NSMutableArray *sortActions = [NSMutableArray new];
        NSArray *titles = @[@"Name", @"Date Modified", @"Date Created", @"Size"];
        for (NSInteger key = WQSortName; key <= WQSortSize; key++) {
            UIAction *action = [UIAction actionWithTitle:WQLocalizedNullable(titles[(NSUInteger)key]) image:nil identifier:nil handler:^(UIAction *__unused a) {
                wq_choose_sort((WQSortKey)key);
                [weakSelf resortAfterChange];
            }];
            if (key == current) {
                action.state = UIMenuElementStateOn;
                action.subtitle = wq_sort_direction_text((WQSortKey)key, ascending);
            }
            [sortActions addObject:action];
        }
        UIAction *folders = [UIAction actionWithTitle:WQLocalizedNullable(@"Folders on Top") image:nil identifier:nil handler:^(UIAction *__unused a) {
            [NSUserDefaults.standardUserDefaults setBool:!wq_folders_first() forKey:kWQFoldersFirstPref];
            [weakSelf resortAfterChange];
        }];
        folders.state = wq_folders_first() ? UIMenuElementStateOn : UIMenuElementStateOff;
        UIMenu *order = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[folders]];
        UIMenu *sort = [UIMenu menuWithTitle:WQLocalizedNullable(@"Sort By") image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:0
                                    children:[sortActions arrayByAddingObject:order]];
        sort.subtitle = WQLocalizedFormat(@"%@, %@", WQLocalizedNullable(titles[(NSUInteger)current]), wq_sort_direction_text(current, ascending));
        WQDirViewController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_labels) { completion(@[sort]); return; }
        // Container lists filter like Apps (issue #44).
        NSInteger shown = strongSelf.containerFilter;
        NSArray *filterTitles = @[@"All", @"Apple", @"Other", @"Backed Up"];
        NSMutableArray *filters = [NSMutableArray new];
        for (NSInteger i = 0; i < (NSInteger)filterTitles.count; i++) {
            if (i == 3 && !strongSelf.offersBackedUpFilter) continue;
            UIAction *f = [UIAction actionWithTitle:WQLocalizedNullable(filterTitles[(NSUInteger)i]) image:nil identifier:nil handler:^(UIAction *__unused a) {
                [NSUserDefaults.standardUserDefaults setInteger:i forKey:kWQContainerFilterPref];
                [weakSelf resortAfterChange];
            }];
            f.state = i == shown ? UIMenuElementStateOn : UIMenuElementStateOff;
            [filters addObject:f];
        }
        UIMenu *show = [UIMenu menuWithTitle:WQLocalizedNullable(@"Show") image:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
                                  identifier:nil options:0 children:filters];
        show.subtitle = WQLocalizedNullable(filterTitles[(NSUInteger)shown]);
        completion(@[sort, show]);
    }]];
    _menuItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                 menu:[UIMenu menuWithChildren:menuItems]];
    if (_backupStorage) {
        _selectItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Select") style:UIBarButtonItemStylePlain
                                                       target:self action:@selector(enterBackupSelection)];
        _selectItem.enabled = NO;
    } else if ([self canEditHere]) {
        _fileSelectItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Select") style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(enterFileSelection)];
    }
    [self restoreRightItems];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateToolbar)
                                               name:kWQMoveChanged object:nil];
    [self updateToolbar];
    [self updateHeader];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = _labels ? WQLocalized(@"Search names and bundle IDs") : WQLocalized(@"Search this folder");
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self reload];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    // The folder in front is the one to reopen at the next launch.
    if (![NSUserDefaults.standardUserDefaults boolForKey:kWQReopenOffPref])
        [NSUserDefaults.standardUserDefaults setObject:@{ @"path": _path, @"title": _baseTitle ?: _path.lastPathComponent,
                                                           @"readOnly": @(self.readOnly) } forKey:kWQLastFolderPref];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.tabBarController.tabBar.hidden = YES;
    [self updateToolbar];
    if (_scanInFlight) return;
    NSTimeInterval age = NSDate.date.timeIntervalSinceReferenceDate - _lastReloadFinished;
    if (_scanNeedsRefresh || _lastReloadFinished <= 0 || age > 2.0) [self reload];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController) self.tabBarController.tabBar.hidden = NO;
    if (_selectingBackups) [self exitBackupSelection];
    if (_selectingFiles) [self exitFileSelection];
    if (_scanInFlight) {
        _scanNeedsRefresh = YES;
        [_scanCancellation cancel];
    }
    _scanStatus = nil;
    [self.refreshControl endRefreshing];
    [self updateHeader];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (!self.presentedViewController && self.navigationController.topViewController != self) {
        wq_share_cancel(self);
    }
}

// Device strip, then the full path in normal-size text that wraps at the
// slashes (the navigation bar's prompt shrank it until unreadable). Tap to copy.
- (void)updateHeader
{
    CGFloat width = self.tableView.bounds.size.width ?: self.view.bounds.size.width;
    if (!_pathLabel) {
        _pathLabel = [UILabel new];
        _pathLabel.numberOfLines = 2;
        _pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _pathLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        _pathLabel.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
        _pathLabel.textAlignment = NSTextAlignmentLeft;   // paths read left to right in every language
        _pathLabel.textColor = UIColor.secondaryLabelColor;
        _pathLabel.userInteractionEnabled = YES;
        [_pathLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyPath)]];
    }
    if (!_headerBox) {
        _headerBox = wq_device_header(width);
        [_headerBox addSubview:_pathLabel];
        self.tableView.tableHeaderView = _headerBox;
    }
    // Zero-width spaces after each slash let lines break between components.
    NSString *breakable = [_path stringByReplacingOccurrencesOfString:@"/" withString:@"/\u200B"];
    _pathLabel.text = _scanStatus ? [NSString stringWithFormat:@"%@\n%@", breakable, _scanStatus] : breakable;
    CGFloat side = 16, top = kWQDeviceStripHeight + 8;
    CGSize fit = [_pathLabel sizeThatFits:CGSizeMake(width - 2 * side, CGFLOAT_MAX)];
    CGFloat height = top + ceil(fit.height) + 10;
    CGFloat oldHeight = _headerBox.frame.size.height;
    _headerBox.frame = CGRectMake(0, 0, width, height);
    _pathLabel.frame = CGRectMake(side, top, width - 2 * side, ceil(fit.height));
    _headerWidth = width;
    if (fabs(height - oldHeight) > 0.5) self.tableView.tableHeaderView = _headerBox;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (fabs(self.tableView.bounds.size.width - _headerWidth) > 0.5) [self updateHeader];
}

- (void)promptFolderSearch
{
    UIAlertController *alert = wq_alert_controller(@"Search Inside Folders…", nil, UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = WQLocalized(@"Name");
        field.text = self.navigationItem.searchController.searchBar.text;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.returnKeyType = UIReturnKeySearch;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Search", UIAlertActionStyleDefault, ^(UIAlertAction *__unused action) {
        NSString *query = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!query.length) return;
        WQFolderSearchViewController *results = [[WQFolderSearchViewController alloc] initWithPath:self->_path
            query:query readOnly:self.readOnly || self->_backupStorage];
        [self.navigationController pushViewController:results animated:YES];
    })];
    alert.preferredAction = alert.actions.lastObject;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyPath
{
    UIPasteboard.generalPasteboard.string = _path;
    _scanStatus = WQLocalized(@"Path copied");
    [self updateHeader];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self->_scanStatus isEqualToString:WQLocalized(@"Path copied")]) { self->_scanStatus = nil; [self updateHeader]; }
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    _query = q.length ? q : nil;
    [self applyFilter];
    [self.tableView reloadData];
}

// App name, bundle or group ID, or file name; case and accents ignored.
- (BOOL)offersBackedUpFilter { return [_path.lastPathComponent isEqualToString:@"Application"]; }

- (NSInteger)containerFilter
{
    if (!_labels) return 0;
    NSInteger filter = [NSUserDefaults.standardUserDefaults integerForKey:kWQContainerFilterPref];
    if (filter < 0 || filter > 3 || (filter == 3 && !self.offersBackedUpFilter)) return 0;
    return filter;
}

- (void)applyFilter
{
    NSArray<WQItem *> *shown = _all ?: @[];
    NSInteger filter = self.containerFilter;
    if (filter) {
        NSSet *backedUp = nil;
        if (filter == 3) {
            NSMutableSet *ids = [NSMutableSet new];
            NSString *root = wq_app_backup_root();
            for (NSString *bid in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
                if ([bid hasPrefix:@"."]) continue;
                NSArray *units = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:bid] error:nil];
                for (NSString *u in units) if (![u hasPrefix:@"."]) { [ids addObject:bid]; break; }
            }
            backedUp = ids;
        }
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQItem *item, NSDictionary *__unused b) {
            NSString *identifier = item.bundleID ?: item.label ?: @"";
            if (filter == 1) return wq_id_is_apple(identifier);
            if (filter == 2) return !wq_id_is_apple(identifier);
            return [backedUp containsObject:identifier];
        }]];
    }
    if (_query) {
        NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
        NSString *q = _query;
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQItem *item, NSDictionary *__unused b) {
            for (NSString *field in @[item.label ?: @"", item.name ?: @"", item.bundleID ?: @""])
                if ([field rangeOfString:q options:opts].location != NSNotFound) return YES;
            return NO;
        }]];
    }
    _items = wq_sorted_items(shown);
    // Alphabet sidebar: only for longer lists sorted by name.
    NSMutableArray *titles = [NSMutableArray new];
    NSMutableDictionary *rows = [NSMutableDictionary new];
    if (wq_sort_key() == WQSortName && _items.count >= 25) {
        [_items enumerateObjectsUsingBlock:^(WQItem *item, NSUInteger row, BOOL *__unused stop) {
            NSString *letter = wq_index_letter(item.label ?: item.name);
            if (!rows[letter]) { rows[letter] = @(row); [titles addObject:letter]; }
        }];
    }
    _indexTitles = titles.count > 1 ? titles : nil;
    _indexRows = rows;
    // A filled menu button shows that a Show filter hides some containers.
    _menuItem.image = [UIImage systemImageNamed:filter ? @"ellipsis.circle.fill" : @"ellipsis.circle"];
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    return _selectingBackups || _selectingFiles || _error ? nil : _indexTitles;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index
{
    NSNumber *row = _indexRows[title];
    if (row && row.unsignedIntegerValue < _items.count)
        [tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row.integerValue inSection:0]
                         atScrollPosition:UITableViewScrollPositionTop animated:NO];
    return -1;   // already scrolled to the row; the list has one section
}

- (void)resortAfterChange
{
    [self applyFilter];
    [self.tableView reloadData];
    [self.tableView reloadSectionIndexTitles];
}

#pragma mark Backup multi-selection

- (NSArray<NSString *> *)backupUnitPathsInItems
{
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    for (WQItem *item in _items)
        if (wq_backup_unit_deletable(item.path)) [paths addObject:item.path];
    return paths;
}

- (void)updateBackupSelectionAvailability
{
    _selectItem.enabled = !_selectingBackups && [self backupUnitPathsInItems].count > 0;
}

- (void)updateBackupSelectionBar
{
    _deleteItem.enabled = _selectedBackups.count > 0;
    _allItem.enabled = _selectedBackups.count < [self backupUnitPathsInItems].count;
}

- (void)enterBackupSelection
{
    if ([self backupUnitPathsInItems].count == 0) {
        wq_alert(self, @"Nothing to select", @"Only complete backup folders can be selected here.");
        return;
    }
    _selectingBackups = YES;
    [_selectedBackups removeAllObjects];
    if (!_doneItem) {
        _doneItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Done") style:UIBarButtonItemStyleProminent
                                                       target:self action:@selector(exitBackupSelection)];
        _deleteItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Delete") style:UIBarButtonItemStylePlain
                                                       target:self action:@selector(deleteSelectedBackups)];
        _deleteItem.tintColor = UIColor.systemRedColor;
        _allItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle"]
                                                     style:UIBarButtonItemStylePlain
                                                    target:self action:@selector(selectAllBackups)];
        _allItem.accessibilityLabel = WQLocalizedNullable(@"Select All");
    }
    self.refreshControl.enabled = NO;
    self.tableView.allowsMultipleSelection = YES;
    self.title = WQLocalizedNullable(@"Select Backups");
    self.navigationItem.rightBarButtonItems = @[_allItem, _deleteItem, _doneItem];
    [self updateBackupSelectionBar];
    [self.tableView reloadData];
}

- (void)exitBackupSelection
{
    if (!_selectingBackups) return;
    _selectingBackups = NO;
    [_selectedBackups removeAllObjects];
    self.tableView.allowsMultipleSelection = NO;
    self.refreshControl.enabled = YES;
    self.title = _baseTitle;
    [self restoreRightItems];
    [self.tableView reloadData];
    [self updateBackupSelectionAvailability];
}

- (void)selectAllBackups
{
    NSArray<NSString *> *paths = [self backupUnitPathsInItems];
    [_selectedBackups addObjectsFromArray:paths];
    [self updateBackupSelectionBar];
    [self.tableView reloadData];
}

- (void)deleteSelectedBackups
{
    if (wq_refuse_if_deleting_off(self)) return;
    NSArray<NSString *> *paths = [_selectedBackups.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (paths.count == 0) return;
    NSString *message = paths.count == 1
        ? WQLocalizedFormat(@"This permanently removes %lu complete backup and everything inside it. It cannot be undone.",
                            (unsigned long)paths.count)
        : WQLocalizedFormat(@"This permanently removes %lu complete backups and everything inside them. It cannot be undone.",
                            (unsigned long)paths.count);
    UIAlertController *alert = wq_alert_controller(@"Delete backups?", message, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Delete", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self exitBackupSelection];
        [self runIO:^BOOL(NSString **error) {
            NSString *first = nil;
            for (NSString *path in paths) {
                NSString *failure = nil;
                if (!wq_delete_backup(path, &failure) && first == nil)
                    first = failure ?: @"Could not remove a backup.";
            }
            if (first) {
                if (error) *error = [NSString stringWithFormat:@"%@ Some selected backups may still exist.", first];
                return NO;
            }
            return YES;
        } failure:WQLocalizedNullable(@"Cannot delete backups")];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark File selection, Move, Compress, Extract

// Ordinary folders where files may be created, moved and deleted: not
// read-only areas, not backup storage, not the container lists themselves.
- (BOOL)canEditHere
{
    return !self.readOnly && !_backupStorage && !_labels;
}

- (void)restoreRightItems
{
    if (_backupStorage && _selectItem) self.navigationItem.rightBarButtonItems = @[_selectItem, _menuItem];
    else if (_fileSelectItem) self.navigationItem.rightBarButtonItems = @[_fileSelectItem, _menuItem];
    else self.navigationItem.rightBarButtonItems = @[_menuItem];
}

- (BOOL)wq_wantsToolbar
{
    return _selectingFiles || gWQMovePaths.count > 0;
}

- (BOOL)canMoveHere
{
    if (![self canEditHere] || _error || !gWQMovePaths.count) return NO;
    NSString *destination = WQCanonicalVarPath(_path);
    for (NSString *path in gWQMovePaths) {
        NSString *source = WQCanonicalVarPath(path);
        if ([source.stringByDeletingLastPathComponent isEqualToString:destination]) return NO;
        if ([destination isEqualToString:source] || [destination hasPrefix:[source stringByAppendingString:@"/"]]) return NO;
    }
    return YES;
}

- (void)updateToolbar
{
    _fileSelectItem.enabled = !_error && _all.count > 0;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    if (_selectingFiles) {
        BOOL any = _selectedFiles.count > 0;
        UIBarButtonItem *move = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Move") style:UIBarButtonItemStylePlain
                                                                target:self action:@selector(moveSelectedFiles)];
        UIBarButtonItem *zip = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Compress") style:UIBarButtonItemStylePlain
                                                               target:self action:@selector(compressSelectedFiles)];
        UIBarButtonItem *del = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Delete") style:UIBarButtonItemStylePlain
                                                               target:self action:@selector(deleteSelectedFiles)];
        del.tintColor = UIColor.systemRedColor;
        UIBarButtonItem *rename = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Rename") style:UIBarButtonItemStylePlain
                                                                  target:self action:@selector(renameSelectedFile)];
        move.enabled = zip.enabled = del.enabled = any;
        rename.enabled = _selectedFiles.count == 1;   // issue #41
        self.toolbarItems = wq_deleting_allowed() ? @[move, flex, rename, flex, zip, flex, del] : @[move, flex, rename, flex, zip];
    } else if (gWQMovePaths.count) {
        UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Cancel") style:UIBarButtonItemStylePlain
                                                                  target:self action:@selector(cancelMove)];
        UILabel *label = [UILabel new];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        label.textColor = UIColor.secondaryLabelColor;
        label.text = gWQCopyPending ? WQLocalized(@"Copy to Folder…") : gWQMovePaths.count == 1
            ? WQLocalizedFormat(@"Moving “%@”", gWQMovePaths.firstObject.lastPathComponent)
            : WQLocalizedFormat(@"Moving %lu items", (unsigned long)gWQMovePaths.count);
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [label sizeToFit];
        CGRect frame = label.frame;
        frame.size.width = MIN(frame.size.width, 180);
        label.frame = frame;
        UIBarButtonItem *info = [[UIBarButtonItem alloc] initWithCustomView:label];
        UIBarButtonItem *here = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(gWQCopyPending ? @"Copy Here" : @"Move Here") style:UIBarButtonItemStyleProminent
                                                                target:self action:gWQCopyPending ? @selector(copyHere) : @selector(moveHere)];
        here.enabled = [self canMoveHere];
        self.toolbarItems = @[cancel, flex, info, flex, here];
    } else {
        self.toolbarItems = nil;
    }
    if (self.navigationController.topViewController == self)
        [self.navigationController setToolbarHidden:![self wq_wantsToolbar] animated:YES];
}

- (void)updateFileSelectionTitle
{
    self.title = _selectedFiles.count
        ? WQLocalizedFormat(@"%lu Selected", (unsigned long)_selectedFiles.count) : WQLocalized(@"Select Items");
    _fileAllItem.enabled = _selectedFiles.count < _items.count;
    [self updateToolbar];
}

- (void)enterFileSelection
{
    if (_error || _items.count == 0) return;
    _selectingFiles = YES;
    [_selectedFiles removeAllObjects];
    if (!_fileDoneItem) {
        _fileDoneItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Done") style:UIBarButtonItemStyleProminent
                                                        target:self action:@selector(exitFileSelection)];
        _fileAllItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle"]
                                                         style:UIBarButtonItemStylePlain
                                                        target:self action:@selector(selectAllFiles)];
        _fileAllItem.accessibilityLabel = WQLocalizedNullable(@"Select All");
    }
    self.refreshControl.enabled = NO;
    self.navigationItem.rightBarButtonItems = @[_fileDoneItem, _fileAllItem];
    [self updateFileSelectionTitle];
    [self.tableView reloadData];
    [self.tableView reloadSectionIndexTitles];
}

- (void)exitFileSelection
{
    if (!_selectingFiles) return;
    _selectingFiles = NO;
    [_selectedFiles removeAllObjects];
    self.refreshControl.enabled = YES;
    self.title = _baseTitle;
    [self restoreRightItems];
    [self updateToolbar];
    [self.tableView reloadData];
    [self.tableView reloadSectionIndexTitles];
}

- (void)selectAllFiles
{
    for (WQItem *item in _items) [_selectedFiles addObject:item.path];
    [self updateFileSelectionTitle];
    [self.tableView reloadData];
}

- (NSArray<NSString *> *)selectedFilePaths
{
    return _selectedFiles.array.copy;
}

// The identity each path had when it was listed (NSNull when unknown), so a
// later delete or move acts only on the selected objects.
- (NSArray *)identitiesForPaths:(NSArray<NSString *> *)paths
{
    NSMutableDictionary<NSString *, NSDictionary *> *listed = [NSMutableDictionary new];
    for (WQItem *item in _all) if (item.identity) listed[item.path] = item.identity;
    NSMutableArray *identities = [NSMutableArray new];
    for (NSString *path in paths) [identities addObject:listed[path] ?: wq_item_identity(path) ?: (id)NSNull.null];
    return identities;
}

- (void)moveSelectedFiles
{
    NSArray<NSString *> *paths = [self selectedFilePaths];
    if (!paths.count) return;
    NSArray *identities = [self identitiesForPaths:paths];
    [self exitFileSelection];
    [self startMove:paths identities:identities];
}

- (void)startMove:(NSArray<NSString *> *)paths identities:(NSArray *)identities
{
    wq_set_move_paths(paths, identities, NO);
    wq_alert(self, paths.count == 1 ? WQLocalized(@"Move") : WQLocalizedFormat(@"Move %lu items", (unsigned long)paths.count),
             @"Open the folder you want to move to, then tap Move Here at the bottom. Any app's folder works.");
}

- (void)startCopy:(WQItem *)item
{
    if (!item.identity || item.isLink || !(item.isRegular || item.isDir)) return;
    wq_set_move_paths(@[item.path], @[item.identity], YES);
    wq_alert(self, @"Copy to Folder…", @"Open the destination folder, then tap Copy Here.");
}

- (void)copyHere
{
    if (!gWQCopyPending || ![self canMoveHere]) return;
    NSString *source = gWQMovePaths.firstObject;
    NSDictionary *identity = wq_identity_at(gWQMoveIdentities, 0);
    NSString *folder = _path;
    wq_set_move_paths(nil, nil, NO);
    [self runBusy:WQLocalized(@"Copy") failure:WQLocalized(@"Copying failed.")
             work:^BOOL(NSString **error, NSString **__unused note) {
        struct stat st;
        if (!identity || !wq_stat(source, &st) || ![identity isEqualToDictionary:wq_identity_for_stat(&st)]) {
            *error = WQLocalized(@"The item was moved, replaced or changed after it was selected. It was left as it is.");
            return NO;
        }
        // A same-named item there is kept; the copy gets "Name 2".
        NSString *name = wq_free_name_in(folder, source.lastPathComponent, [NSMutableSet new]);
        if (!name) { *error = WQLocalized(@"No free name in this folder"); return NO; }
        NSString *destination = [folder stringByAppendingPathComponent:name];
        return S_ISDIR(st.st_mode) ? wq_copy_tree_new(source, destination, nil, error)
                                  : wq_create_file_from(destination, source, error);
    }];
}

- (void)cancelMove
{
    wq_set_move_paths(nil, nil, NO);
}

- (void)moveHere
{
    NSArray<NSString *> *paths = gWQMovePaths;
    NSArray *identities = gWQMoveIdentities;
    if (![self canMoveHere]) return;
    NSString *dest = _path;
    wq_set_move_paths(nil, nil, NO);
    [self runIO:^BOOL(NSString **error) {
        NSUInteger failed = 0;
        NSString *first = nil;
        for (NSUInteger i = 0; i < paths.count; i++) {
            NSString *path = paths[i];
            NSString *e = nil;
            if (!wq_move_expecting(path, dest, wq_identity_at(identities, i), &e)) {
                failed++;
                if (!first) first = [NSString stringWithFormat:@"%@: %@", path.lastPathComponent, e ?: @"failed"];
            }
        }
        if (failed && error) {
            *error = paths.count == 1 ? first
                : WQLocalizedFormat(@"Items not moved: %lu of %lu.\n\n%@", (unsigned long)failed, (unsigned long)paths.count, first);
        }
        return failed == 0;
    } failure:WQLocalizedNullable(@"Cannot move")];
}

- (void)deleteSelectedFiles
{
    if (wq_refuse_if_deleting_off(self)) return;
    NSArray<NSString *> *paths = [self selectedFilePaths];
    if (!paths.count) return;
    NSArray *identities = [self identitiesForPaths:paths];
    BOOL folders = NO, special = NO;
    for (NSString *path in paths) {
        struct stat st;
        BOOL known = lstat(path.fileSystemRepresentation, &st) == 0 || wq_stat(path, &st);
        if (known && S_ISDIR(st.st_mode)) folders = YES;
        else if (known && !S_ISREG(st.st_mode)) special = YES;
    }
    if (folders) { [self exitFileSelection]; [self confirmDeleteFolders:paths identities:identities]; return; }
    NSString *title = paths.count == 1 ? WQLocalizedFormat(@"Delete “%@”?", paths.firstObject.lastPathComponent)
                                       : WQLocalizedFormat(@"Delete %lu items?", (unsigned long)paths.count);
    // Links and special files have no backup; say so instead of promising one.
    UIAlertController *alert = wq_alert_controller(title, special
        ? @"Files are copied to Backups first. Links and special files (pipes, sockets) are removed without a backup and can't be restored."
        : @"Files are copied to Backups first.", UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Delete", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self exitFileSelection];
        [self runIO:^BOOL(NSString **error) {
            NSUInteger failed = 0;
            NSString *first = nil;
            for (NSUInteger i = 0; i < paths.count; i++) {
                NSString *path = paths[i];
                NSString *e = nil;
                if (!wq_delete_expecting(path, wq_identity_at(identities, i), &e)) {
                    failed++;
                    if (!first) first = [NSString stringWithFormat:@"%@: %@", path.lastPathComponent, e ?: @"failed"];
                }
            }
            if (failed && error) {
                *error = paths.count == 1 ? first
                    : WQLocalizedFormat(@"Items not deleted: %lu of %lu.\n\n%@", (unsigned long)failed, (unsigned long)paths.count, first);
            }
            return failed == 0;
        } failure:WQLocalizedNullable(@"Cannot delete")];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

// "Name.zip", or "Name 2.zip" when that is taken in this folder.
- (NSString *)unusedName:(NSString *)base extension:(NSString *)extension
{
    NSMutableSet<NSString *> *taken = [NSMutableSet new];
    for (WQItem *item in _all) [taken addObject:item.name.lowercaseString];
    for (NSUInteger n = 1; n < 10000; n++) {
        NSString *stem = n == 1 ? base : [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n];
        NSString *name = extension.length ? [stem stringByAppendingPathExtension:extension] : stem;
        if (![taken containsObject:name.lowercaseString]) return name;
    }
    return [NSString stringWithFormat:@"%@ %@", base, NSUUID.UUID.UUIDString];
}

// Runs a long ZIP job with a progress alert that can cancel it. The job calls
// `finishing` before its final step (publishing the result); a cancel that
// arrives too late to stop it is reported as such, not as nothing done.
- (void)runArchiveJob:(NSString *)title failure:(NSString *)failureTitle
                 work:(BOOL (^)(WQArchiveCancelled cancelled, WQArchiveProgress progress, void (^finishing)(void),
                                NSString **error, NSString **note))work
{
    [self runArchiveJob:title failure:failureTitle work:work done:nil];
}

// `done` runs on success (not after a cancel) instead of showing the note;
// it gets the note to show where it fits.
- (void)runArchiveJob:(NSString *)title failure:(NSString *)failureTitle
                 work:(BOOL (^)(WQArchiveCancelled cancelled, WQArchiveProgress progress, void (^finishing)(void),
                                NSString **error, NSString **note))work
                 done:(void (^)(NSString *note))done
{
    WQScanCancellation *cancellation = [WQScanCancellation new];
    UIAlertController *hud = wq_alert_controller(title, @"Starting…", UIAlertControllerStyleAlert);
    [hud addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) { [cancellation cancel]; })];
    [self presentViewController:hud animated:YES completion:nil];
    __block CFAbsoluteTime lastUpdate = 0;
    __block BOOL finishingShown = NO;   // main queue only
    WQArchiveProgress progress = ^(unsigned long long bytes) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastUpdate < 0.25) return;
        lastUpdate = now;
        NSString *text = wq_size_text(bytes);
        dispatch_async(dispatch_get_main_queue(), ^{ if (!finishingShown) hud.message = text; });
    };
    void (^finishing)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ finishingShown = YES; hud.message = WQLocalized(@"Finishing…"); });
    };
    WQArchiveCancelled cancelled = ^BOOL { return cancellation.isCancelled; };
    dispatch_async(wq_io(), ^{
        NSString *error = nil, *note = nil;
        BOOL ok = work(cancelled, progress, finishing, &error, &note);
        BOOL wasCancelled = cancellation.isCancelled;
        // A clean cancel leaves nothing behind and needs no message; any other
        // failure (including a cancel that couldn't clean up) is reported.
        BOOL quietCancel = !ok && wasCancelled && (!error || [error isEqualToString:@"Cancelled"]);
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^finish)(void) = ^{
                if (!ok && !quietCancel) wq_alert(self, failureTitle, error ?: @"Unknown error");
                else if (ok && wasCancelled)
                    wq_alert(self, title, note ? [NSString stringWithFormat:@"%@\n\n%@", WQLocalized(@"It had already finished when you cancelled, so the result was kept."), note]
                                               : WQLocalized(@"It had already finished when you cancelled, so the result was kept."));
                else if (ok && done) { [self reload]; done(note); return; }
                else if (ok && note) wq_alert(self, title, note);
                [self reload];
            };
            if (self.presentedViewController == hud) [self dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}

- (void)compressSelectedFiles
{
    NSArray<NSString *> *paths = [self selectedFilePaths];
    if (!paths.count) return;
    [self exitFileSelection];
    [self compressPaths:paths];
}

- (void)compressPaths:(NSArray<NSString *> *)paths
{
    NSString *base = paths.count == 1 ? paths.firstObject.lastPathComponent : @"Archive";
    NSString *zipName = [self unusedName:base extension:@"zip"];
    NSString *dest = [_path stringByAppendingPathComponent:zipName];
    [self runArchiveJob:WQLocalized(@"Compressing") failure:WQLocalizedNullable(@"Cannot compress")
                   work:^BOOL(WQArchiveCancelled cancelled, WQArchiveProgress progress, void (^finishing)(void),
                              NSString **error, NSString **note) {
        NSString *work = wq_temp_work_dir(@"wq-zip");
        if (!work) { *error = @"Can't create a temporary folder"; return NO; }
        NSString *local = [work stringByAppendingPathComponent:zipName];
        NSUInteger skipped = 0;
        BOOL ok = wq_zip_write(paths, local, wq_app_archive_io(), cancelled, progress, &skipped, error);
        if (ok && cancelled()) ok = NO;
        // Writing the finished ZIP into place can't be interrupted halfway.
        if (ok) { finishing(); ok = wq_create_file_from(dest, local, error); }
        [NSFileManager.defaultManager removeItemAtPath:work error:nil];
        wq_log(@"compress: %lu item(s) -> %@: %@", (unsigned long)paths.count, dest, ok ? @"OK" : *error);
        if (ok && skipped)
            *note = skipped == 1
                ? WQLocalizedFormat(@"Created %@. %lu symbolic link or special file was left out.",
                                    zipName, (unsigned long)skipped)
                : WQLocalizedFormat(@"Created %@. %lu symbolic links or special files were left out.",
                                    zipName, (unsigned long)skipped);
        return ok;
    }];
}

- (void)extractZip:(NSString *)zipPath
{
    [self extractZip:zipPath open:NO];
}

// Tapping a ZIP (issue #41): extract it next to itself and open the folder,
// or open the file itself as before.
- (void)offerZipOpen:(WQItem *)item
{
    UIAlertController *sheet = wq_alert_controller(WQVerbatim(item.name), nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(@"Extract and Open", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self extractZip:item.path open:YES];
    })];
    [sheet addAction:wq_alert_action(@"Open as File", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_scanNeedsRefresh = YES;
        wq_open_file(self.navigationController, item.path, self.readOnly, WQOpenAuto);
    })];
    [sheet addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    NSUInteger row = [_items indexOfObject:item];
    UITableViewCell *cell = row == NSNotFound ? nil : [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)extractZip:(NSString *)zipPath open:(BOOL)openAfter
{
    NSString *base = zipPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *folder = [self unusedName:base.length ? base : @"Archive" extension:nil];
    NSString *dest = [_path stringByAppendingPathComponent:folder];
    [self runArchiveJob:WQLocalized(@"Extracting") failure:WQLocalizedNullable(@"Cannot extract")
                   work:^BOOL(WQArchiveCancelled cancelled, WQArchiveProgress progress, void (^finishing)(void),
                              NSString **error, NSString **note) {
        NSString *work = wq_temp_work_dir(@"wq-unzip");
        if (!work) { *error = @"Can't create a temporary folder"; return NO; }
        NSString *local = [work stringByAppendingPathComponent:folder];
        [NSFileManager.defaultManager createDirectoryAtPath:local withIntermediateDirectories:NO attributes:nil error:nil];
        // The files exist twice for a moment (temporary copy, then in place).
        struct statfs fs;
        unsigned long long available = statfs(work.fileSystemRepresentation, &fs) == 0
            ? (unsigned long long)fs.f_bavail * fs.f_bsize : 0;
        unsigned long long reserve = 256ull * 1024 * 1024;
        unsigned long long limit = available > reserve ? (available - reserve) / 2 : 0;
        NSUInteger files = 0, skipped = 0;
        BOOL ok = wq_zip_extract(zipPath, local, wq_app_archive_io(), limit, cancelled, progress, &files, &skipped, error);
        if (ok && cancelled()) ok = NO;
        // All or nothing: copied next to the destination, then published by
        // one rename that never replaces an item that appeared meanwhile.
        // Cancelling still works until that rename.
        if (ok) { finishing(); ok = wq_copy_tree_new(local, dest, cancelled, error); }
        [NSFileManager.defaultManager removeItemAtPath:work error:nil];
        wq_log(@"extract: %@ -> %@: %@ (%lu files, %lu skipped)", zipPath, dest, ok ? @"OK" : *error,
               (unsigned long)files, (unsigned long)skipped);
        if (ok && skipped) {
            NSString *key;
            if (files == 1 && skipped == 1)
                key = @"Extracted %lu file into %@. %lu symbolic link in the ZIP was left out.";
            else if (files == 1)
                key = @"Extracted %lu file into %@. %lu symbolic links in the ZIP were left out.";
            else if (skipped == 1)
                key = @"Extracted %lu files into %@. %lu symbolic link in the ZIP was left out.";
            else
                key = @"Extracted %lu files into %@. %lu symbolic links in the ZIP were left out.";
            *note = WQLocalizedFormat(key, (unsigned long)files, folder, (unsigned long)skipped);
        }
        return ok;
    } done:openAfter ? ^(NSString *note) {
        WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:dest title:folder];
        dir.readOnly = self.readOnly;
        [self.navigationController pushViewController:dir animated:YES];
        if (note) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            wq_alert(dir, WQLocalized(@"Extracting"), note);
        });
    } : nil];
}

// Pull to refresh: container lists are scanned again instead of reused.
- (void)userRefresh
{
    wq_enumerate_invalidate();
    wq_display_names_reset_miss();
    [self reload];
}

- (void)reload
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanInFlight = YES;
    _scanNeedsRefresh = NO;
    _scanStatus = nil;
    [self.refreshControl endRefreshing];
    [self updateHeader];
    NSString *path = _path;
    BOOL labels = _labels;
    BOOL enumerable = [@[@"/private/var/mobile/Containers/Data/Application",
                         @"/var/mobile/Containers/Data/Application",
                         @"/private/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/private/var/mobile/Containers/Data/InternalDaemon",
                         @"/var/mobile/Containers/Data/InternalDaemon",
                         // Listable on iOS 27; on iOS 26 only by scanning.
                         @"/private/var/mobile/Containers/Shared/AppGroup",
                         @"/var/mobile/Containers/Shared/AppGroup"] containsObject:path];
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSArray *names = wq_list(path, &error);
        NSArray *childPaths = nil;
        // App bundles: the app database knows every installed app's bundle
        // container, so no scan is needed when the folder can't be listed.
        BOOL bundleRoot = [path isEqualToString:@"/private/var/containers/Bundle/Application"] ||
                          [path isEqualToString:@"/var/containers/Bundle/Application"];
        if (!names && bundleRoot && !cancellation.isCancelled) {
            NSArray *bundles = wq_ls_bundle_containers();
            if (bundles.count) childPaths = bundles;
            else wq_log(@"app bundles: can't list %@ (%@) and the app database lists no bundles", path, error ?: @"no reason");
        }
        // Parent gives no token on 27.x: discover children with fsgetpath.
        if (!names && !childPaths && enumerable && !cancellation.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = WQLocalized(@"Scanning inodes…");
                [self updateHeader];
            });
            CFAbsoluteTime scanStarted = CFAbsoluteTimeGetCurrent();
            childPaths = wq_enumerate(path, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                // Time left, once the rate is known: an iOS 26 id scan can take most of an hour.
                double elapsed = CFAbsoluteTimeGetCurrent() - scanStarted;
                NSString *left = @"";
                if (elapsed > 5 && done > 0 && done < total) {
                    double remaining = elapsed * (double)(total - done) / (double)done;
                    left = remaining >= 90 ? WQLocalizedFormat(@" · about %.0f min left", ceil(remaining / 60))
                                           : WQLocalized(@" · less than 2 min left");
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_scanStatus = WQLocalizedFormat(@"Scanning inodes… %lld%% · %lu found%@", total ? (long long)(done * 100 / total) : 0, (unsigned long)f, left);
                    [self updateHeader];
                });
            });
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = nil;
                [self updateHeader];
            });
        }
        if (cancellation.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration) return;
                self->_scanInFlight = NO;
                self->_scanNeedsRefresh = YES;
                self->_scanStatus = nil;
                [self.refreshControl endRefreshing];
                [self updateHeader];
            });
            return;
        }
        NSMutableArray<WQItem *> *items = [NSMutableArray new];
        NSUInteger labelIssues = 0;
        NSArray *entries = names ?: childPaths;
        BOOL haveFullPaths = names == nil;
        NSUInteger entryIndex = 0, entryCount = entries.count;
        for (NSString *entry in entries) {
            entryIndex++;
            // Each container needs a token and its identifier: hundreds take a
            // few seconds, so show where it is.
            if (haveFullPaths && (entryIndex == 1 || entryIndex % 10 == 0)) {
                NSUInteger shown = entryIndex;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_scanStatus = WQLocalizedFormat(@"Reading containers… %lu of %lu", (unsigned long)shown, (unsigned long)entryCount);
                    [self updateHeader];
                });
            }
            if (cancellation.isCancelled) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration) return;
                    self->_scanInFlight = NO;
                    self->_scanNeedsRefresh = YES;
                    self->_scanStatus = nil;
                    [self.refreshControl endRefreshing];
                    [self updateHeader];
                });
                return;
            }
            WQItem *item = [WQItem new];
            item.name = haveFullPaths ? entry.lastPathComponent : entry;
            item.path = haveFullPaths ? entry : [path stringByAppendingPathComponent:entry];
            NSString *name = item.name;
            // Enumerated containers need a token before they can be stat'd.
            if (haveFullPaths) {
                item.isDir = YES;
                BOOL token = wq_grant(item.path);
                NSString *bid = token ? wq_container_label(item.path) : nil;
                if (!bid && bundleRoot) bid = wq_bundle_id_for_container(item.path);
                item.bundleID = bid;
                if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                item.label = token || bid ? (wq_display_name(bid) ?: bid ?: WQLocalized(@"(no label)")) : WQLocalized(@"NO TOKEN");
                if (!token && labelIssues < 3) {
                    wq_log(@"label: no token for %@", item.path);
                    labelIssues++;
                } else if (token && !bid.length && labelIssues < 3) {
                    // Once per container per launch; refreshes would repeat it.
                    static NSMutableSet<NSString *> *reported;
                    @synchronized ([WQItem class]) {
                        if (!reported) reported = [NSMutableSet new];
                        if (![reported containsObject:item.path]) {
                            [reported addObject:item.path];
                            wq_log(@"label: no container identifier for %@", item.path);
                        }
                    }
                    labelIssues++;
                }
            }
            struct stat st;
            if (lstat(item.path.fileSystemRepresentation, &st) == 0) {
                item.isLink = S_ISLNK(st.st_mode);
                item.isDir = S_ISDIR(st.st_mode);
                item.isRegular = S_ISREG(st.st_mode);
                item.identity = wq_identity_for_stat(&st);
                item.size = (unsigned long long)st.st_size;
                item.mode = st.st_mode;
                item.uid = st.st_uid;
                item.modified = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec];
                item.created = [NSDate dateWithTimeIntervalSince1970:st.st_birthtimespec.tv_sec];
            }
            if (!haveFullPaths && labels && item.isDir && wq_looks_like_uuid(name)) {
                NSString *bid = wq_container_label(item.path);
                item.bundleID = bid;
                if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                item.label = wq_display_name(bid) ?: bid;
            }
            if (!haveFullPaths && item.isDir && !item.bundleID) {
                // App backups: AppBackups/<bundle id>/...
                if ([path.lastPathComponent isEqualToString:@"AppBackups"]) {
                    item.bundleID = name;
                    item.label = wq_display_name(name) ?: name;
                }
                // File backups mirror the original path; label container UUIDs
                // from the live container they came from.
                NSString *live = wq_backup_original_path(item.path);
                if (live && wq_looks_like_uuid(name)) {
                    NSString *bid = wq_container_label(live);
                    if (bid) { item.bundleID = bid; item.label = wq_display_name(bid) ?: bid; (void)wq_app_icon(bid); }
                }
                if ([path isEqualToString:wq_backup_root().stringByDeletingLastPathComponent]) {
                    if ([name isEqualToString:@"Backups"]) item.label = WQLocalized(@"File Backups");
                    if ([name isEqualToString:@"AppBackups"]) item.label = WQLocalized(@"App Backups");
                }
            }
            [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration) return;
            self->_scanInFlight = NO;
            if (cancellation.isCancelled) {
                self->_scanNeedsRefresh = YES;
                self->_scanStatus = nil;
                [self.refreshControl endRefreshing];
                [self updateHeader];
                return;
            }
            self->_all = items;
            [self applyFilter];
            [self countChildrenOf:items generation:generation cancellation:cancellation];
            self->_error = (names || childPaths != nil) ? nil
                : (error.length ? error
                   : !wq_app_group() ? WQLocalized(@"WQ Files has no App Group, so it can't open other apps' folders. Re-sign it with a tool that keeps the App Group (see Signing in the README).")
                   : wq_full_scan_was_declined() ? WQLocalized(@"Not listed yet: this needs a scan of all files. Pull down to start it.")
                   : WQLocalized(@"Cannot list this folder. Container enumeration failed; see Log."));
            self->_scanStatus = nil;
            self->_lastReloadFinished = NSDate.date.timeIntervalSinceReferenceDate;
            [self.refreshControl endRefreshing];
            [self updateHeader];
            [self.tableView reloadData];
            [self updateBackupSelectionAvailability];
            if (self->_selectingBackups) [self updateBackupSelectionBar];
            if (self->_selectingFiles) {
                NSMutableSet<NSString *> *present = [NSMutableSet new];
                for (WQItem *item in items) [present addObject:item.path];
                for (NSString *path in self->_selectedFiles.array.copy)
                    if (![present containsObject:path]) [self->_selectedFiles removeObject:path];
                [self updateFileSelectionTitle];
            }
            [self updateToolbar];
        });
    });
}

// Show Item Counts: list each subfolder in the background after the folder
// appears; visible rows update as counts arrive. Container lists are left out
// (hundreds of other apps' folders).
- (void)countChildrenOf:(NSArray<WQItem *> *)items generation:(NSUInteger)generation
           cancellation:(WQScanCancellation *)cancellation
{
    if (!wq_show_item_counts() || _labels) return;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("wq.item-counts", DISPATCH_QUEUE_SERIAL); });
    __weak typeof(self) weakSelf = self;
    void (^refresh)(void) = ^{
        WQDirViewController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_scanGeneration || strongSelf->_error) return;
        NSArray *visible = strongSelf.tableView.indexPathsForVisibleRows;
        if (visible.count) [strongSelf.tableView reconfigureRowsAtIndexPaths:visible];
    };
    dispatch_async(queue, ^{
        CFAbsoluteTime lastRefresh = CFAbsoluteTimeGetCurrent();
        for (WQItem *item in items) {
            if (cancellation.isCancelled || !weakSelf) return;
            if (!item.isDir || item.isLink) continue;
            NSArray *names = wq_list(item.path, NULL);
            NSInteger count = names ? (NSInteger)names.count : -1;
            dispatch_async(dispatch_get_main_queue(), ^{ item.childCount = count; });
            if (CFAbsoluteTimeGetCurrent() - lastRefresh > 0.3) {
                lastRefresh = CFAbsoluteTimeGetCurrent();
                dispatch_async(dispatch_get_main_queue(), refresh);
            }
        }
        dispatch_async(dispatch_get_main_queue(), refresh);
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _error ? 1 : (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"];
    cell.backgroundColor = [UIColor clearColor];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_error) {
        c.text = WQLocalizedNullable(@"Cannot open this folder");
        BOOL container = [_path containsString:@"/Containers/"] || [_path containsString:@"/SystemGroup/"];
        c.secondaryText = container ? _error
            : WQLocalizedFormat(@"%@\n\nThis method only opens containers. Use App Data, App Groups, Extension Data, Internal Daemons or System Groups for the folders inside /private/var.", _error);
        c.secondaryTextProperties.numberOfLines = 0;
        c.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQItem *item = _items[(NSUInteger)indexPath.row];
    c.text = item.label ?: item.name;
    BOOL byCreated = wq_sort_key() == WQSortCreated;
    NSString *date = wq_folder_date_text(byCreated ? item.created : item.modified);
    NSString *detail = item.isDir ? date : WQLocalizedFormat(@"%@ · %@", wq_size_text(item.size), date);
    if (item.isDir && item.childCount >= 0) {
        NSString *items = item.childCount == 1
            ? WQLocalizedFormat(@"%ld item", (long)item.childCount)
            : WQLocalizedFormat(@"%ld items", (long)item.childCount);
        detail = WQLocalizedFormat(@"%@ · %@", date, items);
    }
    // Container lists: the bundle id (issue #27); the folder's UUID is in its path.
    if (item.label) detail = WQLocalizedFormat(@"%@\n%@", item.bundleID.length ? item.bundleID : item.name, detail);
    if (item.isLink) detail = [WQLocalized(@"symlink · ") stringByAppendingString:detail];
    c.secondaryText = detail;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    UIImage *appIcon = item.bundleID ? wq_app_icon(item.bundleID) : nil;
    c.image = appIcon ?: [UIImage systemImageNamed:item.isDir ? @"folder.fill" : (item.isLink ? @"link" : @"doc")];
    if (appIcon) c.imageProperties.maximumSize = CGSizeMake(36, 36);
    cell.contentConfiguration = c;
    if (_selectingFiles) {
        cell.accessoryType = [_selectedFiles containsObject:item.path]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (_selectingBackups) {
        BOOL selectable = wq_backup_unit_deletable(item.path);
        cell.accessoryType = selectable && [_selectedBackups containsObject:item.path]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryType = item.isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_error || indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    if (!_selectingBackups) return indexPath;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    return wq_backup_unit_deletable(item.path) ? indexPath : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_selectingFiles) {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
        if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
        NSString *path = _items[(NSUInteger)indexPath.row].path;
        if ([_selectedFiles containsObject:path]) [_selectedFiles removeObject:path];
        else [_selectedFiles addObject:path];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [self updateFileSelectionTitle];
        return;
    }
    if (_selectingBackups) {
        if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
        WQItem *selected = _items[(NSUInteger)indexPath.row];
        if (!wq_backup_unit_deletable(selected.path)) return;
        [_selectedBackups addObject:selected.path];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [self updateBackupSelectionBar];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_error) return;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    UIViewController *next;
    if (item.isLink) {
        wq_alert(self, @"Symbolic link",
                 @"WQ Files does not follow symbolic links for viewing, sharing or editing. Use Copy Path to open the target explicitly.");
        return;
    }
    if (item.isDir) {
        WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:item.path title:item.label ?: item.name];
        dir.readOnly = self.readOnly;
        next = dir;
    } else {
        if (!item.isRegular) {
            wq_alert(self, @"Cannot open this item", item.isLink
                     ? @"Symbolic links are not followed for viewing, sharing or editing."
                     : @"Only regular files can be viewed.");
            return;
        }
        if ([self canEditHere] && [item.name.pathExtension caseInsensitiveCompare:@"zip"] == NSOrderedSame) {
            [self offerZipOpen:item];
            return;
        }
        _scanNeedsRefresh = YES;
        wq_open_file(self.navigationController, item.path, self.readOnly, WQOpenAuto);
        return;
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_selectingBackups) return;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    [_selectedBackups removeObject:item.path];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateBackupSelectionBar];
}

// Swipe left to delete, with the same rules and confirmation as the
// long-press menu (files are backed up first; backups only as whole units).
- (UISwipeActionsConfiguration *)deleteSwipeForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_selectingBackups || _selectingFiles || _error || !wq_deleting_allowed()) return nil;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    BOOL backupUnit = item.isDir && wq_backup_unit_deletable(item.path);
    BOOL regular = !self.readOnly && !_backupStorage;
    if (!backupUnit && !regular) return nil;
    NSString *itemPath = [item.path copy];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:WQLocalizedNullable(@"Delete") handler:^(UIContextualAction *__unused a, UIView *__unused view, void (^done)(BOOL)) {
        WQDirViewController *strongSelf = weakSelf;
        WQItem *current = nil;
        if (strongSelf && (NSUInteger)indexPath.row < strongSelf->_items.count &&
            [strongSelf->_items[(NSUInteger)indexPath.row].path isEqualToString:itemPath])
            current = strongSelf->_items[(NSUInteger)indexPath.row];
        // The row stays until the confirmed delete reloads the folder.
        done(NO);
        if (!current) return;
        if (backupUnit) [strongSelf confirmDeleteBackup:current];
        else [strongSelf confirmDelete:current];
    }];
    action.image = [UIImage systemImageNamed:@"trash"];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self deleteSwipeForRowAtIndexPath:indexPath];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Delete is on the left swipe only (issue #36).
    return [UISwipeActionsConfiguration configurationWithActions:@[]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (_selectingBackups || _selectingFiles || _error) return nil;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    NSString *itemPath = [item.path copy];
    __weak typeof(self) weakSelf = self;
    WQItem *(^currentItem)(void) = ^WQItem *{
        WQDirViewController *strongSelf = weakSelf;
        if (!strongSelf || indexPath.section != 0 || (NSUInteger)indexPath.row >= strongSelf->_items.count) return nil;
        WQItem *current = strongSelf->_items[(NSUInteger)indexPath.row];
        return [current.path isEqualToString:itemPath] ? current : nil;
    };
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        WQItem *current = currentItem();
        WQDirViewController *strongSelf = weakSelf;
        if (!current || !strongSelf) return nil;
        NSMutableArray *actions = [NSMutableArray new];
        if (current.isDir) {
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Share as ZIP (AirDrop…)") image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (latest && weakSelf) wq_share_folder(weakSelf, latest.path, nil, cell);
            }]];
        }
        if (!current.isDir && current.isRegular) {
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (latest && weakSelf) wq_share(weakSelf, latest.path, cell);
            }]];
            NSString *original = wq_backup_original_path(current.path);
            if (original) {
                [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Restore to Original Location")
                                                       image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    WQItem *latest = currentItem();
                    if (latest && weakSelf) [weakSelf restoreBackup:latest.path to:original];
                }]];
            }
        }
        if (!current.isDir && current.isRegular) {
            BOOL ro = weakSelf.readOnly;
            [actions addObject:[UIMenu menuWithTitle:WQLocalizedNullable(@"Open As") image:[UIImage systemImageNamed:@"arrow.up.forward.app"] identifier:nil
                                             options:0 children:@[
                [UIAction actionWithTitle:WQLocalizedNullable(@"Plist Editor") image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenPlist); }],
                [UIAction actionWithTitle:WQLocalizedNullable(@"Text / Image") image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenText); }],
                [UIAction actionWithTitle:WQLocalizedNullable(@"Hex Viewer") image:[UIImage systemImageNamed:@"number"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenHex); }],
                [UIAction actionWithTitle:WQLocalizedNullable(@"SQLite Viewer") image:[UIImage systemImageNamed:@"tablecells"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenSQLite); }],
                [UIAction actionWithTitle:WQLocalizedNullable(@"Media Player") image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenMedia); }],
            ]]];
        }
        [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Copy Path") image:[UIImage systemImageNamed:@"doc.on.doc"]
                                          identifier:nil handler:^(UIAction *__unused a) {
            WQItem *latest = currentItem();
            if (latest) UIPasteboard.generalPasteboard.string = latest.path;
        }]];
        if (current.label) {
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Copy Identifier") image:[UIImage systemImageNamed:@"tag"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) UIPasteboard.generalPasteboard.string = latest.bundleID ?: latest.label;
            }]];
        }
        // App backups (AppBackups/<bundle id>[/<backup>]): restore through Apps,
        // which knows the installed app's container.
        NSString *backupParent = current.path.stringByDeletingLastPathComponent;
        NSString *restoreID = [backupParent isEqualToString:wq_app_backup_root()] ? current.name
            : [backupParent.stringByDeletingLastPathComponent isEqualToString:wq_app_backup_root()] ? backupParent.lastPathComponent : nil;
        if (current.isDir && restoreID.length) {
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Restore Backup…") image:[UIImage systemImageNamed:@"clock.arrow.circlepath"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf.navigationController pushViewController:[[WQAppsViewController alloc] initRestoringBundleID:restoreID]
                                                         animated:YES];
            }]];
        }
        if (current.isDir && wq_backup_unit_deletable(current.path) && wq_deleting_allowed()) {
            UIAction *remove = [UIAction actionWithTitle:WQLocalizedNullable(@"Delete Backup…") image:[UIImage systemImageNamed:@"trash"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) [weakSelf confirmDeleteBackup:latest];
            }];
            remove.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:remove];
        }
        [actions addObject:[UIAction actionWithTitle:WQLocalized(@"Get Info") image:[UIImage systemImageNamed:@"info.circle"]
                                          identifier:nil handler:^(UIAction *__unused a) {
            WQItem *latest = currentItem();
            if (latest) [weakSelf.navigationController pushViewController:[[WQInfoViewController alloc] initWithPath:latest.path] animated:YES];
        }]];
        if (!current.isLink && (current.isRegular || current.isDir) && current.identity) {
            [actions addObject:[UIAction actionWithTitle:WQLocalized(@"Copy to Folder…") image:[UIImage systemImageNamed:@"doc.on.doc"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) [weakSelf startCopy:latest];
            }]];
        }
        if ([strongSelf canEditHere]) {
            if (!current.isLink && (current.isDir || current.isRegular)) {
                [actions addObject:[UIAction actionWithTitle:WQLocalized(@"Duplicate") image:[UIImage systemImageNamed:@"plus.square.on.square"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    WQItem *latest = currentItem();
                    if (latest) [weakSelf duplicateItem:latest];
                }]];
            }
            if (!current.isDir && current.isRegular &&
                [current.name.pathExtension caseInsensitiveCompare:@"zip"] == NSOrderedSame) {
                [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Extract") image:[UIImage systemImageNamed:@"archivebox"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    WQItem *latest = currentItem();
                    if (latest) [weakSelf extractZip:latest.path];
                }]];
            }
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Compress") image:[UIImage systemImageNamed:@"doc.zipper"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) [weakSelf compressPaths:@[latest.path]];
            }]];
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Move…") image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) [weakSelf startMove:@[latest.path] identities:@[latest.identity ?: wq_item_identity(latest.path) ?: (id)NSNull.null]];
            }]];
        }
        if (!strongSelf.readOnly && !strongSelf->_backupStorage) {
            [actions addObject:[UIAction actionWithTitle:WQLocalizedNullable(@"Rename") image:[UIImage systemImageNamed:@"pencil"]
                                              identifier:nil handler:^(UIAction *__unused a) { WQItem *latest = currentItem(); if (latest) [weakSelf promptRename:latest]; }]];
            UIAction *del = [UIAction actionWithTitle:WQLocalizedNullable(@"Delete") image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *__unused a) { WQItem *latest = currentItem(); if (latest) [weakSelf confirmDelete:latest]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            if (wq_deleting_allowed()) [actions addObject:del];
        }
        return [UIMenu menuWithChildren:actions];
    }];
}

#pragma mark Actions

- (void)runIO:(BOOL (^)(NSString **error))work failure:(NSString *)failureTitle
{
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        BOOL ok = work(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) wq_alert(self, failureTitle, error ?: @"Unknown error");
            [self reload];
        });
    });
}

- (void)promptNewFolder
{
    UIAlertController *alert = wq_alert_controller(@"New Folder", _path, UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = WQLocalizedNullable(@"Name"); }];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Create", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [self->_path stringByAppendingPathComponent:name];
        [self runIO:^BOOL(NSString **error) { return wq_create_dir(path, error); } failure:WQLocalizedNullable(@"Cannot create folder")];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)renameSelectedFile
{
    NSString *path = [self selectedFilePaths].firstObject;
    if ([self selectedFilePaths].count != 1) return;
    WQItem *item = nil;
    for (WQItem *candidate in _all) if ([candidate.path isEqualToString:path]) { item = candidate; break; }
    if (!item) return;
    [self exitFileSelection];
    [self promptRename:item];
}

- (void)promptRename:(WQItem *)item
{
    UIAlertController *alert = wq_alert_controller(@"Rename", item.path, UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = item.name; }];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Rename", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        [self runIO:^BOOL(NSString **error) { return wq_rename_expecting(item.path, name, item.identity, error); } failure:WQLocalizedNullable(@"Cannot rename")];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteBackup:(WQItem *)item
{
    if (wq_refuse_if_deleting_off(self)) return;
    BOOL bundle = [item.path.stringByDeletingLastPathComponent isEqualToString:wq_app_backup_root()];
    NSString *message = bundle
        ? WQLocalizedFormat(@"%@\n\nThis removes every backup for this app. It cannot be undone.", item.path)
        : WQLocalizedFormat(@"%@\n\nThis removes the selected backup. It cannot be undone.", item.path);
    UIAlertController *alert = wq_alert_controller(@"Delete backup?", message, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Delete", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) { return wq_delete_backup(item.path, error); } failure:WQLocalizedNullable(@"Cannot delete backup")];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

// Folders and everything in them (and any files among `paths`): counted
// first, so the alert says how much goes, which of it is backed up (regular
// files) and which is not (links, pipes, sockets), and whether the count is
// complete. `identities` are the selected objects (NSNull when unknown).
- (void)confirmDeleteFolders:(NSArray<NSString *> *)paths identities:(NSArray *)identities
{
    if (wq_refuse_if_deleting_off(self)) return;
    for (NSString *path in paths) {
        if (wq_is_protected_folder(path)) {
            wq_alert(self, @"Cannot delete", WQLocalizedFormat(@"%@\n\nThis folder holds an app's or the system's data and can't be deleted here.", path));
            return;
        }
    }
    dispatch_async(wq_io(), ^{
        static const NSUInteger kLimit = 1000000;
        WQTreeCount total = { 0, 0, 0, WQTreeCountExact };
        for (NSString *path in paths) {
            if (total.regular + total.other >= kLimit) { total.state = MAX(total.state, WQTreeCountLimited); break; }
            WQTreeCount count = wq_tree_count(path, kLimit - total.regular - total.other);
            total.regular += count.regular; total.other += count.other; total.bytes += count.bytes;
            total.state = MAX(total.state, count.state);   // Unreadable outranks Limited
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *title = paths.count == 1 ? WQLocalizedFormat(@"Delete “%@”?", paths.firstObject.lastPathComponent)
                                               : WQLocalizedFormat(@"Delete %lu items?", (unsigned long)paths.count);
            NSMutableString *message = [WQLocalizedFormat(@"%lu files (%@) in total, including everything in the folders. Each file is copied to Backups first and can be restored from Recently Deleted.",
                                                          (unsigned long)total.regular, wq_size_text(total.bytes)) mutableCopy];
            if (total.other)
                [message appendFormat:@"\n\n%@", WQLocalizedFormat(@"%lu links or special files (pipes, sockets) are removed without a backup and can't be restored.",
                                                                    (unsigned long)total.other)];
            if (total.state == WQTreeCountLimited)
                [message appendFormat:@"\n\n%@", WQLocalizedFormat(@"Counting stopped at %lu items, so there may be more.", (unsigned long)kLimit)];
            else if (total.state == WQTreeCountUnreadable)
                [message appendFormat:@"\n\n%@", WQLocalized(@"Some folders or items could not be read, so these totals may be incomplete. Anything in them that is not a regular file is removed without a backup.")];
            UIAlertController *alert = wq_alert_controller(title, nil, UIAlertControllerStyleAlert);
            alert.message = message;
            [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
            [alert addAction:wq_alert_action(@"Delete", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
                [self deleteTrees:paths identities:identities total:total.regular + total.other];
            })];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)deleteTrees:(NSArray<NSString *> *)paths identities:(NSArray *)identities total:(NSUInteger)total
{
    WQScanCancellation *cancellation = [WQScanCancellation new];
    UIAlertController *hud = wq_alert_controller(@"Deleting…", @"Starting…", UIAlertControllerStyleAlert);
    [hud addAction:wq_alert_action(@"Stop", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) { [cancellation cancel]; })];
    [self presentViewController:hud animated:YES completion:nil];
    dispatch_async(wq_io(), ^{
        __block CFAbsoluteTime lastUpdate = 0;
        __block NSUInteger done = 0;
        NSString *error = nil;
        BOOL ok = YES;
        for (NSUInteger i = 0; i < paths.count; i++) {
            NSString *path = paths[i];
            NSUInteger before = done, deleted = 0;
            NSString *e = nil;
            ok = wq_delete_tree_expecting(path, wq_identity_at(identities, i), ^BOOL { return cancellation.isCancelled; }, ^(NSUInteger n) {
                NSUInteger now = before + n;
                CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
                if (t - lastUpdate < 0.2) return;
                lastUpdate = t;
                NSString *text = WQLocalizedFormat(@"%lu of %lu files", (unsigned long)now, (unsigned long)total);
                dispatch_async(dispatch_get_main_queue(), ^{ hud.message = text; });
            }, &deleted, NULL, &e);
            done += deleted;
            if (!ok) { error = e; break; }
        }
        BOOL stopped = cancellation.isCancelled;
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^finish)(void) = ^{
                if (!ok && !stopped)
                    wq_alert(self, @"Not everything was deleted",
                             WQLocalizedFormat(@"%lu files were deleted (copies are in Backups), then:\n%@", (unsigned long)done, error ?: @"unknown error"));
                [self reload];
            };
            if (self.presentedViewController == hud) [self dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}

- (void)confirmDelete:(WQItem *)item
{
    if (wq_refuse_if_deleting_off(self)) return;
    NSString *message;
    if (item.isLink) {
        message = WQLocalizedFormat(@"%@\n\nRemoves the symbolic link only; its target is not changed.", item.path);
    } else if (item.isDir) {
        if (wq_is_protected_folder(item.path)) {
            message = WQLocalizedFormat(@"%@\n\nOnly empty folders can be deleted.", item.path);
        } else {
            [self confirmDeleteFolders:@[item.path] identities:@[item.identity ?: wq_item_identity(item.path) ?: (id)NSNull.null]];
            return;
        }
    } else if (item.isRegular) {
        message = WQLocalizedFormat(@"%@\n\nA copy is kept in Backups.", item.path);
    } else {
        message = WQLocalizedFormat(@"%@\n\nThis special file is removed; no backup is kept.", item.path);
    }
    UIAlertController *alert = wq_alert_controller(WQLocalizedFormat(@"Delete \"%@\"?", item.name), message, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Delete", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) { return wq_delete_expecting(item.path, item.identity, error); } failure:WQLocalizedNullable(@"Cannot delete")];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreBackup:(NSString *)backup to:(NSString *)original
{
    NSString *message = wq_keep_before_restore()
        ? WQLocalizedFormat(@"Write this backup back to\n%@?\n\nIf a file is there now, it is backed up first.", original)
        : WQLocalizedFormat(@"Write this backup back to\n%@?\n\nIf a file is there now, it is backed up first and that backup is deleted after a successful restore (Keep Data Before Restore is off).", original);
    UIAlertController *alert = wq_alert_controller(@"Restore", message, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Restore", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) {
            struct stat st;
            if (!wq_stat(original, &st)) return wq_create_file_from(original, backup, error);
            NSString *unit = nil;
            if (!wq_write_from_file_with_backup(original, backup, &unit, error)) return NO;
            // Keep Data Before Restore off: drop the copy of what was replaced.
            if (!wq_keep_before_restore() && unit) {
                NSString *discardError = nil;
                if (wq_delete_backup(unit, &discardError))
                    wq_log(@"restore %@: removed the before-restore backup %@ (Keep Data Before Restore is off)",
                           original.lastPathComponent, unit.lastPathComponent);
                else
                    wq_log(@"restore %@: couldn't remove the before-restore backup %@ (%@)",
                           original.lastPathComponent, unit.lastPathComponent, discardError);
            }
            return YES;
        } failure:WQLocalizedNullable(@"Restore failed")];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importFile
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    _importingFolder = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importFolder
{
    // Folders can't be handed over as a copy; the picker grants temporary
    // access to the folder itself, which is copied with everything inside.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    _importingFolder = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

// A name in dir that nothing uses yet: "Name", "Name 2", … (keeps the extension).
static NSString *wq_free_name_in(NSString *dir, NSString *name, NSMutableSet<NSString *> *claimed)
{
    NSString *ext = name.pathExtension, *stem = name.stringByDeletingPathExtension;
    if (!stem.length) { stem = name; ext = @""; }
    for (NSUInteger n = 1; n < 10000; n++) {
        NSString *candidate = n == 1 ? name : [NSString stringWithFormat:@"%@ %lu", stem, (unsigned long)n];
        if (n > 1 && ext.length) candidate = [candidate stringByAppendingPathExtension:ext];
        struct stat st;
        if ([claimed containsObject:candidate.lowercaseString] ||
            wq_stat([dir stringByAppendingPathComponent:candidate], &st)) continue;
        [claimed addObject:candidate.lowercaseString];
        return candidate;
    }
    return nil;
}

// Shows a progress alert while work runs on the IO queue, then reports.
- (void)runBusy:(NSString *)title failure:(NSString *)failureTitle
           work:(BOOL (^)(NSString **error, NSString **note))work
{
    UIAlertController *hud = wq_alert_controller(title, @"Please wait…", UIAlertControllerStyleAlert);
    [self presentViewController:hud animated:YES completion:nil];
    dispatch_async(wq_io(), ^{
        NSString *error = nil, *note = nil;
        BOOL ok = work(&error, &note);
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^finish)(void) = ^{
                if (!ok) wq_alert(self, failureTitle, error ?: @"Unknown error");
                else if (note) wq_alert(self, title, note);
                [self reload];
            };
            if (self.presentedViewController == hud) [self dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}

- (void)duplicateItem:(WQItem *)item
{
    if (![self canEditHere] || item.isLink || !(item.isRegular || item.isDir)) return;
    NSString *source = item.path;
    NSString *directory = source.stringByDeletingLastPathComponent;
    NSDictionary *identity = item.identity;
    BOOL isDirectory = item.isDir;
    [self runBusy:WQLocalized(@"Duplicating…") failure:WQLocalized(@"Copying failed.")
             work:^BOOL(NSString **error, NSString **__unused note) {
        if (!identity || ![identity isEqualToDictionary:wq_item_identity(source)]) {
            *error = WQLocalized(@"The item was moved, replaced or changed after it was selected. It was left as it is.");
            return NO;
        }
        // Reserve the original name even if it disappears after the identity check.
        NSMutableSet *claimed = [NSMutableSet setWithObject:source.lastPathComponent.lowercaseString];
        NSString *name = wq_free_name_in(directory, source.lastPathComponent, claimed);
        if (!name) { *error = WQLocalized(@"No free name in this folder"); return NO; }
        NSString *destination = [directory stringByAppendingPathComponent:name];
        return isDirectory ? wq_copy_tree_new(source, destination, nil, error)
                           : wq_create_file_from(destination, source, error);
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (!urls.count) return;
    if (_importingFolder) { [self importFolders:urls]; return; }
    // One file: the existing flow, which offers to replace a file of the same name.
    if (urls.count == 1) { [self importSingleFile:urls.firstObject.path]; return; }
    // Several files: when some names are taken, one question for all of them
    // (issue #49): Replace All (each replaced file is backed up first, as for
    // a single file) or Keep Both ("Name 2.ext").
    NSString *dir = _path;
    NSArray<NSString *> *sources = [urls valueForKey:@"path"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString *, NSDictionary *> *conflicts = [NSMutableDictionary new];
        for (NSString *source in sources) {
            NSString *destination = [dir stringByAppendingPathComponent:source.lastPathComponent];
            conflicts[source] = wq_file_version(destination);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!conflicts.count) { [self importFiles:sources into:dir replacing:nil]; return; }
            UIAlertController *ask = wq_alert_controller(@"Replace existing files?",
                WQLocalizedFormat(@"%lu of the %lu files already exist here. Replace them (each is backed up first) or keep both?",
                                  (unsigned long)conflicts.count, (unsigned long)sources.count), UIAlertControllerStyleAlert);
            [ask addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) {
                for (NSString *source in sources) [NSFileManager.defaultManager removeItemAtPath:source error:nil];
            })];
            [ask addAction:wq_alert_action(@"Keep Both", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [self importFiles:sources into:dir replacing:nil];
            })];
            [ask addAction:wq_alert_action(@"Replace All", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
                [self importFiles:sources into:dir replacing:conflicts];
            })];
            [self presentViewController:ask animated:YES completion:nil];
        });
    });
}

// Replace only the versions shown in the confirmation. Other files get a
// free name, including destinations that appeared after the preflight.
- (void)importFiles:(NSArray<NSString *> *)sources into:(NSString *)dir replacing:(NSDictionary<NSString *, NSDictionary *> *)versions
{
    [self runBusy:WQLocalized(@"Importing") failure:WQLocalizedNullable(@"Import failed") work:^BOOL(NSString **error, NSString **note) {
        NSMutableSet<NSString *> *claimed = [NSMutableSet new];
        NSUInteger done = 0, renamed = 0, replaced = 0;
        NSString *first = nil;
        for (NSString *source in sources) {
            NSString *e = nil;
            NSString *existing = [dir stringByAppendingPathComponent:source.lastPathComponent];
            NSDictionary *expected = versions[source];
            BOOL ok;
            NSString *name = source.lastPathComponent;
            if (expected && ![claimed containsObject:name.lowercaseString]) {
                ok = wq_write_from_file_if_unchanged(existing, source, expected, &e);
                [claimed addObject:name.lowercaseString];
                if (ok) replaced++;
            } else {
                name = wq_free_name_in(dir, source.lastPathComponent, claimed);
                ok = name && wq_create_file_from([dir stringByAppendingPathComponent:name], source, &e);
                if (ok && ![name isEqualToString:source.lastPathComponent]) renamed++;
            }
            [NSFileManager.defaultManager removeItemAtPath:source error:nil];
            if (ok) done++;
            else if (!first) first = [NSString stringWithFormat:@"%@: %@", source.lastPathComponent, e ?: @"no free name"];
        }
        wq_log(@"import: %lu of %lu files into %@ (%lu replaced, %lu renamed)", (unsigned long)done, (unsigned long)sources.count,
               dir, (unsigned long)replaced, (unsigned long)renamed);
        if (done < sources.count) {
            *error = [NSString stringWithFormat:@"%lu of %lu files were imported.\n\n%@",
                      (unsigned long)done, (unsigned long)sources.count, first];
            return NO;
        }
        if (renamed) *note = WQLocalizedFormat(@"Imported %lu files. %lu had a name that was already taken and got a number added.",
                              (unsigned long)done, (unsigned long)renamed);
        return YES;
    }];
}

- (void)importFolders:(NSArray<NSURL *> *)urls
{
    NSString *dir = _path;
    [self runBusy:WQLocalized(@"Importing") failure:WQLocalizedNullable(@"Import failed") work:^BOOL(NSString **error, NSString **note) {
        NSMutableSet<NSString *> *claimed = [NSMutableSet new];
        NSMutableArray<NSString *> *renamed = [NSMutableArray new];
        for (NSURL *url in urls) {
            BOOL scoped = [url startAccessingSecurityScopedResource];
            NSString *name = wq_free_name_in(dir, url.lastPathComponent, claimed);
            __block BOOL ok = NO;
            __block NSString *e = nil;
            if (name) {
                NSString *dest = [dir stringByAppendingPathComponent:name];
                // A coordinated read makes cloud folders download first.
                NSError *coordError = nil;
                [[NSFileCoordinator new] coordinateReadingItemAtURL:url options:0 error:&coordError byAccessor:^(NSURL *readable) {
                    NSString *copyError = nil;
                    // All or nothing, never replacing an item that appeared meanwhile.
                    ok = wq_copy_tree_new(readable.path, dest, nil, &copyError);
                    e = copyError;
                }];
                if (coordError) e = e ?: coordError.localizedDescription;
            } else {
                e = WQLocalized(@"No free name in this folder");
            }
            if (scoped) [url stopAccessingSecurityScopedResource];
            wq_log(@"import folder: %@ -> %@/%@: %@", url.path, dir, name, ok ? @"OK" : e);
            if (!ok) { *error = [NSString stringWithFormat:@"%@: %@", url.lastPathComponent, e ?: @"failed"]; return NO; }
            if (![name isEqualToString:url.lastPathComponent]) [renamed addObject:name];
        }
        if (renamed.count)
            *note = WQLocalizedFormat(@"A folder with the same name already existed, so the import is named %@.",
                     [renamed componentsJoinedByString:@", "]);
        return YES;
    }];
}

- (void)importSingleFile:(NSString *)source
{
    // The picker hands over a local copy (asCopy). It is streamed into place,
    // never read into memory, and the existence check runs off the main thread.
    NSString *dest = [_path stringByAppendingPathComponent:source.lastPathComponent];
    void (^cleanup)(void) = ^{ [NSFileManager.defaultManager removeItemAtPath:source error:nil]; };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct stat st;
        BOOL exists = wq_stat(dest, &st);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!exists) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_create_file_from(dest, source, error);
                    cleanup();
                    return ok;
                } failure:WQLocalizedNullable(@"Import failed")];
                return;
            }
            UIAlertController *alert = wq_alert_controller(@"Replace existing file?", WQLocalizedFormat(@"%@ already exists. It is backed up before being replaced.", dest), UIAlertControllerStyleAlert);
            [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) { cleanup(); })];
            [alert addAction:wq_alert_action(@"Replace", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_write_from_file(dest, source, error);
                    cleanup();
                    return ok;
                } failure:WQLocalizedNullable(@"Import failed")];
            })];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end

#pragma mark - System groups

// The SystemGroup parent gets no token on 27.0.1, so it cannot be listed.
// Known container names are checked one by one (lstat works without access).
@interface WQSystemGroupsViewController : UITableViewController
@end

@implementation WQSystemGroupsViewController {
    NSArray<NSString *> *_names;
    BOOL _listed;
}

static NSString *const kSystemGroupRoot = @"/private/var/containers/Shared/SystemGroup";

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"System Groups");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self action:@selector(tryName)];
    dispatch_async(wq_io(), ^{
        NSArray *listed = wq_list(kSystemGroupRoot, NULL);
        NSArray *names = listed;
        if (!names) {
            NSArray *known = @[
                @"systemgroup.com.apple.configurationprofiles", @"systemgroup.com.apple.mobilegestaltcache",
                @"systemgroup.com.apple.osanalytics", @"systemgroup.com.apple.lsd.iconscache",
                @"systemgroup.com.apple.lsd.identifiers", @"systemgroup.com.apple.ManagedSettings",
                @"systemgroup.com.apple.sharedpclogging", @"systemgroup.com.apple.media.shared.books",
                @"systemgroup.com.apple.nsurlstoragedresources", @"systemgroup.com.apple.pisco.suinfo",
                @"systemgroup.com.apple.icloud.findmydevice.managed", @"systemgroup.com.apple.mobilestoragemounter",
                @"systemgroup.com.apple.mobileactivationd", @"systemgroup.com.apple.sensorkit",
                @"systemgroup.com.apple.powerlog", @"systemgroup.com.apple.diagnosticextensionsd",
                @"systemgroup.com.apple.mediaanalysisd", @"systemgroup.com.apple.translationd",
                @"systemgroup.com.apple.chronod", @"systemgroup.com.apple.coreaudio",
                @"systemgroup.com.apple.ManagedConfiguration.ExternalTrust", @"systemgroup.com.apple.cfprefsd",
            ];
            NSMutableArray *found = [NSMutableArray new];
            for (NSString *name in known) {
                struct stat st;
                NSString *p = [kSystemGroupRoot stringByAppendingPathComponent:name];
                if (lstat(p.fileSystemRepresentation, &st) == 0) [found addObject:name];
            }
            names = found;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_listed = listed != nil;
            self->_names = [names sortedArrayUsingSelector:@selector(compare:)];
            [self.tableView reloadData];
        });
    });
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (!_names) return WQLocalized(@"Loading…");
    return _listed ? nil : WQLocalized(@"This folder cannot be listed on this iOS version. Known names that exist are shown; tap + to try another name.");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_names.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"g"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"g"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.text = [_names[(NSUInteger)indexPath.row] stringByReplacingOccurrencesOfString:@"systemgroup." withString:@""];
    c.image = [UIImage systemImageNamed:@"folder.fill"];
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = _names[(NSUInteger)indexPath.row];
    [self.navigationController pushViewController:[[WQDirViewController alloc]
        initWithPath:[kSystemGroupRoot stringByAppendingPathComponent:name] title:nil] animated:YES];
}

- (void)tryName
{
    UIAlertController *alert = wq_alert_controller(@"Open System Group", nil, UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = @"systemgroup.com.apple.";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Open", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [kSystemGroupRoot stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0) {
            wq_alert(self, @"Not found", path);
            return;
        }
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil] animated:YES];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Log

@interface WQLogViewController : UIViewController
@end

@implementation WQLogViewController {
    UITextView *_textView;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"Log");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _textView.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    _textView.textAlignment = NSTextAlignmentLeft;   // log lines stay left to right
    [self.view addSubview:_textView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                           target:self action:@selector(share:)];
}

// App version, device and iOS first, so a Log someone sends in says where it
// came from.
- (NSString *)fullLog
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return WQLocalizedFormat(@"WQ Files %@ (%@)\n%@\n\n%@",
            info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?", wq_device_line(), wq_log_text());
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _textView.text = [self fullLog];
}

- (void)share:(UIBarButtonItem *)sender
{
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[self fullLog]]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

@end

#pragma mark - Navigation

// Adds a Home button next to Back on screens two or more levels deep. Editors
// guard Back, Home and the interactive edge swipe through WQUnsavedEditing.
@interface WQNavigationController : UINavigationController <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@end

@implementation WQNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;
    self.interactivePopGestureRecognizer.delegate = self;
    self.navigationBar.prefersLargeTitles = YES;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithDefaultBackground];
    appearance.backgroundColor = [UIColor clearColor];
    appearance.shadowColor = [UIColor clearColor];
    self.navigationBar.standardAppearance = appearance;
    self.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationBar.compactAppearance = appearance;
    self.navigationBar.tintColor = [UIColor colorWithRed:0.37 green:0.50 blue:1.0 alpha:1.0];
}

- (void)navigationController:(UINavigationController *)nav willShowViewController:(UIViewController *)vc animated:(BOOL)animated
{
    BOOL toolbar = [vc isKindOfClass:WQDirViewController.class] && [(WQDirViewController *)vc wq_wantsToolbar];
    [nav setToolbarHidden:!toolbar animated:animated];
    NSUInteger depth = [nav.viewControllers indexOfObject:vc];
    if (depth == NSNotFound || depth < 2) {
        if (vc.navigationItem.leftBarButtonItem.tag == 0x484f4d45) vc.navigationItem.leftBarButtonItem = nil;
        return;
    }
    if (vc.navigationItem.leftBarButtonItem) return;
    UIBarButtonItem *home = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"house"]
                                                             style:UIBarButtonItemStylePlain target:self action:@selector(goHome)];
    home.tag = 0x484f4d45;   // "HOME"
    home.accessibilityLabel = WQLocalizedNullable(@"Home");
    vc.navigationItem.leftItemsSupplementBackButton = YES;
    vc.navigationItem.leftBarButtonItem = home;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer != self.interactivePopGestureRecognizer) return YES;
    if (self.viewControllers.count <= 1) return NO;
    UIViewController<WQUnsavedEditing> *editor = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    if (![editor conformsToProtocol:@protocol(WQUnsavedEditing)] || !editor.wq_needsLeaveConfirmation) return YES;
    __weak typeof(self) weakSelf = self;
    [editor confirmLeaveThen:^{ [weakSelf popViewControllerAnimated:YES]; }];
    return NO;
}

- (void)goHome
{
    UIViewController<WQUnsavedEditing> *top = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    __weak typeof(self) weakSelf = self;
    void (^home)(void) = ^{ [weakSelf popToRootViewControllerAnimated:YES]; };
    if ([top conformsToProtocol:@protocol(WQUnsavedEditing)]) [top confirmLeaveThen:home];
    else home();
}

@end

#pragma mark - Root

#pragma mark - Recently Deleted

// Backed-up files whose original is gone (WQTrash): view, restore to where
// they were, or delete them from Backups for good.
@interface WQRecentlyDeletedViewController : UITableViewController
@end

@implementation WQRecentlyDeletedViewController {
    NSArray<WQDeletedItem *> *_items;
    NSString *_problem;   // Backups could not be read (completely)
    NSDictionary<NSString *, NSString *> *_places;   // original path -> "App · folder"
    BOOL _loading;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"Recently Deleted");
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(load) forControlEvents:UIControlEventValueChanged];
    [self load];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (_items) [self load];
}

// "App · Library/Preferences": the app owning the container, and the folder
// inside it.
static NSString *wq_deleted_place(NSString *original)
{
    NSArray<NSString *> *parts = original.stringByDeletingLastPathComponent.pathComponents;
    NSUInteger containersAt = [parts indexOfObject:@"Containers"];
    if (containersAt == NSNotFound) containersAt = [parts indexOfObject:@"containers"];
    if (containersAt != NSNotFound && parts.count > containersAt + 3) {
        NSString *container = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, containersAt + 4)]];
        NSString *bid = wq_container_label(container);
        NSString *app = wq_display_name(bid) ?: bid ?: container.lastPathComponent;
        NSArray *inside = [parts subarrayWithRange:NSMakeRange(containersAt + 4, parts.count - containersAt - 4)];
        return inside.count ? [NSString stringWithFormat:@"%@ · %@", app, [inside componentsJoinedByString:@"/"]] : app;
    }
    return original.stringByDeletingLastPathComponent;
}

- (void)load
{
    if (_loading) return;
    _loading = YES;
    if (!_items) [self.tableView reloadData];
    dispatch_async(wq_io(), ^{
        NSString *problem = nil;
        NSArray<WQDeletedItem *> *items = wq_recently_deleted_checked(&problem) ?: @[];
        NSMutableDictionary *places = [NSMutableDictionary new];
        for (WQDeletedItem *item in items) places[item.originalPath] = wq_deleted_place(item.originalPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_loading = NO;
            self->_items = items;
            self->_problem = problem;
            self->_places = places;
            [self.refreshControl endRefreshing];
            [self.tableView reloadData];
            [self updateButtons];
        });
    });
}

- (void)updateButtons
{
    if (!_items.count || !wq_deleting_allowed()) { self.navigationItem.rightBarButtonItem = nil; return; }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Delete Backups…")
        style:UIBarButtonItemStylePlain target:self action:@selector(confirmDeleteAll)];
    self.navigationItem.rightBarButtonItem.tintColor = UIColor.systemRedColor;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _items.count ? (NSInteger)_items.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    NSString *text = WQLocalized(@"Restore returns a file to its original location. Delete Backup removes the selected copy. Older copies may still be available.");
    return _problem && _items.count ? [NSString stringWithFormat:@"%@\n\n%@", _problem, text] : text;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"d"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"d"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (!_items.count) {
        c.text = !_items ? WQLocalized(@"Looking through Backups…") : _problem ?: WQLocalized(@"Nothing deleted");
        c.textProperties.color = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        WQDeletedItem *item = _items[(NSUInteger)indexPath.row];
        c.text = item.originalPath.lastPathComponent;
        c.image = [UIImage systemImageNamed:@"doc"];
        NSString *when = [NSDateFormatter localizedStringFromDate:item.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
        c.secondaryText = [NSString stringWithFormat:@"%@\n%@ · %@", _places[item.originalPath] ?: @"", when, wq_size_text(item.size)];
        c.secondaryTextProperties.numberOfLines = 2;
        c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _items.count) return;
    wq_open_file(self.navigationController, _items[(NSUInteger)indexPath.row].backupPath, YES, WQOpenAuto);
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= _items.count) return nil;
    WQDeletedItem *item = _items[(NSUInteger)indexPath.row];
    NSMutableArray *actions = [NSMutableArray new];
    if (wq_deleting_allowed()) {
        UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
            title:WQLocalizedNullable(@"Delete") handler:^(UIContextualAction *__unused a, UIView *__unused v, void (^done)(BOOL)) {
            done(NO);
            [self confirmDelete:@[item]];
        }];
        [actions addObject:del];
    }
    UIContextualAction *restore = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:WQLocalizedNullable(@"Restore") handler:^(UIContextualAction *__unused a, UIView *__unused v, void (^done)(BOOL)) {
        done(NO);
        [self restore:item];
    }];
    restore.backgroundColor = UIColor.systemBlueColor;
    [actions addObject:restore];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:actions];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if ((NSUInteger)indexPath.row >= _items.count) return nil;
    WQDeletedItem *item = _items[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        NSMutableArray *actions = [NSMutableArray arrayWithObjects:
            [UIAction actionWithTitle:WQLocalizedNullable(@"Restore") image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                           identifier:nil handler:^(UIAction *__unused a) { [weakSelf restore:item]; }],
            [UIAction actionWithTitle:WQLocalizedNullable(@"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                           identifier:nil handler:^(UIAction *__unused a) {
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (weakSelf) wq_share(weakSelf, item.backupPath, cell);
            }],
            [UIAction actionWithTitle:WQLocalizedNullable(@"Copy Original Path") image:[UIImage systemImageNamed:@"doc.on.doc"]
                           identifier:nil handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = item.originalPath; }],
            nil];
        if (wq_deleting_allowed()) {
            UIAction *del = [UIAction actionWithTitle:WQLocalizedNullable(@"Delete Backup…") image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *__unused a) { [weakSelf confirmDelete:@[item]]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:del];
        }
        return [UIMenu menuWithChildren:actions];
    }];
}

- (void)restore:(WQDeletedItem *)item
{
    UIAlertController *alert = wq_alert_controller(@"Restore", WQLocalizedFormat(@"Put %@ back in\n%@?",
        item.originalPath.lastPathComponent, item.originalPath.stringByDeletingLastPathComponent), UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Restore", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        dispatch_async(wq_io(), ^{
            NSString *error = nil;
            BOOL ok = wq_restore_deleted(item, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) wq_alert(self, @"Restore failed", error ?: @"?");
                [self load];
            });
        });
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteAll { [self confirmDelete:_items]; }

// Deletes the backup units holding these files. A deleted folder's files
// share one unit, so the message says when more goes with it.
- (void)confirmDelete:(NSArray<WQDeletedItem *> *)items
{
    if (!items.count || !wq_deleting_allowed()) return;
    NSMutableOrderedSet<NSString *> *units = [NSMutableOrderedSet new];
    NSUInteger files = 0;
    for (WQDeletedItem *item in items) if (![units containsObject:item.unitPath]) { [units addObject:item.unitPath]; files += item.unitFileCount; }
    NSString *message = items.count == 1 && files == 1
        ? WQLocalizedFormat(@"This removes the selected backup of %@. Older copies may still be available.", items.firstObject.originalPath.lastPathComponent)
        : WQLocalizedFormat(@"This removes %lu backed-up files, including other files in the selected backups. Older copies may still be available.", (unsigned long)files);
    UIAlertController *alert = wq_alert_controller(@"Delete backup?", message, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Delete", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        NSArray *paths = units.array;
        dispatch_async(wq_io(), ^{
            NSMutableArray *failed = [NSMutableArray new];
            for (NSString *unit in paths) {
                NSString *error = nil;
                if (!wq_delete_backup(unit, &error)) [failed addObject:[NSString stringWithFormat:@"%@: %@", unit.lastPathComponent, error ?: @"?"]];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (failed.count) wq_alert(self, @"Not everything was deleted", [failed componentsJoinedByString:@"\n"]);
                [self load];
            });
        });
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface WQHealthViewController : UITableViewController
- (instancetype)initWithChecks:(NSArray<WQHealthCheck *> *)checks;
@property (nonatomic, copy, nullable) void (^onPassed)(NSArray<WQHealthCheck *> *checks);
@end

@interface WQRootViewController : UITableViewController
@end

static NSString *const kWQLanguagePref = @"WQLanguage";

// The language picked in WQ Files, or nil for the device's.
static NSString *wq_chosen_language(void)
{
    NSString *code = [NSUserDefaults.standardUserDefaults stringForKey:kWQLanguagePref];
    return code.length ? code : nil;
}

// Each language in its own name, so it can be found whatever is shown now.
static NSString *wq_language_name(NSString *code)
{
    if (!code.length) return WQLocalized(@"System Default");
    // A regional table (pt-BR) is named with its region: "Português (Brasil)".
    NSLocale *own = [NSLocale localeWithLocaleIdentifier:code];
    NSString *name = [code containsString:@"-"] && ![code isEqualToString:@"zh-Hans"]
        ? [own localizedStringForLocaleIdentifier:code] : [own localizedStringForLanguageCode:code];
    if ([code isEqualToString:@"zh-Hans"]) name = @"简体中文";
    return name.length ? [[name substringToIndex:1].uppercaseString stringByAppendingString:[name substringFromIndex:1]] : code;
}

// A flag for each shipped language, drawn as an image so the names line up.
// Languages are spoken in many countries; the flag is the usual pick for
// language menus (English: UK, Arabic: Saudi Arabia, Portuguese: Brazil as
// shipped). System Default gets a globe.
static UIImage *wq_language_flag(NSString *code)
{
    if (!code.length) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        return [UIImage systemImageNamed:@"globe" withConfiguration:cfg];
    }
    static NSDictionary<NSString *, NSString *> *regions;
    static NSCache *images;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regions = @{ @"en": @"GB", @"de": @"DE", @"it": @"IT", @"es": @"ES", @"pt-BR": @"BR", @"pl": @"PL",
                     @"ru": @"RU", @"ko": @"KR", @"zh-Hans": @"CN", @"ar": @"SA", @"tr": @"TR", @"th": @"TH" };
        images = [NSCache new];
    });
    NSString *region = regions[code];
    if (!region) region = [[NSLocale localeWithLocaleIdentifier:code] objectForKey:NSLocaleCountryCode];
    if (region.length != 2) return nil;
    UIImage *cached = [images objectForKey:region];
    if (cached) return cached;
    // Regional indicator symbols: A = U+1F1E6.
    NSMutableString *flag = [NSMutableString new];
    for (NSUInteger i = 0; i < 2; i++) {
        UTF32Char scalar = 0x1F1E6 + ([region.uppercaseString characterAtIndex:i] - 'A');
        UTF32Char be = NSSwapHostIntToBig(scalar);
        [flag appendString:[[NSString alloc] initWithBytes:&be length:4 encoding:NSUTF32BigEndianStringEncoding]];
    }
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:24] };
    CGSize size = [flag sizeWithAttributes:attrs];
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [flag drawAtPoint:CGPointZero withAttributes:attrs];
    }];
    [images setObject:image forKey:region];
    return image;
}

// iOS only offers Settings → WQ Files → Language when the device has more
// than one preferred language, so WQ Files has its own list, built from the
// languages the app ships. The choice is this app's AppleLanguages default,
// which iOS applies at launch (text and right-to-left layout alike), so it
// takes effect when WQ Files restarts.
@interface WQLanguageViewController : UITableViewController
@end

@implementation WQLanguageViewController {
    NSArray<NSString *> *_codes;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = WQLocalized(@"Language");
        // localizations can name a language twice (the .lproj folder and the
        // CFBundleLocalizations entry, sometimes spelled differently): one
        // row per language.
        NSMutableArray *codes = [NSMutableArray new];
        NSMutableSet *seen = [NSMutableSet new];
        for (NSString *code in NSBundle.mainBundle.localizations) {
            NSString *canonical = [NSLocale canonicalLanguageIdentifierFromString:code];
            if ([code isEqualToString:@"Base"] || [seen containsObject:canonical]) continue;
            [seen addObject:canonical];
            [codes addObject:code];
        }
        [codes sortUsingComparator:^NSComparisonResult(NSString *x, NSString *y) {
            return [wq_language_name(x) localizedCaseInsensitiveCompare:wq_language_name(y)];
        }];
        _codes = codes;
    }
    return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : (NSInteger)_codes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 1 ? WQLocalized(@"The new language is used the next time WQ Files starts.") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"l"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"l"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    NSString *code = indexPath.section == 0 ? @"" : _codes[(NSUInteger)indexPath.row];
    c.text = wq_language_name(code);
    c.image = wq_language_flag(code);
    c.imageProperties.reservedLayoutSize = CGSizeMake(34, 0);
    if (!code.length) c.imageProperties.tintColor = UIColor.secondaryLabelColor;
    // Like iOS: each language in its own name, and in the one shown now.
    NSString *shownLanguage = NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en";
    if (code.length) {
        NSLocale *shown = [NSLocale localeWithLocaleIdentifier:shownLanguage];
        NSString *here = [code containsString:@"-"] && ![code isEqualToString:@"zh-Hans"]
            ? [shown localizedStringForLocaleIdentifier:code] : [shown localizedStringForLanguageCode:code];
        if (here.length && [here localizedCaseInsensitiveCompare:c.text] != NSOrderedSame) c.secondaryText = here;
    } else {
        NSString *device = [NSLocale preferredLanguages].firstObject;
        if (device.length) c.secondaryText = [[NSLocale localeWithLocaleIdentifier:shownLanguage] localizedStringForLanguageCode:device];
    }
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = c;
    cell.accessoryType = [code isEqualToString:wq_chosen_language() ?: @""] ? UITableViewCellAccessoryCheckmark
                                                                          : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *code = indexPath.section == 0 ? @"" : _codes[(NSUInteger)indexPath.row];
    if ([code isEqualToString:wq_chosen_language() ?: @""]) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (code.length) {
        [defaults setObject:code forKey:kWQLanguagePref];
        [defaults setObject:@[code] forKey:@"AppleLanguages"];
    } else {
        [defaults removeObjectForKey:kWQLanguagePref];
        [defaults removeObjectForKey:@"AppleLanguages"];
    }
    [tableView reloadData];
    UIAlertController *restart = wq_alert_controller(@"Restart WQ Files",
        @"The new language is used the next time WQ Files starts.", UIAlertControllerStyleAlert);
    [restart addAction:wq_alert_action(@"Later", UIAlertActionStyleCancel, nil)];
    [restart addAction:wq_alert_action(@"Quit Now", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [NSUserDefaults.standardUserDefaults synchronize];
        exit(0);
    })];
    [self presentViewController:restart animated:YES completion:nil];
}

@end

@interface WQFavoritesViewController : UITableViewController
@end

@implementation WQFavoritesViewController {
    NSArray<NSDictionary *> *_favorites;
}

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.title = WQLocalized(@"Favorites");
    [self reloadFavorites];
}

- (void)reloadFavorites
{
    _favorites = wq_favorites();
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)_favorites.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return _favorites.count ? nil : WQLocalized(@"Add a folder from its More menu.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *favorite = _favorites[(NSUInteger)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"favorite"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"favorite"];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = favorite[@"title"];
    content.secondaryText = favorite[@"path"];
    content.image = [UIImage systemImageNamed:@"star"];
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *favorite = _favorites[(NSUInteger)indexPath.row];
    NSString *path = favorite[@"path"];
    dispatch_async(wq_io(), ^{
        struct stat st;
        BOOL directory = wq_stat(path, &st) && S_ISDIR(st.st_mode);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.navigationController.topViewController != self) return;
            if (!directory) { wq_alert(self, @"Not found", WQVerbatim(path)); return; }
            WQDirViewController *folder = [[WQDirViewController alloc] initWithPath:path title:favorite[@"title"]];
            folder.readOnly = [favorite[@"readOnly"] boolValue];
            [self.navigationController pushViewController:folder animated:YES];
        });
    });
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *path = _favorites[(NSUInteger)indexPath.row][@"path"];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:WQLocalized(@"Remove from Favorites") handler:^(UIContextualAction *__unused action, UIView *__unused view, void (^completion)(BOOL)) {
            wq_set_favorite(path, nil, NO, NO);
            completion(YES);
            [self reloadFavorites];
        }];
    remove.backgroundColor = UIColor.systemGrayColor;
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

@end

@implementation WQRootViewController {
    NSArray<NSArray<NSString *> *> *_locations;  // title, path, symbol
    // Kept between visits so Apps and the Cache Cleaner show their last list
    // right away instead of scanning every container again.
    WQAppsViewController *_apps;
    WQCacheCleanerViewController *_cacheCleaner;
    BOOL _checkingAccess;
    // A failed startup check waits here until the start screen is in front
    // with nothing presented over it.
    NSArray<WQHealthCheck *> *_pendingHealthFailure;
    BOOL _healthRetryScheduled;
    NSDictionary *_reopenFolder;   // the last folder, opened once the startup check passed
    NSString *_availableVersion;   // a newer release on GitHub
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    if (!_apps.parentViewController) _apps = nil;
    if (!_cacheCleaner.parentViewController) _cacheCleaner = nil;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = WQLocalizedNullable(@"WQ Files");
        [self rebuildLocations];
    }
    return self;
}

- (void)rebuildLocations
{
    {
        _locations = @[
            @[@"App Data", @"/private/var/mobile/Containers/Data/Application", @"square.grid.2x2"],
            @[@"App Groups", @"/private/var/mobile/Containers/Shared/AppGroup", @"square.stack.3d.up"],
            @[@"Extension Data", @"/private/var/mobile/Containers/Data/PluginKitPlugin", @"puzzlepiece.extension"],
            @[@"Internal Daemons", @"/private/var/mobile/Containers/Data/InternalDaemon", @"gearshape.2"],
        ];
        // Bundle containers open on some iOS versions only (found by the
        // startup check); System Data on iOS 27.
        if (wq_app_bundles_reachable())
            _locations = [_locations arrayByAddingObject:@[@"App Bundles", @"/private/var/containers/Bundle/Application", @"app.badge"]];
        if (wq_system_areas_reachable())
            _locations = [_locations arrayByAddingObject:@[@"System Data", @"/private/var/containers/Data/System", @"cpu"]];
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.tableFooterView = [self authorFooter];
    dispatch_async(wq_io(), ^{
        NSString *recovery = wq_recover_interrupted_restore();
        if (recovery) {
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_alert(self, @"Restore recovery", recovery);
            });
        }
        (void)wq_app_group();   // resolves (and logs) the group off the main thread
    });
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // The Language row shows the choice made in the language list.
    if (self.isViewLoaded && self.tableView.numberOfSections > 2)
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:3 inSection:2]] withRowAnimation:UITableViewRowAnimationNone];
}

// The startup check (WQHealth), once the start screen is on screen: it runs
// in the background so nothing waits for it, and browsing stays possible. A
// failure covers the app with WQHealthViewController once the user is back
// on the start screen with nothing open over it (never over an action, a
// confirmation or a progress sheet); warnings are shown once per build.
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self presentPendingHealthFailure];
    static BOOL checked;
    if (checked) {
        // Back on the start screen: nothing to reopen next time.
        _reopenFolder = nil;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQLastFolderPref];
        return;
    }
    checked = YES;
    NSDictionary *last = [NSUserDefaults.standardUserDefaults dictionaryForKey:kWQLastFolderPref];
    if (![NSUserDefaults.standardUserDefaults boolForKey:kWQReopenOffPref] && [last[@"path"] isKindOfClass:NSString.class])
        _reopenFolder = last;
    [self checkForUpdate];
    _checkingAccess = YES;
    // A spinner in the bar while it runs: unlike a text row, it doesn't move
    // the list when it goes away.
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithFrame:CGRectZero];
    [spinner sizeToFit];
    [spinner startAnimating];
    spinner.accessibilityLabel = WQLocalized(@"Checking access…");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WQHealthCheck *> *checks = wq_health_run(nil);
        dispatch_async(dispatch_get_main_queue(), ^{ [self healthCheckFinished:checks]; });
    });
}

- (void)healthCheckFinished:(NSArray<WQHealthCheck *> *)checks
{
    _checkingAccess = NO;
    self.navigationItem.rightBarButtonItem = nil;
    [self rebuildLocations];   // App Bundles depends on the result
    [self.tableView reloadData];
    WQHealthState worst = wq_health_worst(checks);
    if (worst < WQHealthFailed) [self reopenLastFolder];
    else _reopenFolder = nil;
    if (worst == WQHealthWarning) { [self showHealthWarnings:checks]; return; }
    if (worst < WQHealthFailed) return;
    _pendingHealthFailure = checks;
    [self presentPendingHealthFailure];
}

// Reopens the folder that was in front when WQ Files was last used, but only
// after the startup check passed and while the start screen is still idle
// (if the user already went somewhere, they're not interrupted).
- (void)reopenLastFolder
{
    NSDictionary *last = _reopenFolder;
    _reopenFolder = nil;
    if (!last) return;
    NSString *path = last[@"path"];
    dispatch_async(wq_io(), ^{
        struct stat st;
        BOOL folder = wq_stat(path, &st) && S_ISDIR(st.st_mode);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!folder) { wq_log(@"reopen: %@ is gone", path); return; }
            if (![self healthFailureCanPresent]) return;
            WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:path
                title:[last[@"title"] isKindOfClass:NSString.class] ? last[@"title"] : path.lastPathComponent];
            dir.readOnly = [last[@"readOnly"] boolValue];
            [self.navigationController pushViewController:dir animated:YES];
        });
    });
}

// Check for Updates: at most every 12 hours, one request for the public
// source.json on GitHub (no data about the device is sent). A newer version
// shows a banner at the top of the start screen.
- (void)checkForUpdate
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kWQUpdateCheckOffPref]) return;
    NSDate *last = [defaults objectForKey:kWQUpdateCheckedPref];
    NSString *known = [defaults stringForKey:@"WQUpdateAvailable"];
    NSString *mine = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
    if (known.length && [known compare:mine options:NSNumericSearch] == NSOrderedDescending) [self showUpdateBanner:known];
    if ([last isKindOfClass:NSDate.class] && -last.timeIntervalSinceNow < 12 * 3600) return;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 15;
    config.HTTPCookieStorage = nil;
    NSURL *url = [NSURL URLWithString:@"https://raw.githubusercontent.com/kolbicz/WQFiles/main/source.json"];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sessionWithConfiguration:config] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status != 200 || data.length > 1024 * 1024) {
            wq_log(@"update check: failed (%@)", error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status]);
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id apps = [json isKindOfClass:NSDictionary.class] ? json[@"apps"] : nil;
        id app = [apps isKindOfClass:NSArray.class] && [apps count] ? [apps firstObject] : nil;
        id version = [app isKindOfClass:NSDictionary.class] ? app[@"version"] : nil;
        if (![version isKindOfClass:NSString.class] || [version length] > 20) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [defaults setObject:NSDate.date forKey:kWQUpdateCheckedPref];
            [defaults setObject:version forKey:@"WQUpdateAvailable"];
            BOOL newer = [version compare:mine options:NSNumericSearch] == NSOrderedDescending;
            wq_log(@"update check: latest %@, this is %@%@", version, mine, newer ? @" (update available)" : @"");
            if (newer) [weakSelf showUpdateBanner:version];
        });
    }] resume];
}

- (void)showUpdateBanner:(NSString *)version
{
    if ([_availableVersion isEqualToString:version]) return;
    _availableVersion = version;
    UIButtonConfiguration *config = [UIButtonConfiguration tintedButtonConfiguration];
    config.title = WQLocalizedFormat(@"WQ Files %@ is available", version);
    config.image = [UIImage systemImageNamed:@"arrow.down.circle"];
    config.imagePadding = 8;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/kolbicz/WQFiles/releases/latest"]
                                         options:@{} completionHandler:nil];
    }]];
    CGFloat width = self.tableView.bounds.size.width ?: self.view.bounds.size.width;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 60)];
    button.frame = CGRectMake(16, 8, width - 32, 44);
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [box addSubview:button];
    self.tableView.tableHeaderView = box;
}

// Idle: the start screen is the visible screen, the app is active and
// nothing (alert, sheet, scan window) is presented.
- (BOOL)healthFailureCanPresent
{
    UIViewController *host = self.navigationController ?: self;
    if (!self.view.window || host.presentedViewController) return NO;
    if (self.navigationController && self.navigationController.topViewController != self) return NO;
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (void)presentPendingHealthFailure
{
    NSArray<WQHealthCheck *> *checks = _pendingHealthFailure;
    if (!checks) return;
    if (![self healthFailureCanPresent]) {
        static BOOL logged;
        if (!logged) {
            logged = YES;
            wq_log(@"health: check failed; the result is shown when the start screen is back in front");
        }
        if (_healthRetryScheduled) return;
        _healthRetryScheduled = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_healthRetryScheduled = NO;
            [strongSelf presentPendingHealthFailure];
        });
        return;
    }
    _pendingHealthFailure = nil;
    WQHealthViewController *health = [[WQHealthViewController alloc] initWithChecks:checks];
    __weak typeof(self) weakSelf = self;
    health.onPassed = ^(NSArray<WQHealthCheck *> *passed) {
        [weakSelf rebuildLocations];
        [weakSelf.tableView reloadData];
        if (wq_health_worst(passed) == WQHealthWarning) [weakSelf showHealthWarnings:passed];
    };
    WQNavigationController *nav = [[WQNavigationController alloc] initWithRootViewController:health];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.modalInPresentation = YES;
    [(self.navigationController ?: self) presentViewController:nav animated:YES completion:nil];
}

// Each set of warnings once per build, so the same notice doesn't repeat on
// every launch.
- (void)showHealthWarnings:(NSArray<WQHealthCheck *> *)checks
{
    NSMutableArray *lines = [NSMutableArray new];
    for (WQHealthCheck *c in checks)
        if (c.state == WQHealthWarning) [lines addObject:[NSString stringWithFormat:@"%@: %@", c.title, c.detail]];
    NSString *text = [lines componentsJoinedByString:@"\n\n"];
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"], text];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([[defaults stringForKey:@"WQHealthWarned"] isEqualToString:key]) return;
    [defaults setObject:key forKey:@"WQHealthWarned"];
    UIAlertController *alert = wq_alert_controller(@"Not everything works here", text, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleCancel, nil)];
    UIViewController *host = self.navigationController ?: self;
    while (host.presentedViewController) host = host.presentedViewController;
    [host presentViewController:alert animated:YES completion:nil];
}

// "by kolbicz" with GitHub and X links, under the last section.
- (UIView *)authorFooter
{
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 128)];
    UILabel *by = [UILabel new];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    by.text = WQLocalizedFormat(@"WQ Files %@ (%@) by kolbicz",
               info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?");
    by.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    by.textColor = UIColor.secondaryLabelColor;

    UIButton *(^link)(NSString *, NSString *, NSString *) = ^UIButton *(NSString *title, NSString *symbol, NSString *url) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
        cfg.title = title;
        cfg.image = [UIImage systemImageNamed:symbol];
        cfg.imagePadding = 6;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.buttonSize = UIButtonConfigurationSizeSmall;
        return [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
        }]];
    };
    UIStackView *links = [[UIStackView alloc] initWithArrangedSubviews:@[
        link(@"GitHub", @"chevron.left.forwardslash.chevron.right", @"https://github.com/kolbicz"),
        link(@"@_kolbicz", @"at", @"https://x.com/_kolbicz"),
    ]];
    links.spacing = 12;

    UIButtonConfiguration *creditCfg = [UIButtonConfiguration plainButtonConfiguration];
    creditCfg.attributedTitle = [[NSAttributedString alloc] initWithString:WQLocalized(@"Sandbox escape: worse_query by @forcequitOS")
        attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]}];
    creditCfg.buttonSize = UIButtonConfigurationSizeSmall;
    UIButton *credit = [UIButton buttonWithConfiguration:creditCfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://x.com/forcequitOS"] options:@{} completionHandler:nil];
    }]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[by, links, credit]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
    ]];
    return footer;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // System Groups is the extra last row, on iOS 27 only.
    if (section == 2) return 6;
    return section == 0 ? (NSInteger)_locations.count + (wq_system_areas_reachable() ? 1 : 0) : 8;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? WQLocalized(@"Containers") : section == 1 ? WQLocalized(@"Tools") : WQLocalized(@"Settings");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 && !wq_system_areas_reachable())
        return WQLocalized(@"On iOS 26, System Data and System Groups can't be reached (worse_query covers them on iOS 27 only), and Internal Daemons need a scan of every file id: the first one can take most of an hour on a well-used device, later ones only check new files.");
    if (section == 2)
        return [NSString stringWithFormat:@"%@\n\n%@",
                WQLocalized(@"Allow Deleting: when off, nothing can be deleted: no Delete or swipe to delete in folders and backups, no Clear Data in Apps and no cleaning in the Cache Cleaner. Saving, moving and restoring still work.\n\nShow Item Counts: shows how many items each folder holds. Every subfolder has to be listed for this, which slows down folders with many subfolders, especially in other apps' data."),
                [NSString stringWithFormat:@"%@\n\n%@", WQLocalized(@"Keep Data Before Restore: restoring an app or file backup first backs up what's there now, so a failed restore can be undone. When off, that backup is deleted once the restore succeeded."),
                 WQLocalized(@"Reopen Last Folder: WQ Files starts in the folder you were in. Check for Updates: twice a day WQ Files reads the public release list on GitHub and shows a note when a new version is out; nothing about your device is sent.")]];
    return section == 1
        ? WQLocalized(@"Overwritten and deleted files are copied to Backups first (also visible in the Files app). Long-press a backup to restore it.")
        : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"r"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"r"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (indexPath.section == 2 && indexPath.row == 3) {
        UIListContentConfiguration *v = [UIListContentConfiguration valueCellConfiguration];
        v.text = WQLocalized(@"Language");
        v.image = [UIImage systemImageNamed:@"globe"];
        v.secondaryText = wq_language_name(wq_chosen_language());
        cell.contentConfiguration = v;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (indexPath.section == 2) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        NSInteger row = indexPath.row;
        // Rows 0-2 and 4-5 are switches; row 3 is Language (above).
        NSUInteger index = (NSUInteger)(row > 3 ? row - 1 : row);
        c.text = WQLocalized(@[@"Allow Deleting", @"Show Item Counts", @"Keep Data Before Restore", @"Reopen Last Folder", @"Check for Updates"][index]);
        c.image = [UIImage systemImageNamed:@[@"trash.slash", @"number", @"clock.arrow.circlepath", @"arrow.uturn.forward", @"arrow.down.circle"][index]];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        UISwitch *toggle = [UISwitch new];
        toggle.on = row == 1 ? wq_show_item_counts() : row == 2 ? wq_keep_before_restore()
                  : row == 4 ? ![defaults boolForKey:kWQReopenOffPref] : row == 5 ? ![defaults boolForKey:kWQUpdateCheckOffPref]
                  : wq_deleting_allowed();
        [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
            BOOL on = ((UISwitch *)action.sender).isOn;
            if (row == 1) [defaults setBool:on forKey:kWQShowItemCountsPref];
            else if (row == 2) wq_set_keep_before_restore(on);
            else if (row == 4) { [defaults setBool:!on forKey:kWQReopenOffPref]; if (!on) [defaults removeObjectForKey:kWQLastFolderPref]; }
            else if (row == 5) [defaults setBool:!on forKey:kWQUpdateCheckOffPref];
            else wq_set_deleting_allowed(on);
        }] forControlEvents:UIControlEventValueChanged];
        cell.contentConfiguration = c;
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            c.text = WQLocalizedNullable(loc[0]);
            c.image = [UIImage systemImageNamed:loc[2]];
        } else {
            c.text = WQLocalizedNullable(@"System Groups");
            c.image = [UIImage systemImageNamed:@"lock.square.stack"];
        }
    } else {
        NSArray *tools = @[@[@"Apps", @"square.grid.3x3"], @[@"Cache Cleaner", @"trash"], @[@"Go to Path…", @"arrow.right.circle"],
                           @[@"App Backups", @"clock.arrow.circlepath"], @[@"Backups", @"clock.arrow.circlepath"],
                           @[@"Recently Deleted", @"trash.circle"], @[@"Log", @"doc.plaintext"], @[@"Favorites", @"star"]];
        c.text = WQLocalizedNullable(tools[(NSUInteger)indexPath.row][0]);
        c.image = [UIImage systemImageNamed:tools[(NSUInteger)indexPath.row][1]];
    }
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2 && indexPath.row == 3) {
        [self.navigationController pushViewController:[WQLanguageViewController new] animated:YES];
        return;
    }
    if (indexPath.section == 2) return;
    UIViewController *next = nil;
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            next = [[WQDirViewController alloc] initWithPath:loc[1] title:loc[0]];
        } else {
            next = [WQSystemGroupsViewController new];
        }
    } else if (indexPath.row == 0) {
        if (!_apps || _apps.parentViewController) _apps = [WQAppsViewController new];
        next = _apps;
    } else if (indexPath.row == 1) {
        if (!_cacheCleaner || _cacheCleaner.parentViewController) _cacheCleaner = [WQCacheCleanerViewController new];
        next = _cacheCleaner;
    } else if (indexPath.row == 2) {
        [self goToPath];
        return;
    } else if (indexPath.row == 3) {
        [NSFileManager.defaultManager createDirectoryAtPath:wq_app_backup_root() withIntermediateDirectories:YES attributes:nil error:nil];
        next = [[WQDirViewController alloc] initWithPath:wq_app_backup_root() title:WQLocalizedNullable(@"App Backups")];
    } else if (indexPath.row == 4) {
        [NSFileManager.defaultManager createDirectoryAtPath:wq_backup_root() withIntermediateDirectories:YES attributes:nil error:nil];
        next = [[WQDirViewController alloc] initWithPath:wq_backup_root() title:WQLocalizedNullable(@"Backups")];
    } else if (indexPath.row == 5) {
        next = [WQRecentlyDeletedViewController new];
    } else if (indexPath.row == 7) {
        next = [WQFavoritesViewController new];
    } else {
        next = [WQLogViewController new];
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (void)goToPath
{
    UIAlertController *alert = wq_alert_controller(@"Go to Path", @"A folder or file path", UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = UIPasteboard.generalPasteboard.hasStrings && [UIPasteboard.generalPasteboard.string hasPrefix:@"/"]
            ? UIPasteboard.generalPasteboard.string : @"/private/var/";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Open", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *path = alert.textFields.firstObject.text.stringByStandardizingPath;
        if (![path hasPrefix:@"/"]) return;
        dispatch_async(wq_io(), ^{
            struct stat st;
            BOOL exists = wq_stat(path, &st);
            BOOL isDir = exists && S_ISDIR(st.st_mode);
            if (exists && S_ISLNK(st.st_mode)) {
                struct stat target;
                isDir = stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!exists) {
                    wq_alert(self, @"Not found", path);
                    return;
                }
                if (!isDir) { wq_open_file(self.navigationController, path, NO, WQOpenAuto); return; }
                [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil]
                                                     animated:YES];
            });
        });
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - WQ Prism UI

// ---------------------------------------------------------------------------
// WQ Prism: the first UIKit layer of the redesign. The data and safety logic
// stays in the existing controllers; these views only present it.
// ---------------------------------------------------------------------------

static NSArray<UIColor *> *WQPrismTone(NSString *tone)
{
    if ([tone isEqualToString:@"violet"]) return @[[UIColor colorWithRed:0.71 green:0.61 blue:1.00 alpha:1], [UIColor colorWithRed:0.43 green:0.31 blue:0.91 alpha:1]];
    if ([tone isEqualToString:@"mint"])   return @[[UIColor colorWithRed:0.38 green:0.92 blue:0.80 alpha:1], [UIColor colorWithRed:0.04 green:0.67 blue:0.55 alpha:1]];
    if ([tone isEqualToString:@"amber"])  return @[[UIColor colorWithRed:1.00 green:0.84 blue:0.54 alpha:1], [UIColor colorWithRed:0.88 green:0.55 blue:0.09 alpha:1]];
    if ([tone isEqualToString:@"pink"])   return @[[UIColor colorWithRed:1.00 green:0.62 blue:0.80 alpha:1], [UIColor colorWithRed:0.87 green:0.23 blue:0.53 alpha:1]];
    if ([tone isEqualToString:@"sky"])    return @[[UIColor colorWithRed:0.54 green:0.85 blue:1.00 alpha:1], [UIColor colorWithRed:0.17 green:0.58 blue:0.91 alpha:1]];
    if ([tone isEqualToString:@"orange"]) return @[[UIColor colorWithRed:1.00 green:0.73 blue:0.49 alpha:1], [UIColor colorWithRed:0.89 green:0.42 blue:0.12 alpha:1]];
    if ([tone isEqualToString:@"indigo"]) return @[[UIColor colorWithRed:0.55 green:0.55 blue:1.00 alpha:1], [UIColor colorWithRed:0.26 green:0.25 blue:0.79 alpha:1]];
    if ([tone isEqualToString:@"gray"])   return @[[UIColor colorWithRed:0.67 green:0.71 blue:0.80 alpha:1], [UIColor colorWithRed:0.35 green:0.40 blue:0.49 alpha:1]];
    return @[[UIColor colorWithRed:0.50 green:0.65 blue:1.00 alpha:1], [UIColor colorWithRed:0.24 green:0.38 blue:0.90 alpha:1]];
}

@interface WQPrismGlassView : UIView
@property (nonatomic, readonly) UIView *contentView;
- (instancetype)initWithRadius:(CGFloat)radius;
@end

@implementation WQPrismGlassView {
    UIVisualEffectView *_effect;
}

- (instancetype)initWithRadius:(CGFloat)radius
{
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = radius;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.42 alpha:0.055];

        _effect = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        _effect.translatesAutoresizingMaskIntoConstraints = NO;
        _effect.userInteractionEnabled = NO;
        [self addSubview:_effect];
        [NSLayoutConstraint activateConstraints:@[
            [_effect.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_effect.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_effect.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_effect.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];

        _contentView = [UIView new];
        _contentView.translatesAutoresizingMaskIntoConstraints = NO;
        _contentView.backgroundColor = [UIColor clearColor];
        [self addSubview:_contentView];
        [NSLayoutConstraint activateConstraints:@[
            [_contentView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
        [self updateBorder];
    }
    return self;
}

- (void)updateBorder
{
    BOOL dark = self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight;
    CGFloat scale = self.traitCollection.displayScale;
    if (scale <= 0) scale = 3.0;
    self.layer.borderWidth = 1.0 / scale;
    self.layer.borderColor = [UIColor colorWithWhite:(dark ? 1.0 : 0.0) alpha:(dark ? 0.14 : 0.08)].CGColor;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self updateBorder];
}

@end

@interface WQPrismIconTile : UIView
- (instancetype)initWithSymbol:(NSString *)symbol tone:(NSString *)tone size:(CGFloat)size;
@end

@implementation WQPrismIconTile {
    CAGradientLayer *_gradient;
    UIImageView *_imageView;
}

- (instancetype)initWithSymbol:(NSString *)symbol tone:(NSString *)tone size:(CGFloat)size
{
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.userInteractionEnabled = NO;
        self.layer.cornerRadius = size * 0.29;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        NSArray<UIColor *> *colors = WQPrismTone(tone);
        _gradient = [CAGradientLayer layer];
        _gradient.startPoint = CGPointMake(0.0, 0.0);
        _gradient.endPoint = CGPointMake(1.0, 1.0);
        _gradient.colors = @[(id)colors[0].CGColor, (id)colors[1].CGColor];
        [self.layer addSublayer:_gradient];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size * 0.44
                                                                                         weight:UIImageSymbolWeightSemibold];
        _imageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:cfg]];
        _imageView.translatesAutoresizingMaskIntoConstraints = NO;
        _imageView.tintColor = UIColor.whiteColor;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_imageView];
        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintEqualToConstant:size],
            [self.heightAnchor constraintEqualToConstant:size],
            [_imageView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_imageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_imageView.widthAnchor constraintEqualToConstant:size * 0.60],
            [_imageView.heightAnchor constraintEqualToConstant:size * 0.60],
        ]];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    _gradient.frame = self.bounds;
}

@end

@interface WQPrismCardView : UIControl
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIButton *moreButton;
- (instancetype)initWithTitle:(NSString *)title
                         meta:(NSString *)meta
                       symbol:(NSString *)symbol
                         tone:(NSString *)tone
                      compact:(BOOL)compact;
@end

@implementation WQPrismCardView {
    WQPrismGlassView *_glass;
    WQPrismIconTile *_icon;
    UIImageView *_chevron;
}

- (instancetype)initWithTitle:(NSString *)title
                         meta:(NSString *)meta
                       symbol:(NSString *)symbol
                         tone:(NSString *)tone
                      compact:(BOOL)compact
{
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = compact ? 20 : 24;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _glass = [[WQPrismGlassView alloc] initWithRadius:compact ? 20 : 24];
        _glass.userInteractionEnabled = NO;
        [self addSubview:_glass];
        [NSLayoutConstraint activateConstraints:@[
            [_glass.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];

        _icon = [[WQPrismIconTile alloc] initWithSymbol:symbol tone:tone size:compact ? 30 : 36];
        [self addSubview:_icon];

        UIFont *titleFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
            scaledFontForFont:[UIFont systemFontOfSize:(compact ? 13.0 : 15.0) weight:UIFontWeightSemibold]];
        UIFont *metaFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
            scaledFontForFont:[UIFont systemFontOfSize:(compact ? 9.5 : 10.5) weight:UIFontWeightRegular]];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = titleFont;
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.textColor = UIColor.labelColor;
        _titleLabel.text = title;
        _titleLabel.numberOfLines = 1;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.userInteractionEnabled = NO;
        [self addSubview:_titleLabel];

        _metaLabel = [UILabel new];
        _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _metaLabel.font = metaFont;
        _metaLabel.adjustsFontForContentSizeCategory = YES;
        _metaLabel.textColor = UIColor.secondaryLabelColor;
        _metaLabel.text = meta;
        _metaLabel.numberOfLines = 1;
        _metaLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _metaLabel.userInteractionEnabled = NO;
        [self addSubview:_metaLabel];

        if (!compact) {
            _moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
            _moreButton.translatesAutoresizingMaskIntoConstraints = NO;
            [_moreButton setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
            _moreButton.tintColor = UIColor.tertiaryLabelColor;
            _moreButton.showsMenuAsPrimaryAction = YES;
            _moreButton.accessibilityLabel = WQLocalizedNullable(@"More");
            [self addSubview:_moreButton];

            _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
            _chevron.translatesAutoresizingMaskIntoConstraints = NO;
            _chevron.tintColor = UIColor.quaternaryLabelColor;
            _chevron.image = [_chevron.image imageFlippedForRightToLeftLayoutDirection];
            _chevron.userInteractionEnabled = NO;
            [self addSubview:_chevron];
        }

        CGFloat top = compact ? 10.0 : 13.0;
        CGFloat side = compact ? 11.0 : 13.0;
        [NSLayoutConstraint activateConstraints:@[
            [_icon.topAnchor constraintEqualToAnchor:self.topAnchor constant:top],
            [_icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:side],
            [_titleLabel.topAnchor constraintEqualToAnchor:_icon.bottomAnchor constant:(compact ? 8 : 11)],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:side],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-side],
            [_metaLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
            [_metaLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:side],
            [_metaLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-side],
            [self.heightAnchor constraintEqualToConstant:(compact ? 104 : 140)],
        ]];
        if (_moreButton) {
            [NSLayoutConstraint activateConstraints:@[
                [_moreButton.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],
                [_moreButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-5],
                [_moreButton.widthAnchor constraintEqualToConstant:30],
                [_moreButton.heightAnchor constraintEqualToConstant:30],
                [_chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-13],
                [_chevron.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
                [_chevron.widthAnchor constraintEqualToConstant:11],
                [_chevron.heightAnchor constraintEqualToConstant:11],
            ]];
        }

        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel = meta.length ? [NSString stringWithFormat:@"%@, %@", title, meta] : title;
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.16 animations:^{
        self.alpha = highlighted ? 0.82 : 1.0;
        self.transform = highlighted ? CGAffineTransformMakeScale(0.985, 0.985) : CGAffineTransformIdentity;
    }];
}

@end

static NSAttributedString *WQPrismButtonTitle(NSString *title)
{
    return [[NSAttributedString alloc] initWithString:title
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold]}];
}

static UIView *WQPrismSectionHeaderView(NSString *title, NSString *detail)
{
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.secondaryLabelColor;
    label.numberOfLines = 1;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;
    if (detail.length) {
        UILabel *right = [UILabel new];
        right.text = detail;
        right.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        right.textColor = UIColor.tertiaryLabelColor;
        right.textAlignment = NSTextAlignmentNatural;
        [row addArrangedSubview:right];
    }
    return row;
}

@interface WQPrismHomeViewController : UIViewController
@end

@interface WQPrismSettingsViewController : UITableViewController
@end

@interface WQPrismVaultViewController : UITableViewController
@end

static BOOL WQPrismScreenshotMode(void)
{
    return [NSProcessInfo.processInfo.arguments containsObject:@"-WQPrismScreenshot"];
}

@implementation WQPrismHomeViewController {
    NSArray<NSArray<NSString *> *> *_locations;
    UIScrollView *_scroll;
    UIStackView *_contentStack;
    UIStackView *_containersStack;
    UIStackView *_favoritesStack;
    UIStackView *_systemRows;
    UIView *_systemSection;
    UIView *_heroView;
    UIView *_updateBanner;
    UIView *_statusPill;
    UILabel *_statusLabel;
    UILabel *_heroSubtitle;
    UIButton *_quickButton;
    NSString *_appGroupName;
    BOOL _checkingAccess;
    NSArray<WQHealthCheck *> *_pendingHealthFailure;
    BOOL _healthRetryScheduled;
    NSDictionary *_reopenFolder;
    NSString *_availableVersion;
}

- (instancetype)init
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.title = WQLocalizedNullable(@"WQ Files");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;

    UIBarButtonItem *gear = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                                            style:UIBarButtonItemStylePlain
                                                           target:self
                                                           action:@selector(openSettings)];
    gear.accessibilityLabel = WQLocalizedNullable(@"Settings");
    self.navigationItem.rightBarButtonItem = gear;

    [self buildInterface];
    [self rebuildLocations];
    if (WQPrismScreenshotMode()) {
        NSMutableArray<NSArray<NSString *> *> *locations = [_locations mutableCopy];
        if (![locations containsObject:@[@"App Bundles", @"/private/var/containers/Bundle/Application", @"app.badge"]])
            [locations addObject:@[@"App Bundles", @"/private/var/containers/Bundle/Application", @"app.badge"]];
        if (![locations containsObject:@[@"System Data", @"/private/var/containers/Data/System", @"cpu"]])
            [locations addObject:@[@"System Data", @"/private/var/containers/Data/System", @"cpu"]];
        _locations = locations;
        _appGroupName = @"group.cz.kolbi.wqfiles";
    }
    [self rebuildContainers];
    [self rebuildFavorites];
    [self rebuildSystem];
    [self updateHealthUI];

    if (!WQPrismScreenshotMode()) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(wq_io(), ^{
            NSString *recovery = wq_recover_interrupted_restore();
            if (recovery) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    wq_alert(weakSelf, @"Restore recovery", recovery);
                });
            }
            NSString *group = wq_app_group();
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf->_appGroupName = group;
                [strongSelf updateHealthUI];
            });
        });
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.tabBarController.tabBar.hidden = NO;
    [self rebuildFavorites];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (WQPrismScreenshotMode()) {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        __weak typeof(self) weakSelf = self;
        if ([arguments containsObject:@"-WQPrismSettings"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf openSettings];
            });
        } else if ([arguments containsObject:@"-WQPrismFolder"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                [weakSelf openPath:documents ?: @"/private/var/mobile/Containers/Data/Application"
                             title:WQLocalizedNullable(@"App Data")];
            });
        } else if ([arguments containsObject:@"-WQPrismBottom"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                CGFloat bottom = MAX(0, strongSelf->_scroll.contentSize.height - strongSelf->_scroll.bounds.size.height + 104);
                [strongSelf->_scroll setContentOffset:CGPointMake(0, bottom) animated:NO];
            });
        }
        return;
    }
    [self presentPendingHealthFailure];
    static BOOL checked;
    if (checked) {
        _reopenFolder = nil;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQLastFolderPref];
        return;
    }
    checked = YES;
    NSDictionary *last = [NSUserDefaults.standardUserDefaults dictionaryForKey:kWQLastFolderPref];
    if (![NSUserDefaults.standardUserDefaults boolForKey:kWQReopenOffPref] && [last[@"path"] isKindOfClass:NSString.class])
        _reopenFolder = last;
    [self checkForUpdate];
    [self runHealthCheck];
}

- (void)buildInterface
{
    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.contentInset = UIEdgeInsetsMake(0, 0, 104, 0);
    _scroll.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, 104, 0);
    [self.view addSubview:_scroll];

    _contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.alignment = UIStackViewAlignmentFill;
    _contentStack.spacing = 14;
    [_scroll addSubview:_contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_contentStack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:10],
        [_contentStack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [_contentStack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:16],
        [_contentStack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [_contentStack.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    [self buildHero];
    [_contentStack setCustomSpacing:20 afterView:_heroView];

    UIView *containersHeader = WQPrismSectionHeaderView(WQLocalizedNullable(@"Containers"), nil);
    [_contentStack addArrangedSubview:containersHeader];
    [_contentStack setCustomSpacing:10 afterView:containersHeader];

    _containersStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _containersStack.axis = UILayoutConstraintAxisVertical;
    _containersStack.spacing = 10;
    [_contentStack addArrangedSubview:_containersStack];

    UIView *toolsHeader = WQPrismSectionHeaderView(WQLocalizedNullable(@"Tools"), nil);
    [_contentStack addArrangedSubview:toolsHeader];
    [_contentStack setCustomSpacing:16 afterView:toolsHeader];
    [_contentStack addArrangedSubview:[self buildToolsRail]];

    UIView *favoritesHeader = WQPrismSectionHeaderView(WQLocalizedNullable(@"Favorites"), nil);
    [_contentStack addArrangedSubview:favoritesHeader];
    [_contentStack setCustomSpacing:16 afterView:favoritesHeader];
    [_contentStack addArrangedSubview:[self buildFavoritesRail]];

    [self buildSystemSection];
    [_contentStack addArrangedSubview:[self buildFooter]];

    _contentStack.spacing = 12;
    [_contentStack setCustomSpacing:22 afterView:[_contentStack.arrangedSubviews lastObject]];
}

- (void)buildHero
{
    WQPrismGlassView *glass = [[WQPrismGlassView alloc] initWithRadius:26];
    _heroView = glass;

    _statusPill = [UIView new];
    _statusPill.translatesAutoresizingMaskIntoConstraints = NO;
    _statusPill.layer.cornerRadius = 9;
    _statusPill.layer.cornerCurve = kCACornerCurveContinuous;

    _statusLabel = [UILabel new];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _statusLabel.textColor = UIColor.systemGreenColor;
    _statusLabel.text = WQLocalizedNullable(@"Checking access…");
    [_statusPill addSubview:_statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_statusLabel.topAnchor constraintEqualToAnchor:_statusPill.topAnchor constant:4],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:_statusPill.bottomAnchor constant:-4],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_statusPill.leadingAnchor constant:9],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:_statusPill.trailingAnchor constant:-9],
    ]];

    UILabel *title = [UILabel new];
    title.text = WQLocalizedNullable(@"All your containers, in one place.");
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    title.textColor = UIColor.labelColor;
    title.numberOfLines = 0;
    title.maximumContentSizeCategory = UIContentSizeCategoryAccessibilityLarge;

    _heroSubtitle = [UILabel new];
    _heroSubtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _heroSubtitle.adjustsFontForContentSizeCategory = YES;
    _heroSubtitle.textColor = UIColor.secondaryLabelColor;
    _heroSubtitle.numberOfLines = 2;
    _heroSubtitle.text = wq_device_line();

    UIButtonConfiguration *quickCfg = [UIButtonConfiguration tintedButtonConfiguration];
    quickCfg.attributedTitle = WQPrismButtonTitle(WQLocalizedNullable(@"Quick Check"));
    quickCfg.image = [UIImage systemImageNamed:@"arrow.clockwise"];
    quickCfg.imagePadding = 5;
    quickCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    quickCfg.buttonSize = UIButtonConfigurationSizeSmall;
    __weak typeof(self) weakSelf = self;
    _quickButton = [UIButton buttonWithConfiguration:quickCfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [weakSelf runHealthCheck];
    }]];
    _quickButton.tintColor = [UIColor colorWithRed:0.42 green:0.53 blue:1.0 alpha:1.0];

    UIButtonConfiguration *logCfg = [UIButtonConfiguration plainButtonConfiguration];
    logCfg.attributedTitle = WQPrismButtonTitle(WQLocalizedNullable(@"Log"));
    logCfg.image = [UIImage systemImageNamed:@"doc.plaintext"];
    logCfg.imagePadding = 5;
    logCfg.buttonSize = UIButtonConfigurationSizeSmall;
    logCfg.baseForegroundColor = UIColor.secondaryLabelColor;
    UIButton *logButton = [UIButton buttonWithConfiguration:logCfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [weakSelf openLog];
    }]];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[_quickButton, logButton]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 8;
    buttons.alignment = UIStackViewAlignmentCenter;

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_statusPill, title, _heroSubtitle, buttons]];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;
    text.spacing = 8;

    WQPrismIconTile *shield = [[WQPrismIconTile alloc] initWithSymbol:@"checkmark.shield.fill" tone:@"mint" size:58];
    [shield setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[text, shield]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [glass.contentView addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor constant:16],
        [row.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor constant:-16],
        [row.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:-16],
    ]];

    [_contentStack addArrangedSubview:glass];
    [self updateHealthUI];
}

- (UIView *)buildToolsRail
{
    UIScrollView *rail = [[UIScrollView alloc] initWithFrame:CGRectZero];
    rail.translatesAutoresizingMaskIntoConstraints = NO;
    rail.showsHorizontalScrollIndicator = NO;
    rail.alwaysBounceHorizontal = YES;
    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 9;
    [rail addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [rail.heightAnchor constraintEqualToConstant:110],
        [row.topAnchor constraintEqualToAnchor:rail.contentLayoutGuide.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:rail.contentLayoutGuide.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:rail.contentLayoutGuide.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:rail.contentLayoutGuide.trailingAnchor],
        [row.heightAnchor constraintEqualToAnchor:rail.frameLayoutGuide.heightAnchor],
    ]];

    NSArray<NSArray<NSString *> *> *tools = @[
        @[@"Apps", @"square.grid.3x3.fill", @"sky", @"App Data"],
        @[@"Cache Cleaner", @"sparkles", @"mint", @"Library/Caches"],
        @[@"Go to Path…", @"arrow.right.circle.fill", @"violet", @"Path"],
        @[@"Backups", @"clock.arrow.circlepath", @"amber", @"App Backups"],
    ];
    for (NSUInteger i = 0; i < tools.count; i++) {
        NSArray *t = tools[i];
        WQPrismCardView *card = [[WQPrismCardView alloc] initWithTitle:WQLocalizedNullable(t[0])
                                                                  meta:WQLocalizedNullable(t[3])
                                                                symbol:t[1]
                                                                  tone:t[2]
                                                               compact:YES];
        card.tag = (NSInteger)i;
        [card addTarget:self action:@selector(openToolCard:) forControlEvents:UIControlEventTouchUpInside];
        [card.widthAnchor constraintEqualToConstant:124].active = YES;
        [row addArrangedSubview:card];
    }
    return rail;
}

- (UIView *)buildFavoritesRail
{
    UIScrollView *rail = [[UIScrollView alloc] initWithFrame:CGRectZero];
    rail.translatesAutoresizingMaskIntoConstraints = NO;
    rail.showsHorizontalScrollIndicator = NO;
    _favoritesStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _favoritesStack.translatesAutoresizingMaskIntoConstraints = NO;
    _favoritesStack.axis = UILayoutConstraintAxisHorizontal;
    _favoritesStack.spacing = 7;
    [rail addSubview:_favoritesStack];
    [NSLayoutConstraint activateConstraints:@[
        [rail.heightAnchor constraintEqualToConstant:38],
        [_favoritesStack.topAnchor constraintEqualToAnchor:rail.contentLayoutGuide.topAnchor],
        [_favoritesStack.bottomAnchor constraintEqualToAnchor:rail.contentLayoutGuide.bottomAnchor],
        [_favoritesStack.leadingAnchor constraintEqualToAnchor:rail.contentLayoutGuide.leadingAnchor],
        [_favoritesStack.trailingAnchor constraintEqualToAnchor:rail.contentLayoutGuide.trailingAnchor],
        [_favoritesStack.heightAnchor constraintEqualToAnchor:rail.frameLayoutGuide.heightAnchor],
    ]];
    return rail;
}

- (void)buildSystemSection
{
    _systemSection = [[UIStackView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = (UIStackView *)_systemSection;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    [stack addArrangedSubview:WQPrismSectionHeaderView(WQLocalizedNullable(@"System"), nil)];

    WQPrismGlassView *glass = [[WQPrismGlassView alloc] initWithRadius:22];
    UIStackView *rows = [[UIStackView alloc] initWithFrame:CGRectZero];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 0;
    [glass.contentView addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor constant:4],
        [rows.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor constant:-4],
        [rows.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:10],
        [rows.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:-10],
    ]];
    _systemRows = rows;
    [stack addArrangedSubview:glass];
    [_contentStack addArrangedSubview:stack];
    [_contentStack setCustomSpacing:16 afterView:stack];
}

- (UIView *)buildFooter
{
    UILabel *version = [UILabel new];
    version.text = wq_app_version_line();
    version.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    version.textColor = UIColor.tertiaryLabelColor;
    version.textAlignment = NSTextAlignmentCenter;

    UIButtonConfiguration *linkCfg = [UIButtonConfiguration plainButtonConfiguration];
    linkCfg.title = @"GitHub";
    linkCfg.image = [UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"];
    linkCfg.imagePadding = 4;
    linkCfg.buttonSize = UIButtonConfigurationSizeSmall;
    linkCfg.baseForegroundColor = UIColor.secondaryLabelColor;
    UIButton *github = [UIButton buttonWithConfiguration:linkCfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/kolbicz"] options:@{} completionHandler:nil];
    }]];

    UIButtonConfiguration *xcfg = [UIButtonConfiguration plainButtonConfiguration];
    xcfg.title = @"@_kolbicz";
    xcfg.image = [UIImage systemImageNamed:@"at"];
    xcfg.imagePadding = 4;
    xcfg.buttonSize = UIButtonConfigurationSizeSmall;
    xcfg.baseForegroundColor = UIColor.secondaryLabelColor;
    UIButton *x = [UIButton buttonWithConfiguration:xcfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://x.com/_kolbicz"] options:@{} completionHandler:nil];
    }]];

    UIStackView *links = [[UIStackView alloc] initWithArrangedSubviews:@[github, x]];
    links.axis = UILayoutConstraintAxisHorizontal;
    links.spacing = 12;
    links.alignment = UIStackViewAlignmentCenter;

    UILabel *credit = [UILabel new];
    credit.text = WQLocalizedNullable(@"Sandbox escape: worse_query by @forcequitOS");
    credit.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    credit.textColor = UIColor.tertiaryLabelColor;
    credit.textAlignment = NSTextAlignmentCenter;
    credit.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[version, links, credit]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 7;
    return stack;
}

- (void)rebuildLocations
{
    if (WQPrismScreenshotMode()) {
        _locations = @[
            @[@"App Data", @"/private/var/mobile/Containers/Data/Application", @"square.grid.2x2"],
            @[@"App Groups", @"/private/var/mobile/Containers/Shared/AppGroup", @"square.stack.3d.up"],
            @[@"Extension Data", @"/private/var/mobile/Containers/Data/PluginKitPlugin", @"puzzlepiece.extension"],
            @[@"Internal Daemons", @"/private/var/mobile/Containers/Data/InternalDaemon", @"gearshape.2"],
        ];
        return;
    }
    NSMutableArray<NSArray<NSString *> *> *locations = [@[
        @[@"App Data", @"/private/var/mobile/Containers/Data/Application", @"square.grid.2x2"],
        @[@"App Groups", @"/private/var/mobile/Containers/Shared/AppGroup", @"square.stack.3d.up"],
        @[@"Extension Data", @"/private/var/mobile/Containers/Data/PluginKitPlugin", @"puzzlepiece.extension"],
        @[@"Internal Daemons", @"/private/var/mobile/Containers/Data/InternalDaemon", @"gearshape.2"],
    ] mutableCopy];
    if (wq_app_bundles_reachable())
        [locations addObject:@[@"App Bundles", @"/private/var/containers/Bundle/Application", @"app.badge"]];
    if (wq_system_areas_reachable())
        [locations addObject:@[@"System Data", @"/private/var/containers/Data/System", @"cpu"]];
    _locations = locations;
}

- (NSString *)shortPath:(NSString *)path
{
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *tail = [NSMutableArray new];
    for (NSString *part in [parts reverseObjectEnumerator]) {
        if (!part.length) continue;
        [tail insertObject:part atIndex:0];
        if (tail.count == 2) break;
    }
    return [tail componentsJoinedByString:@"/"];
}

- (NSString *)toneForContainer:(NSString *)title
{
    if ([title isEqualToString:@"App Data"]) return @"blue";
    if ([title isEqualToString:@"App Groups"]) return @"violet";
    if ([title isEqualToString:@"Extension Data"]) return @"orange";
    if ([title isEqualToString:@"Internal Daemons"]) return @"mint";
    if ([title isEqualToString:@"App Bundles"]) return @"sky";
    if ([title isEqualToString:@"System Data"]) return @"indigo";
    return @"blue";
}

- (UIMenu *)containerMenuForIndex:(NSUInteger)index
{
    NSArray<NSString *> *location = _locations[index];
    NSString *title = WQLocalizedNullable(location[0]);
    NSString *path = location[1];
    NSString *canonical = WQCanonicalVarPath(path);
    BOOL saved = wq_favorite_index(wq_favorites(), canonical) != NSNotFound;
    __weak typeof(self) weakSelf = self;

    UIAction *open = [UIAction actionWithTitle:WQLocalizedNullable(@"Open")
                                        image:[UIImage systemImageNamed:@"folder"]
                                   identifier:nil
                                      handler:^(UIAction *__unused a) {
        [weakSelf openPath:path title:title];
    }];
    UIAction *favorite = [UIAction actionWithTitle:WQLocalizedNullable(saved ? @"Remove from Favorites" : @"Add to Favorites")
                                            image:[UIImage systemImageNamed:saved ? @"star.slash" : @"star"]
                                       identifier:nil
                                          handler:^(UIAction *__unused a) {
        wq_set_favorite(canonical, title, NO, !saved);
        [weakSelf rebuildFavorites];
    }];
    UIAction *copy = [UIAction actionWithTitle:WQLocalizedNullable(@"Copy Path")
                                        image:[UIImage systemImageNamed:@"doc.on.doc"]
                                   identifier:nil
                                      handler:^(UIAction *__unused a) {
        UIPasteboard.generalPasteboard.string = path;
    }];
    UIAction *info = [UIAction actionWithTitle:WQLocalizedNullable(@"Info")
                                        image:[UIImage systemImageNamed:@"info.circle"]
                                   identifier:nil
                                      handler:^(UIAction *__unused a) {
        wq_alert(weakSelf, title, WQVerbatim(path));
    }];
    return [UIMenu menuWithTitle:@"" children:@[open, favorite, copy, info]];
}

- (void)rebuildContainers
{
    for (UIView *view in _containersStack.arrangedSubviews) {
        [_containersStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSMutableArray<WQPrismCardView *> *cards = [NSMutableArray new];
    for (NSUInteger i = 0; i < _locations.count; i++) {
        NSArray<NSString *> *location = _locations[i];
        if ([location[0] isEqualToString:@"System Data"]) continue;
        NSString *title = WQLocalizedNullable(location[0]);
        WQPrismCardView *card = [[WQPrismCardView alloc] initWithTitle:title
                                                                  meta:[self shortPath:location[1]]
                                                                symbol:location[2]
                                                                  tone:[self toneForContainer:location[0]]
                                                               compact:NO];
        card.tag = (NSInteger)i;
        [card addTarget:self action:@selector(openContainerCard:) forControlEvents:UIControlEventTouchUpInside];
        card.moreButton.menu = [self containerMenuForIndex:i];
        card.metaLabel.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
        card.metaLabel.textAlignment = NSTextAlignmentLeft;
        [cards addObject:card];
    }
    for (NSUInteger i = 0; i < cards.count; i += 2) {
        WQPrismCardView *left = cards[i];
        UIView *right = (i + 1 < cards.count) ? cards[i + 1] : [UIView new];
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 10;
        row.distribution = UIStackViewDistributionFillEqually;
        [_containersStack addArrangedSubview:row];
    }
}

- (void)rebuildFavorites
{
    for (UIView *view in _favoritesStack.arrangedSubviews) {
        [_favoritesStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<NSDictionary *> *favorites = wq_favorites();
    if (!favorites.count && WQPrismScreenshotMode()) {
        favorites = @[
            @{ @"path": @"/private/var/mobile/Containers/Data/Application", @"title": @"Documents" },
            @{ @"path": @"/private/var/mobile/Containers/Shared/AppGroup", @"title": @"WhatsApp" },
            @{ @"path": @"/private/var/mobile/Library", @"title": @"Library" },
        ];
    }
    if (!favorites.count) {
        UILabel *empty = [UILabel new];
        empty.text = WQLocalizedNullable(@"Add a folder from its More menu.");
        empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        empty.textColor = UIColor.tertiaryLabelColor;
        [_favoritesStack addArrangedSubview:empty];
        return;
    }
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *entry in favorites) {
        NSString *path = entry[@"path"];
        if (![path isKindOfClass:NSString.class]) continue;
        UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
        cfg.title = entry[@"title"] ?: path.lastPathComponent;
        cfg.image = [UIImage systemImageNamed:@"star.fill"];
        cfg.imagePadding = 4;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.buttonSize = UIButtonConfigurationSizeSmall;
        UIButton *button = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            [weakSelf openPath:path title:entry[@"title"] ?: path.lastPathComponent];
        }]];
        button.tintColor = UIColor.systemOrangeColor;
        [_favoritesStack addArrangedSubview:button];
    }
}

- (void)rebuildSystem
{
    for (UIView *view in _systemRows.arrangedSubviews) {
        [_systemRows removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    BOOL hasRows = NO;
    if (WQPrismScreenshotMode() || wq_system_areas_reachable()) {
        hasRows = YES;
        [_systemRows addArrangedSubview:[self systemRowWithTitle:WQLocalizedNullable(@"System Data")
                                                         subtitle:@"/containers/Data/System"
                                                           symbol:@"cpu"
                                                             tone:@"indigo"
                                                         selector:@selector(openSystemData)]];
        [_systemRows addArrangedSubview:[self systemRowWithTitle:WQLocalizedNullable(@"System Groups")
                                                         subtitle:@"MobileGestalt · Supervision"
                                                           symbol:@"lock.square.stack"
                                                             tone:@"violet"
                                                         selector:@selector(openSystemGroups)]];
    }
    _systemSection.hidden = !hasRows;
}

- (UIControl *)systemRowWithTitle:(NSString *)title
                         subtitle:(NSString *)subtitle
                           symbol:(NSString *)symbol
                             tone:(NSString *)tone
                         selector:(SEL)selector
{
    UIControl *row = [UIControl new];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    WQPrismIconTile *icon = [[WQPrismIconTile alloc] initWithSymbol:symbol tone:tone size:30];
    [row addSubview:icon];

    UILabel *name = [UILabel new];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.text = title;
    name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    name.textColor = UIColor.labelColor;
    name.numberOfLines = 1;
    [row addSubview:name];

    UILabel *sub = [UILabel new];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = subtitle;
    sub.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    sub.textColor = UIColor.secondaryLabelColor;
    sub.numberOfLines = 1;
    sub.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [row addSubview:sub];

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = UIColor.tertiaryLabelColor;
    chevron.image = [chevron.image imageFlippedForRightToLeftLayoutDirection];
    [row addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:54],
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [name.topAnchor constraintEqualToAnchor:row.topAnchor constant:7],
        [name.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:9],
        [name.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8],
        [sub.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:1],
        [sub.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
        [sub.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-6],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:11],
        [chevron.heightAnchor constraintEqualToConstant:11],
    ]];
    [row addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return row;
}

- (void)openContainerCard:(WQPrismCardView *)sender
{
    if (sender.tag < 0 || (NSUInteger)sender.tag >= _locations.count) return;
    NSArray<NSString *> *location = _locations[(NSUInteger)sender.tag];
    if ([location[0] isEqualToString:@"System Data"]) {
        [self openSystemData];
        return;
    }
    [self openPath:location[1] title:WQLocalizedNullable(location[0])];
}

- (void)openToolCard:(WQPrismCardView *)sender
{
    switch (sender.tag) {
        case 0: [self openTab:1]; break;
        case 1: [self openTab:2]; break;
        case 2: [self goToPath]; break;
        case 3: [self openTab:3]; break;
        default: break;
    }
}

- (void)openTab:(NSInteger)index
{
    if (self.tabBarController) {
        self.tabBarController.selectedIndex = index;
        return;
    }
    if (index == 1) [self.navigationController pushViewController:[WQAppsViewController new] animated:YES];
    else if (index == 2) [self.navigationController pushViewController:[WQCacheCleanerViewController new] animated:YES];
    else if (index == 3) [self.navigationController pushViewController:[WQPrismVaultViewController new] animated:YES];
}

- (void)openPath:(NSString *)path title:(NSString *)title
{
    WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:path title:title];
    [self.navigationController pushViewController:dir animated:YES];
}

- (void)openSystemData
{
    [self openPath:@"/private/var/containers/Data/System" title:WQLocalizedNullable(@"System Data")];
}

- (void)openSystemGroups
{
    [self.navigationController pushViewController:[WQSystemGroupsViewController new] animated:YES];
}

- (void)openLog
{
    [self.navigationController pushViewController:[WQLogViewController new] animated:YES];
}

- (void)openSettings
{
    WQPrismSettingsViewController *settings = [WQPrismSettingsViewController new];
    WQNavigationController *nav = [[WQNavigationController alloc] initWithRootViewController:settings];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
        sheet.preferredCornerRadius = 32;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)goToPath
{
    UIAlertController *alert = wq_alert_controller(@"Go to Path", @"A folder or file path", UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = UIPasteboard.generalPasteboard.hasStrings && [UIPasteboard.generalPasteboard.string hasPrefix:@"/"]
            ? UIPasteboard.generalPasteboard.string : @"/private/var/";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    __weak typeof(self) weakSelf = self;
    [alert addAction:wq_alert_action(@"Open", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *path = alert.textFields.firstObject.text.stringByStandardizingPath;
        if (![path hasPrefix:@"/"]) return;
        dispatch_async(wq_io(), ^{
            struct stat st;
            BOOL exists = wq_stat(path, &st);
            BOOL isDir = exists && S_ISDIR(st.st_mode);
            if (exists && S_ISLNK(st.st_mode)) {
                struct stat target;
                isDir = stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!exists) { wq_alert(weakSelf, @"Not found", path); return; }
                if (!isDir) { wq_open_file(weakSelf.navigationController, path, NO, WQOpenAuto); return; }
                [weakSelf openPath:path title:nil];
            });
        });
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

// MARK: Access check

- (void)runHealthCheck
{
    if (_checkingAccess) return;
    _checkingAccess = YES;
    [self updateHealthUI];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WQHealthCheck *> *checks = wq_health_run(nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf healthCheckFinished:checks];
        });
    });
}

- (void)healthCheckFinished:(NSArray<WQHealthCheck *> *)checks
{
    _checkingAccess = NO;
    _pendingHealthFailure = nil;
    [self rebuildLocations];
    [self rebuildContainers];
    [self rebuildSystem];
    WQHealthState worst = wq_health_worst(checks);
    if (worst >= WQHealthFailed) _pendingHealthFailure = checks;
    [self updateHealthUI];
    if (worst < WQHealthFailed) [self reopenLastFolder];
    else _reopenFolder = nil;
    if (worst == WQHealthWarning) { [self showHealthWarnings:checks]; return; }
    if (worst < WQHealthFailed) return;
    [self presentPendingHealthFailure];
}

- (void)updateHealthUI
{
    UIColor *tint = UIColor.systemGreenColor;
    if (_checkingAccess) {
        tint = UIColor.systemOrangeColor;
        _statusLabel.text = WQLocalizedNullable(@"Checking access…");
    } else if (!_appGroupName.length) {
        tint = UIColor.systemOrangeColor;
        _statusLabel.text = WQLocalizedNullable(@"No App Group");
    } else if (_pendingHealthFailure.count) {
        tint = UIColor.systemRedColor;
        _statusLabel.text = WQLocalizedNullable(@"Access check failed.");
    } else {
        tint = UIColor.systemGreenColor;
        _statusLabel.text = WQLocalizedNullable(@"Access check passed.");
    }
    _statusLabel.textColor = tint;
    _statusPill.backgroundColor = [tint colorWithAlphaComponent:0.13];
    _heroSubtitle.text = _appGroupName.length
        ? [NSString stringWithFormat:@"%@\n%@", wq_device_line(), _appGroupName]
        : [NSString stringWithFormat:@"%@\n%@", wq_device_line(), WQLocalizedNullable(@"No App Group")];
    _quickButton.enabled = !_checkingAccess;
    UIButtonConfiguration *cfg = _quickButton.configuration;
    cfg.attributedTitle = WQPrismButtonTitle(_checkingAccess ? WQLocalizedNullable(@"Checking access…") : WQLocalizedNullable(@"Quick Check"));
    _quickButton.configuration = cfg;
}

- (BOOL)healthFailureCanPresent
{
    if (!self.view.window) return NO;
    if (self.tabBarController && self.tabBarController.selectedViewController != self.navigationController) return NO;
    UIViewController *host = self.navigationController ?: self;
    if (host.presentedViewController) return NO;
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (void)presentPendingHealthFailure
{
    NSArray<WQHealthCheck *> *checks = _pendingHealthFailure;
    if (!checks) return;
    if (![self healthFailureCanPresent]) {
        if (_healthRetryScheduled) return;
        _healthRetryScheduled = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_healthRetryScheduled = NO;
            [strongSelf presentPendingHealthFailure];
        });
        return;
    }
    _pendingHealthFailure = nil;
    WQHealthViewController *health = [[WQHealthViewController alloc] initWithChecks:checks];
    __weak typeof(self) weakSelf = self;
    health.onPassed = ^(NSArray<WQHealthCheck *> *passed) {
        [weakSelf rebuildLocations];
        [weakSelf rebuildContainers];
        [weakSelf rebuildSystem];
        [weakSelf updateHealthUI];
        if (wq_health_worst(passed) == WQHealthWarning) [weakSelf showHealthWarnings:passed];
    };
    WQNavigationController *nav = [[WQNavigationController alloc] initWithRootViewController:health];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.modalInPresentation = YES;
    [(self.tabBarController ?: self.navigationController ?: self) presentViewController:nav animated:YES completion:nil];
}

- (void)showHealthWarnings:(NSArray<WQHealthCheck *> *)checks
{
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (WQHealthCheck *c in checks)
        if (c.state == WQHealthWarning) [lines addObject:[NSString stringWithFormat:@"%@: %@", c.title, c.detail]];
    NSString *text = [lines componentsJoinedByString:@"\n\n"];
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"], text];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([[defaults stringForKey:@"WQHealthWarned"] isEqualToString:key]) return;
    [defaults setObject:key forKey:@"WQHealthWarned"];
    UIAlertController *alert = wq_alert_controller(@"Not everything works here", text, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleCancel, nil)];
    UIViewController *host = self.tabBarController ?: self.navigationController ?: self;
    while (host.presentedViewController) host = host.presentedViewController;
    [host presentViewController:alert animated:YES completion:nil];
}

- (void)reopenLastFolder
{
    NSDictionary *last = _reopenFolder;
    _reopenFolder = nil;
    if (!last) return;
    NSString *path = last[@"path"];
    if (![path isKindOfClass:NSString.class]) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        struct stat st;
        BOOL folder = wq_stat(path, &st) && S_ISDIR(st.st_mode);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!folder || ![weakSelf healthFailureCanPresent]) return;
            WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:path
                title:[last[@"title"] isKindOfClass:NSString.class] ? last[@"title"] : path.lastPathComponent];
            dir.readOnly = [last[@"readOnly"] boolValue];
            [weakSelf.navigationController pushViewController:dir animated:YES];
        });
    });
}

// MARK: Update check

- (void)checkForUpdate
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kWQUpdateCheckOffPref]) return;
    NSDate *last = [defaults objectForKey:kWQUpdateCheckedPref];
    NSString *known = [defaults stringForKey:@"WQUpdateAvailable"];
    NSString *mine = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
    if (known.length && [known compare:mine options:NSNumericSearch] == NSOrderedDescending) [self showUpdateBanner:known];
    if ([last isKindOfClass:NSDate.class] && -last.timeIntervalSinceNow < 12 * 3600) return;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 15;
    config.HTTPCookieStorage = nil;
    NSURL *url = [NSURL URLWithString:@"https://raw.githubusercontent.com/kolbicz/WQFiles/main/source.json"];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sessionWithConfiguration:config] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status != 200 || data.length > 1024 * 1024) {
            wq_log(@"update check: failed (%@)", error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status]);
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id apps = [json isKindOfClass:NSDictionary.class] ? json[@"apps"] : nil;
        id app = [apps isKindOfClass:NSArray.class] && [apps count] ? [apps firstObject] : nil;
        id version = [app isKindOfClass:NSDictionary.class] ? app[@"version"] : nil;
        if (![version isKindOfClass:NSString.class] || [version length] > 20) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [defaults setObject:NSDate.date forKey:kWQUpdateCheckedPref];
            [defaults setObject:version forKey:@"WQUpdateAvailable"];
            BOOL newer = [version compare:mine options:NSNumericSearch] == NSOrderedDescending;
            wq_log(@"update check: latest %@, this is %@%@", version, mine, newer ? @" (update available)" : @"");
            if (newer) [weakSelf showUpdateBanner:version];
        });
    }] resume];
}

- (void)showUpdateBanner:(NSString *)version
{
    if ([_availableVersion isEqualToString:version] && _updateBanner) return;
    _availableVersion = version;
    if (_updateBanner) {
        [_contentStack removeArrangedSubview:_updateBanner];
        [_updateBanner removeFromSuperview];
        _updateBanner = nil;
    }
    UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
    cfg.title = WQLocalizedFormat(@"WQ Files %@ is available", version);
    cfg.image = [UIImage systemImageNamed:@"arrow.down.circle"];
    cfg.imagePadding = 8;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    UIButton *button = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/kolbicz/WQFiles/releases/latest"] options:@{} completionHandler:nil];
    }]];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:46].active = YES;
    _updateBanner = button;
    NSUInteger index = [_contentStack.arrangedSubviews indexOfObject:_heroView];
    if (index == NSNotFound) index = 0;
    [_contentStack insertArrangedSubview:button atIndex:index + 1];
}

@end

#pragma mark - WQ Prism settings

@implementation WQPrismSettingsViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = WQLocalizedNullable(@"Settings");
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Done")
                                                                               style:UIBarButtonItemStylePlain
                                                                              target:self
                                                                              action:@selector(done)];
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 5 : 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"prism-settings"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"prism-settings"];
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (indexPath.section == 0) {
        NSArray<NSString *> *titles = @[@"Allow Deleting", @"Show Item Counts", @"Keep Data Before Restore", @"Reopen Last Folder", @"Check for Updates"];
        NSArray<NSString *> *symbols = @[@"trash.slash", @"number", @"clock.arrow.circlepath", @"arrow.uturn.forward", @"arrow.down.circle"];
        c.text = WQLocalizedNullable(titles[(NSUInteger)indexPath.row]);
        c.image = [UIImage systemImageNamed:symbols[(NSUInteger)indexPath.row]];
        UISwitch *toggle = [UISwitch new];
        toggle.on = indexPath.row == 1 ? wq_show_item_counts()
                   : indexPath.row == 2 ? wq_keep_before_restore()
                   : indexPath.row == 3 ? ![defaults boolForKey:kWQReopenOffPref]
                   : indexPath.row == 4 ? ![defaults boolForKey:kWQUpdateCheckOffPref]
                   : wq_deleting_allowed();
        [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
            BOOL on = ((UISwitch *)action.sender).isOn;
            if (indexPath.row == 1) [defaults setBool:on forKey:kWQShowItemCountsPref];
            else if (indexPath.row == 2) wq_set_keep_before_restore(on);
            else if (indexPath.row == 3) {
                [defaults setBool:!on forKey:kWQReopenOffPref];
                if (!on) [defaults removeObjectForKey:kWQLastFolderPref];
            } else if (indexPath.row == 4) [defaults setBool:!on forKey:kWQUpdateCheckOffPref];
            else wq_set_deleting_allowed(on);
        }] forControlEvents:UIControlEventValueChanged];
        cell.contentConfiguration = c;
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSArray<NSString *> *titles = @[@"Language", @"Log", @"About"];
    NSArray<NSString *> *symbols = @[@"globe", @"doc.plaintext", @"info.circle"];
    c.text = WQLocalizedNullable(titles[(NSUInteger)indexPath.row]);
    c.image = [UIImage systemImageNamed:symbols[(NSUInteger)indexPath.row]];
    if (indexPath.row == 0) c.secondaryText = wq_language_name(wq_chosen_language());
    if (indexPath.row == 1) c.secondaryText = nil;
    if (indexPath.row == 2) c.secondaryText = wq_app_version_line();
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) return;
    if (indexPath.row == 0) {
        [self.navigationController pushViewController:[WQLanguageViewController new] animated:YES];
    } else if (indexPath.row == 1) {
        [self.navigationController pushViewController:[WQLogViewController new] animated:YES];
    } else {
        NSString *version = [NSString stringWithFormat:@"%@\n\n%@", wq_app_version_line(), WQLocalizedNullable(@"Sandbox escape: worse_query by @forcequitOS")];
        UIAlertController *alert = wq_alert_controller(@"WQ Files", version, UIAlertControllerStyleAlert);
        [alert addAction:wq_alert_action(@"GitHub", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/kolbicz/WQFiles"] options:@{} completionHandler:nil];
        })];
        [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleCancel, nil)];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

#pragma mark - WQ Prism vault

@implementation WQPrismVaultViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = WQLocalizedNullable(@"Vault");
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 90, 0);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 3 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 0 ? WQLocalizedNullable(@"Backups are checked before every restore.") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"prism-vault"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"prism-vault"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (indexPath.section == 0) {
        NSArray<NSString *> *titles = @[@"App Backups", @"Backups", @"Recently Deleted"];
        NSArray<NSString *> *symbols = @[@"clock.arrow.circlepath", @"archivebox", @"trash.circle"];
        c.text = WQLocalizedNullable(titles[(NSUInteger)indexPath.row]);
        c.image = [UIImage systemImageNamed:symbols[(NSUInteger)indexPath.row]];
    } else {
        NSArray<NSString *> *titles = @[@"Favorites", @"Log"];
        NSArray<NSString *> *symbols = @[@"star", @"doc.plaintext"];
        c.text = WQLocalizedNullable(titles[(NSUInteger)indexPath.row]);
        c.image = [UIImage systemImageNamed:symbols[(NSUInteger)indexPath.row]];
    }
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = [UIColor clearColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self.navigationController pushViewController:[WQFavoritesViewController new] animated:YES];
        else [self.navigationController pushViewController:[WQLogViewController new] animated:YES];
        return;
    }
    if (indexPath.row == 0) {
        [NSFileManager.defaultManager createDirectoryAtPath:wq_app_backup_root() withIntermediateDirectories:YES attributes:nil error:nil];
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:wq_app_backup_root()
            title:WQLocalizedNullable(@"App Backups")] animated:YES];
    } else if (indexPath.row == 1) {
        [NSFileManager.defaultManager createDirectoryAtPath:wq_backup_root() withIntermediateDirectories:YES attributes:nil error:nil];
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:wq_backup_root()
            title:WQLocalizedNullable(@"Backups")] animated:YES];
    } else {
        [self.navigationController pushViewController:[WQRecentlyDeletedViewController new] animated:YES];
    }
}

@end

#pragma mark - WQ Prism tabs

@interface WQPrismTabController : UITabBarController
@end

@implementation WQPrismTabController

- (void)viewDidLoad
{
    [super viewDidLoad];
    WQPrismHomeViewController *home = [WQPrismHomeViewController new];
    WQAppsViewController *apps = [WQAppsViewController new];
    WQCacheCleanerViewController *clean = [WQCacheCleanerViewController new];
    WQPrismVaultViewController *vault = [WQPrismVaultViewController new];

    WQNavigationController *homeNav = [[WQNavigationController alloc] initWithRootViewController:home];
    WQNavigationController *appsNav = [[WQNavigationController alloc] initWithRootViewController:apps];
    WQNavigationController *cleanNav = [[WQNavigationController alloc] initWithRootViewController:clean];
    WQNavigationController *vaultNav = [[WQNavigationController alloc] initWithRootViewController:vault];

    homeNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:WQLocalizedNullable(@"Home")
        image:[UIImage systemImageNamed:@"house.fill"] tag:0];
    appsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:WQLocalizedNullable(@"Apps")
        image:[UIImage systemImageNamed:@"square.grid.3x3.fill"] tag:1];
    cleanNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:WQLocalizedNullable(@"Clean")
        image:[UIImage systemImageNamed:@"sparkles"] tag:2];
    vaultNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:WQLocalizedNullable(@"Vault")
        image:[UIImage systemImageNamed:@"shield.fill"] tag:3];

    self.viewControllers = @[homeNav, appsNav, cleanNav, vaultNav];
    self.selectedIndex = 0;
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger tabIndex = [arguments indexOfObject:@"-WQPrismTab"];
    if (tabIndex != NSNotFound && tabIndex + 1 < arguments.count) {
        NSInteger index = [arguments[tabIndex + 1] integerValue];
        if (index >= 0 && index < 4) self.selectedIndex = (NSUInteger)index;
    }
    self.tabBar.tintColor = [UIColor colorWithRed:0.37 green:0.50 blue:1.0 alpha:1.0];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.viewControllers.count > 2) {
        WQNavigationController *cleanNav = self.viewControllers[2];
        cleanNav.tabBarItem.title = WQLocalizedNullable(@"Clean");
    }
}

@end

#pragma mark - Startup check

// The startup check runs in the background while the start screen is up
// (WQRootViewController). When something essential fails, this screen covers
// the app with what failed; it only goes away through Try Again (when the
// check then passes) or Continue Anyway. (Declared before the start screen.)

@implementation WQHealthViewController {
    NSArray<WQHealthCheck *> *_checks;
    NSString *_stage;
    BOOL _running;
}

- (instancetype)initWithChecks:(NSArray<WQHealthCheck *> *)checks
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _checks = [checks copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"WQ Files");
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.tableHeaderView = wq_device_header(self.view.bounds.size.width);
}

- (void)retry
{
    if (_running) return;
    _running = YES;
    _stage = WQLocalized(@"Checking access…");
    [self.tableView reloadData];
    wq_enumerate_invalidate();
    wq_display_names_reset_miss();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *checks = wq_health_run(^(NSString *text) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_stage = text; [self.tableView reloadData]; });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_running = NO;
            self->_checks = checks;
            if (wq_health_worst(checks) < WQHealthFailed) {
                void (^passed)(NSArray *) = self.onPassed;
                [self dismissViewControllerAnimated:YES completion:^{ if (passed) passed(checks); }];
                return;
            }
            [self.tableView reloadData];
        });
    });
}

// The buttons under the checks: 0 Try Again, 1 Log, 3 Signing Help (when
// the App Group is missing), 4 Reset Access Cache (when no folder opens),
// 2 Continue Anyway.
- (NSArray<NSNumber *> *)actions
{
    BOOL noGroup = _checks.count && _checks[0].state == WQHealthFailed;
    BOOL noAccess = NO;
    for (WQHealthCheck *c in _checks)
        if ([c.key isEqualToString:@"Sandbox access"] && c.state == WQHealthFailed) noAccess = YES;
    if (noGroup) return @[@0, @1, @3, @2];
    return noAccess ? @[@0, @4, @1, @2] : @[@0, @1, @2];
}

- (void)resetAccessCache
{
    UIAlertController *alert = wq_alert_controller(@"Reset Access Cache?",
        @"Another app that shares WQ Files' App Group (for example one signed with the same tool) can leave its cache folder in a state that blocks sandbox access. This puts it back; nothing is deleted.",
        UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Reset", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *error = nil;
        if (wq_reset_access_cache(&error)) { [self retry]; return; }
        wq_alert(self, @"Reset failed", error ?: @"see Log");
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _running ? 1 : 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_running) return 1;
    return section == 0 ? (NSInteger)_checks.count : (NSInteger)self.actions.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return !_running && section == 0 ? WQLocalized(@"WQ Files can't work properly here") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (_running) return nil;
    if (section == 0)
        return WQLocalized(@"WQ Files stopped here instead of showing empty or wrong lists. A new iOS version can block its sandbox access; please send the Log with your device and iOS version.");
    return WQLocalized(@"Continue Anyway opens WQ Files as it is: lists may be empty or wrong, and nothing should be restored or deleted based on them.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"h"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"h"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (_running) {
        c.text = _stage;
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithFrame:CGRectZero];
        [spinner sizeToFit];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    } else if (indexPath.section == 0) {
        WQHealthCheck *check = _checks[(NSUInteger)indexPath.row];
        NSArray *symbols = @[@"checkmark.circle.fill", @"minus.circle", @"exclamationmark.triangle.fill", @"xmark.octagon.fill"];
        NSArray *colors = @[UIColor.systemGreenColor, UIColor.secondaryLabelColor, UIColor.systemOrangeColor, UIColor.systemRedColor];
        c.text = check.title;
        c.secondaryText = check.detail;
        c.secondaryTextProperties.numberOfLines = 0;
        c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        c.image = [UIImage systemImageNamed:symbols[(NSUInteger)check.state]];
        c.imageProperties.tintColor = colors[(NSUInteger)check.state];
    } else {
        NSArray *titles = @[@"Try Again", @"Log", @"Continue Anyway", @"Signing Help", @"Reset Access Cache"];
        NSUInteger action = self.actions[(NSUInteger)indexPath.row].unsignedIntegerValue;
        c = [UIListContentConfiguration cellConfiguration];
        c.text = WQLocalized(titles[action]);
        c.textProperties.color = action == 2 ? UIColor.systemRedColor : self.view.tintColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_running || indexPath.section != 1) return;
    switch (self.actions[(NSUInteger)indexPath.row].integerValue) {
        case 0:
            [self retry];
            break;
        case 1:
            [self.navigationController pushViewController:[WQLogViewController new] animated:YES];
            break;
        case 3:
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/kolbicz/WQFiles#signing-the-app-group"]
                                             options:@{} completionHandler:nil];
            break;
        case 4:
            [self resetAccessCache];
            break;
        default: {
            UIAlertController *alert = wq_alert_controller(@"Continue Anyway?",
                @"Lists may be empty or wrong. Don't restore, clean or delete anything based on them.", UIAlertControllerStyleAlert);
            [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
            [alert addAction:wq_alert_action(@"Continue", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
                wq_log(@"health: the user continued despite failed checks");
                [self dismissViewControllerAnimated:YES completion:nil];
            })];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }
}

@end

#pragma mark - App

@interface WQSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WQSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.rootViewController = [WQPrismTabController new];
    [window makeKeyAndVisible];
    self.window = window;
}

@end

#pragma mark - Full scan: confirmation and progress window

static UIViewController *wq_top_view_controller(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow) continue;
            UIViewController *top = window.rootViewController;
            while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
            return top;
        }
    }
    return nil;
}

static NSString *wq_duration_text(double seconds)
{
    if (seconds < 90) return WQLocalized(@"about a minute");
    if (seconds < 3600) return WQLocalizedFormat(@"about %.0f minutes", ceil(seconds / 60));
    return WQLocalizedFormat(@"about %.1f hours", seconds / 3600);
}

static NSString *wq_count_text(int64_t n)
{
    if (n >= 1000000) return WQLocalizedFormat(@"%.0f million", n / 1e6);
    return [NSNumberFormatter localizedStringFromNumber:@(n) numberStyle:NSNumberFormatterDecimalStyle];
}

@interface WQScanWindowController : UIViewController
- (void)updateDone:(int64_t)done total:(int64_t)total;
@end

@implementation WQScanWindowController {
    UIProgressView *_bar;
    UILabel *_status;
    CFAbsoluteTime _started;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _started = CFAbsoluteTimeGetCurrent();
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:40 weight:UIImageSymbolWeightRegular];
    icon.tintColor = UIColor.tintColor;
    UILabel *title = [UILabel new];
    title.text = WQLocalizedNullable(@"Scanning all files");
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    UILabel *text = [UILabel new];
    text.numberOfLines = 0;
    text.textAlignment = NSTextAlignmentCenter;
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text.textColor = UIColor.secondaryLabelColor;
    text.text = WQLocalizedNullable(@"iOS doesn't let WQ Files list these folders directly, so it checks every file on this device once. This is only slow the first time: later scans only check new files.\n\nKeep WQ Files open. Switching to another app or locking the screen pauses the scan.");
    _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _status = [UILabel new];
    _status.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                                    weight:UIFontWeightRegular];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.text = WQLocalizedNullable(@"Starting…");
    UIButton *hide = [UIButton buttonWithConfiguration:UIButtonConfiguration.borderedButtonConfiguration primaryAction:
        [UIAction actionWithTitle:WQLocalizedNullable(@"Hide") image:nil identifier:nil handler:^(UIAction *__unused a) {
            [self dismissViewControllerAnimated:YES completion:nil];
        }]];
    UIButtonConfiguration *stopConfig = UIButtonConfiguration.borderedButtonConfiguration;
    stopConfig.baseForegroundColor = UIColor.systemRedColor;
    UIButton *stop = [UIButton buttonWithConfiguration:stopConfig primaryAction:
        [UIAction actionWithTitle:WQLocalizedNullable(@"Stop Scan") image:nil identifier:nil handler:^(UIAction *__unused a) {
            wq_full_scan_stop();
            [self dismissViewControllerAnimated:YES completion:nil];
        }]];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[hide, stop]];
    buttons.spacing = 12;
    buttons.distribution = UIStackViewDistributionFillEqually;
    UILabel *note = [UILabel new];
    note.numberOfLines = 0;
    note.textAlignment = NSTextAlignmentCenter;
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.textColor = UIColor.tertiaryLabelColor;
    note.text = WQLocalizedNullable(@"Hide keeps the scan running; the list fills in when it's done.");
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, text, _bar, _status, buttons, note]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
        [_bar.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [text.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [note.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
}

- (void)updateDone:(int64_t)done total:(int64_t)total
{
    if (total <= 0) return;
    float fraction = (float)((double)done / (double)total);
    [_bar setProgress:fraction animated:NO];
    double elapsed = CFAbsoluteTimeGetCurrent() - _started;
    NSString *left = @"";
    if (elapsed > 5 && done > 0 && done < total) {
        double remaining = elapsed * (double)(total - done) / (double)done;
        left = WQLocalizedFormat(@" · %@ left", wq_duration_text(remaining));
    }
    _status.text = [NSString stringWithFormat:@"%.0f%%%@", fraction * 100, left];
}

@end

static WQScanWindowController *gScanWindow;
static UIBackgroundTaskIdentifier gScanBackgroundTask;   // 0 is UIBackgroundTaskInvalid

// Called on a scan thread: asks on the main thread and waits for the answer.
static BOOL wq_confirm_full_scan(NSString *what, int64_t ids, double seconds)
{
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL start = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = wq_top_view_controller();
        if (!top) { dispatch_semaphore_signal(answered); return; }   // not in front: don't scan unasked
        NSString *message = WQLocalizedFormat(@"To list %@, WQ Files has to check every file on this device once: %@ files, %@.\n\nThis is only needed the first time; later scans only check new files and take seconds.\n\nKeep WQ Files open while it scans.", what, wq_count_text(ids), wq_duration_text(seconds));
        UIAlertController *alert = wq_alert_controller(@"Scan all files?", message, UIAlertControllerStyleAlert);
        [alert addAction:wq_alert_action(@"Not Now", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) {
            dispatch_semaphore_signal(answered);
        })];
        [alert addAction:wq_alert_action(@"Start Scan", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            start = YES;
            // A little extra time when the user switches away (iOS grants about 30 s).
            if (gScanBackgroundTask == UIBackgroundTaskInvalid) {
                gScanBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"WQ full scan" expirationHandler:^{
                    [UIApplication.sharedApplication endBackgroundTask:gScanBackgroundTask];
                    gScanBackgroundTask = UIBackgroundTaskInvalid;
                }];
            }
            WQScanWindowController *window = [WQScanWindowController new];
            window.modalPresentationStyle = UIModalPresentationPageSheet;
            window.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                                          UISheetPresentationControllerDetent.largeDetent];
            window.sheetPresentationController.prefersGrabberVisible = YES;
            gScanWindow = window;
            dispatch_semaphore_signal(answered);
            // After the alert has gone (presenting during its dismissal fails).
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIViewController *host = wq_top_view_controller();
                if (gScanWindow == window && host && host != window) [host presentViewController:window animated:YES completion:nil];
            });
        })];
        [top presentViewController:alert animated:YES completion:nil];
    });
    dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    return start;
}

static void wq_full_scan_progress(int64_t done, int64_t total, BOOL finished)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!finished) { [gScanWindow updateDone:done total:total]; return; }
        WQScanWindowController *window = gScanWindow;
        gScanWindow = nil;
        if (window.presentingViewController && !window.isBeingDismissed) [window dismissViewControllerAnimated:YES completion:nil];
        if (gScanBackgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:gScanBackgroundTask];
            gScanBackgroundTask = UIBackgroundTaskInvalid;
        }
    });
}

@interface WQAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation WQAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    config.delegateClass = WQSceneDelegate.class;
    return config;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        // Container folders get their bundle id from the LaunchServices database
        // when the identifier attribute can't be read (iOS 27.2).
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_set_container_list_provider(wq_ls_container_paths);
        wq_set_full_scan_ui(wq_confirm_full_scan, wq_full_scan_progress);
        // Temporary media copies and share exports left by earlier runs.
        wq_media_sweep_stale();
        wq_share_sweep_stale_exports();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WQAppDelegate.class));
    }
}
