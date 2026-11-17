//
//  WQInspector.m
//  WQ Files
//
//  See WQInspector.h. Foundation and JavaScriptCore only, so the host tests
//  run it on the Mac.
//

#import "WQInspector.h"
#import "WQLocalization.h"
#import <JavaScriptCore/JavaScriptCore.h>
#include <dlfcn.h>
#include <sys/stat.h>

#pragma mark - Model

@implementation WQInspector
- (BOOL)matchesFileName:(NSString *)fileName
{
    NSString *ext = fileName.pathExtension.lowercaseString;
    for (NSString *e in self.extensions)
        if ([e isEqualToString:@"*"] || (ext.length && [e isEqualToString:ext])) return YES;
    return NO;
}
@end

@implementation WQInspectorRow
@end

@implementation WQInspectorSection
@end

@implementation WQInspectorResult
- (NSString *)plainText
{
    NSMutableString *out = [NSMutableString new];
    if (self.title.length) [out appendFormat:@"%@\n\n", self.title];
    for (WQInspectorSection *s in self.sections) {
        if (s.title.length) [out appendFormat:@"%@\n", s.title];
        for (WQInspectorRow *r in s.rows) [out appendFormat:@"%@: %@\n", r.label, r.value];
        if (s.text.length) [out appendFormat:@"%@\n", s.text];
        [out appendString:@"\n"];
    }
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
@end

#pragma mark - Loading

NSString *wq_inspectors_folder(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Inspectors"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// A plain file directly inside `folder`: no path separators, no links.
static NSString *wq_inspector_file(NSString *folder, id name, NSString **error)
{
    if (![name isKindOfClass:NSString.class] || ![(NSString *)name length] || [name containsString:@"/"] ||
        [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        if (error) *error = WQLocalizedFormat(@"\"%@\" is not a file name in the inspector's folder.", [name description]);
        return nil;
    }
    NSString *path = [folder stringByAppendingPathComponent:name];
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) {
        if (error) *error = WQLocalizedFormat(@"%@ is missing or not a regular file.", name);
        return nil;
    }
    return path;
}

WQInspector *wq_inspector_load(NSString *folder, NSString **error)
{
    NSString *manifestPath = wq_inspector_file(folder, @"manifest.json", error);
    if (!manifestPath) return nil;
    NSData *data = [NSData dataWithContentsOfFile:manifestPath];
    id manifest = data.length && data.length <= 64 * 1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![manifest isKindOfClass:NSDictionary.class]) {
        if (error) *error = WQLocalized(@"manifest.json is not a JSON object (or larger than 64 KB).");
        return nil;
    }
    id name = manifest[@"name"], api = manifest[@"api"], extensions = manifest[@"extensions"];
    if (![name isKindOfClass:NSString.class] || ![(NSString *)name length] || [(NSString *)name length] > 80) {
        if (error) *error = WQLocalized(@"manifest.json needs a \"name\" of 1 to 80 characters.");
        return nil;
    }
    if (![api isKindOfClass:NSNumber.class] || [api integerValue] != 1) {
        if (error) *error = WQLocalized(@"manifest.json needs \"api\": 1.");
        return nil;
    }
    NSMutableArray<NSString *> *exts = [NSMutableArray new];
    if ([extensions isKindOfClass:NSArray.class])
        for (id e in extensions) {
            if (![e isKindOfClass:NSString.class]) continue;
            NSString *clean = [[e lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@". "]];
            if (clean.length && ![exts containsObject:clean]) [exts addObject:clean];
        }
    if (!exts.count) {
        if (error) *error = WQLocalized(@"manifest.json needs \"extensions\", for example [\"json\"] or [\"*\"].");
        return nil;
    }
    NSString *script = wq_inspector_file(folder, manifest[@"script"] ?: @"inspect.js", error);
    if (!script) return nil;
    NSString *dataPath = nil;
    if (manifest[@"data"]) {
        dataPath = wq_inspector_file(folder, manifest[@"data"], error);
        if (!dataPath) return nil;
    } else {
        dataPath = wq_inspector_file(folder, @"data.json", NULL);
    }
    WQInspector *inspector = [WQInspector new];
    inspector.name = name;
    inspector.folder = folder;
    inspector.scriptPath = script;
    inspector.dataPath = dataPath;
    inspector.extensions = exts;
    id description = manifest[@"description"];
    if ([description isKindOfClass:NSString.class] && [(NSString *)description length])
        inspector.inspectorDescription = [(NSString *)description length] > 300 ? [description substringToIndex:300] : description;
    return inspector;
}

NSArray<WQInspector *> *wq_inspectors_in(NSString *folder, NSArray<NSString *> **problems)
{
    NSMutableArray<WQInspector *> *found = [NSMutableArray new];
    NSMutableArray<NSString *> *skipped = [NSMutableArray new];
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil] ?: @[]) {
        if ([entry hasPrefix:@"."]) continue;
        NSString *path = [folder stringByAppendingPathComponent:entry];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        NSString *error = nil;
        WQInspector *inspector = wq_inspector_load(path, &error);
        if (inspector) [found addObject:inspector];
        else [skipped addObject:[NSString stringWithFormat:@"%@: %@", entry, error ?: @"?"]];
    }
    [found sortUsingComparator:^NSComparisonResult(WQInspector *a, WQInspector *b) { return [a.name localizedStandardCompare:b.name]; }];
    if (problems) *problems = skipped;
    return found;
}

#pragma mark - Running

// The execution time limit is JavaScriptCore API that isn't in the public
// headers (JSContextRefPrivate.h); it has been exported for years. Without
// it a script with an endless loop would block its queue until WQ Files quits.
typedef bool (*WQShouldTerminate)(JSContextRef, void *);
typedef void (*WQSetTimeLimit)(JSContextGroupRef, double, WQShouldTerminate, void *);
static bool wq_inspector_terminate(JSContextRef ctx, void *context) { (void)ctx; (void)context; return true; }

static NSString *wq_inspector_cap(NSString *text, BOOL *capped)
{
    if (text.length <= WQInspectorMaxText) return text;
    *capped = YES;
    NSUInteger end = [text rangeOfComposedCharacterSequenceAtIndex:WQInspectorMaxText].location;
    return [[text substringToIndex:end] stringByAppendingString:@"…"];
}

// A row value as text: strings as they are, numbers and booleans written
// out, null/undefined as "—", objects and arrays as compact JSON.
static NSString *wq_inspector_value_text(JSValue *value)
{
    if (value.isUndefined || value.isNull) return @"—";
    if (value.isString) return value.toString;
    if (value.isBoolean) return value.toBool ? @"true" : @"false";
    if (value.isNumber) return value.toString;
    JSValue *json = [value.context[@"JSON"] invokeMethod:@"stringify" withArguments:@[value]];
    return json.isString ? json.toString : value.toString;
}

static NSString *wq_inspector_check(JSValue *result, WQInspectorResult *out)
{
    if (!result.isObject || result.isArray) return WQLocalized(@"inspect() must return an object with \"sections\".");
    JSValue *title = result[@"title"];
    BOOL capped = NO;
    if (!title.isUndefined && !title.isNull) {
        if (!title.isString) return WQLocalized(@"\"title\" must be a string.");
        out.title = wq_inspector_cap(title.toString, &capped);
    }
    JSValue *sections = result[@"sections"];
    if (!sections.isArray) return WQLocalized(@"inspect() must return an object with \"sections\".");
    NSUInteger count = [sections[@"length"] toUInt32], rowsTotal = 0;
    if (count > WQInspectorMaxSections) { count = WQInspectorMaxSections; capped = YES; }
    NSMutableArray<WQInspectorSection *> *list = [NSMutableArray new];
    for (NSUInteger i = 0; i < count; i++) {
        JSValue *s = [sections valueAtIndex:i];
        if (!s.isObject || s.isArray) return WQLocalizedFormat(@"Section %lu is not an object.", (unsigned long)i + 1);
        WQInspectorSection *section = [WQInspectorSection new];
        JSValue *st = s[@"title"], *rows = s[@"rows"], *text = s[@"text"];
        if (!st.isUndefined && !st.isNull) {
            if (!st.isString) return WQLocalizedFormat(@"The title of section %lu must be a string.", (unsigned long)i + 1);
            section.title = wq_inspector_cap(st.toString, &capped);
        }
        if (!text.isUndefined && !text.isNull) {
            if (!text.isString) return WQLocalizedFormat(@"The text of section %lu must be a string.", (unsigned long)i + 1);
            section.text = wq_inspector_cap(text.toString, &capped);
        }
        NSMutableArray<WQInspectorRow *> *rowList = [NSMutableArray new];
        if (!rows.isUndefined && !rows.isNull) {
            if (!rows.isArray) return WQLocalizedFormat(@"The rows of section %lu must be an array.", (unsigned long)i + 1);
            NSUInteger n = [rows[@"length"] toUInt32];
            for (NSUInteger j = 0; j < n; j++) {
                if (rowsTotal >= WQInspectorMaxRows) { capped = YES; break; }
                JSValue *r = [rows valueAtIndex:j];
                if (!r.isObject || r.isArray)
                    return WQLocalizedFormat(@"Row %lu of section %lu is not an object.", (unsigned long)j + 1, (unsigned long)i + 1);
                WQInspectorRow *row = [WQInspectorRow new];
                JSValue *label = r[@"label"];
                row.label = wq_inspector_cap(label.isUndefined || label.isNull ? @"" : wq_inspector_value_text(label), &capped);
                row.value = wq_inspector_cap(wq_inspector_value_text(r[@"value"]), &capped);
                [rowList addObject:row];
                rowsTotal++;
            }
        }
        section.rows = rowList;
        if (!section.rows.count && !section.text && !section.title)
            return WQLocalizedFormat(@"Section %lu has no title, rows or text.", (unsigned long)i + 1);
        [list addObject:section];
    }
    out.sections = list;
    out.capped = capped;
    return nil;
}

// A property list as values JavaScript gets as plain JSON-like data.
static id wq_inspector_plain(id value, NSUInteger depth)
{
    if (depth > 64) return NSNull.null;
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSDate.class]) {
        static NSISO8601DateFormatter *formatter;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            formatter = [NSISO8601DateFormatter new];
            formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        });
        return [formatter stringFromDate:value];
    }
    if ([value isKindOfClass:NSData.class]) return [(NSData *)value base64EncodedStringWithOptions:0];
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray new];
        for (id v in value) [out addObject:wq_inspector_plain(v, depth + 1)];
        return out;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary new];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id v, BOOL *__unused stop) {
            out[[key description]] = wq_inspector_plain(v, depth + 1);
        }];
        return out;
    }
    return [value description] ?: NSNull.null;   // e.g. keyed-archiver UIDs
}

static id wq_inspector_plist(NSData *bytes, BOOL truncated)
{
    if (truncated || bytes.length < 8) return nil;
    BOOL binary = memcmp(bytes.bytes, "bplist0", 7) == 0;
    NSData *head = [bytes subdataWithRange:NSMakeRange(0, MIN(bytes.length, (NSUInteger)1024))];
    NSString *headText = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding] ?: @"";
    if (!binary && ![headText containsString:@"<plist"]) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:nil];
    return plist ? wq_inspector_plain(plist, 0) : nil;
}

// UTF-8 text of the bytes; a capped snapshot may end inside a character.
static NSString *wq_inspector_text(NSData *bytes, BOOL truncated)
{
    NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    for (NSUInteger cut = 1; !text && truncated && cut <= 3 && cut < bytes.length; cut++)
        text = [[NSString alloc] initWithData:[bytes subdataWithRange:NSMakeRange(0, bytes.length - cut)] encoding:NSUTF8StringEncoding];
    return text;
}

static void wq_inspector_release_bytes(void *bytes, void *context) { (void)bytes; CFRelease(context); }

WQInspectorResult *wq_inspector_run(WQInspector *inspector, NSData *bytes, BOOL truncated,
                                    NSString *fileName, unsigned long long fileSize,
                                    NSTimeInterval timeLimit, NSArray<NSString *> **logOut, NSString **error)
{
    if (logOut) *logOut = @[];
    NSData *scriptData = [NSData dataWithContentsOfFile:inspector.scriptPath];
    NSString *script = scriptData.length <= WQInspectorMaxScriptBytes
        ? [[NSString alloc] initWithData:scriptData ?: [NSData data] encoding:NSUTF8StringEncoding] : nil;
    if (!script) {
        if (error) *error = WQLocalized(@"The script can't be read as UTF-8 text (or is larger than 1 MB).");
        return nil;
    }
    id data = NSNull.null;
    if (inspector.dataPath) {
        NSData *raw = [NSData dataWithContentsOfFile:inspector.dataPath];
        data = raw.length <= WQInspectorMaxDataBytes
            ? [NSJSONSerialization JSONObjectWithData:raw ?: [NSData data] options:NSJSONReadingFragmentsAllowed error:nil] : nil;
        if (!data) {
            if (error) *error = WQLocalizedFormat(@"%@ is not valid JSON (or larger than 4 MB).", inspector.dataPath.lastPathComponent);
            return nil;
        }
    }

    JSContextGroupRef group = JSContextGroupCreate();
    static WQSetTimeLimit setTimeLimit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ setTimeLimit = (WQSetTimeLimit)dlsym(RTLD_DEFAULT, "JSContextGroupSetExecutionTimeLimit"); });
    if (setTimeLimit) setTimeLimit(group, timeLimit, wq_inspector_terminate, NULL);
    JSGlobalContextRef global = JSGlobalContextCreateInGroup(group, NULL);
    JSContext *context = [JSContext contextWithJSGlobalContextRef:global];
    JSGlobalContextRelease(global);
    JSContextGroupRelease(group);

    __block NSString *exceptionText = nil;
    context.exceptionHandler = ^(JSContext *__unused c, JSValue *exception) {
        if (exceptionText) return;
        JSValue *line = exception[@"line"];
        exceptionText = line.isNumber ? [NSString stringWithFormat:@"%@ (line %@)", exception.toString, line.toString] : exception.toString;
    };
    NSMutableArray<NSString *> *log = [NSMutableArray new];
    context[@"console"] = @{};
    context[@"console"][@"log"] = ^{
        if (log.count >= WQInspectorMaxLogLines) return;
        NSMutableArray *parts = [NSMutableArray new];
        for (JSValue *v in JSContext.currentArguments) [parts addObject:v.isString ? v.toString : wq_inspector_value_text(v)];
        BOOL unused = NO;
        [log addObject:wq_inspector_cap([parts componentsJoinedByString:@" "], &unused)];
    };

    // input.bytes: the snapshot without a copy, kept alive by the array.
    JSValueRef exception = NULL;
    NSData *keep = [bytes copy];
    JSObjectRef array = JSObjectMakeTypedArrayWithBytesNoCopy(context.JSGlobalContextRef, kJSTypedArrayTypeUint8Array,
                                                              (void *)keep.bytes, keep.length, wq_inspector_release_bytes,
                                                              (void *)CFBridgingRetain(keep), &exception);
    JSValue *input = [JSValue valueWithNewObjectInContext:context];
    input[@"name"] = fileName;
    input[@"extension"] = fileName.pathExtension.lowercaseString;
    input[@"size"] = @(fileSize);
    input[@"truncated"] = @(truncated);
    input[@"bytes"] = array && !exception ? [JSValue valueWithJSValueRef:array inContext:context] : [JSValue valueWithNullInContext:context];
    input[@"text"] = wq_inspector_text(bytes, truncated) ?: (id)NSNull.null;
    input[@"plist"] = wq_inspector_plist(bytes, truncated) ?: (id)NSNull.null;
    JSValue *dataValue = [JSValue valueWithObject:data inContext:context];

    [context evaluateScript:script withSourceURL:[NSURL fileURLWithPath:inspector.scriptPath]];
    JSValue *result = nil;
    if (!exceptionText) {
        JSValue *function = context[@"inspect"];
        if (!function.isObject || !JSObjectIsFunction(context.JSGlobalContextRef, JSValueToObject(context.JSGlobalContextRef, function.JSValueRef, NULL))) exceptionText = WQLocalized(@"The script doesn't define function inspect(input, data).");
        else result = [function callWithArguments:@[input, dataValue]];
    }
    if (logOut) *logOut = [log copy];
    if (exceptionText) {
        if ([exceptionText containsString:@"terminated"])
            exceptionText = WQLocalizedFormat(@"The script took longer than %.0f seconds and was stopped.", timeLimit);
        if (error) *error = exceptionText;
        return nil;
    }
    WQInspectorResult *out = [WQInspectorResult new];
    NSString *problem = wq_inspector_check(result, out);
    if (problem) { if (error) *error = problem; return nil; }
    out.log = [log copy];
    return out;
}
