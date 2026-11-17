// Custom inspectors (#45) on the host: manifests, the JavaScript contract,
// input shapes, result checks and limits, and the time limit.
#import "../WQInspector.h"
#include <stdlib.h>

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}

static NSString *base;

static NSString *makeInspector(NSString *folder, NSDictionary *manifest, NSString *script, NSString *data)
{
    NSString *dir = [base stringByAppendingPathComponent:folder];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (manifest) [[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil] writeToFile:[dir stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
    if (script) [script writeToFile:[dir stringByAppendingPathComponent:@"inspect.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (data) [data writeToFile:[dir stringByAppendingPathComponent:@"data.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return dir;
}

static WQInspectorResult *run(NSString *script, NSData *bytes, BOOL truncated, NSString **error, NSArray **log)
{
    NSString *dir = makeInspector([@"run-" stringByAppendingString:NSUUID.UUID.UUIDString],
                                  @{@"name": @"Run", @"api": @1, @"extensions": @[@"*"]}, script, @"{\"types\": {\"1\": \"Note\"}}");
    WQInspector *inspector = wq_inspector_load(dir, error);
    if (!inspector) return nil;
    return wq_inspector_run(inspector, bytes, truncated, @"sample.json", bytes.length, 1.0, log, error);
}

int main(void)
{
    @autoreleasepool {
        base = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"WQInspectorTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *error = nil;
        NSArray *log = nil;

        // Manifests.
        makeInspector(@"Good", @{@"name": @"JSON Summary", @"api": @1, @"extensions": @[@".JSON", @"plist"]}, @"function inspect(){return {sections:[]}}", nil);
        makeInspector(@"NoScript", @{@"name": @"x", @"api": @1, @"extensions": @[@"json"]}, nil, nil);
        makeInspector(@"BadAPI", @{@"name": @"x", @"api": @2, @"extensions": @[@"json"]}, @"", nil);
        makeInspector(@"Escape", @{@"name": @"x", @"api": @1, @"extensions": @[@"json"], @"script": @"../Good/inspect.js"}, @"", nil);
        makeInspector(@"NoExt", @{@"name": @"x", @"api": @1, @"extensions": @[]}, @"", nil);
        NSArray<NSString *> *problems = nil;
        NSArray<WQInspector *> *found = wq_inspectors_in(base, &problems);
        check(found.count == 1 && [found.firstObject.name isEqualToString:@"JSON Summary"], @"only the valid inspector is listed");
        check(problems.count == 4, @"each invalid folder is reported");
        check([found.firstObject.extensions isEqualToArray:(@[@"json", @"plist"])], @"extensions are lowercased without dots");
        check([found.firstObject matchesFileName:@"a.JSON"] && ![found.firstObject matchesFileName:@"a.txt"], @"extension matching");
        check(found.firstObject.dataPath == nil, @"data.json is optional");

        // The contract: text, data, rows of any value type, console.log.
        NSData *json = [@"{\"name\":\"Milk\",\"type\":1,\"done\":false}" dataUsingEncoding:NSUTF8StringEncoding];
        WQInspectorResult *r = run(@"function inspect(input, data) {"
                                    "  const rec = JSON.parse(input.text); console.log('size', input.size);"
                                    "  return { title: 'T', sections: [ { title: 'Details', rows: ["
                                    "    { label: 'Name', value: rec.name }, { label: 'Type', value: data.types[rec.type] ?? 'Unknown' },"
                                    "    { label: 'Done', value: rec.done }, { label: 'Raw', value: { a: [1, 2] } }, { label: 'Nothing', value: null } ] },"
                                    "    { text: 'free text' } ] }; }", json, NO, &error, &log);
        check(r != nil, [@"basic inspector runs " stringByAppendingString:error ?: @""]);
        check([r.title isEqualToString:@"T"] && r.sections.count == 2, @"title and sections");
        NSArray *rows = r.sections.firstObject.rows;
        check([[rows[0] value] isEqualToString:@"Milk"] && [[rows[1] value] isEqualToString:@"Note"], @"text input and data.json reach the script");
        check([[rows[2] value] isEqualToString:@"false"] && [[rows[3] value] isEqualToString:@"{\"a\":[1,2]}"] && [[rows[4] value] isEqualToString:@"—"],
              @"booleans, objects and null become text");
        check([r.sections[1].text isEqualToString:@"free text"], @"text sections");
        check([log isEqualToArray:@[[NSString stringWithFormat:@"size %lu", (unsigned long)json.length]]], @"console.log lines");
        check([r.plainText containsString:@"Name: Milk"], @"plain text for Share");

        // Bytes and plist input.
        unsigned char raw[] = {0xde, 0xad, 0xbe, 0xef};
        r = run(@"function inspect(i){ return {sections:[{rows:[{label:'b', value: Array.from(i.bytes).join(',')}, {label:'t', value: i.text}]}]} }",
                [NSData dataWithBytes:raw length:4], NO, &error, NULL);
        check([[r.sections[0].rows[0] value] isEqualToString:@"222,173,190,239"] && [[r.sections[0].rows[1] value] isEqualToString:@"—"],
              @"bytes as Uint8Array, text null for non-UTF-8");
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:@{@"when": [NSDate dateWithTimeIntervalSince1970:0], @"blob": [@"hi" dataUsingEncoding:NSUTF8StringEncoding], @"n": @3}
                                                                   format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        r = run(@"function inspect(i){ return {sections:[{rows:[{label:'when', value:i.plist.when},{label:'blob', value:i.plist.blob},{label:'n', value:i.plist.n}]}]} }",
                plist, NO, &error, NULL);
        check([[r.sections[0].rows[0] value] hasPrefix:@"1970-01-01T00:00:00"] && [[r.sections[0].rows[1] value] isEqualToString:@"aGk="] &&
              [[r.sections[0].rows[2] value] isEqualToString:@"3"], @"binary plist parsed, dates as ISO 8601, data as base64");
        r = run(@"function inspect(i){ return {sections:[{rows:[{label:'p', value: i.plist}]}]} }", plist, YES, &error, NULL);
        check([[r.sections[0].rows[0] value] isEqualToString:@"—"], @"no plist from a truncated snapshot");

        // Errors and checks.
        check(!run(@"function inspect(){ throw new Error('boom') }", json, NO, &error, NULL) && [error containsString:@"boom"], @"script errors are reported");
        check(!run(@"var x = 1;", json, NO, &error, NULL) && error.length, @"missing inspect() is reported");
        check(!run(@"function inspect(){ return 5 }", json, NO, &error, NULL) && error.length, @"non-object result refused");
        check(!run(@"function inspect(){ return {sections:[{rows:'x'}]} }", json, NO, &error, NULL) && error.length, @"rows must be an array");
        check(!run(@"function inspect(){ return {sections:[{}]} }", json, NO, &error, NULL) && error.length, @"empty section refused");
        r = run(@"function inspect(){ const rows=[]; for (let i=0;i<6000;i++) rows.push({label:''+i, value:i});"
                 " return {sections:[{rows}, {text:'x'.repeat(30000)}]} }", json, NO, &error, NULL);
        check(r.capped && r.sections[0].rows.count == WQInspectorMaxRows && r.sections[1].text.length == WQInspectorMaxText + 1,
              @"rows and text are capped");

        // The time limit stops an endless loop.
        NSDate *start = NSDate.date;
        check(!run(@"function inspect(){ for(;;){} }", json, NO, &error, NULL) && error.length, @"endless loop is stopped");
        check(-start.timeIntervalSinceNow < 10, @"... within the time limit");

        [NSFileManager.defaultManager removeItemAtPath:base error:nil];
        printf("All inspector tests passed.\n");
    }
    return 0;
}
