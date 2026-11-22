//
//  WQWebServer.m
//  WQ Files
//
//  One request per connection (Connection: close), GET, HEAD and PUT, HTTP
//  Basic auth on every request. Routes:
//    /browse/<path>/   folder page        /file/<path>[?dl=1]  open or download
//    /zip/<path>       folder as ZIP      /                    → /browse/
//  <path> is relative to the shared folder; "..", "." and symbolic links are
//  refused, so nothing outside the folder can be reached.
//

#import "WQWebServer.h"
#import "WQWebSupport.h"
#import "WQAccess.h"
#import "WQArchive.h"
#import "WQLaunchServices.h"
#import "WQLocalization.h"
#import "WQUI.h"
#import "WQTheme.h"
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Security/Security.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <stdatomic.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

@implementation WQWebEntry
@end

#pragma mark Sharing password

static NSDictionary *WQSharingPasswordQuery(void)
{
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @"WQFiles.WiFiSharing",
             (__bridge id)kSecAttrAccount: @"wq"};
}

// Fallback for signers that leave out the keychain entitlement (SecItemAdd
// fails with -34018): the app's own preferences, inside its sandbox.
static NSString *const kWQSharingPasswordPref = @"WQSharingPassword";

NSString *wq_sharing_password(void)
{
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kWQSharingPasswordPref];
    if (stored.length) return stored;
    NSMutableDictionary *query = [WQSharingPasswordQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSData *data = (__bridge_transfer NSData *)result;
    NSString *password = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return password.length ? password : nil;
}

BOOL wq_set_sharing_password(NSString *password)
{
    SecItemDelete((__bridge CFDictionaryRef)WQSharingPasswordQuery());
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQSharingPasswordPref];
    if (!password.length) return YES;
    NSMutableDictionary *item = [WQSharingPasswordQuery() mutableCopy];
    item[(__bridge id)kSecValueData] = [password dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status == errSecSuccess) return YES;
    wq_log(@"wifi sharing: keychain refused the password (%d); kept in the app's preferences instead", (int)status);
    [NSUserDefaults.standardUserDefaults setObject:password forKey:kWQSharingPasswordPref];
    return YES;
}

void wq_edit_sharing_password(UIViewController *host, void (^done)(void))
{
    NSString *current = wq_sharing_password();
    UIAlertController *alert = wq_alert_controller(@"Sharing Password",
        @"A fixed password for Wi-Fi Sharing. The user is always “wq”.", UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.placeholder = WQLocalized(@"At least 6 characters.");
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
        field.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    if (current) {
        [alert addAction:wq_alert_action(@"Use Random Password", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
            wq_set_sharing_password(nil);
            if (done) done();
        })];
    }
    __weak UIViewController *weakHost = host;
    [alert addAction:wq_alert_action(@"Save", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        if (text.length < 6) {
            wq_alert(weakHost, @"Sharing Password", @"At least 6 characters.");
            return;
        }
        if (!wq_set_sharing_password(text)) {
            wq_alert(weakHost, @"Sharing Password", @"The password could not be saved in the keychain.");
            return;
        }
        if (done) done();
    })];
    [host presentViewController:alert animated:YES completion:nil];
}

static const NSUInteger kWQWebMaxHeader = 16384;
static const NSUInteger kWQWebMaxConnections = 12;
static const CFTimeInterval kWQWebHeaderSeconds = 20;
static const size_t kWQWebChunk = 256 * 1024;

static NSString *WQWebEncode(NSString *component)
{
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet alphanumericCharacterSet];
        [set addCharactersInString:@"-._~"];
        allowed = [set copy];
    });
    return [component stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *WQWebEncodePath(NSArray<NSString *> *components)
{
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *c in components) [parts addObject:WQWebEncode(c)];
    return [parts componentsJoinedByString:@"/"];
}

static BOOL WQWebLooksLikeUUID(NSString *name)
{
    return name.length == 36 && [[NSUUID alloc] initWithUUIDString:name] != nil;
}

static NSString *WQWebCSSColor(UIColor *color)
{
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"rgba(%d,%d,%d,%.2f)", (int)lround(MIN(1, MAX(0, r)) * 255),
            (int)lround(MIN(1, MAX(0, g)) * 255), (int)lround(MIN(1, MAX(0, b)) * 255), a];
}

static BOOL WQWebSend(int fd, const void *bytes, size_t length)
{
    const char *p = bytes;
    while (length > 0) {
        ssize_t n = send(fd, p, length, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        p += n;
        length -= (size_t)n;
    }
    return YES;
}

@interface WQWebItem : NSObject
@property (nonatomic, copy) NSString *name, *path;
@property (nonatomic, copy, nullable) NSString *label;
@property (nonatomic) BOOL isDir, isLink, readable;
@property (nonatomic) unsigned long long size;
@property (nonatomic, strong, nullable) NSDate *modified;
@end
@implementation WQWebItem
@end

@implementation WQWebServer {
    NSString *_root, *_title;
    NSDictionary<NSString *, WQWebEntry *> *_entries;
    int _listenFD;
    dispatch_source_t _source;
    dispatch_semaphore_t _slots;
    NSData *_expectedAuth;
    atomic_bool _stopped;
    NSLock *_publishLock;
}

- (instancetype)initWithRoot:(NSString *)root title:(NSString *)title rootEntries:(NSArray<WQWebEntry *> *)entries
{
    if ((self = [super init])) {
        _root = [root copy];
        _title = [title copy];
        if (entries.count) {
            NSMutableDictionary *byName = [NSMutableDictionary new];
            for (WQWebEntry *e in entries) if (e.path.lastPathComponent.length) byName[e.path.lastPathComponent] = e;
            _entries = byName;
        }
        _listenFD = -1;
        atomic_init(&_stopped, false);
        _publishLock = [NSLock new];
        _user = @"wq";
        _password = wq_sharing_password() ?: [WQWebServer randomPassword];
        _slots = dispatch_semaphore_create(kWQWebMaxConnections);
        NSString *pair = [NSString stringWithFormat:@"%@:%@", _user, _password];
        _expectedAuth = [pair dataUsingEncoding:NSUTF8StringEncoding];
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

+ (NSString *)randomPassword
{
    // No 0/O, 1/l/I: it is read off the screen and typed.
    static const char alphabet[] = "abcdefghjkmnpqrstuvwxyz23456789";
    uint8_t bytes[8];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof bytes, bytes) != errSecSuccess) arc4random_buf(bytes, sizeof bytes);
    char out[sizeof bytes + 1];
    for (size_t i = 0; i < sizeof bytes; i++) out[i] = alphabet[bytes[i] % (sizeof alphabet - 1)];
    out[sizeof bytes] = 0;
    return @(out);
}

// The Wi-Fi IPv4 address (en0), another network port (en*), or a Personal
// Hotspot one (bridge*).
+ (nullable NSString *)wifiAddress
{
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *wifi = nil, *wired = nil, *hotspot = nil;
    for (struct ifaddrs *i = list; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
        if (!(i->ifa_flags & IFF_UP) || !(i->ifa_flags & IFF_RUNNING) || (i->ifa_flags & IFF_LOOPBACK)) continue;
        char text[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, text, sizeof text);
        NSString *name = @(i->ifa_name), *address = @(text);
        if ([address hasPrefix:@"169.254."]) continue;   // link-local, no DHCP
        if ([name isEqualToString:@"en0"]) wifi = address;
        else if ([name hasPrefix:@"en"] && !wired) wired = address;   // e.g. an iPad's USB Ethernet
        else if ([name hasPrefix:@"bridge"] && !hotspot) hotspot = address;
    }
    freeifaddrs(list);
    return wifi ?: wired ?: hotspot;
}

- (BOOL)start:(NSString **)errorText
{
    if (_running) return YES;
    NSString *ip = [WQWebServer wifiAddress];
    if (!ip) {
        if (errorText) *errorText = WQLocalized(@"Not connected to Wi-Fi. Connect to a Wi-Fi network (or turn on Personal Hotspot) and try again.");
        return NO;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (errorText) *errorText = @(strerror(errno));
        return NO;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct sockaddr_in addr = {0};
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    inet_pton(AF_INET, ip.UTF8String, &addr.sin_addr);
    BOOL bound = NO;
    for (int port = 8080; port <= 8099 && !bound; port++) {
        addr.sin_port = htons((uint16_t)port);
        bound = bind(fd, (struct sockaddr *)&addr, sizeof addr) == 0;
    }
    if (!bound) {
        addr.sin_port = 0;
        bound = bind(fd, (struct sockaddr *)&addr, sizeof addr) == 0;
    }
    socklen_t len = sizeof addr;
    if (!bound || listen(fd, 16) != 0 || getsockname(fd, (struct sockaddr *)&addr, &len) != 0) {
        if (errorText) *errorText = @(strerror(errno));
        close(fd);
        return NO;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    _listenFD = fd;
    _stopped = NO;
    _address = [NSString stringWithFormat:@"http://%@:%d/", ip, ntohs(addr.sin_port)];
    dispatch_queue_t queue = dispatch_queue_create("wq.web.accept", DISPATCH_QUEUE_SERIAL);
    _source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_source, ^{ [weakSelf acceptConnections]; });
    dispatch_source_set_cancel_handler(_source, ^{ close(fd); });
    dispatch_resume(_source);
    _running = YES;
    wq_log(@"wifi sharing: serving %@ at %@", _root, _address);
    return YES;
}

- (void)stop
{
    if (!_running) return;
    _running = NO;
    [_publishLock lock];
    _stopped = YES;
    [_publishLock unlock];
    if (_source) dispatch_source_cancel(_source);
    _source = nil;
    _listenFD = -1;
    wq_log(@"wifi sharing: stopped");
}

- (void)acceptConnections
{
    for (;;) {
        int client = accept(_listenFD, NULL, NULL);
        if (client < 0) return;
        int one = 1, flags = fcntl(client, F_GETFL);
        if (flags >= 0) fcntl(client, F_SETFL, flags & ~O_NONBLOCK);
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        struct timeval timeout = {.tv_sec = 30};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
        if (dispatch_semaphore_wait(_slots, DISPATCH_TIME_NOW) != 0) {   // too many at once
            static const char busy[] = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            WQWebSend(client, busy, sizeof busy - 1);
            close(client);
            continue;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { [self handleConnection:client]; }
            close(client);
            dispatch_semaphore_signal(self->_slots);
        });
    }
}

#pragma mark Requests

- (void)handleConnection:(int)fd
{
    NSMutableData *buffer = [NSMutableData new];
    char chunk[4096];
    NSRange end = {NSNotFound, 0};
    // The whole header within this time: the 30 s receive timeout alone lets
    // a client that sends a byte now and then keep one of the few
    // connection slots for good.
    CFAbsoluteTime headerDeadline = CFAbsoluteTimeGetCurrent() + kWQWebHeaderSeconds;
    while (end.location == NSNotFound) {
        if (CFAbsoluteTimeGetCurrent() > headerDeadline) return;
        ssize_t n = recv(fd, chunk, sizeof chunk, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        [buffer appendBytes:chunk length:(NSUInteger)n];
        if (buffer.length > kWQWebMaxHeader) {
            [self respond:fd status:431 type:@"text/plain" body:[@"Request too large" dataUsingEncoding:NSUTF8StringEncoding] head:NO extra:nil];
            return;
        }
        end = [buffer rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, buffer.length)];
    }
    NSString *head = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding];
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    if (requestLine.count != 3) return;
    NSString *method = requestLine[0], *target = requestLine[1];
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary new];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        headers[[lines[i] substringToIndex:colon.location].lowercaseString] =
            [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    BOOL isHead = [method isEqualToString:@"HEAD"];
    if (![self authorized:headers[@"authorization"]]) {
        if (headers[@"authorization"]) usleep(800000);   // slows down guessing
        [self respond:fd status:401 type:@"text/plain; charset=utf-8"
                 body:[WQLocalized(@"WQ Files: password required.") dataUsingEncoding:NSUTF8StringEncoding]
                 head:isHead extra:@{@"WWW-Authenticate": @"Basic realm=\"WQ Files\", charset=\"UTF-8\""}];
        return;
    }
    if ([method isEqualToString:@"PUT"]) {
        NSUInteger bodyStart = end.location + 4;
        [self handleUpload:fd target:target headers:headers
                     early:[buffer subdataWithRange:NSMakeRange(bodyStart, buffer.length - bodyStart)]];
        return;
    }
    if (!isHead && ![method isEqualToString:@"GET"]) {
        [self respond:fd status:405 type:@"text/plain" body:[@"Not allowed" dataUsingEncoding:NSUTF8StringEncoding]
                 head:NO extra:@{@"Allow": @"GET, HEAD, PUT"}];
        return;
    }
    NSString *query = @"";
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        query = [target substringFromIndex:q.location + 1];
        target = [target substringToIndex:q.location];
    }
    NSString *line = [NSString stringWithFormat:@"%@ %@", method, target.stringByRemovingPercentEncoding ?: target];
    void (^log)(NSString *) = self.requestHandler;
    if (log) dispatch_async(dispatch_get_main_queue(), ^{ log(line); });

    if ([target isEqualToString:@"/app.js"]) {
        [self respond:fd status:200 type:@"text/javascript; charset=utf-8" body:[kWQWebScript dataUsingEncoding:NSUTF8StringEncoding]
                 head:isHead extra:nil];
        return;
    }
    if ([target isEqualToString:@"/"] || [target isEqualToString:@"/browse"]) {
        [self respond:fd status:302 type:@"text/plain" body:[NSData data] head:isHead extra:@{@"Location": @"/browse/"}];
        return;
    }
    NSString *route = nil;
    for (NSString *r in @[@"/browse/", @"/file/", @"/zip/"]) if ([target hasPrefix:r]) { route = r; break; }
    NSArray<NSString *> *components = route ? WQWebPathComponents([target substringFromIndex:route.length]) : nil;
    if (!components) {
        [self respondError:fd status:404 message:WQLocalized(@"Not found.") head:isHead];
        return;
    }
    struct stat st;
    NSString *path = [self resolve:components stat:&st];
    if (!path) {
        [self respondError:fd status:404 message:WQLocalized(@"Not found.") head:isHead];
        return;
    }
    if ([route isEqualToString:@"/browse/"]) {
        if (!S_ISDIR(st.st_mode)) {
            [self respond:fd status:302 type:@"text/plain" body:[NSData data] head:isHead
                    extra:@{@"Location": [@"/file/" stringByAppendingString:WQWebEncodePath(components)]}];
            return;
        }
        [self respond:fd status:200 type:@"text/html; charset=utf-8"
                 body:[[self pageFor:path components:components] dataUsingEncoding:NSUTF8StringEncoding] head:isHead
                extra:@{@"Content-Security-Policy": @"default-src 'none'; style-src 'unsafe-inline'; img-src data:; script-src 'self'; connect-src 'self'"}];
    } else if ([route isEqualToString:@"/file/"]) {
        if (!S_ISREG(st.st_mode)) {
            [self respondError:fd status:404 message:WQLocalized(@"Not found.") head:isHead];
            return;
        }
        BOOL download = [[query componentsSeparatedByString:@"&"] containsObject:@"dl=1"];
        [self sendFile:fd path:path download:download range:headers[@"range"] head:isHead];
    } else {
        if (!S_ISDIR(st.st_mode)) {
            [self respondError:fd status:404 message:WQLocalized(@"Not found.") head:isHead];
            return;
        }
        [self sendZip:fd path:path components:components head:isHead];
    }
}

#pragma mark Uploads

// PUT /upload/<folder>/<name>, raw file bytes as the body. The page sends an
// X-WQ-Upload header: a custom header makes browsers ask first (CORS
// preflight, which this server never allows), so other web sites can't upload.
- (void)handleUpload:(int)fd target:(NSString *)target headers:(NSDictionary<NSString *, NSString *> *)headers early:(NSData *)early
{
    void (^reply)(int, NSString *) = ^(int status, NSString *text) {
        [self respond:fd status:status type:@"text/plain; charset=utf-8" body:[text dataUsingEncoding:NSUTF8StringEncoding] head:NO extra:nil];
    };
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) target = [target substringToIndex:q.location];
    if (!self.allowUploads) { reply(403, WQLocalized(@"Uploads are off.")); return; }
    if (![headers[@"x-wq-upload"] isEqualToString:@"1"] || ![target hasPrefix:@"/upload/"]) { reply(403, @"Forbidden"); return; }
    NSArray<NSString *> *components = WQWebPathComponents([target substringFromIndex:8]);
    NSString *name = components.lastObject;
    if (!name.length || strlen(name.fileSystemRepresentation) > 255) { reply(400, WQLocalized(@"Not found.")); return; }
    NSArray<NSString *> *dirComponents = [components subarrayWithRange:NSMakeRange(0, components.count - 1)];
    struct stat st;
    NSString *dir = (!dirComponents.count && _entries) ? nil : [self resolve:dirComponents stat:&st];   // not into a container root
    if (!dir || !S_ISDIR(st.st_mode)) { reply(404, WQLocalized(@"Not found.")); return; }
    NSString *lengthText = headers[@"content-length"];
    if (!lengthText.length || headers[@"transfer-encoding"]) { reply(411, @"Length Required"); return; }
    // Digits only, all of them: "12abc" or "-1" is not a length.
    unsigned long long declared = 0;
    if (!WQWebParseUnsigned(lengthText, &declared) || declared > (unsigned long long)LLONG_MAX) { reply(400, @"Bad Request"); return; }
    long long length = (long long)declared;
    // An upload is written to temporary storage and then copied next to its
    // destination: room for both, and a reserve, before a byte is read.
    struct statfs fs;
    BOOL spaceKnown = statfs(NSTemporaryDirectory().fileSystemRepresentation, &fs) == 0;
    unsigned long long available = spaceKnown ? (unsigned long long)fs.f_bavail * fs.f_bsize : 0;
    if (spaceKnown && !WQWebUploadFits(declared, available)) { reply(507, WQLocalized(@"Not enough space on this device.")); return; }
    if ([headers[@"expect"].lowercaseString isEqualToString:@"100-continue"]) {
        static const char cont[] = "HTTP/1.1 100 Continue\r\n\r\n";
        WQWebSend(fd, cont, sizeof cont - 1);
    }
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"WQUpload-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    int out = open(temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (out < 0) { reply(500, @(strerror(errno))); return; }
    unsigned long long remaining = (unsigned long long)length;
    BOOL ok = YES;
    int writeError = 0;
    NSUInteger first = (NSUInteger)MIN((unsigned long long)early.length, remaining);
    if (first && write(out, early.bytes, first) != (ssize_t)first) { ok = NO; writeError = errno; }
    remaining -= first;
    char *chunk = malloc(kWQWebChunk);
    while (ok && remaining > 0 && !_stopped) {
        ssize_t n = recv(fd, chunk, (size_t)MIN((unsigned long long)kWQWebChunk, remaining), 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = NO; break; }
        if (write(out, chunk, (size_t)n) != n) { ok = NO; writeError = errno; break; }
        remaining -= (unsigned long long)n;
    }
    free(chunk);
    close(out);
    if (!ok || remaining > 0 || _stopped) {
        unlink(temp.fileSystemRepresentation);
        if (writeError == ENOSPC) reply(507, WQLocalized(@"Not enough space on this device."));
        else if (writeError) reply(500, @(strerror(writeError)));
        return;   // the browser went away
    }
    // Stage the bytes on the destination volume outside the publish lock.
    // Only the final no-replace rename is serialized with Stop.
    NSString *stageName = [kWQUploadStagePrefix stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *stage = [dir stringByAppendingPathComponent:stageName];
    NSString *error = nil;
    BOOL staged = !_stopped && wq_create_file_from(stage, temp, &error);
    unlink(temp.fileSystemRepresentation);
    if (!staged) {
        if (!_stopped) reply(500, WQLocalizedFormat(@"Upload failed: %@", error ?: @"?"));
        return;
    }

    NSString *base = name.stringByDeletingPathExtension, *ext = name.pathExtension;
    NSString *finalName = nil;
    NSDictionary *identity = wq_item_identity(stage);
    // "name 2", "name 3"… up to 999, then a random suffix; the name part is
    // shortened when a suffix would make it longer than 255 bytes (DR-28).
    for (NSUInteger i = 1; identity && i <= 1000 && !finalName && !_stopped; i++) {
        NSString *candidate = i == 1 ? name
            : WQUploadCandidate(base, ext, i < 1000 ? [NSString stringWithFormat:@" %lu", (unsigned long)i]
                                                    : [@" " stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:8]]);
        [_publishLock lock];
        BOOL permitted = !_stopped && self.allowUploads;
        BOOL published = permitted && wq_rename_expecting(stage, candidate, identity, &error);
        int publishError = errno;
        [_publishLock unlock];
        if (published) finalName = candidate;
        else if (!permitted || publishError != EEXIST) break;
    }
    // The stage name is our own random one; without an identity (it couldn't
    // be read) it is still removed rather than left behind.
    if (!finalName && (!identity || [identity isEqualToDictionary:wq_item_identity(stage)])) {
        if (unlink(stage.fileSystemRepresentation) != 0 && wq_grant(dir))
            unlink(stage.fileSystemRepresentation);
    }
    if (!finalName && _stopped) return;
    if (!finalName) { reply(500, WQLocalizedFormat(@"Upload failed: %@", error ?: @"?")); return; }
    wq_log(@"wifi sharing: uploaded %@ (%lld bytes) to %@", finalName, length, dir);
    NSString *line = [NSString stringWithFormat:@"PUT %@", [[@"/" stringByAppendingString:[dirComponents componentsJoinedByString:@"/"]] stringByAppendingPathComponent:finalName]];
    void (^log)(NSString *) = self.requestHandler;
    if (log) dispatch_async(dispatch_get_main_queue(), ^{ log(line); });
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"name": finalName} options:0 error:nil];
    [self respond:fd status:201 type:@"application/json" body:json head:NO extra:nil];
}

- (BOOL)authorized:(NSString *)header
{
    if (![header.lowercaseString hasPrefix:@"basic "]) return NO;
    NSData *given = [[NSData alloc] initWithBase64EncodedString:[header substringFromIndex:6]
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (given.length != _expectedAuth.length) return NO;
    const uint8_t *a = given.bytes, *b = _expectedAuth.bytes;
    uint8_t diff = 0;
    for (NSUInteger i = 0; i < given.length; i++) diff |= a[i] ^ b[i];   // constant time
    return diff == 0;
}

// Full path for components below the shared folder, or nil when something on
// the way is missing, a symbolic link, or (at the top of an enumerated
// container root) not one of the listed containers.
- (nullable NSString *)resolve:(NSArray<NSString *> *)components stat:(struct stat *)st
{
    NSString *current = _root;
    if (!wq_stat(current, st)) return nil;
    for (NSUInteger i = 0; i < components.count; i++) {
        if (!S_ISDIR(st->st_mode)) return nil;
        if (i == 0 && _entries) {
            WQWebEntry *entry = _entries[components[0]];
            if (!entry) return nil;
            current = entry.path;
            (void)wq_grant(current);
        } else {
            current = [current stringByAppendingPathComponent:components[i]];
        }
        if (!wq_stat(current, st) || S_ISLNK(st->st_mode)) return nil;
    }
    return current;
}

#pragma mark Responses

- (void)respond:(int)fd status:(int)status type:(NSString *)type body:(NSData *)body head:(BOOL)head
          extra:(nullable NSDictionary<NSString *, NSString *> *)extra
{
    NSDictionary *reasons = @{@200: @"OK", @201: @"Created", @206: @"Partial Content", @411: @"Length Required", @507: @"Insufficient Storage", @302: @"Found", @400: @"Bad Request", @401: @"Unauthorized",
                              @403: @"Forbidden", @404: @"Not Found", @405: @"Method Not Allowed", @416: @"Range Not Satisfiable",
                              @431: @"Request Header Fields Too Large", @500: @"Internal Server Error"};
    NSMutableString *h = [NSMutableString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\n"
                          "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
                          "Referrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n",
                          status, reasons[@(status)] ?: @"OK", type, (unsigned long)body.length];
    [extra enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL * __unused stop) { [h appendFormat:@"%@: %@\r\n", k, v]; }];
    [h appendString:@"\r\n"];
    NSData *headData = [h dataUsingEncoding:NSUTF8StringEncoding];
    if (!WQWebSend(fd, headData.bytes, headData.length)) return;
    if (!head && body.length) WQWebSend(fd, body.bytes, body.length);
}

- (void)respondError:(int)fd status:(int)status message:(NSString *)message head:(BOOL)head
{
    NSString *page = [self pageShellWithTitle:_title body:[NSString stringWithFormat:@"<p class=\"empty\">%@</p>"
                                                           "<p><a class=\"pill\" href=\"/browse/\">%@</a></p>",
                                                           WQWebHTMLEscape(message), WQWebHTMLEscape(_title)]];
    [self respond:fd status:status type:@"text/html; charset=utf-8" body:[page dataUsingEncoding:NSUTF8StringEncoding] head:head
            extra:@{@"Content-Security-Policy": @"default-src 'none'; style-src 'unsafe-inline'"}];
}

static NSString *WQWebDisposition(NSString *kind, NSString *name)
{
    NSMutableString *ascii = [NSMutableString new];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        [ascii appendString:(c >= 0x20 && c < 0x7f && c != '"' && c != '\\') ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    return [NSString stringWithFormat:@"%@; filename=\"%@\"; filename*=UTF-8''%@", kind, ascii, WQWebEncode(name)];
}

- (void)sendFile:(int)fd path:(NSString *)path download:(BOOL)download range:(nullable NSString *)range head:(BOOL)head
{
    int file = wq_open_for_reading(path);
    struct stat st;
    if (file < 0 || fstat(file, &st) != 0 || !S_ISREG(st.st_mode)) {
        if (file >= 0) close(file);
        [self respondError:fd status:403 message:WQLocalized(@"WQ Files can't open this file.") head:head];
        return;
    }
    unsigned long long size = (unsigned long long)st.st_size, start = 0, last = size ? size - 1 : 0;
    BOOL partial = NO;
    // One range, strictly parsed; anything malformed is ignored (the whole
    // file is sent), as HTTP allows.
    if (range && size > 0) {
        switch (WQWebParseRange(range, size, &start, &last)) {
            case WQWebRangeNone: start = 0; last = size - 1; break;
            case WQWebRangeUnsatisfiable:
                close(file);
                [self respond:fd status:416 type:@"text/plain" body:[NSData data] head:head
                        extra:@{@"Content-Range": [NSString stringWithFormat:@"bytes */%llu", size]}];
                return;
            case WQWebRangePartial: partial = YES; break;
        }
    }
    NSString *name = path.lastPathComponent;
    UTType *type = [UTType typeWithFilenameExtension:name.pathExtension];
    NSString *mime = type.preferredMIMEType ?: @"application/octet-stream";
    // Only types a browser shows without running anything open in the tab;
    // other text is shown as plain text, everything else downloads.
    BOOL media = [mime hasPrefix:@"image/"] || [mime hasPrefix:@"video/"] || [mime hasPrefix:@"audio/"] ||
                 [mime isEqualToString:@"application/pdf"];
    if ([mime isEqualToString:@"image/svg+xml"]) media = NO;
    BOOL text = !media && type && [type conformsToType:UTTypeText];
    BOOL inlineView = !download && (media || text);
    if (text) mime = @"text/plain; charset=utf-8";
    if (!inlineView && !text && !media) mime = @"application/octet-stream";
    unsigned long long length = size ? last - start + 1 : 0;
    NSMutableDictionary *extra = [@{@"Accept-Ranges": @"bytes",
                                    @"Content-Disposition": WQWebDisposition(inlineView ? @"inline" : @"attachment", name)} mutableCopy];
    if (![mime isEqualToString:@"application/pdf"]) extra[@"Content-Security-Policy"] = @"sandbox; default-src 'none'; img-src 'self'; media-src 'self'";
    if (partial) extra[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", start, last, size];
    NSMutableString *h = [NSMutableString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Type: %@\r\nContent-Length: %llu\r\n"
                          "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
                          "Referrer-Policy: no-referrer\r\n", partial ? @"206 Partial Content" : @"200 OK", mime, length];
    [extra enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL * __unused stop) { [h appendFormat:@"%@: %@\r\n", k, v]; }];
    [h appendString:@"\r\n"];
    NSData *headData = [h dataUsingEncoding:NSUTF8StringEncoding];
    if (!WQWebSend(fd, headData.bytes, headData.length) || head) { close(file); return; }
    char *buffer = malloc(kWQWebChunk);
    unsigned long long offset = start, remaining = length;
    while (remaining > 0 && !_stopped) {
        size_t want = (size_t)MIN((unsigned long long)kWQWebChunk, remaining);
        ssize_t n = pread(file, buffer, want, (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0 || !WQWebSend(fd, buffer, (size_t)n)) break;
        offset += (unsigned long long)n;
        remaining -= (unsigned long long)n;
    }
    free(buffer);
    close(file);
}

- (void)sendZip:(int)fd path:(NSString *)path components:(NSArray<NSString *> *)components head:(BOOL)head
{
    // HEAD: the headers only, without a length. Building the whole archive
    // (up to 4 GB of temporary storage) just to learn its size and drop it
    // is not worth it.
    if (head) {
        static const char reply[] = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nConnection: close\r\n"
                                    "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n";
        WQWebSend(fd, reply, sizeof reply - 1);
        return;
    }
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"WQWeb-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = components.count ? components.lastObject : (_title.length ? _title : path.lastPathComponent);
    NSString *zip = [dir stringByAppendingPathComponent:[[name stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByAppendingPathExtension:@"zip"]];
    WQArchiveIO *io = [WQArchiveIO new];
    io.stat = ^BOOL(NSString *p, struct stat *s) { return wq_stat(p, s); };
    io.list = ^NSArray<NSString *> *(NSString *d) {
        return [wq_list(d, NULL) filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
            ^BOOL(NSString *name, NSDictionary *__unused bindings) {
                return ![name.lowercaseString hasPrefix:kWQUploadStagePrefix];
            }]];
    };
    io.openRead = ^int(NSString *p) { return wq_open_for_reading(p); };
    io.skipUnreadable = YES;
    io.expectedUnreadableNames = [NSSet setWithObject:@".com.apple.mobile_container_manager.metadata.plist"];
    NSArray<NSString *> *paths = @[path];
    if (!components.count && _entries) paths = [_entries.allValues valueForKey:@"path"];
    NSString *error = nil;
    __weak typeof(self) weakSelf = self;
    // One archive at a time: each is built in temporary storage first (up
    // to 4 GB), so a few requests at once could fill the device.
    static dispatch_semaphore_t oneZip;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ oneZip = dispatch_semaphore_create(1); });
    while (dispatch_semaphore_wait(oneZip, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2)) != 0) {
        if (_stopped) { [NSFileManager.defaultManager removeItemAtPath:dir error:nil]; return; }
    }
    BOOL ok = wq_zip_write(paths, zip, io, ^BOOL { WQWebServer *me = weakSelf; return !me || me->_stopped; }, nil, NULL, &error);
    dispatch_semaphore_signal(oneZip);
    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        [self respondError:fd status:500 message:WQLocalizedFormat(@"The ZIP could not be created: %@", error ?: @"?") head:head];
        return;
    }
    int file = open(zip.fileSystemRepresentation, O_RDONLY);
    struct stat st;
    if (file >= 0 && fstat(file, &st) == 0) {
        NSString *h = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: %lld\r\n"
                       "Content-Disposition: %@\r\nConnection: close\r\nCache-Control: no-store\r\n"
                       "X-Content-Type-Options: nosniff\r\n\r\n",
                       (long long)st.st_size, WQWebDisposition(@"attachment", zip.lastPathComponent)];
        NSData *headData = [h dataUsingEncoding:NSUTF8StringEncoding];
        if (WQWebSend(fd, headData.bytes, headData.length) && !head) {
            char *buffer = malloc(kWQWebChunk);
            ssize_t n;
            while (!_stopped && (n = read(file, buffer, kWQWebChunk)) > 0) if (!WQWebSend(fd, buffer, (size_t)n)) break;
            free(buffer);
        }
    }
    if (file >= 0) close(file);
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

#pragma mark Page

- (NSArray<WQWebItem *> *)itemsIn:(NSString *)path components:(NSArray<NSString *> *)components error:(NSString **)error
{
    NSMutableArray<WQWebItem *> *items = [NSMutableArray new];
    NSArray<NSString *> *names;
    if (!components.count && _entries) names = _entries.allKeys;
    else names = wq_list(path, error);
    if (!names) return nil;
    BOOL containers = [@[@"Application", @"AppGroup", @"PluginKitPlugin", @"InternalDaemon", @"System"]
                       containsObject:path.lastPathComponent];
    for (NSString *name in names) {
        if ([name.lowercaseString hasPrefix:kWQUploadStagePrefix]) continue;
        WQWebItem *item = [WQWebItem new];
        item.name = name;
        WQWebEntry *entry = (!components.count && _entries) ? _entries[name] : nil;
        item.path = entry ? entry.path : [path stringByAppendingPathComponent:name];
        item.label = entry.label;
        if (entry) (void)wq_grant(item.path);
        struct stat st;
        if (!wq_stat(item.path, &st)) continue;
        item.isLink = S_ISLNK(st.st_mode);
        item.isDir = S_ISDIR(st.st_mode);
        item.readable = !item.isLink && wq_stat_readable(&st);
        item.size = (unsigned long long)st.st_size;
        item.modified = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec];
        if (!item.label && containers && item.isDir && WQWebLooksLikeUUID(name)) {
            NSString *bid = wq_container_label(item.path);
            item.label = bid ? (wq_display_name(bid) ?: bid) : nil;
        }
        [items addObject:item];
    }
    [items sortUsingComparator:^NSComparisonResult(WQWebItem *a, WQWebItem *b) {
        if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        return [(a.label ?: a.name) localizedStandardCompare:(b.label ?: b.name)];
    }];
    return items;
}

// Upload: Upload Files button and drag and drop, one PUT per file with a
// progress bar; texts come from data- attributes so they are translated.
static NSString *const kWQWebScript =
    @"(function(){var b=document.body,base=b.dataset.upload;if(!base)return;"
    "var input=document.getElementById('wq-up'),box=document.getElementById('wq-box'),"
    "label=document.getElementById('wq-label'),bar=document.getElementById('wq-bar');"
    "function fmt(t,v){return t.replace('%@',v);}"
    "function send(files,i){if(i>=files.length){label.textContent=b.dataset.done;setTimeout(function(){location.reload();},700);return;}"
    "var f=files[i],x=new XMLHttpRequest();box.hidden=false;bar.value=0;"
    "label.textContent=fmt(b.dataset.uploading,f.name)+(files.length>1?' ('+(i+1)+'/'+files.length+')':'');"
    "x.open('PUT',base+encodeURIComponent(f.name));x.setRequestHeader('X-WQ-Upload','1');"
    "x.upload.onprogress=function(e){if(e.lengthComputable)bar.value=e.loaded/e.total;};"
    "x.onload=function(){if(x.status>=200&&x.status<300)send(files,i+1);else label.textContent=fmt(b.dataset.failed,x.responseText||x.status);};"
    "x.onerror=function(){label.textContent=fmt(b.dataset.failed,'network');};x.send(f);}"
    "input.addEventListener('change',function(){if(input.files.length)send(Array.prototype.slice.call(input.files),0);});"
    "document.addEventListener('dragover',function(e){e.preventDefault();b.classList.add('drag');});"
    "document.addEventListener('dragleave',function(e){if(!e.relatedTarget)b.classList.remove('drag');});"
    "document.addEventListener('drop',function(e){e.preventDefault();b.classList.remove('drag');"
    "var fs=Array.prototype.slice.call(e.dataTransfer.files||[]);if(fs.length)send(fs,0);});})();";

static NSString *const kWQWebUploadIcon =
    @"<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M12 21a1 1 0 0 1-1-1v-9.6l-3.3 3.3a1 1 0 1 1-1.4-1.4l5-5a1 1 0 0 1 1.4 0l5 5a1 1 0 1 1-1.4 1.4L13 10.4V20a1 1 0 0 1-1 1zM5 5a1 1 0 0 1 1-1h12a1 1 0 1 1 0 2H6a1 1 0 0 1-1-1z\"/></svg>";

static NSString *const kWQWebFolderIcon =
    @"<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M3 6.5A2.5 2.5 0 0 1 5.5 4h3.6c.6 0 1.2.25 1.6.7L12 6h6.5A2.5 2.5 0 0 1 21 8.5v9a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z\"/></svg>";
static NSString *const kWQWebFileIcon =
    @"<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M6.5 2h7.2c.5 0 1 .2 1.4.6l4.3 4.3c.4.4.6.9.6 1.4V19.5A2.5 2.5 0 0 1 17.5 22h-11A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2zM13 3.8V8c0 .55.45 1 1 1h4.2z\"/></svg>";
static NSString *const kWQWebLinkIcon =
    @"<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M10.6 13.4a1 1 0 0 1 0-1.4l3.5-3.5a3 3 0 1 1 4.2 4.2l-2 2a1 1 0 1 1-1.4-1.4l2-2a1 1 0 1 0-1.4-1.4l-3.5 3.5a1 1 0 0 1-1.4 0zm2.8-2.8a1 1 0 0 1 0 1.4l-3.5 3.5a3 3 0 1 1-4.2-4.2l2-2a1 1 0 0 1 1.4 1.4l-2 2a1 1 0 1 0 1.4 1.4l3.5-3.5a1 1 0 0 1 1.4 0z\"/></svg>";
static NSString *const kWQWebDownloadIcon =
    @"<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M12 3a1 1 0 0 1 1 1v9.6l3.3-3.3a1 1 0 1 1 1.4 1.4l-5 5a1 1 0 0 1-1.4 0l-5-5a1 1 0 1 1 1.4-1.4l3.3 3.3V4a1 1 0 0 1 1-1zM5 19a1 1 0 0 1 1-1h12a1 1 0 1 1 0 2H6a1 1 0 0 1-1-1z\"/></svg>";

// Tile tone for a file (WQ Prism uses colored tiles like the app's cards).
static NSString *WQWebTone(WQWebItem *item)
{
    if (item.isDir) return @"sky";
    UTType *type = [UTType typeWithFilenameExtension:item.name.pathExtension];
    if (!type) return @"gray";
    if ([type conformsToType:UTTypeImage]) return @"pink";
    if ([type conformsToType:UTTypeMovie] || [type conformsToType:UTTypeVideo]) return @"violet";
    if ([type conformsToType:UTTypeAudio]) return @"orange";
    if ([type conformsToType:UTTypeArchive]) return @"amber";
    if ([type conformsToType:UTTypeDatabase] || [item.name.pathExtension.lowercaseString isEqualToString:@"sqlite"]) return @"mint";
    if ([type conformsToType:UTTypeText] || [type conformsToType:UTTypePropertyList]) return @"indigo";
    return @"gray";
}

- (NSString *)styleSheet
{
    BOOL prism = wq_prism_enabled();
    NSMutableString *css = [NSMutableString stringWithString:
        @":root{color-scheme:light dark}"
        "*{box-sizing:border-box}"
        "body{margin:0;min-height:100vh;font:16px/1.4 -apple-system,BlinkMacSystemFont,\"SF Pro Text\",\"Segoe UI\",Roboto,\"Helvetica Neue\",Arial,sans-serif;"
        "-webkit-font-smoothing:antialiased;color:var(--text);background:var(--bg)}"
        "a{color:inherit;text-decoration:none}"
        ".wrap{max-width:920px;margin:0 auto;padding:28px 16px 56px}"
        ".top{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}"
        ".brand{font-size:13px;font-weight:600;letter-spacing:.02em;color:var(--sub)}"
        "h1{font-size:34px;line-height:1.15;font-weight:700;letter-spacing:-.02em;margin:10px 0 6px;overflow-wrap:anywhere}"
        ".path{font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--sub);overflow-wrap:anywhere}"
        ".path a{color:var(--accent)}"
        ".bar{display:flex;gap:10px;flex-wrap:wrap;margin:16px 0 18px}"
        ".pill{display:inline-flex;align-items:center;gap:7px;padding:9px 15px;border-radius:999px;font-size:15px;font-weight:600;"
        "color:var(--accent);background:var(--pill)}"
        ".pill svg{width:17px;height:17px}"
        ".list{overflow:hidden;border-radius:var(--radius);background:var(--card);border:1px solid var(--stroke)}"
        ".row{display:flex;align-items:center;gap:14px;padding:11px 14px 11px 16px;position:relative}"
        ".row+.row:before{content:\"\";position:absolute;top:0;left:66px;right:0;border-top:1px solid var(--sep)}"
        "a.main{display:flex;align-items:center;gap:14px;flex:1;min-width:0}"
        ".icon{width:36px;height:36px;flex:none;display:flex;align-items:center;justify-content:center}"
        ".icon svg{width:22px;height:22px}"
        ".text{min-width:0;flex:1}"
        ".name{font-weight:500;overflow-wrap:anywhere}"
        ".meta{font-size:13px;color:var(--sub);margin-top:1px;overflow-wrap:anywhere}"
        ".act{flex:none;width:34px;height:34px;border-radius:999px;display:flex;align-items:center;justify-content:center;color:var(--accent);background:var(--pill)}"
        ".act svg{width:18px;height:18px}"
        ".chev{flex:none;color:var(--sub);font-size:20px;opacity:.6}"
        ".off{opacity:.45}"
        ".empty{padding:22px 18px;color:var(--sub);text-align:center}"
        ".foot{margin-top:18px;font-size:12.5px;color:var(--sub);text-align:center}"
        "@media (hover:hover){a.main:hover .name{text-decoration:underline}.act:hover,.pill:hover{filter:brightness(1.1)}}"
        "label.pill{cursor:pointer}#wq-up{position:absolute;width:1px;height:1px;opacity:0}"
        ".upbox{margin:0 0 16px;padding:12px 16px;border-radius:var(--radius);background:var(--card);border:1px solid var(--stroke)}"
        ".upbox[hidden]{display:none}.upbox progress{width:100%;height:6px;margin-top:8px;accent-color:var(--accent)}"
        ".hint{font-size:13px;color:var(--sub);margin:-6px 0 14px}"
        "body.drag .list{outline:2px dashed var(--accent);outline-offset:4px}"];
    if (!prism) {
        // Classic design: iOS grouped list.
        [css appendString:
            @":root{--bg:#f2f2f7;--text:#000;--sub:rgba(60,60,67,.6);--card:#fff;--stroke:transparent;--sep:rgba(60,60,67,.18);"
            "--accent:#007aff;--pill:rgba(0,122,255,.1);--radius:12px}"
            "@media (prefers-color-scheme:dark){:root{--bg:#000;--text:#fff;--sub:rgba(235,235,245,.6);--card:#1c1c1e;"
            "--sep:rgba(84,84,88,.6);--accent:#0a84ff;--pill:rgba(10,132,255,.18)}}"
            ".icon{color:var(--accent)}.icon.file{color:var(--sub)}"];
        return css;
    }
    // WQ Prism: the app's backdrop (same palette, so Plain Background and the
    // picked Background Color apply), translucent cards and colored tiles.
    NSString *(^backdrop)(BOOL) = ^NSString *(BOOL dark) {
        WQPrismPalette *p = wq_prism_palette(dark);
        NSArray *spots = @[@"12% 12%", @"86% 6%", @"74% 78%", @"4% 96%"];
        NSMutableArray *layers = [NSMutableArray new];
        for (NSUInteger i = 0; i < p.glows.count && i < spots.count; i++)
            [layers addObject:[NSString stringWithFormat:@"radial-gradient(circle at %@, %@ 0, transparent 38vmax)", spots[i], WQWebCSSColor(p.glows[i])]];
        [layers addObject:[NSString stringWithFormat:@"linear-gradient(%@, %@)", WQWebCSSColor(p.baseTop), WQWebCSSColor(p.baseBottom)]];
        return [NSString stringWithFormat:@"%@;background-attachment:fixed", [layers componentsJoinedByString:@","]];
    };
    [css appendFormat:
        @":root{--text:#0b1020;--sub:rgba(20,28,52,.6);--card:rgba(255,255,255,.72);--stroke:rgba(255,255,255,.7);--sep:rgba(20,28,52,.1);"
        "--accent:#3f63f0;--pill:rgba(94,128,255,.14);--radius:22px}"
        "body{background:%@}"
        "@media (prefers-color-scheme:dark){:root{--text:#f4f6ff;--sub:rgba(226,232,255,.62);--card:rgba(28,30,40,.66);"
        "--stroke:rgba(255,255,255,.08);--sep:rgba(255,255,255,.08);--accent:#8aa2ff;--pill:rgba(94,128,255,.2)}body{background:%@}}"
        "%@"
        ".list{backdrop-filter:blur(22px) saturate(1.4);-webkit-backdrop-filter:blur(22px) saturate(1.4);box-shadow:0 10px 30px rgba(0,0,0,.12)}"
        ".icon{border-radius:10px;color:#fff;box-shadow:inset 0 0 0 .5px rgba(255,255,255,.25)}"
        ".row+.row:before{left:66px}"
        ".sky{background:linear-gradient(135deg,#8ad9ff,#3d7dff)}.pink{background:linear-gradient(135deg,#ff9ec7,#f0457f)}"
        ".violet{background:linear-gradient(135deg,#b59bff,#7a4dff)}.orange{background:linear-gradient(135deg,#ffbb73,#ff7a2e)}"
        ".amber{background:linear-gradient(135deg,#ffd970,#f2a400)}.mint{background:linear-gradient(135deg,#62ebc8,#12b39a)}"
        ".indigo{background:linear-gradient(135deg,#9ea3ff,#5658e8)}.gray{background:linear-gradient(135deg,#b7bfd0,#7b8498)}"
        "h1{font-size:36px}",
        backdrop(NO), backdrop(YES), [self themeAccentCSS]];
    return css;
}

// An imported theme's accent replaces the page's default blue.
- (NSString *)themeAccentCSS
{
    WQTheme *theme = wq_active_theme();
    UIColor *light = [theme appearanceDark:NO].accent, *dark = [theme appearanceDark:YES].accent;
    NSMutableString *css = [NSMutableString new];
    if (light) [css appendFormat:@":root{--accent:%@;--pill:%@}", WQWebCSSColor(light), WQWebCSSColor([light colorWithAlphaComponent:0.14])];
    if (dark) [css appendFormat:@"@media (prefers-color-scheme:dark){:root{--accent:%@;--pill:%@}}", WQWebCSSColor(dark), WQWebCSSColor([dark colorWithAlphaComponent:0.2])];
    return css;
}

- (NSString *)pageShellWithTitle:(NSString *)title body:(NSString *)body
{
    return [self pageShellWithTitle:title body:body upload:nil];
}

- (NSString *)pageShellWithTitle:(NSString *)title body:(NSString *)body upload:(nullable NSString *)uploadBase
{
    NSString *attributes = @"", *script = @"";
    if (uploadBase) {
        attributes = [NSString stringWithFormat:@" data-upload=\"%@\" data-uploading=\"%@\" data-done=\"%@\" data-failed=\"%@\"",
                      WQWebHTMLEscape(uploadBase), WQWebHTMLEscape(WQLocalized(@"Uploading %@…")),
                      WQWebHTMLEscape(WQLocalized(@"Uploaded.")), WQWebHTMLEscape(WQLocalized(@"Upload failed: %@"))];
        script = @"<script src=\"/app.js\"></script>";
    }
    return [NSString stringWithFormat:
        @"<!doctype html><html lang=\"%@\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\">"
        "<title>%@ · WQ Files</title><style>%@</style></head><body%@><div class=\"wrap\">"
        "<div class=\"top\"><div class=\"brand\">WQ FILES · %@</div></div>%@</div>%@</body></html>",
        WQWebHTMLEscape(NSLocale.preferredLanguages.firstObject ?: @"en"), WQWebHTMLEscape(title), [self styleSheet], attributes,
        WQWebHTMLEscape(WQLocalized(self.allowUploads ? @"Uploads on" : @"Read-only").uppercaseString), body, script];
}

- (NSString *)pageFor:(NSString *)path components:(NSArray<NSString *> *)components
{
    NSString *error = nil;
    NSArray<WQWebItem *> *items = [self itemsIn:path components:components error:&error];
    BOOL prism = wq_prism_enabled();
    NSString *title = components.count ? components.lastObject : _title;
    if (components.count == 1 && _entries[components[0]].label) title = _entries[components[0]].label;
    NSMutableString *body = [NSMutableString new];
    [body appendFormat:@"<h1>%@</h1>", WQWebHTMLEscape(title)];
    // Breadcrumbs: the shared folder, then each component.
    NSMutableString *crumbs = [NSMutableString stringWithFormat:@"<a href=\"/browse/\">%@</a>", WQWebHTMLEscape(_root)];
    for (NSUInteger i = 0; i < components.count; i++) {
        NSString *href = [NSString stringWithFormat:@"/browse/%@/", WQWebEncodePath([components subarrayWithRange:NSMakeRange(0, i + 1)])];
        [crumbs appendFormat:@"/<a href=\"%@\">%@</a>", href, WQWebHTMLEscape(components[i])];
    }
    [body appendFormat:@"<div class=\"path\">%@</div><div class=\"bar\">", crumbs];
    if (components.count) {
        NSString *up = [NSString stringWithFormat:@"/browse/%@%@", WQWebEncodePath([components subarrayWithRange:NSMakeRange(0, components.count - 1)]),
                        components.count > 1 ? @"/" : @""];
        [body appendFormat:@"<a class=\"pill\" href=\"%@\">‹ %@</a>", up, WQWebHTMLEscape(WQLocalized(@"Up"))];
    }
    [body appendFormat:@"<a class=\"pill\" href=\"/zip/%@\">%@ %@</a>", WQWebEncodePath(components), kWQWebDownloadIcon,
                       WQWebHTMLEscape(WQLocalized(@"Download Folder as ZIP"))];
    // Uploads go into real folders, not into a container root (App Data…).
    NSString *uploadBase = nil;
    if (self.allowUploads && items && !(!components.count && _entries)) {
        uploadBase = [NSString stringWithFormat:@"/upload/%@%@", WQWebEncodePath(components), components.count ? @"/" : @""];
        [body appendFormat:@"<label class=\"pill\" for=\"wq-up\">%@ %@</label><input id=\"wq-up\" type=\"file\" multiple>",
                           kWQWebUploadIcon, WQWebHTMLEscape(WQLocalized(@"Upload Files…"))];
    }
    [body appendString:@"</div>"];
    if (uploadBase) {
        [body appendFormat:@"<div class=\"hint\">%@</div><div class=\"upbox\" id=\"wq-box\" hidden><div id=\"wq-label\"></div>"
                           "<progress id=\"wq-bar\" max=\"1\" value=\"0\"></progress></div>",
                           WQWebHTMLEscape(WQLocalized(@"Drop files here or use Upload Files. Nothing is overwritten."))];
    }
    [body appendString:@"<div class=\"list\">"];
    if (!items) {
        [body appendFormat:@"<div class=\"empty\">%@</div>", WQWebHTMLEscape(WQLocalized(@"WQ Files can't open this folder."))];
    } else if (!items.count) {
        [body appendFormat:@"<div class=\"empty\">%@</div>", WQWebHTMLEscape(WQLocalized(@"This folder is empty."))];
    }
    NSDateFormatter *dates = [NSDateFormatter new];
    dates.dateStyle = NSDateFormatterMediumStyle;
    dates.timeStyle = NSDateFormatterShortStyle;
    for (WQWebItem *item in items) {
        NSString *rel = WQWebEncodePath([components arrayByAddingObject:item.name]);
        NSString *shown = item.label ?: item.name;
        NSMutableArray *meta = [NSMutableArray new];
        if (item.label) [meta addObject:WQWebHTMLEscape(item.name)];
        if (!item.isDir && !item.isLink) [meta addObject:WQWebHTMLEscape(wq_size_text(item.size))];
        if (item.modified) [meta addObject:WQWebHTMLEscape([dates stringFromDate:item.modified])];
        if (item.isLink) [meta addObject:WQWebHTMLEscape(WQLocalized(@"Symbolic link"))];
        else if (!item.readable) [meta addObject:WQWebHTMLEscape(WQLocalized(@"No access"))];
        NSString *icon = item.isLink ? kWQWebLinkIcon : item.isDir ? kWQWebFolderIcon : kWQWebFileIcon;
        NSString *tone = prism ? (item.isLink ? @"gray" : WQWebTone(item)) : (item.isDir ? @"" : @"file");
        NSString *inner = [NSString stringWithFormat:@"<span class=\"icon %@\">%@</span><span class=\"text\"><div class=\"name\">%@</div>"
                           "<div class=\"meta\">%@</div></span>", tone, icon, WQWebHTMLEscape(shown), [meta componentsJoinedByString:@" · "]];
        if (item.isLink || !item.readable) {
            [body appendFormat:@"<div class=\"row off\"><span class=\"main\" style=\"display:flex;align-items:center;gap:14px;flex:1;min-width:0\">%@</span></div>", inner];
        } else if (item.isDir) {
            [body appendFormat:@"<div class=\"row\"><a class=\"main\" href=\"/browse/%@/\">%@</a>"
                               "<a class=\"act\" href=\"/zip/%@\" title=\"%@\" aria-label=\"%@\">%@</a><span class=\"chev\">›</span></div>",
                               rel, inner, rel, WQWebHTMLEscape(WQLocalized(@"Download Folder as ZIP")),
                               WQWebHTMLEscape(WQLocalized(@"Download Folder as ZIP")), kWQWebDownloadIcon];
        } else {
            [body appendFormat:@"<div class=\"row\"><a class=\"main\" href=\"/file/%@\" target=\"_blank\" rel=\"noopener\">%@</a>"
                               "<a class=\"act\" href=\"/file/%@?dl=1\" title=\"%@\" aria-label=\"%@\">%@</a><span class=\"chev\" style=\"visibility:hidden\">›</span></div>",
                               rel, inner, rel, WQWebHTMLEscape(WQLocalized(@"Download")), WQWebHTMLEscape(WQLocalized(@"Download")), kWQWebDownloadIcon];
        }
    }
    [body appendString:@"</div>"];
    [body appendFormat:@"<div class=\"foot\">%@</div>", WQWebHTMLEscape(items ? (self.allowUploads ? WQLocalizedFormat(@"%lu items", (unsigned long)items.count)
                                                                                           : WQLocalizedFormat(@"%lu items · read-only", (unsigned long)items.count))
                                                                         : WQLocalized(@"Read-only"))];
    return [self pageShellWithTitle:title body:body upload:uploadBase];
}

@end

#pragma mark - Sharing screen

@interface WQWebShareViewController : UITableViewController
@end

@implementation WQWebShareViewController {
    NSString *_root, *_folderTitle;
    NSArray<WQWebEntry *> *_entries;
    WQWebServer *_server;
    NSString *_problem;
    NSMutableArray<NSString *> *_requests;
    UIImage *_qr;
    BOOL _uploadable, _allowUploads;
}

- (instancetype)initWithRoot:(NSString *)root title:(NSString *)title entries:(NSArray<WQWebEntry *> *)entries uploadable:(BOOL)uploadable
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _uploadable = uploadable && !entries.count;   // container roots: only their containers' folders
        _root = [root copy];
        _folderTitle = [title copy];
        _entries = [entries copy];
        _requests = [NSMutableArray new];
        self.title = WQLocalizedNullable(@"Wi-Fi Sharing");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = UIColor.clearColor;
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Done")
        style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded)
                                               name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self startSharing];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_server stop];
    UIApplication.sharedApplication.idleTimerDisabled = NO;
}

- (void)close
{
    [self stopSharing];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (self.navigationController.isBeingDismissed || self.isBeingDismissed || !self.view.window) [self stopSharing];
}

- (void)backgrounded
{
    if (!_server.running) return;
    [self stopSharing];
    _problem = WQLocalized(@"Sharing stopped because WQ Files went to the background.");
    [self.tableView reloadData];
}

- (void)startSharing
{
    [_server stop];
    // A new server each time: a new password.
    _server = [[WQWebServer alloc] initWithRoot:_root title:_folderTitle rootEntries:_entries];
    _server.allowUploads = _allowUploads;
    __weak typeof(self) weakSelf = self;
    _server.requestHandler = ^(NSString *line) {
        typeof(self) me = weakSelf;
        if (!me) return;
        [me->_requests insertObject:line atIndex:0];
        if (me->_requests.count > 8) [me->_requests removeLastObject];
        [me.tableView reloadSections:[NSIndexSet indexSetWithIndex:3] withRowAnimation:UITableViewRowAnimationNone];
    };
    NSString *error = nil;
    _problem = [_server start:&error] ? nil : (error ?: WQLocalized(@"Sharing could not start."));
    _qr = _server.running ? [self qrFor:_server.address] : nil;
    UIApplication.sharedApplication.idleTimerDisabled = _server.running;   // a sleeping iPhone stops serving
    [self.tableView reloadData];
}

- (void)stopSharing
{
    [_server stop];
    _qr = nil;
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    if (self.isViewLoaded) [self.tableView reloadData];
}

- (UIImage *)qrFor:(NSString *)text
{
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *image = [filter.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(12, 12)];
    if (!image) return nil;
    CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:image fromRect:image.extent];
    if (!cg) return nil;
    UIImage *result = [UIImage imageWithCGImage:cg scale:3 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return result;
}

- (void)copyText:(NSString *)text
{
    if (!text.length) return;
    UIPasteboard.generalPasteboard.string = text;
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 1;
    if (section == 1) return _server.running ? 3 : 0;
    if (section == 2) return _server.running ? (_uploadable ? 3 : 2) : 1;
    return _server.running ? (NSInteger)MAX(_requests.count, 1) : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 3 && _server.running ? WQLocalized(@"Requests") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section != 2) return nil;
    NSString *text = [NSString stringWithFormat:@"%@ %@",
        WQLocalized(@"Open the address in a browser on a computer or phone on the same Wi-Fi and sign in with the user and password. Files can be opened and downloaded. Sharing stops when you close this screen or leave WQ Files."),
        WQLocalized(wq_sharing_password() ? @"The password is the one set in Settings → Sharing Password."
                                          : @"The password changes each time; set a fixed one in Settings → Sharing Password.")];
    text = [text stringByAppendingFormat:@"\n\n%@", WQLocalized(@"The connection is not encrypted: others on the same network can read the password and the files. Share only on a network you trust.")];
    if (_uploadable) text = [text stringByAppendingFormat:@"\n\n%@", WQLocalized(@"Allow Uploads: the browser can add files to this folder and its subfolders. Nothing is overwritten or deleted: a file whose name is taken is saved as “name 2”.")];
    return text;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *c;
    if (indexPath.section == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIStackView *stack = [UIStackView new];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 10;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *status = [UILabel new];
        status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        status.numberOfLines = 0;
        status.textAlignment = NSTextAlignmentCenter;
        BOOL on = _server.running;
        status.text = on ? WQLocalizedFormat(@"Sharing “%@” on Wi-Fi", _folderTitle) : (_problem ?: WQLocalized(@"Not sharing"));
        status.textColor = on ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
        [stack addArrangedSubview:status];
        if (on) {
            UILabel *address = [UILabel new];
            address.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightSemibold];
            address.adjustsFontSizeToFitWidth = YES;
            address.minimumScaleFactor = 0.6;
            address.text = [_server.address stringByReplacingOccurrencesOfString:@"http://" withString:@""];
            [stack addArrangedSubview:address];
            if (_qr) {
                UIImageView *qr = [[UIImageView alloc] initWithImage:_qr];
                qr.layer.magnificationFilter = kCAFilterNearest;
                qr.backgroundColor = UIColor.whiteColor;
                qr.layer.cornerRadius = 12;
                qr.clipsToBounds = YES;
                qr.contentMode = UIViewContentModeScaleAspectFit;
                [qr.widthAnchor constraintEqualToConstant:180].active = YES;
                [qr.heightAnchor constraintEqualToConstant:180].active = YES;
                [stack addArrangedSubview:qr];
            }
        }
        [cell.contentView addSubview:stack];
        UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:18],
            [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-18],
        ]];
        return cell;
    }
    if (indexPath.section == 1) {
        c = [UIListContentConfiguration valueCellConfiguration];
        NSArray *titles = @[@"Address", @"User", @"Password"];
        NSArray *values = @[_server.address ?: @"", _server.user, _server.password];
        c.text = WQLocalized(titles[(NSUInteger)indexPath.row]);
        c.secondaryText = values[(NSUInteger)indexPath.row];
        c.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:17 weight:indexPath.row == 2 ? UIFontWeightSemibold : UIFontWeightRegular];
        c.secondaryTextProperties.color = UIColor.labelColor;
        c.prefersSideBySideTextAndSecondaryText = YES;
        cell.contentConfiguration = c;
        cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]];
        cell.accessoryView.tintColor = UIColor.tertiaryLabelColor;
        return cell;
    }
    if (indexPath.section == 2 && _server.running && _uploadable && indexPath.row == 1) {
        c = [UIListContentConfiguration cellConfiguration];
        c.text = WQLocalized(@"Allow Uploads");
        c.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
        cell.contentConfiguration = c;
        UISwitch *toggle = [UISwitch new];
        toggle.on = _allowUploads;
        __weak typeof(self) weakSelf = self;
        [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
            typeof(self) me = weakSelf;
            if (!me) return;
            me->_allowUploads = ((UISwitch *)action.sender).isOn;
            me->_server.allowUploads = me->_allowUploads;
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 2) {
        c = [UIListContentConfiguration cellConfiguration];
        BOOL stop = _server.running && indexPath.row == [self tableView:tableView numberOfRowsInSection:2] - 1;
        if (_server.running && indexPath.row == 0) {
            c.text = WQLocalized(@"Copy Address");
            c.image = [UIImage systemImageNamed:@"link"];
            c.textProperties.color = self.view.tintColor;
        } else {
            c.text = WQLocalized(stop ? @"Stop Sharing" : @"Start Sharing");
            c.image = [UIImage systemImageNamed:stop ? @"stop.circle" : @"wifi"];
            c.textProperties.color = stop ? UIColor.systemRedColor : self.view.tintColor;
        }
        c.imageProperties.tintColor = c.textProperties.color;
        cell.contentConfiguration = c;
        return cell;
    }
    c = [UIListContentConfiguration cellConfiguration];
    c.text = _requests.count ? _requests[(NSUInteger)indexPath.row] : WQLocalized(@"No requests yet.");
    c.textProperties.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    c.textProperties.color = _requests.count ? UIColor.labelColor : UIColor.secondaryLabelColor;
    c.textProperties.numberOfLines = 2;
    cell.contentConfiguration = c;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        NSArray *values = @[_server.address ?: @"", _server.user, _server.password];
        [self copyText:values[(NSUInteger)indexPath.row]];
    } else if (indexPath.section == 2) {
        if (_server.running && indexPath.row == 0) [self copyText:_server.address];
        else if (_server.running && indexPath.row == [self tableView:tableView numberOfRowsInSection:2] - 1) {
            [self stopSharing]; _problem = nil; [tableView reloadData];
        }
        else if (_server.running) return;   // the Allow Uploads switch row
        else [self startSharing];
    }
}

@end

void wq_present_wifi_sharing(UIViewController *host, NSString *root, NSString *title, NSArray<WQWebEntry *> *rootEntries, BOOL uploadable)
{
    WQWebShareViewController *share = [[WQWebShareViewController alloc] initWithRoot:root title:title entries:rootEntries uploadable:uploadable];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:share];
    [host presentViewController:nav animated:YES completion:nil];
}
