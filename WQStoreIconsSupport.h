//
//  WQStoreIconsSupport.h
//  WQ Files
//
//  Settings → App Store Icons (off by default). Other apps' icons can't be
//  read with worse_query, so WQ Files can ask Apple's public App Store lookup
//  for them instead: https://itunes.apple.com/lookup?bundleId=a,b,c&country=xx
//  returns each app's artwork URL on mzstatic.com. Sends the bundle ids and
//  the region to Apple; sideloaded and removed apps have no entry.
//
//  Pure helpers (no UIKit, no network) so they can be tested.
//

#import <Foundation/Foundation.h>
#import "WQAppsSupport.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *const WQStoreIconsPref = @"WQStoreIcons";

enum {
    WQStoreIconsBatch = 50,                     // bundle ids per lookup request
    WQStoreIconsMaxResponseBytes = 4 << 20,
    WQStoreIconsMaxIconBytes = 512 << 10,
    WQStoreIconsPixels = 120,                   // 40 pt at 3x
};
static const NSTimeInterval WQStoreIconsMissRetry = 7 * 24 * 3600;   // ask again for a missing app after a week

// App ids worth asking for: valid, and not Apple's own (those have real icons)
// or a group container's id.
static inline BOOL WQStoreIconsEligible(NSString *_Nullable bundleID)
{
    if (!WQAppsSupportBundleIDValid(bundleID)) return NO;
    NSString *lower = bundleID.lowercaseString;
    return ![lower hasPrefix:@"com.apple."] && ![lower hasPrefix:@"group."] && ![lower hasPrefix:@"systemgroup."];
}

// Two lowercase ASCII letters from a region code, "us" otherwise.
static inline NSString *WQStoreIconsCountry(NSString *_Nullable regionCode)
{
    NSString *code = [regionCode isKindOfClass:NSString.class] ? regionCode.lowercaseString : @"";
    if (code.length != 2) return @"us";
    for (NSUInteger i = 0; i < 2; i++) {
        unichar c = [code characterAtIndex:i];
        if (c < 'a' || c > 'z') return @"us";
    }
    return code;
}

static inline NSURL *_Nullable WQStoreIconsLookupURL(NSArray<NSString *> *bundleIDs, NSString *country)
{
    if (!bundleIDs.count || bundleIDs.count > WQStoreIconsBatch) return nil;
    for (NSString *bid in bundleIDs) if (!WQStoreIconsEligible(bid)) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://itunes.apple.com/lookup"];
    url.queryItems = @[[NSURLQueryItem queryItemWithName:@"bundleId" value:[bundleIDs componentsJoinedByString:@","]],
                       [NSURLQueryItem queryItemWithName:@"country" value:WQStoreIconsCountry(country)],
                       [NSURLQueryItem queryItemWithName:@"entity" value:@"software"]];
    return url.URL;
}

// The icon URL to download: https on *.mzstatic.com only, resized to
// WQStoreIconsPixels as PNG ("…/100x100bb.jpg" -> "…/120x120bb.png").
static inline NSURL *_Nullable WQStoreIconsArtworkURL(id _Nullable value)
{
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] > 2048) return nil;
    NSURL *url = [NSURL URLWithString:value];
    NSString *host = url.host.lowercaseString;
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || !host.length) return nil;
    if (![host isEqualToString:@"mzstatic.com"] && ![host hasSuffix:@".mzstatic.com"]) return nil;
    NSString *last = url.lastPathComponent;
    if (![last hasPrefix:@"100x100"]) return url;
    NSString *sized = [NSString stringWithFormat:@"%dx%dbb.png", WQStoreIconsPixels, WQStoreIconsPixels];
    return [url.URLByDeletingLastPathComponent URLByAppendingPathComponent:sized];
}

// Bundle id (as asked) -> icon URL, from a lookup response. Ids that weren't
// asked for, and entries without a usable icon, are left out.
static inline NSDictionary<NSString *, NSURL *> *WQStoreIconsArtwork(NSData *_Nullable json, NSArray<NSString *> *asked)
{
    NSMutableDictionary<NSString *, NSURL *> *found = [NSMutableDictionary new];
    if (json.length == 0 || json.length > WQStoreIconsMaxResponseBytes) return found;
    id root = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    NSArray *results = [root isKindOfClass:NSDictionary.class] ? root[@"results"] : nil;
    if (![results isKindOfClass:NSArray.class]) return found;
    NSMutableDictionary<NSString *, NSString *> *byLower = [NSMutableDictionary new];
    for (NSString *bid in asked) byLower[bid.lowercaseString] = bid;
    for (id result in results) {
        if (![result isKindOfClass:NSDictionary.class]) continue;
        id bid = result[@"bundleId"];
        NSString *key = [bid isKindOfClass:NSString.class] ? byLower[[(NSString *)bid lowercaseString]] : nil;
        if (!key || found[key]) continue;
        NSURL *art = WQStoreIconsArtworkURL(result[@"artworkUrl100"]) ?: WQStoreIconsArtworkURL(result[@"artworkUrl60"]);
        if (art) found[key] = art;
    }
    return found;
}

NS_ASSUME_NONNULL_END
