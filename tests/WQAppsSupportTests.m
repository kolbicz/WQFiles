#import <Foundation/Foundation.h>
#import "WQAppsSupport.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static NSDictionary *WQBaseManifest(void)
{
    return @{ @"Complete": @YES, @"Format": @1, @"BundleID": @"com.example.app",
              @"Created": [NSDate dateWithTimeIntervalSinceReferenceDate:100],
              @"Parts": @[@"Documents", @"Library"], @"Sequence": @1 };
}

static void TestManifestTypes(void)
{
    NSString *error = nil;
    NSArray *parts = nil;
    WQCheck(WQAppsSupportManifestFields(WQBaseManifest(), @"com.example.app", &parts, &error));
    BOOL canonicalParts = [parts isEqualToArray:@[@"Documents", @"Library"]];
    WQCheck(canonicalParts);

    NSMutableDictionary *wrongBundle = [WQBaseManifest() mutableCopy];
    wrongBundle[@"BundleID"] = @"com.other.app";
    WQCheck(!WQAppsSupportManifestFields(wrongBundle, @"com.example.app", NULL, &error));

    NSMutableDictionary *wrongFormat = [WQBaseManifest() mutableCopy];
    wrongFormat[@"Format"] = @2;
    WQCheck(!WQAppsSupportManifestFields(wrongFormat, @"com.example.app", NULL, &error));

    NSMutableDictionary *missingTimestamp = [WQBaseManifest() mutableCopy];
    [missingTimestamp removeObjectForKey:@"Created"];
    WQCheck(!WQAppsSupportManifestFields(missingTimestamp, @"com.example.app", NULL, &error));

    NSMutableDictionary *duplicatePart = [WQBaseManifest() mutableCopy];
    duplicatePart[@"Parts"] = @[@"Documents", @"Documents"];
    WQCheck(!WQAppsSupportManifestFields(duplicatePart, @"com.example.app", NULL, &error));

    NSMutableDictionary *unexpectedPart = [WQBaseManifest() mutableCopy];
    unexpectedPart[@"Parts"] = @[@"Documents", @"tmp"];
    WQCheck(!WQAppsSupportManifestFields(unexpectedPart, @"com.example.app", NULL, &error));

    NSMutableDictionary *missingParts = [WQBaseManifest() mutableCopy];
    [missingParts removeObjectForKey:@"Parts"];
    WQCheck(!WQAppsSupportManifestFields(missingParts, @"com.example.app", NULL, &error));

    NSMutableDictionary *malformedReason = [WQBaseManifest() mutableCopy];
    malformedReason[@"Reason"] = @[@"not", @"text"];
    WQCheck(!WQAppsSupportManifestFields(malformedReason, @"com.example.app", NULL, &error));

    NSMutableDictionary *malformedSequence = [WQBaseManifest() mutableCopy];
    malformedSequence[@"Sequence"] = @0;
    WQCheck(!WQAppsSupportManifestFields(malformedSequence, @"com.example.app", NULL, &error));

    NSMutableDictionary *stringSequence = [WQBaseManifest() mutableCopy];
    stringSequence[@"Sequence"] = @"10";
    WQCheck(!WQAppsSupportManifestFields(stringSequence, @"com.example.app", NULL, &error));

    NSMutableDictionary *partialManifest = [WQBaseManifest() mutableCopy];
    partialManifest[@"Parts"] = @[@"Library"];
    parts = nil;
    WQCheck(WQAppsSupportManifestFields(partialManifest, @"com.example.app", &parts, &error));
    WQCheck([parts isEqualToArray:@[@"Library"]]);

    NSMutableDictionary *typedComplete = [WQBaseManifest() mutableCopy];
    typedComplete[@"Complete"] = @1;
    WQCheck(!WQAppsSupportManifestFields(typedComplete, @"com.example.app", NULL, &error));

    NSMutableDictionary *hashes = [WQBaseManifest() mutableCopy];
    hashes[@"PartHashes"] = @{ @"Documents": @"aa", @"Library": @"bb" };
    WQCheck(WQAppsSupportManifestFields(hashes, @"com.example.app", NULL, &error));
    NSMutableDictionary *missingHash = [hashes mutableCopy];
    missingHash[@"PartHashes"] = @{ @"Documents": @"aa" };
    WQCheck(!WQAppsSupportManifestFields(missingHash, @"com.example.app", NULL, &error));
    NSMutableDictionary *extraHash = [hashes mutableCopy];
    extraHash[@"PartHashes"] = @{ @"Documents": @"aa", @"Library": @"bb", @"tmp": @"cc" };
    WQCheck(!WQAppsSupportManifestFields(extraHash, @"com.example.app", NULL, &error));
    NSMutableDictionary *badHash = [hashes mutableCopy];
    badHash[@"PartHashes"] = @{ @"Documents": @1, @"Library": @"bb" };
    WQCheck(!WQAppsSupportManifestFields(badHash, @"com.example.app", NULL, &error));
}

static void TestNumericOrdering(void)
{
    NSDate *sameTime = [NSDate dateWithTimeIntervalSinceReferenceDate:100];
    WQCheck(WQAppsSupportBackupSequence(@"2026-11-09 20.00.00") == 1);
    WQCheck(WQAppsSupportBackupSequence(@"2026-11-09 20.00.00 (9)") == 9);
    WQCheck(WQAppsSupportBackupSequence(@"2026-11-09 20.00.00 (10)") == 10);
    WQCheck(WQAppsSupportCompareBackupMetadata(sameTime, 10, @"stamp (10)",
                                                sameTime, 9, @"stamp (9)") == NSOrderedDescending);
    WQCheck(WQAppsSupportCompareBackupMetadata(sameTime, 9, @"stamp (9)",
                                                sameTime, 10, @"stamp (10)") == NSOrderedAscending);
    NSDate *newer = [NSDate dateWithTimeIntervalSinceReferenceDate:101];
    WQCheck(WQAppsSupportCompareBackupMetadata(newer, 1, @"newer",
                                                sameTime, 99, @"older") == NSOrderedDescending);
}

static void TestBundleIdentifiers(void)
{
    WQCheck(WQAppsSupportBundleIDValid(@"com.example.app"));
    WQCheck(WQAppsSupportBundleIDValid(@"com.example-app_1"));
    WQCheck(!WQAppsSupportBundleIDValid(@""));
    WQCheck(WQAppsSupportBundleIDValid(@"pinterest"));   // real one-word bundle ids
    WQCheck(WQAppsSupportBundleIDValid(@"ifengNews"));
    WQCheck(!WQAppsSupportBundleIDValid(@"ab"));
    WQCheck(!WQAppsSupportBundleIDValid(@"..."));
    WQCheck(!WQAppsSupportBundleIDValid(@"com/example"));
    WQCheck(!WQAppsSupportBundleIDValid(@"com..example"));
    WQCheck(!WQAppsSupportBundleIDValid(@".com.example"));
    WQCheck(!WQAppsSupportBundleIDValid(@"com.example."));
    WQCheck(!WQAppsSupportBundleIDValid(@"com example.app"));
    WQCheck(!WQAppsSupportBundleIDValid(@"../escape"));
}

static void TestJournalStates(void)
{
    WQCheck(WQAppsSupportJournalStateForDictionary(@{ @"State": @"Active" }) == WQAppsSupportJournalActive);
    WQCheck(WQAppsSupportJournalStateForDictionary(@{ @"State": @"Committed" }) == WQAppsSupportJournalCommitted);
    WQCheck(WQAppsSupportJournalStateForDictionary(@{ @"State": @"Other" }) == WQAppsSupportJournalUnknown);
    WQCheck(WQAppsSupportJournalStateForDictionary(@{}) == WQAppsSupportJournalUnknown);
    WQCheck(WQAppsSupportJournalStateForDictionary(nil) == WQAppsSupportJournalMissing);
    NSString *error = nil;
    WQCheck(!WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalActive, &error) && error.length > 0);
    error = nil;
    WQCheck(!WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalUnknown, &error) && error.length > 0);
    WQCheck(WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalMissing, NULL));
    WQCheck(WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalCommitted, NULL));
}

static void TestTreeSignatures(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [@"WQAppsTree-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *src = [base stringByAppendingPathComponent:@"src"];
    NSString *dst = [base stringByAppendingPathComponent:@"dst"];
    @try {
        WQCheck([fm createDirectoryAtPath:[src stringByAppendingPathComponent:@"nested"]
              withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *file = [src stringByAppendingPathComponent:@"file"];
        WQCheck([[@"original" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
        WQCheck(symlink(file.fileSystemRepresentation,
                        [src stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0);

        NSString *error = nil;
        BOOL exists = NO;
        NSString *before = WQAppsSupportTreeSignature(src, YES, &exists, &error);
        NSString *shape = WQAppsSupportTreeSignature(src, NO, &exists, &error);
        WQCheck(before.length > 0 && shape.length > 0 && exists);

        WQCheck([fm copyItemAtPath:src toPath:dst error:nil]);
        NSString *sourceAfter = WQAppsSupportTreeSignature(src, YES, &exists, &error);
        NSString *sourceShape = WQAppsSupportTreeSignature(src, NO, &exists, &error);
        NSString *destinationShape = WQAppsSupportTreeSignature(dst, NO, &exists, &error);
        WQCheck([before isEqualToString:sourceAfter]);       // source did not change
        WQCheck([sourceShape isEqualToString:destinationShape]); // copy has the same shape
        NSString *destinationIdentity = WQAppsSupportTreeSignature(dst, YES, &exists, &error);
        WQCheck(destinationIdentity && ![before isEqualToString:destinationIdentity]);

        // CR-07: unsupported special entries are left out of both variants and counted.
        NSString *fifo = [src stringByAppendingPathComponent:@"nested/pipe"];
        WQCheck(mkfifo(fifo.fileSystemRepresentation, 0600) == 0);
        NSUInteger omitted = 0;
        WQCheck([WQAppsSupportTreeSignatureOmitting(src, NO, &exists, &omitted, &error) isEqualToString:destinationShape] && omitted == 1);
        WQCheck(WQAppsSupportTreeSignatureOmitting(src, YES, &exists, &omitted, &error).length > 0 && omitted == 1);
        WQCheck(unlink(fifo.fileSystemRepresentation) == 0);

        // A source mutation after the signature was captured must be visible.
        WQCheck([[@"original plus more" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
        NSString *changed = WQAppsSupportTreeSignature(src, YES, &exists, &error);
        WQCheck(![before isEqualToString:changed]);
    } @finally {
        [fm removeItemAtPath:base error:nil];
    }
}


static void TestImportRoot(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [@"WQImportRoot-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    void (^mk)(NSString *) = ^(NSString *rel) {
        [fm createDirectoryAtPath:[base stringByAppendingPathComponent:rel] withIntermediateDirectories:YES attributes:nil error:nil];
    };
    void (^file)(NSString *, id) = ^(NSString *rel, id plist) {
        NSString *path = [base stringByAppendingPathComponent:rel];
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if ([plist isKindOfClass:NSDictionary.class]) [plist writeToFile:path atomically:YES];
        else [[@"x" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
    };
    NSString *error = nil;
    // Documents/Library directly in the picked folder.
    mk(@"direct/Documents"); mk(@"direct/tmp"); file(@"direct/.DS_Store", nil); file(@"direct/notes.txt", nil);
    NSString *direct = [base stringByAppendingPathComponent:@"direct"];
    WQCheck([WQAppsSupportImportRoot(direct, &error) isEqualToString:direct]);
    WQCheck([WQAppsSupportImportIgnored(direct) isEqualToArray:(@[@"notes.txt", @"tmp"])]);
    // Wrapped (a shared backup ZIP) with a WQ Files checklist.
    mk(@"wrapped/Telegram 2026-11-11/Library");
    file(@"wrapped/Telegram 2026-11-11/.wqbackup.plist", @{@"BundleID": @"ph.telegra.Telegraph"});
    mk(@"wrapped/__MACOSX/x/Documents");
    NSString *wrapped = [base stringByAppendingPathComponent:@"wrapped/Telegram 2026-11-11"];
    WQCheck([WQAppsSupportImportRoot([base stringByAppendingPathComponent:@"wrapped"], &error) isEqualToString:wrapped]);
    WQCheck([WQAppsSupportImportDeclaredBundle(wrapped) isEqualToString:@"ph.telegra.Telegraph"]);
    WQCheck(WQAppsSupportImportIgnored(wrapped).count == 0);
    // A container copy, two levels down, identified by its metadata file.
    mk(@"deep/export/Container/Documents");
    file(@"deep/export/Container/.com.apple.mobile_container_manager.metadata.plist", @{@"MCMMetadataIdentifier": @"com.example.app"});
    NSString *deep = [base stringByAppendingPathComponent:@"deep/export/Container"];
    WQCheck([WQAppsSupportImportRoot([base stringByAppendingPathComponent:@"deep"], &error) isEqualToString:deep]);
    WQCheck([WQAppsSupportImportDeclaredBundle(deep) isEqualToString:@"com.example.app"]);
    WQCheck(WQAppsSupportImportDeclaredBundle(direct) == nil);
    // CR-06: every declaration counts; conflicts and invalid IDs are visible.
    mk(@"both/Documents");
    file(@"both/.wqbackup.plist", @{@"BundleID": @"com.example.a"});
    file(@"both/.com.apple.mobile_container_manager.metadata.plist", @{@"MCMMetadataIdentifier": @"com.example.b"});
    NSString *both = [base stringByAppendingPathComponent:@"both"];
    NSString *invalid = nil;
    WQCheck([WQAppsSupportImportDeclaredBundles(both, &invalid) isEqualToArray:(@[@"com.example.a", @"com.example.b"])] && !invalid);
    mk(@"same/Documents");
    file(@"same/.wqbackup.plist", @{@"BundleID": @"com.example.a"});
    file(@"same/.com.apple.mobile_container_manager.metadata.plist", @{@"MCMMetadataIdentifier": @"com.example.a"});
    WQCheck([WQAppsSupportImportDeclaredBundles([base stringByAppendingPathComponent:@"same"], &invalid) isEqualToArray:(@[@"com.example.a"])] && !invalid);
    mk(@"bad/Documents");
    file(@"bad/.wqbackup.plist", @{@"BundleID": @"../evil"});
    file(@"bad/.com.apple.mobile_container_manager.metadata.plist", @{@"MCMMetadataIdentifier": @"com.example.b"});
    NSArray *badIDs = WQAppsSupportImportDeclaredBundles([base stringByAppendingPathComponent:@"bad"], &invalid);
    WQCheck([badIDs isEqualToArray:(@[@"com.example.b"])] && [invalid isEqualToString:@"../evil"]);
    mk(@"nonstring/Documents");
    file(@"nonstring/.wqbackup.plist", @{@"BundleID": @42});
    WQCheck(WQAppsSupportImportDeclaredBundles([base stringByAppendingPathComponent:@"nonstring"], &invalid).count == 0 && [invalid isEqualToString:@"42"]);
    WQCheck(WQAppsSupportImportDeclaredBundles(direct, &invalid).count == 0 && !invalid);
    // Two apps side by side: ambiguous.
    mk(@"two/A/Documents"); mk(@"two/B/Library");
    error = nil;
    WQCheck(WQAppsSupportImportRoot([base stringByAppendingPathComponent:@"two"], &error) == nil && [error containsString:@"A, B"]);
    // Nothing usable; a symlinked Documents doesn't count.
    mk(@"none/Pictures");
    [fm createSymbolicLinkAtPath:[base stringByAppendingPathComponent:@"none/Documents"] withDestinationPath:@"/tmp" error:nil];
    error = nil;
    WQCheck(WQAppsSupportImportRoot([base stringByAppendingPathComponent:@"none"], &error) == nil && error.length > 0);

    // An Apps Manager backup (.adbk, unpacked; issue #19). Its App Group
    // folder has a Library too and sits deeper, so it must never be chosen.
    mk(@"adbk/com.example.app/Documents"); mk(@"adbk/com.example.app/Library/Preferences");
    mk(@"adbk/com.example.app/tmp"); mk(@"adbk/com.example.app/StoreKit");
    file(@"adbk/com.example.app/.com.apple.mobile_container_manager.metadata.plist", @{@"MCMMetadataIdentifier": @"com.example.app"});
    mk(@"adbk/___groups___/group.com.example.app/Library");
    mk(@"adbk/__pasteboards__");
    file(@"adbk/Binfo.plist", (@{@"id": @"com.example.app", @"displayName": @"Example", @"date": NSDate.date}));
    file(@"adbk/__private_info", nil);
    file(@"adbk/com.example.app.plist", @{});
    NSString *adbkTop = [base stringByAppendingPathComponent:@"adbk"];
    NSString *adbkRoot = [adbkTop stringByAppendingPathComponent:@"com.example.app"];
    error = nil;
    WQCheck([WQAppsSupportImportRoot(adbkTop, &error) isEqualToString:adbkRoot]);
    WQCheck([WQAppsSupportADBKBundle(adbkTop, &invalid) isEqualToString:@"com.example.app"] && !invalid);
    WQCheck([WQAppsSupportImportDeclaredBundlesIn(adbkTop, adbkRoot, &invalid) isEqualToArray:(@[@"com.example.app"])] && !invalid);
    WQCheck([WQAppsSupportADBKDir(adbkTop, adbkRoot) isEqualToString:adbkTop]);
    WQCheck([WQAppsSupportADBKGroups(adbkTop) isEqualToArray:(@[@"group.com.example.app"])]);
    WQCheck(WQAppsSupportADBKHasKeychain(adbkTop));
    WQCheck([WQAppsSupportImportIgnored(adbkRoot) isEqualToArray:(@[@"StoreKit", @"tmp"])]);
    // Binfo.plist naming another app than the container metadata: both count.
    mk(@"adbk-other/com.example.app/Documents");
    file(@"adbk-other/com.example.app/.com.apple.mobile_container_manager.metadata.plist", @{@"MCMMetadataIdentifier": @"com.example.app"});
    file(@"adbk-other/Binfo.plist", @{@"id": @"com.example.other"});
    mk(@"adbk-other/com.example.other/Library");
    NSString *otherTop = [base stringByAppendingPathComponent:@"adbk-other"];
    NSString *otherRoot = WQAppsSupportImportRoot(otherTop, &error);
    WQCheck([otherRoot isEqualToString:[otherTop stringByAppendingPathComponent:@"com.example.other"]]);
    WQCheck([WQAppsSupportImportDeclaredBundlesIn(otherTop, [otherTop stringByAppendingPathComponent:@"com.example.app"], &invalid)
             isEqualToArray:(@[@"com.example.app", @"com.example.other"])] && !invalid);
    // The named folder has no Documents/Library: refused, not the App Group's Library.
    mk(@"adbk-empty/com.example.app/tmp");
    mk(@"adbk-empty/___groups___/group.com.example.app/Library");
    file(@"adbk-empty/Binfo.plist", @{@"id": @"com.example.app"});
    error = nil;
    WQCheck(WQAppsSupportImportRoot([base stringByAppendingPathComponent:@"adbk-empty"], &error) == nil &&
            [error containsString:@"com.example.app"]);
    // An invalid id is never used as a folder name and is reported.
    mk(@"adbk-bad/data/Documents");
    file(@"adbk-bad/Binfo.plist", @{@"id": @"../evil"});
    NSString *badTop = [base stringByAppendingPathComponent:@"adbk-bad"];
    NSString *badRoot = WQAppsSupportImportRoot(badTop, &error);
    WQCheck([badRoot isEqualToString:[badTop stringByAppendingPathComponent:@"data"]]);
    WQCheck(WQAppsSupportImportDeclaredBundlesIn(badTop, badRoot, &invalid).count == 0 && [invalid isEqualToString:@"../evil"]);
    // Other imports: no Apps Manager data, same declarations as before.
    WQCheck(WQAppsSupportADBKDir([base stringByAppendingPathComponent:@"deep"], deep) == nil);
    WQCheck(WQAppsSupportADBKDir(direct, direct) == nil);
    WQCheck([WQAppsSupportImportDeclaredBundlesIn([base stringByAppendingPathComponent:@"deep"], deep, &invalid)
             isEqualToArray:(@[@"com.example.app"])] && !invalid);
    [fm removeItemAtPath:base error:nil];
}

int main(void)
{
    @autoreleasepool {
        TestManifestTypes();
        TestNumericOrdering();
        TestBundleIdentifiers();
        TestJournalStates();
        TestTreeSignatures();
        TestImportRoot();
        if (failures) {
            fprintf(stderr, "%d Apps regression check(s) failed\n", failures);
            return 1;
        }
        puts("All Apps manifest/order/tree regression tests passed.");
    }
    return 0;
}
