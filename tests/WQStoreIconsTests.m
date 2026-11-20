#import <Foundation/Foundation.h>
#import "WQStoreIconsSupport.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void TestEligible(void)
{
    WQCheck(WQStoreIconsEligible(@"com.facebook.Facebook"));
    WQCheck(WQStoreIconsEligible(@"pinterest"));
    WQCheck(!WQStoreIconsEligible(@"com.apple.mobilesafari"));
    WQCheck(!WQStoreIconsEligible(@"COM.APPLE.Music"));
    WQCheck(!WQStoreIconsEligible(@"group.net.whatsapp.WhatsApp.shared"));
    WQCheck(!WQStoreIconsEligible(@"systemgroup.com.apple.configurationprofiles"));
    WQCheck(!WQStoreIconsEligible(@"../escape"));
    WQCheck(!WQStoreIconsEligible(@"a,b"));        // would split the lookup list
    WQCheck(!WQStoreIconsEligible(nil));
}

static void TestCountry(void)
{
    WQCheck([WQStoreIconsCountry(@"DE") isEqualToString:@"de"]);
    WQCheck([WQStoreIconsCountry(@"sa") isEqualToString:@"sa"]);
    WQCheck([WQStoreIconsCountry(nil) isEqualToString:@"us"]);
    WQCheck([WQStoreIconsCountry(@"419") isEqualToString:@"us"]);
    WQCheck([WQStoreIconsCountry(@"deu") isEqualToString:@"us"]);
    WQCheck([WQStoreIconsCountry(@"d&") isEqualToString:@"us"]);
}

static void TestLookupURL(void)
{
    NSURL *url = WQStoreIconsLookupURL(@[@"com.facebook.Facebook", @"pinterest"], @"DE");
    WQCheck([url.absoluteString isEqualToString:@"https://itunes.apple.com/lookup?bundleId=com.facebook.Facebook,pinterest&country=de&entity=software"]);
    WQCheck(WQStoreIconsLookupURL(@[], @"us") == nil);
    WQCheck(WQStoreIconsLookupURL(@[@"com.apple.mobilesafari"], @"us") == nil);
    WQCheck(WQStoreIconsLookupURL(@[@"x&country=zz"], @"us") == nil);
    NSMutableArray *many = [NSMutableArray new];
    for (int i = 0; i <= WQStoreIconsBatch; i++) [many addObject:[NSString stringWithFormat:@"com.example.app%d", i]];
    WQCheck(WQStoreIconsLookupURL(many, @"us") == nil);
}

static void TestArtworkURL(void)
{
    NSURL *url = WQStoreIconsArtworkURL(@"https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/88/ef/Icon.png/100x100bb.jpg");
    WQCheck([url.absoluteString isEqualToString:@"https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/88/ef/Icon.png/120x120bb.png"]);
    WQCheck(WQStoreIconsArtworkURL(@"http://is1-ssl.mzstatic.com/a/100x100bb.jpg") == nil);
    WQCheck(WQStoreIconsArtworkURL(@"https://evil.example.com/100x100bb.jpg") == nil);
    WQCheck(WQStoreIconsArtworkURL(@"https://mzstatic.com.evil.example/100x100bb.jpg") == nil);
    WQCheck(WQStoreIconsArtworkURL(@"https://evilmzstatic.com/100x100bb.jpg") == nil);
    WQCheck(WQStoreIconsArtworkURL(@42) == nil);
    WQCheck(WQStoreIconsArtworkURL(nil) == nil);
}

static void TestArtwork(void)
{
    NSDictionary *response = @{ @"resultCount": @4, @"results": @[
        @{ @"bundleId": @"com.facebook.Facebook", @"artworkUrl100": @"https://is1-ssl.mzstatic.com/a/100x100bb.jpg" },
        @{ @"bundleId": @"PINTEREST", @"artworkUrl100": @"https://is2-ssl.mzstatic.com/b/100x100bb.jpg" },
        @{ @"bundleId": @"com.not.asked", @"artworkUrl100": @"https://is1-ssl.mzstatic.com/c/100x100bb.jpg" },
        @{ @"bundleId": @"net.whatsapp.WhatsApp", @"artworkUrl100": @"https://evil.example.com/d/100x100bb.jpg" },
        @"junk" ] };
    NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
    NSDictionary *found = WQStoreIconsArtwork(json, @[@"com.facebook.Facebook", @"pinterest", @"net.whatsapp.WhatsApp"]);
    WQCheck(found.count == 2);
    WQCheck([[found[@"com.facebook.Facebook"] absoluteString] hasSuffix:@"/a/120x120bb.png"]);
    WQCheck([[found[@"pinterest"] absoluteString] hasSuffix:@"/b/120x120bb.png"]);   // matched case-insensitively, keyed as asked
    WQCheck(found[@"net.whatsapp.WhatsApp"] == nil);
    WQCheck(WQStoreIconsArtwork([@"not json" dataUsingEncoding:NSUTF8StringEncoding], @[@"pinterest"]).count == 0);
    WQCheck(WQStoreIconsArtwork([@"[1,2]" dataUsingEncoding:NSUTF8StringEncoding], @[@"pinterest"]).count == 0);
    WQCheck(WQStoreIconsArtwork(nil, @[@"pinterest"]).count == 0);
}

int main(void)
{
    @autoreleasepool {
        TestEligible();
        TestCountry();
        TestLookupURL();
        TestArtworkURL();
        TestArtwork();
    }
    if (failures) return 1;
    printf("PASS: store icon lookup helpers\n");
    return 0;
}
