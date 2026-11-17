//
//  WQInspector.h
//  WQ Files
//
//  Custom inspectors (#45): small read-only JavaScript programs the user
//  installs in Documents/Inspectors (visible in the Files app). WQ Files
//  ships only the runtime and a generic table; no app-specific scripts.
//
//  One folder per inspector:
//
//    Inspectors/My Inspector/
//      manifest.json   { "name": "My Inspector",        1–80 characters
//                        "api": 1,                       must be 1
//                        "extensions": ["json", "plist"] or ["*"]
//                        "script": "inspect.js",         optional, default
//                        "data": "data.json",            optional
//                        "description": "…" }            optional
//      inspect.js      defines  function inspect(input, data) { … }
//      data.json       optional reference data, passed as `data`
//
//  input = { name, extension, size, truncated,
//            bytes: Uint8Array (at most 8 MB of the file),
//            text:  the bytes as UTF-8, or null,
//            plist: the file parsed as a property list, or null
//                   (dates as ISO 8601 strings, data as base64 strings) }
//
//  inspect returns { title?: "…", sections: [ { title?: "…",
//                    rows?: [ { label: "…", value: … } ], text?: "…" } ] }
//
//  Scripts are run off the main thread with a time limit, with no access to
//  files, the network or the app; console.log lines are shown under the
//  result. Results are checked and capped (sections, rows, text length).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    WQInspectorMaxInputBytes = 8 * 1024 * 1024,
    WQInspectorMaxDataBytes = 4 * 1024 * 1024,
    WQInspectorMaxScriptBytes = 1024 * 1024,
    WQInspectorMaxSections = 100,
    WQInspectorMaxRows = 5000,
    WQInspectorMaxText = 20000,       // characters per label, value or text
    WQInspectorMaxLogLines = 200,
};

@interface WQInspector : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *folder;            // full path
@property (nonatomic, copy) NSString *scriptPath;
@property (nonatomic, copy, nullable) NSString *dataPath;
@property (nonatomic, copy, nullable) NSString *inspectorDescription;
@property (nonatomic, copy) NSArray<NSString *> *extensions;   // lowercase, "*" = any
- (BOOL)matchesFileName:(NSString *)fileName;
@end

@interface WQInspectorRow : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *value;
@end

@interface WQInspectorSection : NSObject
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy) NSArray<WQInspectorRow *> *rows;
@property (nonatomic, copy, nullable) NSString *text;
@end

@interface WQInspectorResult : NSObject
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy) NSArray<WQInspectorSection *> *sections;
@property (nonatomic, copy) NSArray<NSString *> *log;    // console.log lines
@property (nonatomic) BOOL capped;                       // something was cut to the limits
// Everything as plain text, for Share.
- (NSString *)plainText;
@end

// Documents/Inspectors, created when missing.
NSString *wq_inspectors_folder(void);

// The inspectors in `folder` (one subfolder each), sorted by name.
// *problems gets one line per folder that was skipped and why.
NSArray<WQInspector *> *wq_inspectors_in(NSString *folder, NSArray<NSString *> *_Nullable *_Nullable problems);

// Reads one inspector folder; nil with *error when it isn't valid.
WQInspector *_Nullable wq_inspector_load(NSString *folder, NSString *_Nullable *_Nullable error);

// Installs the inspector in the ZIP at `zipPath` into `folder`: manifest.json
// at the top of the archive or inside its one top-level folder. The folder
// is named after the inspector; an installed one with that name is replaced
// (*replaced). nil with *error when the ZIP holds no valid inspector; nothing
// is left behind then.
WQInspector *_Nullable wq_inspector_install_zip(NSString *zipPath, NSString *folder, BOOL *_Nullable replaced,
                                                NSString *_Nullable *_Nullable error);

// Runs `inspector` on `bytes` (already capped by the caller; `truncated`
// says the file is longer). Blocking: call off the main thread. nil with
// *error (script error, time limit, invalid result); *log gets console.log
// lines even then. `timeLimit` in seconds.
WQInspectorResult *_Nullable wq_inspector_run(WQInspector *inspector, NSData *bytes, BOOL truncated,
                                              NSString *fileName, unsigned long long fileSize,
                                              NSTimeInterval timeLimit,
                                              NSArray<NSString *> *_Nullable *_Nullable log,
                                              NSString *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
