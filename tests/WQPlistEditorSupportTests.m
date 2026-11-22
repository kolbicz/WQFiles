//
//  WQPlistEditorSupportTests.m
//  WQ Files regression tests
//

#import <Foundation/Foundation.h>
#import "WQPlistEditorSupport.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void TestInputLimits(void)
{
    NSString *stringLimit = [@"" stringByPaddingToLength:WQPMaxStringInputCharacters
                                               withString:@"x"
                                          startingAtIndex:0];
    NSString *stringOver = [stringLimit stringByAppendingString:@"x"];
    NSString *dataLimit = [@"" stringByPaddingToLength:WQPMaxDataInputCharacters
                                             withString:@"0"
                                        startingAtIndex:0];
    NSString *dataOver = [dataLimit stringByAppendingString:@"0"];

    WQCheck(WQPStringInputWithinLimit(stringLimit));
    WQCheck(!WQPStringInputWithinLimit(stringOver));
    WQCheck(WQPDataInputWithinLimit(dataLimit));
    WQCheck(!WQPDataInputWithinLimit(dataOver));
}

static void TestPreviewAndSerializedLimits(void)
{
    NSString *longString = [@"" stringByPaddingToLength:WQPMaxDisplayedStringCharacters + 200
                                             withString:@"a"
                                        startingAtIndex:0];
    NSString *preview = WQPBoundedStringPreview(longString);
    WQCheck(preview.length <= WQPMaxDisplayedStringCharacters);
    WQCheck([preview containsString:@"…"]);
    WQCheck([WQPBoundedStringPreview(@"") isEqualToString:@"(empty)"]);
    WQCheck(WQPBoundedStringPreview(@"short").length == 5);

    NSData *atLimit = [NSMutableData dataWithLength:WQPMaxSerializedBytes];
    NSData *overLimit = [NSMutableData dataWithLength:WQPMaxSerializedBytes + 1];
    WQCheck(WQPSerializedDataWithinLimit(atLimit));
    WQCheck(!WQPSerializedDataWithinLimit(overLimit));
}

static void TestFormatPolicy(void)
{
    WQCheck(WQPlistFormatIsWritable(NSPropertyListXMLFormat_v1_0));
    WQCheck(WQPlistFormatIsWritable(NSPropertyListBinaryFormat_v1_0));
    WQCheck(!WQPlistFormatIsWritable(NSPropertyListOpenStepFormat));
    WQCheck([WQPlistFormatName(NSPropertyListOpenStepFormat) isEqualToString:@"OpenStep"]);
    WQCheck([WQPlistFormatName(NSPropertyListXMLFormat_v1_0) isEqualToString:@"XML"]);
    NSData *openStep = [@"{ foo = bar; }" dataUsingEncoding:NSUTF8StringEncoding];
    NSPropertyListFormat format = 0;
    id plist = [NSPropertyListSerialization propertyListWithData:openStep options:0 format:&format error:nil];
    WQCheck(plist != nil);
    WQCheck(!WQPlistFormatIsWritable(format));
}

static void TestKeyedArchiveUIDs(void)
{
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:@{ @"a": @"b" }
                                            requiringSecureCoding:NO error:nil];
    WQCheck(archive.length > 0);
    NSPropertyListFormat format = 0;
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:archive
                                                         options:NSPropertyListMutableContainersAndLeaves
                                                          format:&format error:&error];
    WQCheck([plist isKindOfClass:NSDictionary.class]);
    id uid = plist[@"$top"][@"root"];
    WQCheck(uid != nil);
    WQCheck(WQPlistIsKeyedArchiveUID(uid));
    WQCheck(!WQPlistIsKeyedArchiveUID(@"plain string"));
    WQCheck(!WQPlistIsKeyedArchiveUID(@1));

    NSString *copyError = nil;
    id copy = WQPlistImmutableCopy(plist, &copyError);
    WQCheck(copy != nil && copyError == nil);
    NSData *encoded = copy ? [NSPropertyListSerialization dataWithPropertyList:copy
                                                                        format:NSPropertyListBinaryFormat_v1_0
                                                                       options:0 error:&error] : nil;
    WQCheck(encoded.length > 0);
    if (encoded) {
        id unarchived = [NSKeyedUnarchiver unarchivedObjectOfClass:NSDictionary.class
                                                          fromData:encoded error:&error];
        WQCheck([unarchived isEqual:@{ @"a": @"b" }]);
    }

    copyError = nil;
    WQCheck(WQPlistImmutableCopy([NSNull null], &copyError) == nil && copyError.length > 0);
}

static id RoundTrip(id value, NSPropertyListFormat format)
{
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{ @"v": value } format:format options:0 error:&error];
    if (!data) return nil;
    NSDictionary *back = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
    return back[@"v"];
}

static void TestDateRoundTrips(void)
{
    // 0.75 s is exact in binary, so text -> date must reproduce it exactly.
    NSDate *fractional = [NSDate dateWithTimeIntervalSinceReferenceDate:815000000.75];
    NSString *text = WQPDateText(fractional);
    WQCheck([text containsString:@".750"]);
    NSDate *parsed = WQPParseDate(text);
    WQCheck(parsed && parsed.timeIntervalSinceReferenceDate == fractional.timeIntervalSinceReferenceDate);
    // Binary plists store the double, so the edited date is saved exactly.
    // (XML plist <date> has whole-second precision by format; that loss is
    // the file format's, not the editor's.)
    NSDate *saved = RoundTrip(parsed, NSPropertyListBinaryFormat_v1_0);
    WQCheck(saved && saved.timeIntervalSinceReferenceDate == fractional.timeIntervalSinceReferenceDate);
    NSDate *odd = [NSDate dateWithTimeIntervalSinceReferenceDate:815000000.123456];
    WQCheck(fabs(WQPParseDate(WQPDateText(odd)).timeIntervalSinceReferenceDate - odd.timeIntervalSinceReferenceDate) < 0.001);

    // Whole seconds keep the short form; both forms parse.
    NSDate *whole = [NSDate dateWithTimeIntervalSinceReferenceDate:815000000];
    WQCheck(![WQPDateText(whole) containsString:@"."]);
    WQCheck([WQPParseDate(WQPDateText(whole)) isEqualToDate:whole]);
    WQCheck([WQPParseDate(@"2026-11-09T15:00:00Z") isEqualToDate:WQPParseDate(@"2026-11-09T15:00:00.000Z")]);
    WQCheck(WQPParseDate(@"2026-11-09T15:00:00.250+01:00").timeIntervalSinceReferenceDate
            == WQPParseDate(@"2026-11-09T14:00:00Z").timeIntervalSinceReferenceDate + 0.25);
    WQCheck(WQPParseDate(@"") == nil);
    WQCheck(WQPParseDate(@"yesterday") == nil);
}

static void TestIntegerParsing(void)
{
    WQCheck([WQPParseInteger(@"42") isEqualToNumber:@42]);
    WQCheck([WQPParseReal(@"1.5") isEqualToNumber:@1.5]);
    WQCheck([WQPParseReal(@"1,5") isEqualToNumber:@1.5]);
    WQCheck([WQPParseReal(@" -2.25e3 ") isEqualToNumber:@(-2250.0)]);
    WQCheck(WQPParseReal(@"1e999") == nil);
    WQCheck(WQPParseReal(@"1,2,3") == nil);
    WQCheck(WQPParseReal(@"1.5x") == nil);
    WQCheck(WQPParseReal(@"") == nil);
    WQCheck([WQPParseInteger(@" -7 ") isEqualToNumber:@(-7)]);
    WQCheck([WQPParseInteger(@"+5") isEqualToNumber:@5]);
    WQCheck([WQPParseInteger(@"9223372036854775807") isEqualToNumber:@(LLONG_MAX)]);
    WQCheck([WQPParseInteger(@"-9223372036854775808") isEqualToNumber:@(LLONG_MIN)]);
    WQCheck(WQPParseInteger(@"-9223372036854775809") == nil);   // below LLONG_MIN: rejected, not clamped

    NSNumber *above = WQPParseInteger(@"9223372036854775808");
    WQCheck(above && above.unsignedLongLongValue == (unsigned long long)LLONG_MAX + 1);
    NSNumber *max = WQPParseInteger(@"18446744073709551615");
    WQCheck(max && max.unsignedLongLongValue == ULLONG_MAX);
    WQCheck(max && ![max isEqualToNumber:@(LLONG_MAX)]);
    WQCheck([max.stringValue isEqualToString:@"18446744073709551615"]);
    WQCheck(WQPParseInteger(@"18446744073709551616") == nil);   // above ULLONG_MAX: rejected
    WQCheck(WQPParseInteger(@"99999999999999999999999") == nil);

    WQCheck(WQPParseInteger(@"") == nil);
    WQCheck(WQPParseInteger(@"-") == nil);
    WQCheck(WQPParseInteger(@"12a") == nil);
    WQCheck(WQPParseInteger(@"1.5") == nil);
    WQCheck(WQPParseInteger(@"0x10") == nil);
    WQCheck(WQPParseInteger(@"１２") == nil);   // full-width digits

    // The displayed text of a ULLONG_MAX leaf re-parses to the same value and
    // survives XML and binary serialization.
    NSNumber *leaf = [NSNumber numberWithUnsignedLongLong:ULLONG_MAX];
    WQCheck([WQPParseInteger(leaf.stringValue) isEqualToNumber:leaf]);
    for (NSNumber *format in @[ @(NSPropertyListXMLFormat_v1_0), @(NSPropertyListBinaryFormat_v1_0) ]) {
        NSNumber *saved = RoundTrip(max, (NSPropertyListFormat)format.unsignedIntegerValue);
        WQCheck(saved && saved.unsignedLongLongValue == ULLONG_MAX);
        WQCheck([saved.stringValue isEqualToString:@"18446744073709551615"]);
        NSNumber *signedMax = RoundTrip(WQPParseInteger(@"9223372036854775807"), (NSPropertyListFormat)format.unsignedIntegerValue);
        WQCheck(signedMax && signedMax.longLongValue == LLONG_MAX);
        NSNumber *signedMin = RoundTrip(WQPParseInteger(@"-9223372036854775808"), (NSPropertyListFormat)format.unsignedIntegerValue);
        WQCheck(signedMin && signedMin.longLongValue == LLONG_MIN);
    }
}

static void TestFractionalDates(void)
{
    NSDate *whole = [NSDate dateWithTimeIntervalSinceReferenceDate:1000];
    NSDate *fraction = [NSDate dateWithTimeIntervalSinceReferenceDate:1000.75];
    WQCheck(!WQPHasFractionalDate(whole));
    WQCheck(WQPHasFractionalDate(fraction));
    WQCheck(!WQPHasFractionalDate(@{@"a": @[whole, @1, @"x"]}));
    WQCheck(WQPHasFractionalDate(@{@"a": @[@{@"b": fraction}]}));
}

int main(void)
{
    @autoreleasepool {
        TestInputLimits();
        TestFractionalDates();
        TestPreviewAndSerializedLimits();
        TestFormatPolicy();
        TestKeyedArchiveUIDs();
        TestDateRoundTrips();
        TestIntegerParsing();
        if (failures) {
            fprintf(stderr, "%d plist support regression check(s) failed\n", failures);
            return 1;
        }
        puts("All WQPlistEditorSupport regression tests passed.");
    }
    return 0;
}
