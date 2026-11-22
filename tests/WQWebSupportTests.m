// Wi-Fi sharing helpers on the host: request paths that must stay inside the
// shared folder, upload names, HTML escaping, and strict number parsing.
#import "../WQWebSupport.h"
#include <stdio.h>
#include <stdlib.h>

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}

int main(void)
{
    @autoreleasepool {
        // Paths.
        check([WQWebPathComponents(@"Documents/a%20b.txt") isEqualToArray:(@[@"Documents", @"a b.txt"])], @"percent-encoding is decoded");
        check([WQWebPathComponents(@"") isEqualToArray:@[]] && [WQWebPathComponents(@"//a///b/") isEqualToArray:(@[@"a", @"b"])],
              @"empty parts are dropped");
        for (NSString *bad in @[@"..", @"a/../b", @"a/./b", @"%2e%2e/x", @"a/%2E%2E", @"a%2Fb", @"a%5Cb", @"a%00b", @".wq-upload-1", @"x/.WQ-UPLOAD-abc"])
            check(WQWebPathComponents(bad) == nil, [@"refused path: " stringByAppendingString:bad]);
        check([WQWebPathComponents(@"..a/b..") isEqualToArray:(@[@"..a", @"b.."])], @"dots inside a name are fine");

        // Upload names.
        check([WQUploadCandidate(@"photo", @"jpg", @" 2") isEqualToString:@"photo 2.jpg"] &&
              [WQUploadCandidate(@"notes", @"", @" 3") isEqualToString:@"notes 3"], @"upload candidate keeps the extension");
        NSString *longBase = [@"" stringByPaddingToLength:300 withString:@"ä" startingAtIndex:0];
        NSString *fitted = WQUploadCandidate(longBase, @"txt", @" 2");
        check(strlen(fitted.UTF8String) <= 255 && [fitted hasSuffix:@" 2.txt"] && [fitted hasPrefix:@"ä"],
              @"a long name is cut to 255 bytes, whole characters only");

        // HTML.
        check([WQWebHTMLEscape(@"<a href=\"x\">O'Neil & co</a>") isEqualToString:@"&lt;a href=&quot;x&quot;&gt;O&#39;Neil &amp; co&lt;/a&gt;"],
              @"file names can't become markup");

        // Numbers.
        unsigned long long v = 7;
        check(WQWebParseUnsigned(@"0", &v) && v == 0 && WQWebParseUnsigned(@"1234567890123456789", &v) && v == 1234567890123456789ull,
              @"digits parse exactly");
        for (NSString *bad in @[@"", @"12abc", @"-1", @"+1", @" 1", @"1 ", @"1.0", @"0x10", @"12345678901234567890", @"١٢"])
            check(!WQWebParseUnsigned(bad, &v), [@"not a number: " stringByAppendingString:bad]);
        check(!WQWebParseUnsigned(nil, &v), @"no text is not a number");

        // Uploads and free space.
        unsigned long long mb = 1024ull * 1024;
        check(WQWebUploadFits(100 * mb, 1024 * mb) && WQWebUploadFits(384 * mb, 1024 * mb) && !WQWebUploadFits(385 * mb, 1024 * mb) &&
              !WQWebUploadFits(1, 256 * mb) && !WQWebUploadFits(0, 0) && WQWebUploadFits(0, 257 * mb), @"an upload needs twice its size and a reserve");

        // Ranges.
        unsigned long long s = 0, l = 0;
        check(WQWebParseRange(@"bytes=0-99", 1000, &s, &l) == WQWebRangePartial && s == 0 && l == 99, @"first-last");
        check(WQWebParseRange(@"bytes=500-", 1000, &s, &l) == WQWebRangePartial && s == 500 && l == 999, @"open end");
        check(WQWebParseRange(@"bytes=-100", 1000, &s, &l) == WQWebRangePartial && s == 900 && l == 999, @"suffix");
        check(WQWebParseRange(@"bytes=-5000", 1000, &s, &l) == WQWebRangePartial && s == 0 && l == 999, @"suffix longer than the file");
        check(WQWebParseRange(@"bytes=10-5000", 1000, &s, &l) == WQWebRangePartial && s == 10 && l == 999, @"end past the file is clamped");
        check(WQWebParseRange(@"bytes=1000-", 1000, &s, &l) == WQWebRangeUnsatisfiable &&
              WQWebParseRange(@"bytes=-0", 1000, &s, &l) == WQWebRangeUnsatisfiable, @"outside the file");
        for (NSString *bad in @[@"bytes=0-1,5-9", @"bytes=a-b", @"bytes=5-2", @"bytes=1x-2", @"bytes=1-2x", @"bytes=-", @"bytes=", @"items=0-1",
                                @"bytes=0-1-2", @"bytes=99999999999999999999-"])
            check(WQWebParseRange(bad, 1000, &s, &l) == WQWebRangeNone, [@"ignored range: " stringByAppendingString:bad]);
        check(WQWebParseRange(@"bytes=0-0", 0, &s, &l) == WQWebRangeNone, @"an empty file has no ranges");
        puts("All Wi-Fi sharing helper tests passed.");
    }
    return 0;
}
