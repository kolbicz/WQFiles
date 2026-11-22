//
//  WQSyntaxTests.m
//  Tokenizer checks for the text viewer's syntax highlighting.
//

#import <Foundation/Foundation.h>
#import "WQSyntax.h"

static int failures;
#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond); failures++; } } while (0)

// The kind of the token covering text[at], or 0.
static WQSyntaxKind KindAt(NSString *text, NSString *language, NSString *needle)
{
    NSData *data = wq_syntax_tokens(text, language, nil);
    NSRange where = [text rangeOfString:needle];
    if (!data || where.location == NSNotFound) return 0;
    const WQSyntaxToken *t = data.bytes;
    for (NSUInteger i = 0; i < data.length / sizeof(WQSyntaxToken); i++)
        if (NSLocationInRange(where.location, t[i].range) && NSMaxRange(where) <= NSMaxRange(t[i].range)) return t[i].kind;
    return 0;
}

static void TestLanguages(void)
{
    CHECK([wq_syntax_language(@"Info.plist", nil) isEqualToString:@"xml"]);
    CHECK([wq_syntax_language(@"a.JSON", nil) isEqualToString:@"json"]);
    CHECK([wq_syntax_language(@"main.m", nil) isEqualToString:@"c"]);
    CHECK([wq_syntax_language(@".zshrc", nil) isEqualToString:@"shell"]);
    CHECK([wq_syntax_language(@"run", @"#!/usr/bin/env python3\nprint(1)") isEqualToString:@"python"]);
    CHECK([wq_syntax_language(@"run", @"#!/bin/sh\necho hi") isEqualToString:@"shell"]);
    CHECK([wq_syntax_language(@"data", @"  {\"a\": 1}") isEqualToString:@"json"]);
    CHECK([wq_syntax_language(@"data", @"<?xml version=\"1.0\"?><a/>") isEqualToString:@"xml"]);
    CHECK(wq_syntax_language(@"notes.txt", @"hello") == nil);
    CHECK(wq_syntax_language(@"data", @"{ not json") == nil);
}

static void TestTokens(void)
{
    // Every language's expression compiles.
    for (NSString *l in @[@"xml", @"json", @"css", @"sql", @"ini", @"yaml", @"markdown", @"python", @"shell", @"ruby",
                          @"lua", @"c", @"js", @"swift", @"java", @"go", @"rust"])
        CHECK(wq_syntax_tokens(@"x = 1 // y\n", l, nil) != nil);
    CHECK(wq_syntax_tokens(@"x", @"nope", nil) == nil);

    NSString *c = @"#import <Foundation/Foundation.h>\n// note\nNSString *s = @\"http://x // not a comment\";\n"
                   "/* block\n comment */ int n = 0x1F; return YES;";
    CHECK(KindAt(c, @"c", @"#import") == WQSyntaxPreprocessor);
    CHECK(KindAt(c, @"c", @"// note") == WQSyntaxComment);
    CHECK(KindAt(c, @"c", @"// not a comment") == WQSyntaxString);   // inside the string
    CHECK(KindAt(c, @"c", @" comment */") == WQSyntaxComment);
    CHECK(KindAt(c, @"c", @"0x1F") == WQSyntaxNumber);
    CHECK(KindAt(c, @"c", @"return") == WQSyntaxKeyword);
    CHECK(KindAt(c, @"c", @"YES") == WQSyntaxKeyword);
    CHECK(KindAt(@"/* never closed", @"c", @"never") == WQSyntaxComment);

    NSString *json = @"{\"name\": \"value: x\", \"n\": -1.5e3, \"ok\": true, \"none\": null}";
    CHECK(KindAt(json, @"json", @"\"name\"") == WQSyntaxKey);
    CHECK(KindAt(json, @"json", @"\"value: x\"") == WQSyntaxString);
    CHECK(KindAt(json, @"json", @"1.5e3") == WQSyntaxNumber);
    CHECK(KindAt(json, @"json", @"true") == WQSyntaxKeyword);

    NSString *xml = @"<?xml version=\"1.0\"?>\n<!-- c -->\n<dict a=\"1\">\n<key>Name</key><string>a &amp; b</string>\n</dict>";
    CHECK(KindAt(xml, @"xml", @"<?xml") == WQSyntaxPreprocessor);
    CHECK(KindAt(xml, @"xml", @"<!-- c -->") == WQSyntaxComment);
    CHECK(KindAt(xml, @"xml", @"<dict") == WQSyntaxTag);
    CHECK(KindAt(xml, @"xml", @"a=") == WQSyntaxAttribute || KindAt(xml, @"xml", @"a") == WQSyntaxAttribute);
    CHECK(KindAt(xml, @"xml", @"\"1\"") == WQSyntaxString);
    CHECK(KindAt(xml, @"xml", @"&amp;") == WQSyntaxKeyword);
    CHECK(KindAt(xml, @"xml", @"Name") == 0);   // text content stays plain

    NSString *py = @"#!/usr/bin/env python3\n# hi\ndef f(x):\n    return \"a # b\" if x else '''doc\nmore'''\n";
    CHECK(KindAt(py, @"python", @"#!/usr") == WQSyntaxPreprocessor);
    CHECK(KindAt(py, @"python", @"# hi") == WQSyntaxComment);
    CHECK(KindAt(py, @"python", @"def") == WQSyntaxKeyword);
    CHECK(KindAt(py, @"python", @"a # b") == WQSyntaxString);
    CHECK(KindAt(py, @"python", @"more") == WQSyntaxString);

    NSString *sh = @"echo \"$HOME\" # comment\nURL=http://a#b\n";
    CHECK(KindAt(sh, @"shell", @"# comment") == WQSyntaxComment);
    CHECK(KindAt(sh, @"shell", @"#b") == 0);   // not a comment inside a word

    NSString *sql = @"SELECT name FROM t WHERE a = 'it''s' -- c\n";
    CHECK(KindAt(sql, @"sql", @"SELECT") == WQSyntaxKeyword);
    CHECK(KindAt(sql, @"sql", @"'it''s'") == WQSyntaxString);
    CHECK(KindAt(sql, @"sql", @"-- c") == WQSyntaxComment);

    NSString *css = @"body .x { color: #fff; margin: 4px !important; }";
    CHECK(KindAt(css, @"css", @"color") == WQSyntaxKey);
    CHECK(KindAt(css, @"css", @"#fff") == WQSyntaxNumber);
    CHECK(KindAt(css, @"css", @"body") == WQSyntaxTag);
    CHECK(KindAt(css, @"css", @".x") == WQSyntaxTag);
    // Long literals and blobs: linear time, and the text after them is still colored.
    NSMutableString *blob = [NSMutableString new];
    while (blob.length < 300000) [blob appendString:@"iVBORw0KGgo/AAAANSUhEUgAA+abcDEF0123456789"];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSString *bigCSS = [NSString stringWithFormat:@"a { background: url(data:image/png;base64,%@); }\nh1 { color: #fff; }", blob];
    CHECK(KindAt(bigCSS, @"css", @"#fff") == WQSyntaxNumber);
    CHECK(KindAt(bigCSS, @"css", @"h1") == WQSyntaxTag);
    NSString *bigJSON = [NSString stringWithFormat:@"{\"blob\": \"%@\", \"n\": true}", blob];
    CHECK(KindAt(bigJSON, @"json", @"true") == WQSyntaxKeyword);
    NSString *bigC = [NSString stringWithFormat:@"char *s = \"%@\"; // tail", blob];
    CHECK(KindAt(bigC, @"c", @"// tail") == WQSyntaxComment);
    CHECK(CFAbsoluteTimeGetCurrent() - t0 < 5.0);

    NSString *yaml = @"name: app # c\nlist:\n  - enabled: true\n";
    CHECK(KindAt(yaml, @"yaml", @"name") == WQSyntaxKey);
    CHECK(KindAt(yaml, @"yaml", @"# c") == WQSyntaxComment);
    CHECK(KindAt(yaml, @"yaml", @"true") == WQSyntaxKeyword);

    // Limits and cancellation.
    NSString *big = [@"" stringByPaddingToLength:kWQSyntaxMaxLength + 1 withString:@"a" startingAtIndex:0];
    CHECK(wq_syntax_tokens(big, @"c", nil) == nil);
    NSMutableString *many = [NSMutableString new];
    for (int i = 0; i < 5000; i++) [many appendString:@"int x = 1;\n"];
    CHECK(wq_syntax_tokens(many, @"c", ^BOOL { return YES; }) == nil);
    NSDate *start = NSDate.date;
    CHECK(wq_syntax_tokens(many, @"c", nil).length > 0);
    CHECK(-start.timeIntervalSinceNow < 2.0);
}

int main(void)
{
    @autoreleasepool {
        TestLanguages();
        TestTokens();
        if (failures) { fprintf(stderr, "%d syntax check(s) failed\n", failures); return 1; }
        puts("All syntax highlighting tests passed.");
    }
    return 0;
}
