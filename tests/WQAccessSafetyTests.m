#import "WQAccessSafety.h"
#include <stdlib.h>

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s (errno %d)\n", name.UTF8String, errno); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *lcReal = @"/private/var/mobile/Containers/Shared/AppGroup/B1E3527C-AA70-4F5C-A443-410B7D47ABBE";
        check([WQGroupRootForPath([lcReal stringByAppendingString:@"/LiveContainer/Data/AppGroup/group.com.rileytestut.AltStore.X"]) isEqualToString:lcReal], @"LiveContainer stand-in maps to the real group");
        check([WQGroupRootForPath(@"/var/mobile/Containers/Shared/AppGroup/ABC/LiveContainer/Data/AppGroup/g") isEqualToString:@"/var/mobile/Containers/Shared/AppGroup/ABC"], @"/var alias accepted");
        check([WQGroupRootForPath(lcReal) isEqualToString:lcReal], @"plain group path unchanged");
        check([WQGroupRootForPath(@"/private/var/mobile/Containers/Data/Application/X/LiveContainer/Data/AppGroup/g") hasSuffix:@"/g"], @"stand-in outside Shared/AppGroup unchanged");
        check([WQGroupRootForPath(@"/private/var/mobile/Containers/Shared/AppGroup/A/B/LiveContainer/Data/AppGroup/g") hasSuffix:@"/g"], @"nested real group unchanged");
        check(WQGroupRootForPath(nil) == nil, @"nil path");
        check([WQGroupRootFromTokenPath(@"/private/var/mobile/Containers/Shared/AppGroup/E4D186B4-F6D2-477F-9850-0F96AAF59A49/Library/Caches")
               isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup/E4D186B4-F6D2-477F-9850-0F96AAF59A49"], @"token path gives the group root");
        check(WQGroupRootFromTokenPath(@"/private/var/mobile/Containers/Data/InternalDaemon/X/Library/Caches") == nil, @"token for another container is ignored");
        check(WQGroupRootFromTokenPath(@"/private/var/mobile/Containers/Shared/AppGroup/A/B/Library/Caches") == nil, @"nested token path is ignored");
        check(WQGroupRootFromTokenPath(@"/private/var/mobile/Containers/Shared/AppGroup/A/Library") == nil, @"token path without Caches is ignored");
        check(WQGroupRootFromTokenPath(nil) == nil, @"no token path");
        check(!WQWorseQueryPatchedBuild(@"24C5037i"), @"27.3 beta 1 not patched");
        check(WQWorseQueryPatchedBuild(@"24C5049d"), @"27.3 beta 2 patched");
        check(WQWorseQueryPatchedBuild(@"24C5060a"), @"27.3 later beta patched");
        check(WQWorseQueryPatchedBuild(@"24C66"), @"27.3 release patched");
        check(WQWorseQueryPatchedBuild(@"24D5010a"), @"27.4 patched");
        check(WQWorseQueryPatchedBuild(@"25A5300a"), @"iOS 28 patched");
        check(!WQWorseQueryPatchedBuild(@"24B85"), @"27.2.1 not patched");
        check(!WQWorseQueryPatchedBuild(@"24A350"), @"27.0.1 not patched");
        check(!WQWorseQueryPatchedBuild(@"23H31"), @"iOS 26 not patched");
        check(!WQWorseQueryPatchedBuild(@""), @"empty build not patched");
        check(!WQWorseQueryPatchedBuild(@"garbage"), @"garbage build not patched");
        NSString *base = [NSTemporaryDirectory().stringByResolvingSymlinksInPath stringByAppendingPathComponent:
                          [@"WQAccessSafetyTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *library = [base stringByAppendingPathComponent:@"Library"];
        NSString *nested = [library stringByAppendingPathComponent:@"Caches/nested"];
        check([fm createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:nil], @"create temp fixture");
        @try {
            NSString *sentinel = [nested stringByAppendingPathComponent:@"sentinel"];
            NSData *bytes = [@"preserve these bytes" dataUsingEncoding:NSUTF8StringEncoding];
            check([bytes writeToFile:sentinel atomically:YES], @"write sentinel");
            int fd = WQOpenDirectoryNoLinks(library);
            check(fd >= 0, @"open no-link library");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin cache swap");
            check([fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-preserved/nested/sentinel"]], @"nested contents preserved while swapped");
            check(WQCacheSwapRecover(fd), @"recover simulated interruption after symlink");
            check([[NSData dataWithContentsOfFile:sentinel] isEqual:bytes], @"original bytes restored");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin second swap");
            check(unlinkat(fd, "Caches", 0) == 0, @"simulate interruption before symlink");
            check(WQCacheSwapRecover(fd), @"recover absent caches");
            check([[NSData dataWithContentsOfFile:sentinel] isEqual:bytes], @"bytes survive absent-path recovery");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin conflict test");
            check(unlinkat(fd, "Caches", 0) == 0 && mkdirat(fd, "Caches", 0755) == 0, @"simulate unexpected caches creator");
            check(!WQCacheSwapRecover(fd), @"recovery refuses unexpected directory");
            check([fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-preserved/nested/sentinel"]], @"conflict retains preserved original");
            check(unlinkat(fd, "Caches", AT_REMOVEDIR) == 0 && WQCacheSwapRecover(fd), @"recover after fixture conflict removed");
            check(WQCacheSwapRecover(fd), @"recovery idempotent");
            // Precomposed characters: the link holds the decomposed form.
            for (NSString *target in @[@"/private/var/Caf\u00e9/\u00fcber", @"/private/var/\ud55c\uae00", @"/private/var/Cafe\u0301"]) {
                check(WQCacheSwapBegin(fd, target), @"begin swap with a non-ASCII target");
                check(WQCacheSwapRecover(fd), @"recover a non-ASCII target");
                check(WQCacheSwapRecover(fd), @"non-ASCII recovery idempotent");
            }
            // Reset Access Cache (#42): a foreign Caches link without our
            // marker blocks every token; reset clears it, keeps everything.
            check(renameat(fd, "Caches", fd, "Caches-real") == 0 && symlinkat("/private/var/other-app-target", fd, "Caches") == 0,
                  @"simulate another app's Caches link");
            check(!WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"a foreign link blocks token requests");
            NSMutableArray *steps = [NSMutableArray new];
            check(WQCacheSwapReset(fd, steps) && steps.count, @"reset repairs a foreign link");
            struct stat cst;
            check(fstatat(fd, "Caches", &cst, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(cst.st_mode), @"Caches is a folder again");
            check(rmdir([library stringByAppendingPathComponent:@"Caches"].fileSystemRepresentation) == 0 &&
                  renameat(fd, "Caches-real", fd, "Caches") == 0, @"restore real Caches fixture");
            // Interrupted swap whose saved folder conflicts with a new Caches.
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin reset conflict fixture");
            check(unlinkat(fd, "Caches", 0) == 0 && mkdirat(fd, "Caches", 0755) == 0, @"new Caches beside the preserved one");
            check(!WQCacheSwapRecover(fd), @"recovery refuses the conflict");
            [steps removeAllObjects];
            check(WQCacheSwapReset(fd, steps), @"reset resolves the conflict");
            check(WQCacheSwapRecover(fd) && WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target") && WQCacheSwapRecover(fd),
                  @"token requests work after reset");
            NSArray *kept = [[fm contentsOfDirectoryAtPath:library error:nil] filteredArrayUsingPredicate:
                             [NSPredicate predicateWithFormat:@"SELF BEGINSWITH '.wq-caches-reset-'"]];
            check(kept.count == 1 && [fm fileExistsAtPath:[library stringByAppendingPathComponent:
                  [kept.firstObject stringByAppendingPathComponent:@"nested/sentinel"]]], @"reset kept the original contents");
            [steps removeAllObjects];
            check(WQCacheSwapReset(fd, steps) && steps.count == 0, @"reset of a healthy cache does nothing");
            check([fm removeItemAtPath:[library stringByAppendingPathComponent:kept.firstObject] error:nil] &&
                  [fm createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:nil] &&
                  [bytes writeToFile:sentinel atomically:YES], @"restore sentinel fixture");
            check(WQRecoverCacheSwapAtPath(library), @"normal startup requires no recovery");
            check(![fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-lock"]], @"normal startup creates no lock or marker");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin startup recovery fixture");
            int lock = WQOpenRegularAt(fd, ".wq-caches-lock", O_RDWR | O_CREAT, 0600);
            check(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, @"hold token-operation lock");
            check(!WQRecoverCacheSwapAtPath(library), @"startup does not interfere with an active token query");
            close(lock);
            check(WQRecoverCacheSwapAtPath(library) && [[NSData dataWithContentsOfFile:sentinel] isEqual:bytes], @"startup restores interrupted cache swap without a token query");
            check(WQRecoverCacheSwapAtPath([base stringByAppendingPathComponent:@"absent"]), @"startup does not create an absent Library");
            // A marker left behind by a failed write must not disable recovery
            // when the original Caches directory is intact.
            int broken = openat(fd, WQCacheMarker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            check(broken >= 0, @"create zero-length marker fixture");
            close(broken);
            check(WQCacheSwapRecover(fd), @"zero-length marker is discarded when Caches is intact");
            check(![fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-swap.plist"]], @"invalid marker removed");
            broken = openat(fd, WQCacheMarker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            check(broken >= 0 && write(broken, "partial", 7) == 7, @"create partial marker fixture");
            close(broken);
            check(WQCacheSwapRecover(fd), @"partial marker is discarded when Caches is intact");

            // A stale temporary marker must not block the next swap.
            broken = openat(fd, ".wq-caches-swap.plist.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0600);
            check(broken >= 0 && write(broken, "stale", 5) == 5, @"create stale temporary marker");
            close(broken);
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin cleans a stale temporary marker");
            check(WQCacheSwapRecover(fd), @"recover stale temporary marker fixture");

            // If recovery material exists, an invalid marker must fail closed.
            NSString *library2 = [base stringByAppendingPathComponent:@"Library2"];
            NSString *nested2 = [library2 stringByAppendingPathComponent:@"Caches/nested"];
            check([fm createDirectoryAtPath:nested2 withIntermediateDirectories:YES attributes:nil error:nil], @"create second library fixture");
            NSString *sentinel2 = [nested2 stringByAppendingPathComponent:@"sentinel"];
            check([bytes writeToFile:sentinel2 atomically:YES], @"write second sentinel");
            int fd2 = WQOpenDirectoryNoLinks(library2);
            check(fd2 >= 0, @"open second library");
            check(WQCacheSwapBegin(fd2, @"/private/var/nonexistent-token-target"), @"begin second swap");
            broken = openat(fd2, WQCacheMarker, O_WRONLY | O_TRUNC);
            check(broken >= 0 && write(broken, "garbage", 7) == 7, @"corrupt marker with preserved data");
            close(broken);
            check(!WQCacheSwapRecover(fd2), @"invalid marker with preserved data fails closed");
            check([fm fileExistsAtPath:[library2 stringByAppendingPathComponent:@".wq-caches-preserved/nested/sentinel"]], @"preserved data retained");
            close(fd2);

            NSString *restricted = [base stringByAppendingPathComponent:@"search-only/child"];
            check([fm createDirectoryAtPath:restricted withIntermediateDirectories:YES attributes:nil error:nil], @"create traversal fixture");
            NSString *parent = restricted.stringByDeletingLastPathComponent;
            check(chmod(parent.fileSystemRepresentation, 0111) == 0, @"set traversal-only ancestor permissions");
            @try {
                int child = WQOpenDirectoryNoLinks(restricted);
                check(child >= 0, @"no-follow walk does not require ancestor enumeration");
                close(child);
            } @finally { chmod(parent.fileSystemRepresentation, 0700); }

            // CR-13: a non-regular .wq-caches-lock (link or folder) keeps
            // blocking token requests, but explicit repair moves it aside
            // without following it, creates a regular lock and then resets.
            for (NSString *kind in @[@"link", @"folder"]) {
                NSString *library3 = [base stringByAppendingPathComponent:[@"Library-lock-" stringByAppendingString:kind]];
                NSString *nested3 = [library3 stringByAppendingPathComponent:@"Caches/nested"];
                check([fm createDirectoryAtPath:nested3 withIntermediateDirectories:YES attributes:nil error:nil], @"create lock fixture library");
                NSString *sentinel3 = [nested3 stringByAppendingPathComponent:@"sentinel"];
                check([bytes writeToFile:sentinel3 atomically:YES], @"write lock fixture sentinel");
                NSString *target = [base stringByAppendingPathComponent:[@"lock-target-" stringByAppendingString:kind]];
                check([[@"foreign" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:target atomically:YES], @"lock link target");
                int fd3 = WQOpenDirectoryNoLinks(library3);
                check(fd3 >= 0, @"open lock fixture library");
                check(WQCacheSwapBegin(fd3, @"/private/var/nonexistent-token-target"), @"interrupted swap beside a bad lock");
                if ([kind isEqual:@"link"]) {
                    check(symlinkat(target.fileSystemRepresentation, fd3, ".wq-caches-lock") == 0, @"symlink lock fixture");
                } else {
                    check(mkdirat(fd3, ".wq-caches-lock", 0700) == 0, @"directory lock fixture");
                    int inner = openat(fd3, ".wq-caches-lock/inner", O_WRONLY | O_CREAT | O_EXCL, 0600);
                    check(inner >= 0 && write(inner, "inner", 5) == 5, @"directory lock content");
                    close(inner);
                }
                check(WQOpenRegularAt(fd3, ".wq-caches-lock", O_RDWR | O_CREAT, 0600) < 0 && !WQRecoverCacheSwapAtPath(library3),
                      @"normal lock requests stay fail-closed on a non-regular lock");
                NSMutableArray *repairSteps = [NSMutableArray new];
                int repaired = WQCacheLockOpenForRepair(fd3, repairSteps);
                check(repaired >= 0 && flock(repaired, LOCK_EX | LOCK_NB) == 0, @"repair creates and locks a regular lock");
                struct stat lockSt;
                check(fstatat(fd3, ".wq-caches-lock", &lockSt, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(lockSt.st_mode), @"lock is a regular file again");
                NSArray *quarantined = [[fm contentsOfDirectoryAtPath:library3 error:nil] filteredArrayUsingPredicate:
                                        [NSPredicate predicateWithFormat:@"SELF BEGINSWITH '.wq-caches-lock-quarantine-'"]];
                check(quarantined.count == 1, @"bad lock quarantined, not deleted");
                NSString *q = [library3 stringByAppendingPathComponent:quarantined.firstObject];
                if ([kind isEqual:@"link"])
                    check([[fm destinationOfSymbolicLinkAtPath:q error:nil] isEqual:target] &&
                          [[NSData dataWithContentsOfFile:target] isEqual:[@"foreign" dataUsingEncoding:NSUTF8StringEncoding]],
                          @"symlink lock target never followed or changed");
                else
                    check([[NSData dataWithContentsOfFile:[q stringByAppendingPathComponent:@"inner"]] isEqual:[@"inner" dataUsingEncoding:NSUTF8StringEncoding]],
                          @"directory lock contents kept");
                check(WQCacheSwapReset(fd3, repairSteps) && [[NSData dataWithContentsOfFile:sentinel3] isEqual:bytes],
                      @"reset after lock repair restores the preserved Caches");
                close(repaired);
                check(WQRecoverCacheSwapAtPath(library3) && WQCacheSwapBegin(fd3, @"/private/var/nonexistent-token-target") &&
                      WQCacheSwapRecover(fd3), @"token requests work after lock repair");
                [repairSteps removeAllObjects];
                int again = WQCacheLockOpenForRepair(fd3, repairSteps);
                check(again >= 0 && repairSteps.count == 0, @"repair of a healthy lock does nothing");
                close(again);
                close(fd3);
            }
            check(!WQAbsolutePathGrammar(@"/private/var/../file") && !WQAbsolutePathGrammar(@"/private//var/file"), @"grammar rejects traversal and ambiguous empty components");
            NSData *(^utf8)(NSString *) = ^NSData *(NSString *t) { return [t dataUsingEncoding:NSUTF8StringEncoding]; };
            check([WQIdentityAttributeIdentifier(utf8(@"v: 01\nschema: 002\nuuid: 39B822B6-0A32-42A7-ACD8-B1E23F6279A6\ninstance-uuid: none\nidentifier: group.com.apple.newsd\n")) isEqualToString:@"group.com.apple.newsd"],
                  @"identity attribute gives its identifier line");
            check(WQIdentityAttributeIdentifier(utf8(@"v: 01\nuuid: x\n")) == nil, @"identity attribute without identifier gives nothing");
            check(WQIdentityAttributeIdentifier(utf8(@"identifier: a.b\nidentifier: c.d\n")) == nil, @"two identifier lines give nothing");
            check(WQIdentityAttributeIdentifier(utf8(@"identifier: \n")) == nil, @"empty identifier gives nothing");
            check(WQIdentityAttributeIdentifier(utf8(@"identifier: a b\n")) == nil, @"identifier with spaces gives nothing");
            close(fd);
            // Samples for the app-bundle probe: every index once, spread out.
            check([WQSpreadSampleIndexes(0, 3) isEqualToArray:@[]] && [WQSpreadSampleIndexes(1, 3) isEqualToArray:@[@0]] &&
                  [WQSpreadSampleIndexes(2, 3) isEqualToArray:(@[@0, @1])] && [WQSpreadSampleIndexes(3, 3) isEqualToArray:(@[@0, @1, @2])] &&
                  [WQSpreadSampleIndexes(10, 3) isEqualToArray:(@[@0, @3, @6])], @"sample indexes never repeat (2 items: both)");
            // "Keep Both": a renamed database takes its companions along.
            check([WQSQLiteCompanionNameForMoved(@"db.sqlite-wal", @"db.sqlite", @"db 2.sqlite") isEqualToString:@"db 2.sqlite-wal"] &&
                  [WQSQLiteCompanionNameForMoved(@"DB.sqlite-shm", @"db.sqlite", @"DB 2.sqlite") isEqualToString:@"DB 2.sqlite-shm"] &&
                  [WQSQLiteCompanionNameForMoved(@"db.sqlite-journal", @"db.sqlite", @"db 3.sqlite") isEqualToString:@"db 3.sqlite-journal"],
                  @"companions follow the database's new name");
            check(!WQSQLiteCompanionNameForMoved(@"db.sqlite", @"db.sqlite", @"db 2.sqlite") &&
                  !WQSQLiteCompanionNameForMoved(@"db.sqlite-wal", @"db.sqlite", nil) &&
                  !WQSQLiteCompanionNameForMoved(@"other.sqlite-wal", @"db.sqlite", @"db 2.sqlite") &&
                  !WQSQLiteCompanionNameForMoved(@"x", @"db.sqlite", @"db 2.sqlite"), @"the database itself and unmoved sets keep their names");
            // Update check: version from source.json, compared as numbers.
            check([WQUpdateVersionInSource(utf8(@"{\"apps\":[{\"version\":\"0.9.21\"},{\"version\":\"9\"}]}")) isEqualToString:@"0.9.21"],
                  @"update version is the first app's");
            check(!WQUpdateVersionInSource(utf8(@"{\"apps\":[]}")) && !WQUpdateVersionInSource(utf8(@"[1]")) && !WQUpdateVersionInSource(utf8(@"x")) &&
                  !WQUpdateVersionInSource(utf8(@"{\"apps\":[{\"version\":7}]}")) && !WQUpdateVersionInSource([NSData data]) &&
                  !WQUpdateVersionInSource(utf8(@"{\"apps\":[{\"version\":\"1.2.3.4.5.6.7.8.9.10.11\"}]}")), @"anything else in source.json gives no version");
            check(WQVersionIsNewer(@"0.9.20", @"0.9.9") && !WQVersionIsNewer(@"0.9.9", @"0.9.20") && !WQVersionIsNewer(@"1.0", @"1.0") &&
                  !WQVersionIsNewer(nil, @"1.0") && !WQVersionIsNewer(@"", @"1.0"), @"versions compare by number, not as text");
        } @finally {
            [fm removeItemAtPath:base error:nil];
        }
    }
    return 0;
}
