//
//  WQSQLiteViewer.m
//  WQ Files
//
//  SQLite viewer and editor. The database and its -wal file are copied into a
//  private temporary folder first (a -shm file is rebuilt by SQLite there),
//  then opened with PRAGMA query_only. Every statement is checked with
//  sqlite3_stmt_readonly before it runs. Edit turns query_only off for the
//  copy; Save writes the copy back over the app's database (WQSQLiteSave).
//

#import "WQSQLiteViewer.h"
#import "WQSQLiteSave.h"
#import "WQSQLiteSupport.h"
#import "WQEditing.h"
#import "WQAccess.h"
#import "WQSharing.h"
#import "WQUI.h"
#import <sqlite3.h>

BOOL wq_is_sqlite_header(NSData *head)
{
    return head.length >= 16 && memcmp(head.bytes, "SQLite format 3\0", 16) == 0;
}

static const NSUInteger kWQSQLitePage = 100;
static const NSUInteger kWQSQLiteQueryLimit = 1000;

#pragma mark - Snapshot

// A private copy of the database. All SQLite calls run on its serial queue.
@interface WQSQLiteSnapshot : NSObject
@property (nonatomic, readonly) dispatch_queue_t queue;
@property (nonatomic, readonly, nullable) sqlite3 *db;
@property (nonatomic, copy, readonly) NSString *sourcePath;
@property (nonatomic, readonly) BOOL copiedWAL;
// The app's files when the copy was made; nil if they changed while copying
// (then the copy can't be saved back).
@property (nonatomic, copy, nullable) NSDictionary *sourceState;
// Main thread only.
@property (nonatomic) BOOL editing;
@property (nonatomic) BOOL dirty;
@property (nonatomic) NSUInteger generation;          // bumps on every change
@property (nonatomic, weak) UIViewController<WQUnsavedEditing> *owner;
- (void)changed;
@end

@implementation WQSQLiteSnapshot {
    NSString *_dir;
}

// Streams `src` into `dst` through wq_read_range (which asks for access when
// needed). Returns NO with an error text on failure.
static BOOL wq_sqlite_copy(NSString *src, NSString *dst, NSString **error)
{
    if (![NSFileManager.defaultManager createFileAtPath:dst contents:nil attributes:nil]) {
        *error = WQLocalized(@"cannot create the temporary copy");
        return NO;
    }
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:dst];
    if (!out) { *error = WQLocalized(@"cannot write the temporary copy"); return NO; }
    const NSUInteger chunk = 1024 * 1024;
    unsigned long long offset = 0;
    BOOL ok = YES;
    @try {
        for (;;) {
            NSString *readError = nil;
            NSData *data = wq_read_range(src, offset, chunk, &readError);
            if (!data) { *error = readError ?: WQLocalized(@"read failed"); ok = NO; break; }
            if (data.length) [out writeData:data];
            offset += data.length;
            if (data.length < chunk) break;
        }
    } @catch (NSException *exception) {
        *error = exception.reason ?: WQLocalized(@"write failed");
        ok = NO;
    }
    [out closeFile];
    return ok;
}

- (nullable instancetype)initWithPath:(NSString *)path error:(NSString **)error
{
    if (!(self = [super init])) return nil;
    _sourcePath = [path copy];
    _queue = dispatch_queue_create("wqfiles.sqlite", DISPATCH_QUEUE_SERIAL);
    _dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"wq-sqlite-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:nil]) {
        *error = WQLocalized(@"cannot create a temporary folder");
        return nil;
    }
    NSString *copy = [_dir stringByAppendingPathComponent:@"db.sqlite"];
    NSDictionary *stateBefore = wq_sqlite_source_state(path);
    if (!wq_sqlite_copy(path, copy, error)) return nil;
    // Recent changes of WAL databases are still in the -wal file. The -shm
    // index is not copied: SQLite rebuilds it next to the copy.
    NSString *wal = [path stringByAppendingString:@"-wal"];
    struct stat st;
    if (wq_stat(wal, &st) && S_ISREG(st.st_mode) && st.st_size > 0) {
        NSString *walError = nil;
        _copiedWAL = wq_sqlite_copy(wal, [copy stringByAppendingString:@"-wal"], &walError);
        if (!_copiedWAL) {
            *error = WQLocalizedFormat(@"Cannot read this file: %@", walError ?: wal.lastPathComponent);
            return nil;
        }
    }
    // A copy taken while the app was writing may mix two versions: viewable,
    // but not something to write back.
    NSDictionary *stateAfter = wq_sqlite_source_state(path);
    _sourceState = stateBefore && [stateBefore isEqualToDictionary:stateAfter] ? stateBefore : nil;
    if (!_sourceState) wq_log(@"sqlite: %@ changed while it was being copied; editing is off for this copy", path);
    // Read-write on the private copy so SQLite can apply the WAL there;
    // query_only and the per-statement check keep it read-only in practice.
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(copy.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL);
    if (rc != SQLITE_OK) {
        *error = db ? @(sqlite3_errmsg(db)) : WQLocalized(@"cannot open the database");
        if (db) sqlite3_close(db);
        return nil;
    }
    sqlite3_exec(db, "PRAGMA query_only = ON", NULL, NULL, NULL);
    // Fail early on files that only look like databases.
    sqlite3_stmt *probe = NULL;
    rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &probe, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_step(probe);
    sqlite3_finalize(probe);
    if (rc != SQLITE_ROW) {
        *error = @(sqlite3_errmsg(db));
        sqlite3_close(db);
        return nil;
    }
    _db = db;
    return self;
}

- (void)changed
{
    _dirty = YES;
    _generation++;
}

- (void)dealloc
{
    if (_db) sqlite3_close(_db);
    if (_dir) [NSFileManager.defaultManager removeItemAtPath:_dir error:nil];
}

@end

#pragma mark - Values

static NSString *wq_sqlite_quote_identifier(NSString *name)
{
    return [NSString stringWithFormat:@"\"%@\"", [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

// The name that reaches a table's rowid ("rowid", "_rowid_" or "oid", the
// first no column shadows); nil for views and WITHOUT ROWID tables.
static NSString *wq_sqlite_rowid_alias(sqlite3 *db, NSString *table)
{
    NSMutableSet *names = [NSMutableSet new];
    sqlite3_stmt *stmt = NULL;
    NSString *info = [NSString stringWithFormat:@"PRAGMA table_xinfo(%@)", wq_sqlite_quote_identifier(table)];
    if (sqlite3_prepare_v2(db, info.UTF8String, -1, &stmt, NULL) == SQLITE_OK)
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *n = sqlite3_column_text(stmt, 1);
            if (n) [names addObject:@((const char *)n).lowercaseString];
        }
    sqlite3_finalize(stmt);
    for (NSString *alias in @[@"rowid", @"_rowid_", @"oid"]) {
        if ([names containsObject:alias]) continue;
        NSString *probe = [NSString stringWithFormat:@"SELECT %@ FROM %@ LIMIT 0", alias, wq_sqlite_quote_identifier(table)];
        stmt = NULL;
        BOOL ok = sqlite3_prepare_v2(db, probe.UTF8String, -1, &stmt, NULL) == SQLITE_OK;
        sqlite3_finalize(stmt);
        return ok ? alias : nil;
    }
    return nil;
}

#pragma mark - Row detail

// Text typed for a field, bound the way the field held its value before:
// numbers stay numbers when the text is one; everything else is text (the
// column's affinity may still convert it).
static BOOL wq_sqlite_bind_typed(sqlite3_stmt *stmt, int index, NSString *text, int previousType)
{
    NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSScanner *scanner = [NSScanner scannerWithString:t];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    long long i = 0;
    double d = 0;
    // NSScanner clamps an out-of-range integer to LLONG_MAX and says YES:
    // such a value goes on as a real, as SQLite itself reads the literal.
    BOOL integer = wq_sqlite_exact_integer(t, &i);
    if (previousType == SQLITE_INTEGER && integer) { sqlite3_bind_int64(stmt, index, i); return YES; }
    scanner.scanLocation = 0;
    if ((previousType == SQLITE_FLOAT || previousType == SQLITE_INTEGER) && [scanner scanDouble:&d] && scanner.isAtEnd && isfinite(d)) {
        sqlite3_bind_double(stmt, index, d);
        return YES;
    }
    // Text that can't be encoded is refused, not written as '' (review DR-29).
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8) return NO;
    sqlite3_bind_text(stmt, index, utf8.length ? utf8.bytes : "", (int)utf8.length, SQLITE_TRANSIENT);
    return YES;
}

@interface WQSQLiteRowViewController : UITableViewController <WQUnsavedEditing>
- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot table:(nullable NSString *)table rowidAlias:(nullable NSString *)alias
                           rowid:(long long)rowid columns:(NSArray<NSString *> *)columns values:(NSArray<NSString *> *)values
                           types:(NSArray<NSNumber *> *)types title:(NSString *)title;
@property (nonatomic, copy, nullable) void (^onChange)(NSNumber *oldRowid, NSNumber *newRowid, NSArray<NSString *> *values, NSArray<NSNumber *> *types);
@end

@implementation WQSQLiteRowViewController {
    WQSQLiteSnapshot *_snapshot;
    NSString *_table, *_alias;
    long long _rowid;
    BOOL _updating;
    NSArray<NSString *> *_columns;
    NSArray<NSString *> *_values;
    NSArray<NSNumber *> *_types;
}

- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot table:(NSString *)table rowidAlias:(NSString *)alias
                           rowid:(long long)rowid columns:(NSArray<NSString *> *)columns values:(NSArray<NSString *> *)values
                           types:(NSArray<NSNumber *> *)types title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _snapshot = snapshot;
        _table = [table copy];
        _alias = [alias copy];
        _rowid = rowid;
        _columns = [columns copy];
        _values = [values copy];
        _types = [types copy];
        self.title = title;
    }
    return self;
}

- (BOOL)editable { return _snapshot.editing && _table && _alias && !_updating; }

- (BOOL)wq_needsLeaveConfirmation { return NO; }
- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if (_snapshot.owner) [_snapshot.owner confirmLeaveThen:proceed];
    else proceed();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_columns.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return _columns[(NSUInteger)section]; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return self.editable && section == (NSInteger)_columns.count - 1 ? WQLocalized(@"Tap a value to change it.") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"v"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"v"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.text = _values[(NSUInteger)indexPath.section];
    c.textProperties.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    c.textProperties.numberOfLines = 0;
    cell.contentConfiguration = c;
    cell.selectionStyle = self.editable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.editable) return;
    NSUInteger column = (NSUInteger)indexPath.section;
    int type = _types[column].intValue;
    if (type == SQLITE_BLOB) {
        wq_alert(self, @"Can't edit here", @"Binary values can't be edited here. Use SQL with a hex literal, for example UPDATE t SET c = X'00ff' WHERE rowid = 1.");
        return;
    }
    if (type == WQSQLiteTextRaw) {
        wq_alert(self, @"Can't edit here", @"This text has bytes that aren't plain UTF-8 (invalid or NUL bytes), so editing it here would change bytes you didn't touch. Use SQL with a hex literal, for example UPDATE t SET c = CAST(X'610062' AS TEXT) WHERE rowid = 1.");
        return;
    }
    NSString *name = _columns[column];
    UIAlertController *alert = wq_alert_controller(WQVerbatim(name), nil, UIAlertControllerStyleAlert);
    NSString *current = type == SQLITE_NULL ? @"" : _values[column];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = current;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeWhileEditing;
        f.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    }];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Set NULL", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self setColumn:column text:nil];
    })];
    [alert addAction:wq_alert_action(@"Save", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *typed = alert.textFields.firstObject.text ?: @"";
        // Unchanged text writes nothing: a NULL stays NULL instead of
        // becoming '', and a number keeps its exact value (review DR-29).
        if ([typed isEqualToString:current]) return;
        [self setColumn:column text:typed];
    })];
    alert.preferredAction = alert.actions.lastObject;
    [self presentViewController:alert animated:YES completion:nil];
}

// Writes one field of this row in the copy, then reads the row back.
- (void)setColumn:(NSUInteger)column text:(nullable NSString *)text
{
    _updating = YES;
    WQSQLiteSnapshot *snapshot = _snapshot;
    NSString *table = wq_sqlite_quote_identifier(_table), *alias = _alias;
    NSString *name = _columns[column];
    int previousType = _types[column].intValue;
    long long rowid = _rowid;
    NSUInteger count = _columns.count;
    dispatch_async(snapshot.queue, ^{
        NSString *error = nil;
        NSString *sql = [NSString stringWithFormat:@"UPDATE %@ SET %@ = ? WHERE %@ = ? RETURNING %@", table, wq_sqlite_quote_identifier(name), alias, alias];
        long long updatedRowid = rowid;
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(snapshot.db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            error = @(sqlite3_errmsg(snapshot.db));
        } else {
            BOOL bound = YES;
            if (text) bound = wq_sqlite_bind_typed(stmt, 1, text, previousType);
            else sqlite3_bind_null(stmt, 1);
            sqlite3_bind_int64(stmt, 2, rowid);
            int rc = bound ? sqlite3_step(stmt) : SQLITE_MISUSE;
            if (!bound) error = WQLocalized(@"The text can't be stored as UTF-8, so nothing was changed.");
            if (rc == SQLITE_ROW) {
                updatedRowid = sqlite3_column_int64(stmt, 0);
                if (sqlite3_step(stmt) != SQLITE_DONE) error = @(sqlite3_errmsg(snapshot.db));
            } else if (bound) {
                error = rc == SQLITE_DONE ? WQLocalized(@"The row is gone.") : @(sqlite3_errmsg(snapshot.db));
            }
        }
        sqlite3_finalize(stmt);
        NSMutableArray *values = nil, *types = nil;
        if (!error) {
            NSString *read = [NSString stringWithFormat:@"SELECT * FROM %@ WHERE %@ = ?", table, alias];
            stmt = NULL;
            if (sqlite3_prepare_v2(snapshot.db, read.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_int64(stmt, 1, updatedRowid);
                if (sqlite3_step(stmt) == SQLITE_ROW && (NSUInteger)sqlite3_column_count(stmt) == count) {
                    values = [NSMutableArray new];
                    types = [NSMutableArray new];
                    for (int i = 0; i < (int)count; i++) {
                        int kind = 0;
                        [values addObject:wq_sqlite_value(stmt, i, YES, &kind)];
                        [types addObject:@(kind)];
                    }
                }
            }
            sqlite3_finalize(stmt);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_updating = NO;
            if (error) { wq_alert(self, @"Cannot change", error); return; }
            self->_rowid = updatedRowid;
            [snapshot changed];
            if (values) {
                self->_values = values;
                self->_types = types;
                if (self.onChange) self.onChange(@(rowid), @(updatedRowid), values, types);
            } else {
                // The list re-reads itself (the generation changed); this
                // screen would show the old values, so stop offering edits.
                self->_table = nil;
                wq_alert(self, @"Done", @"The value was changed in the copy, but the row could not be read again. Go back to see the current rows.");
            }
            [self.tableView reloadData];
        });
    });
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    NSString *value = _values[(NSUInteger)indexPath.section];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        return [UIMenu menuWithChildren:@[[UIAction actionWithTitle:WQLocalizedNullable(@"Copy") image:[UIImage systemImageNamed:@"doc.on.doc"]
                                                          identifier:nil handler:^(UIAction *__unused a) {
            UIPasteboard.generalPasteboard.string = value;
        }]]];
    }];
}

@end

#pragma mark - Rows (a table, a view or a query)

@interface WQSQLiteRowsViewController : UITableViewController <WQUnsavedEditing>
- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot sql:(NSString *)sql title:(NSString *)title
                     exportName:(nullable NSString *)exportName limit:(NSUInteger)limit;
// The rows of one table: loaded with their rowid so they can be edited.
- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot table:(NSString *)table;
@end

@implementation WQSQLiteRowsViewController {
    WQSQLiteSnapshot *_snapshot;
    NSString *_sql;
    NSString *_exportName;
    NSUInteger _limit;            // 0 = page through everything
    NSArray<NSString *> *_columns;
    NSMutableArray<NSArray<NSString *> *> *_rows;
    NSMutableArray<NSArray<NSNumber *> *> *_types;
    NSMutableArray<NSNumber *> *_rowids;
    NSString *_table, *_alias;       // _alias: how this table's rowid is reached, if it has one
    BOOL _aliasResolved;
    NSUInteger _generation;
    NSUInteger _loadEpoch;            // bumps when the shown rows are thrown away
    BOOL _loading, _done;
    NSString *_error;
    NSMutableArray<NSString *> *_exportDirs;
    BOOL _exporting;
}

- (void)dealloc
{
    for (NSString *dir in _exportDirs) [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot table:(NSString *)table
{
    if ((self = [self initWithSnapshot:snapshot sql:[@"SELECT * FROM " stringByAppendingString:wq_sqlite_quote_identifier(table)]
                                 title:table exportName:table limit:0]))
        _table = [table copy];
    return self;
}

- (BOOL)wq_needsLeaveConfirmation { return NO; }
- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if (_snapshot.owner) [_snapshot.owner confirmLeaveThen:proceed];
    else proceed();
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Changed through SQL (or another screen) since these rows were read.
    if (_generation != _snapshot.generation && (_rows.count || _done)) {
        _generation = _snapshot.generation;
        _loadEpoch++;
        [_rows removeAllObjects];
        [_types removeAllObjects];
        [_rowids removeAllObjects];
        _done = NO;
        _error = nil;
        _columns = nil;
        [self.tableView reloadData];
        [self loadMore];
    }
}

- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot sql:(NSString *)sql title:(NSString *)title
                     exportName:(NSString *)exportName limit:(NSUInteger)limit
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _snapshot = snapshot;
        _sql = [sql copy];
        _exportName = [exportName copy];
        _limit = limit;
        _rows = [NSMutableArray new];
        _types = [NSMutableArray new];
        _rowids = [NSMutableArray new];
        _generation = snapshot.generation;
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (_exportName) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"CSV") style:UIBarButtonItemStylePlain
                                                                                 target:self action:@selector(exportCSV:)];
    }
    [self loadMore];
}

- (void)loadMore
{
    if (_loading || _done) return;
    _loading = YES;
    NSUInteger offset = _rows.count;
    NSUInteger page = _limit ? _limit : kWQSQLitePage;
    WQSQLiteSnapshot *snapshot = _snapshot;
    NSString *table = _table, *knownAlias = _alias;
    BOOL aliasResolved = _aliasResolved;
    NSNumber *lastRowid = _rowids.count == _rows.count ? _rowids.lastObject : nil;
    NSString *baseSQL = _sql;
    NSUInteger limit = _limit;
    // The page belongs to the rows shown now: a reset, a delete or an edit
    // while it loads makes its offset stale, so it is dropped and re-read.
    NSUInteger epoch = _loadEpoch, generation = _generation;
    dispatch_async(snapshot.queue, ^{
        NSString *alias = aliasResolved ? knownAlias : (table ? wq_sqlite_rowid_alias(snapshot.db, table) : nil);
        // Tables with a rowid page by it ("after the last row shown", in
        // rowid order, which is the order a plain scan gives anyway): OFFSET
        // reads and drops every earlier row again, for each page. Other
        // tables page with LIMIT/OFFSET; a query (which may be a PRAGMA or
        // EXPLAIN, and can't be wrapped) runs as typed and stops after
        // `limit` rows.
        NSString *after = offset && lastRowid ? [NSString stringWithFormat:@" WHERE %@ > %lld", alias, lastRowid.longLongValue] : @"";
        NSString *sql = limit ? baseSQL
            : alias && (!offset || lastRowid)
                    ? [NSString stringWithFormat:@"SELECT %@ AS \"__wq_rowid\", * FROM %@%@ ORDER BY %@ LIMIT %lu", alias,
                       wq_sqlite_quote_identifier(table), after, alias, (unsigned long)page]
            : alias ? [NSString stringWithFormat:@"SELECT %@ AS \"__wq_rowid\", * FROM %@ LIMIT %lu OFFSET %lu", alias,
                       wq_sqlite_quote_identifier(table), (unsigned long)page, (unsigned long)offset]
                    : [NSString stringWithFormat:@"SELECT * FROM (%@) LIMIT %lu OFFSET %lu", baseSQL, (unsigned long)page, (unsigned long)offset];
        int first = alias ? 1 : 0;
        NSMutableArray *columns = [NSMutableArray new];
        NSMutableArray *rows = [NSMutableArray new], *types = [NSMutableArray new], *rowids = [NSMutableArray new];
        NSString *error = nil;
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(snapshot.db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            error = @(sqlite3_errmsg(snapshot.db));
        } else if (!sqlite3_stmt_readonly(stmt)) {
            error = WQLocalized(@"Only read-only statements can run here.");
        } else {
            int count = sqlite3_column_count(stmt);
            for (int i = first; i < count; i++) [columns addObject:@(sqlite3_column_name(stmt, i) ?: "?")];
            int rc = SQLITE_DONE;
            while (rows.count < page && (rc = sqlite3_step(stmt)) == SQLITE_ROW) {
                NSMutableArray *values = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
                NSMutableArray *kinds = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
                for (int i = first; i < count; i++) {
                    int kind = 0;
                    [values addObject:wq_sqlite_value(stmt, i, YES, &kind)];
                    [kinds addObject:@(kind)];
                }
                [rows addObject:values];
                [types addObject:kinds];
                if (alias) [rowids addObject:@(sqlite3_column_int64(stmt, 0))];
            }
            if (rows.count < page && rc != SQLITE_DONE) error = @(sqlite3_errmsg(snapshot.db));
        }
        sqlite3_finalize(stmt);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_loading = NO;
            if (epoch != self->_loadEpoch || generation != self->_generation || snapshot != self->_snapshot) {
                [self loadMore];
                return;
            }
            self->_alias = alias;
            self->_aliasResolved = YES;
            if (error) { self->_error = error; self->_done = YES; [self.tableView reloadData]; return; }
            if (!self->_columns) self->_columns = columns;
            [self->_rows addObjectsFromArray:rows];
            [self->_types addObjectsFromArray:types];
            [self->_rowids addObjectsFromArray:rowids];
            if (rows.count < page || self->_limit) self->_done = YES;
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (_error || (!_rows.count && _done)) ? 1 : (NSInteger)_rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_error || !_columns) return nil;
    NSString *more = _done ? @"" : @"+";
    if (_limit && _rows.count >= _limit) more = WQLocalizedFormat(@" (first %lu)", (unsigned long)_limit);
    return WQLocalizedFormat(@"%lu%@ rows · %lu columns", (unsigned long)_rows.count, more, (unsigned long)_columns.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"row"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_error || !_rows.count) {
        c.text = _error ?: WQLocalized(@"No rows");
        c.textProperties.color = _error ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        c.textProperties.numberOfLines = 0;
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSArray<NSString *> *values = _rows[(NSUInteger)indexPath.row];
    NSMutableArray *parts = [NSMutableArray new];
    for (NSUInteger i = 0; i < values.count && i < _columns.count; i++) {
        NSString *v = values[i];
        if (v.length > 80) v = [[v substringToIndex:80] stringByAppendingString:@"…"];
        [parts addObject:[NSString stringWithFormat:@"%@: %@", _columns[i], v]];
    }
    c.text = parts.firstObject;
    c.secondaryText = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" · "] : nil;
    c.textProperties.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    c.secondaryTextProperties.numberOfLines = 2;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if ((NSUInteger)indexPath.row + 20 >= _rows.count) [self loadMore];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_error || (NSUInteger)indexPath.row >= _rows.count) return;
    NSUInteger row = (NSUInteger)indexPath.row;
    BOOL hasRowid = row < _rowids.count;
    WQSQLiteRowViewController *detail = [[WQSQLiteRowViewController alloc]
        initWithSnapshot:_snapshot table:hasRowid ? _table : nil rowidAlias:hasRowid ? _alias : nil
                   rowid:hasRowid ? _rowids[row].longLongValue : 0 columns:_columns values:_rows[row]
                   types:row < _types.count ? _types[row] : @[]
                   title:WQLocalizedFormat(@"Row %ld", (long)indexPath.row + 1)];
    __weak typeof(self) weakSelf = self;
    detail.onChange = ^(NSNumber *oldRowid, NSNumber *newRowid, NSArray<NSString *> *values, NSArray<NSNumber *> *types) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // A changed rowid moves the row in the table's order: patching it in
        // place would make the next page skip one row and repeat this one.
        // The stale generation makes the list load again when it reappears.
        if (![oldRowid isEqualToNumber:newRowid]) return;
        NSUInteger at = [strongSelf->_rowids indexOfObject:oldRowid];
        if (at == NSNotFound) return;
        strongSelf->_rowids[at] = newRowid;
        strongSelf->_rows[at] = values;
        strongSelf->_types[at] = types;
        strongSelf->_generation = strongSelf->_snapshot.generation;
        [strongSelf.tableView reloadData];
    };
    [self.navigationController pushViewController:detail animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSUInteger row = (NSUInteger)indexPath.row;
    if (!_snapshot.editing || !_alias || _error || row >= _rowids.count || !wq_deleting_allowed()) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:WQLocalizedNullable(@"Delete") handler:^(UIContextualAction *__unused a, UIView *__unused v, void (^done)(BOOL)) {
        [self deleteRowWithRowid:self->_rowids[row] done:done];
    }];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[del]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

- (void)deleteRowWithRowid:(NSNumber *)rowid done:(void (^)(BOOL))done
{
    WQSQLiteSnapshot *snapshot = _snapshot;
    NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = ?", wq_sqlite_quote_identifier(_table), _alias];
    dispatch_async(snapshot.queue, ^{
        NSString *error = nil;
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(snapshot.db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) error = @(sqlite3_errmsg(snapshot.db));
        else {
            sqlite3_bind_int64(stmt, 1, rowid.longLongValue);
            if (sqlite3_step(stmt) != SQLITE_DONE) error = @(sqlite3_errmsg(snapshot.db));
        }
        sqlite3_finalize(stmt);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { done(NO); wq_alert(self, @"Cannot delete", error); return; }
            [snapshot changed];
            self->_generation = snapshot.generation;
            NSUInteger at = [self->_rowids indexOfObject:rowid];
            if (at != NSNotFound) {
                [self->_rowids removeObjectAtIndex:at];
                [self->_rows removeObjectAtIndex:at];
                if (at < self->_types.count) [self->_types removeObjectAtIndex:at];
            }
            done(YES);
            [self.tableView reloadData];
        });
    });
}

- (void)exportCSV:(UIBarButtonItem *)sender
{
    if (_exporting) return;
    WQSQLiteSnapshot *snapshot = _snapshot;
    NSString *sql = _sql;
    NSString *name = [[_exportName stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByAppendingPathExtension:@"csv"];
    // A new folder per export: never a file left from an earlier export.
    NSString *dir = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"wq-sqlite-export"]
                     stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) {
        wq_alert(self, @"Cannot export", WQLocalized(@"cannot create the CSV file"));
        return;
    }
    if (!_exportDirs) _exportDirs = [NSMutableArray new];
    [_exportDirs addObject:dir];
    NSString *out = [dir stringByAppendingPathComponent:name];
    _exporting = YES;
    sender.enabled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(snapshot.queue, ^{
        NSString *error = nil;
        // Leaving the screen stops the export.
        BOOL ok = wq_sqlite_export_csv(snapshot.db, sql, out, ^BOOL { return weakSelf == nil; }, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!ok) [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
            if (!strongSelf) return;
            strongSelf->_exporting = NO;
            sender.enabled = YES;
            if (!ok) { wq_alert(strongSelf, @"Cannot export", error ?: @"?"); return; }
            wq_share(strongSelf, out, nil);
        });
    });
}

@end

#pragma mark - Query

@interface WQSQLiteQueryViewController : UIViewController <WQUnsavedEditing>
- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot;
@end

@implementation WQSQLiteQueryViewController {
    WQSQLiteSnapshot *_snapshot;
    UITextView *_textView;
    BOOL _running;
}

- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _snapshot = snapshot;
        self.title = WQLocalizedNullable(@"SQL");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    _textView.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;   // SQL stays left to right
    _textView.textAlignment = NSTextAlignmentLeft;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.smartQuotesType = UITextSmartQuotesTypeNo;
    _textView.smartDashesType = UITextSmartDashesTypeNo;
    _textView.text = @"SELECT name, type FROM sqlite_master";
    [self.view addSubview:_textView];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_textView.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Run") style:UIBarButtonItemStyleProminent
                                                                             target:self action:@selector(run)];
    [_textView becomeFirstResponder];
}

- (BOOL)wq_needsLeaveConfirmation { return _running; }
- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if (_running) return;
    if (_snapshot.owner) [_snapshot.owner confirmLeaveThen:proceed];
    else proceed();
}

static int wq_sqlite_cancel_query(void *context)
{
    return [(__bridge WQScanCancellation *)context isCancelled];
}

// Keep the script inside the savepoint owned by this screen.
static int wq_sqlite_edit_authorizer(void *__unused context, int action, const char *__unused first,
                                    const char *__unused second, const char *__unused database,
                                    const char *__unused trigger)
{
    switch (action) {
        case SQLITE_TRANSACTION:
        case SQLITE_SAVEPOINT:
        case SQLITE_ATTACH:
        case SQLITE_DETACH:
            return SQLITE_DENY;
        default:
            return SQLITE_OK;
    }
}

- (void)run
{
    if (_running) return;
    NSString *sql = [_textView.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([sql hasSuffix:@";"]) sql = [[sql substringToIndex:sql.length - 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!sql.length) return;

    WQSQLiteSnapshot *snapshot = _snapshot;
    BOOL editing = snapshot.editing;
    WQScanCancellation *cancellation = [WQScanCancellation new];
    UIAlertController *progress = wq_alert_controller(@"SQL", @"Starting…", UIAlertControllerStyleAlert);
    [progress addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) {
        [cancellation cancel];
    })];
    _running = YES;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self presentViewController:progress animated:YES completion:nil];
    dispatch_async(snapshot.queue, ^{
        sqlite3 *db = snapshot.db;
        NSString *error = nil;
        BOOL writes = NO, returnsRows = NO;
        NSUInteger statements = 0;
        long long changed = 0;
        sqlite3_progress_handler(db, 1000, wq_sqlite_cancel_query, (__bridge void *)cancellation);
        const char *cursor = sql.UTF8String;
        while (*cursor && !cancellation.isCancelled) {
            sqlite3_stmt *stmt = NULL;
            const char *tail = NULL;
            int rc = sqlite3_prepare_v2(db, cursor, -1, &stmt, &tail);
            if (rc == SQLITE_OK && stmt) {
                statements++;
                writes |= !sqlite3_stmt_readonly(stmt);
                returnsRows = sqlite3_column_count(stmt) > 0;
            }
            sqlite3_finalize(stmt);
            // After a write, a later statement may only compile once the
            // earlier ones ran (CREATE TABLE t; INSERT INTO t …): leave its
            // errors to the run inside the savepoint.
            if (rc != SQLITE_OK && writes) break;
            if (rc != SQLITE_OK) { error = @(sqlite3_errmsg(db)); break; }
            cursor = tail;
        }

        BOOL committed = NO;
        if (!error && !cancellation.isCancelled) {
            if (writes && !editing) {
                error = WQLocalized(@"Only read-only statements (SELECT, read-only PRAGMA, EXPLAIN) can run here. Tap Edit on the database screen to change it.");
            } else if (writes) {
                long long before = sqlite3_total_changes64(db);
                int rc = sqlite3_exec(db, "SAVEPOINT wq_edit", NULL, NULL, NULL);
                if (rc == SQLITE_OK) {
                    sqlite3_set_authorizer(db, wq_sqlite_edit_authorizer, NULL);
                    rc = sqlite3_exec(db, sql.UTF8String, NULL, NULL, NULL);
                    sqlite3_set_authorizer(db, NULL, NULL);
                    if (rc != SQLITE_OK) error = @(sqlite3_errmsg(db));
                    sqlite3_progress_handler(db, 0, NULL, NULL);
                    if (rc == SQLITE_OK && !cancellation.isCancelled) {
                        committed = sqlite3_exec(db, "RELEASE wq_edit", NULL, NULL, NULL) == SQLITE_OK;
                        if (!committed) error = @(sqlite3_errmsg(db));
                    }
                    if (!committed) {
                        sqlite3_exec(db, "ROLLBACK TO wq_edit", NULL, NULL, NULL);
                        sqlite3_exec(db, "RELEASE wq_edit", NULL, NULL, NULL);
                    }
                    changed = sqlite3_total_changes64(db) - before;
                } else {
                    error = @(sqlite3_errmsg(db));
                }
            } else if (statements == 0) {
                error = WQLocalized(@"Nothing to run.");
            } else if (statements > 1) {
                error = WQLocalized(@"Run one statement at a time.");
            } else if (!returnsRows) {
                error = WQLocalized(@"This statement returns no rows.");
            }
        }
        sqlite3_progress_handler(db, 0, NULL, NULL);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (committed) [snapshot changed];
            void (^finish)(void) = ^{
                self->_running = NO;
                self.navigationItem.rightBarButtonItem.enabled = YES;
                if (cancellation.isCancelled && !committed) return;
                if (error) { wq_alert(self, @"Cannot run", error); return; }
                if (committed) {
                    wq_alert(self, @"Done", WQLocalizedFormat(@"%lld rows changed in the copy. Save on the database screen writes them to the app.", changed));
                    return;
                }
                WQSQLiteRowsViewController *rows = [[WQSQLiteRowsViewController alloc]
                    initWithSnapshot:snapshot sql:sql title:WQLocalizedNullable(@"Result") exportName:@"query" limit:kWQSQLiteQueryLimit];
                [self.navigationController pushViewController:rows animated:YES];
            };
            if (self.presentedViewController == progress) [progress dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}

@end

#pragma mark - Tables

@interface WQSQLiteViewController () <WQUnsavedEditing>
@end

@implementation WQSQLiteViewController {
    NSString *_path;
    BOOL _readOnly;
    WQSQLiteSnapshot *_snapshot;
    NSArray<NSDictionary *> *_tables;   // name, type
    NSMutableDictionary<NSString *, NSNumber *> *_counts;
    NSString *_error;
    BOOL _loading, _saving;
    NSUInteger _shownGeneration;
    WQScanCancellation *_counting;      // the running row count, if any
}

- (instancetype)initWithPath:(NSString *)path
{
    return [self initWithPath:path readOnly:NO];
}

- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _path = [path copy];
        _readOnly = readOnly;
        _counts = [NSMutableDictionary new];
        _loading = YES;
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    __weak typeof(self) weakSelf = self;
    self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) {
        [weakSelf confirmLeaveThen:^{ [weakSelf.navigationController popViewControllerAnimated:YES]; }];
    }];
    [self updateButtons];
    [self openSnapshot];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Tables may have been created, dropped or filled through SQL.
    if (_snapshot && _shownGeneration != _snapshot.generation) [self loadTables];
    [self updateButtons];
}

// (Re)copies the database and lists its tables; also how Discard works.
- (void)openSnapshot
{
    _loading = YES;
    _snapshot = nil;
    _tables = nil;
    _error = nil;
    [_counts removeAllObjects];
    [self.tableView reloadData];
    [self updateButtons];
    NSString *path = _path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        WQSQLiteSnapshot *snapshot = [[WQSQLiteSnapshot alloc] initWithPath:path error:&error];
        if (!snapshot) wq_log(@"sqlite: cannot open %@ (%@)", path, error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_snapshot = snapshot;
            snapshot.owner = self;
            self->_error = snapshot ? nil : error;
            if (snapshot) [self loadTables];
            else { self->_loading = NO; [self.tableView reloadData]; [self updateButtons]; }
        });
    });
}

- (void)loadTables
{
    WQSQLiteSnapshot *snapshot = _snapshot;
    _shownGeneration = snapshot.generation;
    dispatch_async(snapshot.queue, ^{
        NSMutableArray *tables = [NSMutableArray new];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(snapshot.db, "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') ORDER BY type, name",
                               -1, &stmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const unsigned char *name = sqlite3_column_text(stmt, 0), *type = sqlite3_column_text(stmt, 1);
                if (name && type) [tables addObject:@{ @"name": @((const char *)name), @"type": @((const char *)type) }];
            }
        }
        sqlite3_finalize(stmt);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (snapshot != self->_snapshot) return;
            self->_loading = NO;
            self->_tables = tables;
            [self->_counts removeAllObjects];
            [self.tableView reloadData];
            [self updateButtons];
            [self countRows];
        });
    });
}

// Edit (when the database may be changed), or Save while editing; SQL.
- (void)updateButtons
{
    UIBarButtonItem *sql = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"SQL") style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(openQuery)];
    sql.enabled = _snapshot != nil && !_saving;
    NSMutableArray *items = [NSMutableArray new];
    if (_snapshot.editing) {
        UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Save") style:UIBarButtonItemStyleProminent
                                                                target:self action:@selector(confirmSave)];
        save.enabled = _snapshot.dirty && !_saving;
        [items addObject:save];
    } else if (!_readOnly) {
        UIBarButtonItem *edit = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Edit") style:UIBarButtonItemStylePlain
                                                                target:self action:@selector(startEditing)];
        edit.enabled = _snapshot != nil;
        [items addObject:edit];
    }
    [items addObject:sql];
    self.navigationItem.rightBarButtonItems = items;
}

- (void)startEditing
{
    if (!_snapshot) return;
    if (!_snapshot.sourceState) {
        wq_alert(self, @"Can't edit this copy", @"The app changed the database while it was being copied. Close the app, then open the database again.");
        return;
    }
    UIAlertController *alert = wq_alert_controller(@"Edit database",
        @"You change WQ Files' copy: edit a value by tapping it in a row, delete rows by swiping, or run SQL. Nothing reaches the app until you tap Save.\n\nBefore saving, force-quit the app (swipe it away in the app switcher): saving while it runs can corrupt its data. The previous database is kept in Backups.",
        UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Edit", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        WQSQLiteSnapshot *snapshot = self->_snapshot;
        // Not dispatch_sync: the queue may be counting rows of a large
        // database, and the main thread would wait for all of it. The
        // counts are stopped (their statement too) and start again after.
        [self->_counting cancel];
        dispatch_async(snapshot.queue, ^{
            sqlite3_exec(snapshot.db, "PRAGMA query_only = OFF", NULL, NULL, NULL);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (snapshot != self->_snapshot) return;
                snapshot.editing = YES;
                [self updateButtons];
                [self.tableView reloadData];
                [self countRows];
            });
        });
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmSave { [self confirmSaveThen:nil]; }

- (void)confirmSaveThen:(nullable void (^)(void))after
{
    if (!_snapshot.dirty || _saving) return;
    UIAlertController *alert = wq_alert_controller(@"Save to the app?",
        @"Force-quit the app first (swipe it away in the app switcher): saving while it runs can corrupt its data. The previous database is kept in Backups.",
        UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Save", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { [self saveThen:after]; })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveThen:(nullable void (^)(void))after
{
    WQSQLiteSnapshot *snapshot = _snapshot;
    NSDictionary *state = snapshot.sourceState;
    NSString *path = _path;
    if (!snapshot || !state) return;
    _saving = YES;
    [self updateButtons];
    dispatch_async(snapshot.queue, ^{
        NSDictionary *newState = nil;
        NSString *error = nil, *unit = nil;
        BOOL ok = wq_sqlite_save(snapshot.db, path, state, &newState, &unit, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_saving = NO;
            if (ok) {
                snapshot.sourceState = newState;
                snapshot.dirty = NO;
            }
            [self updateButtons];
            if (!ok) { wq_alert(self, @"Not saved", error ?: @"?"); return; }
            if (after) { after(); return; }
            wq_alert(self, @"Saved", @"The changes are in the app's database. The previous version is in Backups.");
        });
    });
}

- (BOOL)wq_needsLeaveConfirmation { return _snapshot.dirty || _saving; }

- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if (_saving) return;
    if (!_snapshot.dirty) { proceed(); return; }
    UIAlertController *alert = wq_alert_controller(@"Unsaved changes",
        @"The changes to this database have not been saved to the app.", UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Keep Editing", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Discard", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        self->_snapshot.dirty = NO;
        proceed();
    })];
    [alert addAction:wq_alert_action(@"Save…", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self confirmSaveThen:proceed];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

// Row counts for tables, one at a time in the background (big tables take a while).
- (void)countRows
{
    WQSQLiteSnapshot *snapshot = _snapshot;
    NSArray *tables = _tables;
    NSUInteger generation = _shownGeneration;
    // Counts belong to one listing: a newer listing (after a change) stops
    // this one, and late results of an older one are dropped.
    [_counting cancel];
    WQScanCancellation *counting = [WQScanCancellation new];
    _counting = counting;
    __weak typeof(self) weakSelf = self;
    dispatch_async(snapshot.queue, ^{
        // Lets a cancel end a count(*) that is already running.
        sqlite3_progress_handler(snapshot.db, 20000, wq_sqlite_cancel_query, (__bridge void *)counting);
        for (NSDictionary *table in tables) {
            if (!weakSelf || counting.isCancelled) break;
            if (![table[@"type"] isEqualToString:@"table"]) continue;
            NSString *sql = [@"SELECT count(*) FROM " stringByAppendingString:wq_sqlite_quote_identifier(table[@"name"])];
            sqlite3_stmt *stmt = NULL;
            long long count = -1;
            if (sqlite3_prepare_v2(snapshot.db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW)
                count = sqlite3_column_int64(stmt, 0);
            sqlite3_finalize(stmt);
            NSString *name = table[@"name"];
            dispatch_async(dispatch_get_main_queue(), ^{
                WQSQLiteViewController *strongSelf = weakSelf;
                if (!strongSelf || count < 0 || counting.isCancelled || snapshot != strongSelf->_snapshot ||
                    generation != strongSelf->_shownGeneration || generation != snapshot.generation) return;
                strongSelf->_counts[name] = @(count);
                [strongSelf.tableView reloadData];
            });
        }
        sqlite3_progress_handler(snapshot.db, 0, NULL, NULL);
    });
}

- (void)openQuery
{
    if (!_snapshot) return;
    [self.navigationController pushViewController:[[WQSQLiteQueryViewController alloc] initWithSnapshot:_snapshot] animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (_loading || _error || !_tables.count) ? 1 : (NSInteger)_tables.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return _tables.count ? WQLocalized(@"Tables and views") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (!_snapshot) return nil;
    if (_snapshot.editing)
        return WQLocalized(@"Editing WQ Files' copy: tap a value in a row to change it, swipe a row to delete it, or use SQL. Save writes the copy to the app; force-quit the app first.");
    NSString *wal = _snapshot.copiedWAL ? WQLocalized(@" and its -wal file") : @"";
    return WQLocalizedFormat(@"Read-only. This is a copy of the database%@ made when it was opened; the app's own file is not changed. Close the app first for an up-to-date copy.", wal);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"t"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"t"];
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (_loading) {
        c.text = WQLocalizedNullable(@"Copying and opening…");
    } else if (_error) {
        c.text = [WQLocalized(@"Cannot open this database: ") stringByAppendingString:_error];
        c.textProperties.color = UIColor.systemRedColor;
        c.textProperties.numberOfLines = 0;
    } else if (!_tables.count) {
        c.text = WQLocalizedNullable(@"No tables");
        c.textProperties.color = UIColor.secondaryLabelColor;
    } else {
        NSDictionary *table = _tables[(NSUInteger)indexPath.row];
        BOOL view = [table[@"type"] isEqualToString:@"view"];
        c.text = table[@"name"];
        c.image = [UIImage systemImageNamed:view ? @"eye" : @"tablecells"];
        NSNumber *count = _counts[table[@"name"]];
        c.secondaryText = view ? WQLocalized(@"view") : (count ? WQLocalizedFormat(@"%@ rows", count) : @"…");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_snapshot || (NSUInteger)indexPath.row >= _tables.count) return;
    NSDictionary *table = _tables[(NSUInteger)indexPath.row];
    NSString *name = table[@"name"];
    WQSQLiteRowsViewController *rows = [table[@"type"] isEqualToString:@"table"]
        ? [[WQSQLiteRowsViewController alloc] initWithSnapshot:_snapshot table:name]
        : [[WQSQLiteRowsViewController alloc] initWithSnapshot:_snapshot sql:[@"SELECT * FROM " stringByAppendingString:wq_sqlite_quote_identifier(name)]
                                                         title:name exportName:name limit:0];
    [self.navigationController pushViewController:rows animated:YES];
}

@end
