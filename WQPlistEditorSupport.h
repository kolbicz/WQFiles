//
//  WQPlistEditorSupport.h
//  WQ Files
//
//  Portable limits shared by the property-list editor and its regression tests.
//

#import <Foundation/Foundation.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    WQPMaxDisplayedStringCharacters = 512,
    WQPMaxStringInputCharacters = 64 * 1024,
    WQPMaxDataBytes = 4 * 1024,
    WQPMaxDataInputCharacters = 16 * 1024,
    WQPMaxSerializedBytes = 64 * 1024 * 1024,
};

static inline BOOL WQPStringInputWithinLimit(NSString *text)
{
    return text.length <= WQPMaxStringInputCharacters;
}

static inline BOOL WQPDataInputWithinLimit(NSString *text)
{
    return text.length <= WQPMaxDataInputCharacters;
}

static inline BOOL WQPSerializedDataWithinLimit(NSData *data)
{
    return data.length <= WQPMaxSerializedBytes;
}

// CoreFoundation can write only XML and binary property lists. OpenStep and
// unknown formats are readable but must be treated as read-only documents.
static inline BOOL WQPlistFormatIsWritable(NSPropertyListFormat format)
{
    return format == NSPropertyListXMLFormat_v1_0 || format == NSPropertyListBinaryFormat_v1_0;
}

static inline NSString *WQPlistFormatName(NSPropertyListFormat format)
{
    switch (format) {
        case NSPropertyListXMLFormat_v1_0: return @"XML";
        case NSPropertyListBinaryFormat_v1_0: return @"Binary";
        case NSPropertyListOpenStepFormat: return @"OpenStep";
        default: return @"Unknown";
    }
}

static inline NSString *WQPBoundedStringPreview(NSString *value)
{
    if (value.length == 0) return @"(empty)";
    if (value.length <= WQPMaxDisplayedStringCharacters) return value;

    NSString *suffix = [NSString stringWithFormat:@" … (%lu chars)", (unsigned long)value.length];
    NSUInteger prefixLength = suffix.length < WQPMaxDisplayedStringCharacters
        ? WQPMaxDisplayedStringCharacters - suffix.length : 0;
    return [[value substringToIndex:prefixLength] stringByAppendingString:suffix];
}

// NSKeyedArchiver stores object references as CFKeyedArchiverUID values. They
// are not NSNumber/NSString/NSData, and they do not implement -stringValue or
// NSCopying. They are nevertheless valid property-list leaves and must be
// preserved when the document is re-serialized.
static inline BOOL WQPlistIsKeyedArchiveUID(id value)
{
    if (!value) return NO;
    NSString *className = NSStringFromClass([value class]);
    if (![className isEqualToString:@"__NSCFType"] && ![className containsString:@"KeyedArchiverUID"])
        return NO;
    NSString *description = [value description];
    return [description hasPrefix:@"<CFKeyedArchiverUID "];
}

// Immutable, serializable copy of the editor's mutable document. Keyed-archive
// UID leaves are immutable and are passed through unchanged; unsupported
// objects fail the copy instead of reaching NSPropertyListSerialization.
static inline id _Nullable WQPlistImmutableCopy(id value, NSString *_Nullable *_Nullable errorOut)
{
    if (!value) {
        if (errorOut) *errorOut = @"The property list contains a nil value.";
        return nil;
    }
    if (WQPlistIsKeyedArchiveUID(value)) return value;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *source = value;
        NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithCapacity:source.count];
        for (id key in source) {
            if (![key isKindOfClass:NSString.class]) {
                if (errorOut) *errorOut = @"A dictionary key is not a string.";
                return nil;
            }
            id child = WQPlistImmutableCopy(source[key], errorOut);
            if (!child) return nil;
            copy[key] = child;
        }
        return [copy copy];
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSArray *source = value;
        NSMutableArray *copy = [NSMutableArray arrayWithCapacity:source.count];
        for (id childValue in source) {
            id child = WQPlistImmutableCopy(childValue, errorOut);
            if (!child) return nil;
            [copy addObject:child];
        }
        return [copy copy];
    }
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSDate.class] || [value isKindOfClass:NSData.class]) {
        return [value copy];
    }
    if (errorOut) *errorOut = @"The property list contains an unsupported value.";
    return nil;
}

// Date text for the scalar editor. Whole-second dates keep the short form
// (2026-11-09T15:00:00Z); dates with a fraction show milliseconds so the
// value the user sees is the value that is written back. The editor also
// keeps the original NSDate when the text is left unchanged, which preserves
// sub-millisecond precision exactly.
static inline NSISO8601DateFormatter *WQPDateFormatter(BOOL fractional)
{
    static NSISO8601DateFormatter *whole, *fraction;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        whole = [NSISO8601DateFormatter new];
        fraction = [NSISO8601DateFormatter new];
        fraction.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return fractional ? fraction : whole;
}

static inline NSString *WQPDateText(NSDate *date)
{
    NSTimeInterval t = date.timeIntervalSinceReferenceDate;
    return [WQPDateFormatter(t != floor(t)) stringFromDate:date];
}

// Whether a property list holds a date with a fraction of a second. XML
// property lists store dates to the second, so saving one there would
// silently round it (review DR-38).
static inline BOOL WQPHasFractionalDate(id value)
{
    if ([value isKindOfClass:NSDate.class]) {
        NSTimeInterval t = [(NSDate *)value timeIntervalSinceReferenceDate];
        return t != floor(t);
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id v in [(NSDictionary *)value objectEnumerator]) if (WQPHasFractionalDate(v)) return YES;
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id v in (NSArray *)value) if (WQPHasFractionalDate(v)) return YES;
    }
    return NO;
}

static inline NSDate *_Nullable WQPParseDate(NSString *text)
{
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    return [WQPDateFormatter(NO) dateFromString:trimmed] ?: [WQPDateFormatter(YES) dateFromString:trimmed];
}

// Reals: "." or, as typed in many regions, "," as the decimal separator;
// sign and exponent allowed. Not finite (1e999) or anything else: nil.
static inline NSNumber *_Nullable WQPParseReal(NSString *text)
{
    NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length || t.length > 64) return nil;
    if (![t containsString:@"."] && [t componentsSeparatedByString:@","].count == 2)
        t = [t stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSScanner *scanner = [NSScanner scannerWithString:t];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    scanner.charactersToBeSkipped = nil;
    double d = 0;
    if (![scanner scanDouble:&d] || !scanner.isAtEnd || !isfinite(d)) return nil;
    return @(d);
}

// Whole numbers: optional sign and ASCII digits only. Values from LLONG_MIN
// through ULLONG_MAX are accepted exactly (above LLONG_MAX as an unsigned
// 64-bit NSNumber); anything outside is rejected instead of being clamped.
static inline NSNumber *_Nullable WQPParseInteger(NSString *text)
{
    NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length || t.length > 64) return nil;
    unichar first = [t characterAtIndex:0];
    BOOL negative = first == '-';
    NSUInteger start = (first == '-' || first == '+') ? 1 : 0;
    if (start >= t.length) return nil;
    for (NSUInteger i = start; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c < '0' || c > '9') return nil;
    }
    const char *digits = t.UTF8String;   // ASCII only at this point
    char *end = NULL;
    errno = 0;
    if (negative) {
        long long value = strtoll(digits, &end, 10);
        if (errno == ERANGE || !end || *end) return nil;
        return @(value);
    }
    unsigned long long value = strtoull(digits, &end, 10);
    if (errno == ERANGE || !end || *end) return nil;
    if (value <= (unsigned long long)LLONG_MAX) return @((long long)value);
    return [NSNumber numberWithUnsignedLongLong:value];
}

NS_ASSUME_NONNULL_END
