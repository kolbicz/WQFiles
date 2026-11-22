//
//  WQWebSupport.h
//  WQ Files
//
//  Foundation-only helpers of the Wi-Fi sharing server: request paths, upload
//  names, HTML escaping and strict number parsing. Kept apart from the UIKit
//  server so the host tests can run them.
//
//  GPL-3.0-or-later.
//

#ifndef WQWebSupport_h
#define WQWebSupport_h

#import <Foundation/Foundation.h>
#include <string.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *const kWQUploadStagePrefix = @".wq-upload-";

// `base` + `suffix` (+ "." `ext`) within the 255-byte name limit, cutting
// whole characters off the end of `base` when needed.
static inline NSString *WQUploadCandidate(NSString *base, NSString *ext, NSString *suffix)
{
    NSString *tail = ext.length ? [NSString stringWithFormat:@"%@.%@", suffix, ext] : suffix;
    NSString *head = base;
    while (head.length && [head stringByAppendingString:tail].UTF8String && strlen([head stringByAppendingString:tail].UTF8String) > 255) {
        NSRange last = [head rangeOfComposedCharacterSequenceAtIndex:head.length - 1];
        head = [head substringToIndex:last.location];
    }
    return [head stringByAppendingString:tail];
}

static inline NSArray<NSString *> *_Nullable WQWebPathComponents(NSString *encoded)
{
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (NSString *raw in [encoded componentsSeparatedByString:@"/"]) {
        if (!raw.length) continue;
        NSString *c = raw.stringByRemovingPercentEncoding;
        if (!c.length || [c.lowercaseString hasPrefix:kWQUploadStagePrefix] || [c isEqualToString:@"."] || [c isEqualToString:@".."] ||
            [c containsString:@"/"] || [c containsString:@"\\"] || [c rangeOfString:@"\0"].location != NSNotFound) return nil;
        [out addObject:c];
    }
    return out;
}

static inline NSString *WQWebHTMLEscape(NSString *text)
{
    NSMutableString *s = [NSMutableString stringWithCapacity:text.length + 8];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        switch (c) {
            case '&': [s appendString:@"&amp;"]; break;
            case '<': [s appendString:@"&lt;"]; break;
            case '>': [s appendString:@"&gt;"]; break;
            case '"': [s appendString:@"&quot;"]; break;
            case '\'': [s appendString:@"&#39;"]; break;
            default: [s appendFormat:@"%C", c];
        }
    }
    return s;
}

// A decimal number made of ASCII digits only, the whole text, at most 19 of
// them (so it always fits). "12abc", "-1", "+1", " 1" and "" are not numbers.
static inline BOOL WQWebParseUnsigned(NSString *_Nullable text, unsigned long long *value)
{
    if (!text.length || text.length > 19) return NO;
    unsigned long long v = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
        v = v * 10 + (unsigned long long)(c - '0');
    }
    *value = v;
    return YES;
}

// Whether an upload of `length` bytes may start with `available` bytes free:
// it is stored twice for a moment (temporary file, then the staged copy), and
// 256 MB stay free for the rest of the system.
static inline BOOL WQWebUploadFits(unsigned long long length, unsigned long long available)
{
    const unsigned long long reserve = 256ull * 1024 * 1024;
    return available > reserve && length <= (available - reserve) / 2;
}

typedef NS_ENUM(NSInteger, WQWebRange) {
    WQWebRangeNone = 0,        // no usable range: send the whole file
    WQWebRangePartial,         // *start..*last (inclusive) of the file
    WQWebRangeUnsatisfiable,   // well formed but outside the file: 416
};

// A Range header for a file of `size` > 0 bytes: "bytes=a-b", "bytes=a-" or
// "bytes=-n". Several ranges and anything malformed are ignored.
static inline WQWebRange WQWebParseRange(NSString *header, unsigned long long size,
                                         unsigned long long *start, unsigned long long *last)
{
    if (![header hasPrefix:@"bytes="] || [header containsString:@","] || size == 0) return WQWebRangeNone;
    NSArray<NSString *> *parts = [[header substringFromIndex:6] componentsSeparatedByString:@"-"];
    if (parts.count != 2) return WQWebRangeNone;
    NSString *a = parts[0], *b = parts[1];
    unsigned long long first = 0, end = size - 1, n = 0;
    if (a.length) {
        if (!WQWebParseUnsigned(a, &first)) return WQWebRangeNone;
        if (b.length) {
            if (!WQWebParseUnsigned(b, &n)) return WQWebRangeNone;
            if (n < first) return WQWebRangeNone;   // "5-2" is not a range
            end = MIN(n, size - 1);
        }
        if (first >= size) return WQWebRangeUnsatisfiable;
    } else {
        if (!WQWebParseUnsigned(b, &n)) return WQWebRangeNone;
        if (n == 0) return WQWebRangeUnsatisfiable;
        first = n >= size ? 0 : size - n;
    }
    *start = first;
    *last = end;
    return WQWebRangePartial;
}

NS_ASSUME_NONNULL_END

#endif
