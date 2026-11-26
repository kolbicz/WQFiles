//
//  WQSyntax.m
//  WQ Files
//

#import "WQSyntax.h"

const NSUInteger kWQSyntaxMaxLength = 1024 * 1024;

// Each rule is @[kind, pattern], the pattern with non-capturing groups only;
// the combined expression wraps every rule in one capture group, so the group
// that matched gives the token kind. Earlier rules win where two could start
// at one place.

// Atomic groups (a possessive *+ is not enough inside an alternation): a
// long literal (an embedded base64 blob) otherwise
// overflows the matcher's backtracking stack, and highlighting ends there.
static NSString *const kDQ = @"\"(?>[^\"\\\\\\n]*)(?>(?:\\\\.(?>[^\"\\\\\\n]*))*)\"";   // "…" on one line, with escapes
static NSString *const kSQ = @"'(?>[^'\\\\\\n]*)(?>(?:\\\\.(?>[^'\\\\\\n]*))*)'";
static NSString *const kBQ = @"`(?>[^`\\\\]*)(?>(?:\\\\.(?>[^`\\\\]*))*)`";
static NSString *const kNumber = @"\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)[uUlLfF]*\\b";
static NSString *const kSlashComments = @"//[^\\n]*|/\\*[\\s\\S]*?(?:\\*/|$(?![\\s\\S]))";
static NSString *const kHashComment = @"#[^\\n]*";

static NSString *wq_words(NSString *words)
{
    NSArray *list = [words componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    list = [list filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    return [NSString stringWithFormat:@"\\b(?:%@)\\b", [list componentsJoinedByString:@"|"]];
}

static NSString *const kCKeywords =
    @"auto break case char const continue default do double else enum extern float for goto if inline int long "
     "register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while "
     "bool true false NULL nullptr class namespace template typename public private protected virtual override "
     "new delete this try catch throw using operator const_cast static_cast dynamic_cast reinterpret_cast "
     "id self super nil Nil YES NO BOOL SEL IMP instancetype nonatomic atomic strong weak copy assign readonly readwrite "
     "nullable nonnull _Nullable _Nonnull __weak __strong __block";
static NSString *const kObjCDirectives = @"@(?:interface|implementation|end|protocol|property|synthesize|dynamic|class|"
     "selector|encode|optional|required|import|autoreleasepool|synchronized|try|catch|finally|throw|available)\\b";
static NSString *const kJSKeywords =
    @"async await break case catch class const continue debugger default delete do else export extends false finally "
     "for function if import in instanceof let new null of return static super switch this throw true try typeof "
     "undefined var void while with yield interface type enum implements readonly private public protected "
     "abstract declare namespace as any number string boolean never unknown";
static NSString *const kSwiftKeywords =
    @"associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private "
     "protocol public rethrows static struct subscript typealias var break case continue default defer do else "
     "fallthrough for guard if in repeat return switch where while as catch false is nil super self Self throw "
     "throws true try async await some any final lazy override mutating weak unowned convenience required";
static NSString *const kJavaKeywords =
    @"abstract assert boolean break byte case catch char class const continue default do double else enum extends "
     "final finally float for goto if implements import instanceof int interface long native new package private "
     "protected public return short static strictfp super switch synchronized this throw throws transient try void "
     "volatile while true false null var val fun object when is in override data sealed companion suspend";
static NSString *const kGoKeywords =
    @"break case chan const continue default defer else fallthrough for func go goto if import interface map "
     "package range return select struct switch type var true false nil iota";
static NSString *const kRustKeywords =
    @"as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move "
     "mut pub ref return self Self static struct super trait true type unsafe use where while";
static NSString *const kPythonKeywords =
    @"and as assert async await break class continue def del elif else except False finally for from global if "
     "import in is lambda None nonlocal not or pass raise return True try while with yield self";
static NSString *const kShellKeywords =
    @"if then else elif fi case esac for select while until do done in function return exit export local readonly "
     "declare unset shift source alias echo printf cd test set eval exec trap break continue true false";
static NSString *const kRubyKeywords =
    @"alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or "
     "redo rescue retry return self super then true undef unless until when while yield require attr_accessor";
static NSString *const kSQLKeywords =
    @"select from where and or not insert into values update set delete create table index view trigger drop alter "
     "add column primary key foreign references unique null default join left right inner outer full cross on as "
     "order by group having limit offset distinct union all exists in is like glob between case when then else end "
     "begin commit rollback transaction pragma integer text real blob numeric asc desc if replace without rowid "
     "autoincrement check constraint collate cast";
static NSString *const kLuaKeywords =
    @"and break do else elseif end false for function goto if in local nil not or repeat return then true until while";

// Rules per language family: @[@[kind, pattern], …] and regex options.
static NSArray *wq_language_rules(NSString *language, NSRegularExpressionOptions *options)
{
    *options = NSRegularExpressionAnchorsMatchLines;
    if ([language isEqualToString:@"xml"]) {
        return @[
            @[@(WQSyntaxComment), @"<!--[\\s\\S]*?(?:-->|$(?![\\s\\S]))"],
            @[@(WQSyntaxString), @"<!\\[CDATA\\[[\\s\\S]*?\\]\\]>"],
            @[@(WQSyntaxPreprocessor), @"<[?!][^>]*>"],
            @[@(WQSyntaxTag), @"</?[A-Za-z_][\\w:.-]*|/?>"],
            @[@(WQSyntaxAttribute), @"\\b[A-Za-z_][\\w:.-]*(?=\\s*=\\s*[\"'])"],
            @[@(WQSyntaxString), @"\"[^\"<]*\"|'[^'<]*'"],
            @[@(WQSyntaxKeyword), @"&#?\\w+;"],
        ];
    }
    if ([language isEqualToString:@"json"]) {
        return @[
            @[@(WQSyntaxComment), kSlashComments],   // JSON5 / JSONC
            @[@(WQSyntaxKey), [kDQ stringByAppendingString:@"(?=\\s*:)"]],
            @[@(WQSyntaxString), kDQ],
            @[@(WQSyntaxKeyword), @"\\b(?:true|false|null)\\b"],
            @[@(WQSyntaxNumber), @"-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"],
        ];
    }
    if ([language isEqualToString:@"css"]) {
        return @[
            @[@(WQSyntaxComment), @"/\\*[\\s\\S]*?(?:\\*/|$(?![\\s\\S]))"],
            @[@(WQSyntaxString), [NSString stringWithFormat:@"%@|%@", kDQ, kSQ]],
            @[@(WQSyntaxPreprocessor), @"@[\\w-]+"],
            // Possessive names and a bounded look-ahead for "{": an unquoted
            // url(data:…) made every name rescan the rest of the blob.
            @[@(WQSyntaxKey), @"(?<![\\w-])-{0,2}[A-Za-z][\\w-]*+(?=\\s*:(?![:\\w]{0,200}\\s*\\{))"],
            @[@(WQSyntaxNumber), @"#[0-9a-fA-F]{3,8}\\b|-?\\b\\d+(?:\\.\\d+)?(?:px|em|rem|%|vh|vw|s|ms|pt|deg)?"],
            @[@(WQSyntaxKeyword), @"!important\\b"],
            // A class or id starts at its "." or "#" wherever that stands
            // ("div.foo", "li#main"); a bare name only at a word start.
            @[@(WQSyntaxTag), @"(?:[.#]|(?<![\\w-]))[A-Za-z_][\\w-]*+(?=[^{};]{0,400}\\{)"],
        ];
    }
    if ([language isEqualToString:@"sql"]) {
        *options |= NSRegularExpressionCaseInsensitive;
        return @[
            @[@(WQSyntaxComment), @"--[^\\n]*|/\\*[\\s\\S]*?(?:\\*/|$(?![\\s\\S]))"],
            @[@(WQSyntaxString), @"'(?:[^']|'')*'"],
            @[@(WQSyntaxKey), @"\"(?:[^\"]|\"\")*\"|`[^`]*`|\\[[^\\]\\n]*\\]"],
            @[@(WQSyntaxKeyword), wq_words(kSQLKeywords)],
            @[@(WQSyntaxNumber), kNumber],
        ];
    }
    if ([language isEqualToString:@"ini"]) {
        return @[
            @[@(WQSyntaxComment), @"^\\s*[#;][^\\n]*"],
            @[@(WQSyntaxTag), @"^\\s*\\[[^\\]\\n]*\\]"],
            @[@(WQSyntaxKey), @"^\\s*[\\w.$-]+(?=\\s*[=:])"],
            @[@(WQSyntaxString), [NSString stringWithFormat:@"%@|%@", kDQ, kSQ]],
            @[@(WQSyntaxKeyword), @"\\b(?:true|false|yes|no|on|off|null)\\b"],
            @[@(WQSyntaxNumber), kNumber],
        ];
    }
    if ([language isEqualToString:@"yaml"]) {
        return @[
            @[@(WQSyntaxComment), @"(?:^|(?<=\\s))#[^\\n]*"],
            @[@(WQSyntaxPreprocessor), @"^(?:---|\\.\\.\\.)\\s*$"],
            @[@(WQSyntaxKey), @"^\\s*(?:-\\s+)?[^\\s#:\\-\"'][^:#\\n]*(?=:(?:\\s|$))"],
            @[@(WQSyntaxString), [NSString stringWithFormat:@"%@|%@", kDQ, kSQ]],
            @[@(WQSyntaxKeyword), @"\\b(?:true|false|yes|no|on|off|null)\\b|~"],
            @[@(WQSyntaxNumber), kNumber],
        ];
    }
    if ([language isEqualToString:@"markdown"]) {
        return @[
            @[@(WQSyntaxString), @"^```[\\s\\S]*?(?:^```|$(?![\\s\\S]))|`[^`\\n]+`"],
            @[@(WQSyntaxKeyword), @"^#{1,6}[^\\n]*"],
            @[@(WQSyntaxTag), @"\\[[^\\]\\n]*\\]\\([^)\\n]*\\)"],
            @[@(WQSyntaxAttribute), @"\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__"],
            @[@(WQSyntaxComment), @"^>[^\\n]*"],
            @[@(WQSyntaxNumber), @"^\\s*(?:[-*+]|\\d+\\.)(?=\\s)"],
        ];
    }
    // Hash-comment languages.
    NSDictionary *hash = @{ @"python": kPythonKeywords, @"shell": kShellKeywords, @"ruby": kRubyKeywords };
    if (hash[language]) {
        NSString *strings = [language isEqualToString:@"python"]
            ? [NSString stringWithFormat:@"(?:[rRbBfFuU]{0,2})(?:\"\"\"[\\s\\S]*?(?:\"\"\"|$(?![\\s\\S]))|'''[\\s\\S]*?(?:'''|$(?![\\s\\S]))|%@|%@)", kDQ, kSQ]
            : [NSString stringWithFormat:@"%@|%@|%@", kDQ, kSQ, kBQ];
        return @[
            @[@(WQSyntaxPreprocessor), @"\\A#![^\\n]*"],
            @[@(WQSyntaxComment), [language isEqualToString:@"shell"] ? @"(?:^|(?<=[\\s;]))#[^\\n]*" : kHashComment],
            @[@(WQSyntaxString), strings],
            @[@(WQSyntaxPreprocessor), [language isEqualToString:@"python"] ? @"^\\s*@[\\w.]+" : @"\\$\\{[^}\\n]*\\}|\\$[\\w@#?$!*-]"],
            @[@(WQSyntaxKeyword), wq_words(hash[language])],
            @[@(WQSyntaxNumber), kNumber],
        ];
    }
    if ([language isEqualToString:@"lua"]) {
        return @[
            @[@(WQSyntaxComment), @"--\\[\\[[\\s\\S]*?(?:\\]\\]|$(?![\\s\\S]))|--[^\\n]*"],
            @[@(WQSyntaxString), [NSString stringWithFormat:@"\\[\\[[\\s\\S]*?\\]\\]|%@|%@", kDQ, kSQ]],
            @[@(WQSyntaxKeyword), wq_words(kLuaKeywords)],
            @[@(WQSyntaxNumber), kNumber],
        ];
    }
    // C-like languages.
    NSDictionary *cLike = @{ @"c": kCKeywords, @"js": kJSKeywords, @"swift": kSwiftKeywords, @"java": kJavaKeywords,
                             @"go": kGoKeywords, @"rust": kRustKeywords };
    if (cLike[language]) {
        BOOL c = [language isEqualToString:@"c"];
        NSString *strings = c ? [NSString stringWithFormat:@"@?%@|%@", kDQ, kSQ]
            : [language isEqualToString:@"swift"] ? [NSString stringWithFormat:@"\"\"\"[\\s\\S]*?(?:\"\"\"|$(?![\\s\\S]))|%@", kDQ]
            : [NSString stringWithFormat:@"%@|%@|%@", kDQ, kSQ, kBQ];
        return @[
            @[@(WQSyntaxComment), kSlashComments],
            @[@(WQSyntaxString), strings],
            @[@(WQSyntaxPreprocessor), c ? [@"^\\s*#\\s*\\w+|" stringByAppendingString:kObjCDirectives]
                                         : @"^\\s*#!\\[?[^\\n]*|@[A-Za-z_]\\w*"],
            @[@(WQSyntaxKeyword), wq_words(cLike[language])],
            @[@(WQSyntaxNumber), kNumber],
        ];
    }
    return nil;
}

NSString *wq_syntax_language(NSString *fileName, NSString *text)
{
    static NSDictionary<NSString *, NSString *> *byExtension;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary new];
        void (^add)(NSString *, NSString *) = ^(NSString *language, NSString *extensions) {
            for (NSString *e in [extensions componentsSeparatedByString:@" "]) map[e] = language;
        };
        add(@"xml", @"xml plist html htm xhtml svg xib storyboard entitlements mobileconfig xsd xsl rss atom");
        add(@"json", @"json jsonc json5 geojson webmanifest har ipynb");
        add(@"css", @"css scss less");
        add(@"sql", @"sql");
        add(@"ini", @"ini cfg conf toml properties env gitconfig editorconfig");
        add(@"yaml", @"yaml yml");
        add(@"markdown", @"md markdown");
        add(@"python", @"py pyw pyi");
        add(@"shell", @"sh bash zsh ksh command profile bashrc zshrc");
        add(@"ruby", @"rb gemspec podspec");
        add(@"lua", @"lua");
        add(@"c", @"c h m mm cc cpp cxx hpp hh hxx metal strings");
        add(@"js", @"js mjs cjs jsx ts tsx");
        add(@"swift", @"swift");
        add(@"java", @"java kt kts gradle groovy scala dart cs");
        add(@"go", @"go");
        add(@"rust", @"rs");
        byExtension = map;
    });
    NSString *ext = fileName.pathExtension.lowercaseString;
    if (!ext.length && [fileName hasPrefix:@"."]) ext = [fileName substringFromIndex:1].lowercaseString;   // .zshrc
    NSString *language = ext.length ? byExtension[ext] : nil;
    if (language) return language;
    if (!text.length) return nil;
    // No known extension: a shebang, or text that looks like XML or JSON.
    NSString *head = [text substringToIndex:MIN(text.length, (NSUInteger)200)];
    NSString *trimmed = [head stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed hasPrefix:@"#!"]) {
        NSString *line = [trimmed componentsSeparatedByString:@"\n"].firstObject;
        if ([line containsString:@"python"]) return @"python";
        if ([line containsString:@"ruby"]) return @"ruby";
        if ([line containsString:@"node"]) return @"js";
        if ([line containsString:@"lua"]) return @"lua";
        return @"shell";
    }
    if ([trimmed hasPrefix:@"<?xml"] || [trimmed hasPrefix:@"<!DOCTYPE"] || [trimmed hasPrefix:@"<plist"]) return @"xml";
    if (([trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["]) && ext.length == 0 &&
        [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]
                                        options:NSJSONReadingFragmentsAllowed error:nil])
        return @"json";
    return nil;
}

NSData *wq_syntax_tokens(NSString *text, NSString *language, BOOL (^cancelled)(void))
{
    if (text.length > kWQSyntaxMaxLength) return nil;
    static NSMutableDictionary<NSString *, id> *cache;
    static NSMutableDictionary<NSString *, NSArray *> *kindsCache;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; kindsCache = [NSMutableDictionary new]; lock = [NSObject new]; });
    NSRegularExpression *regex = nil;
    NSArray<NSNumber *> *kinds = nil;
    @synchronized (lock) {
        id cached = cache[language];
        if (!cached) {
            NSRegularExpressionOptions options = 0;
            NSArray *rules = wq_language_rules(language, &options);
            NSMutableArray *parts = [NSMutableArray new], *ruleKinds = [NSMutableArray new];
            for (NSArray *rule in rules) {
                [parts addObject:[NSString stringWithFormat:@"(%@)", rule[1]]];
                [ruleKinds addObject:rule[0]];
            }
            NSError *error = nil;
            NSRegularExpression *built = rules.count
                ? [NSRegularExpression regularExpressionWithPattern:[parts componentsJoinedByString:@"|"] options:options error:&error]
                : nil;
            if (rules.count && !built) NSLog(@"WQSyntax: %@ pattern failed: %@", language, error);
            cached = built ?: NSNull.null;
            cache[language] = cached;
            if (built) kindsCache[language] = ruleKinds;
        }
        if (cached != NSNull.null) { regex = cached; kinds = kindsCache[language]; }
    }
    if (!regex) return nil;
    NSMutableData *tokens = [NSMutableData new];
    __block BOOL stopped = NO;
    __block NSUInteger checked = 0;
    [regex enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                         usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags __unused flags, BOOL *stop) {
        if (cancelled && ++checked % 512 == 0 && cancelled()) { stopped = YES; *stop = YES; return; }
        if (!match || match.range.length == 0) return;
        for (NSUInteger g = 1; g < match.numberOfRanges && g <= kinds.count; g++) {
            NSRange r = [match rangeAtIndex:g];
            if (r.location == NSNotFound) continue;
            WQSyntaxToken token = { r, (WQSyntaxKind)kinds[g - 1].unsignedCharValue };
            [tokens appendBytes:&token length:sizeof(token)];
            break;
        }
    }];
    return stopped ? nil : tokens;
}
