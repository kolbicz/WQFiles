//
//  WQCore.h
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Defines `static id name(void)`: a lock object of its own for one piece of
// state, for @synchronized. Never lock a shared object (NSNull.null, a
// framework class): unrelated code that does the same would then contend
// with, or deadlock against, this state.
#define WQ_DEFINE_LOCK(name) \
    static id name(void) { \
        static id lock; \
        static dispatch_once_t once; \
        dispatch_once(&once, ^{ lock = [NSObject new]; }); \
        return lock; \
    }

// Main-thread edit state shared by all three editors. A successful completion
// clears dirty only when no newer revision was made after beginSave.
@interface WQEditState : NSObject
@property (nonatomic, readonly) NSUInteger revision;
@property (nonatomic, readonly, getter=isDirty) BOOL dirty;
@property (nonatomic, readonly, getter=isSaving) BOOL saving;
- (void)noteChange;
- (NSUInteger)beginSave;
- (void)finishSave:(BOOL)success revision:(NSUInteger)savedRevision;
- (void)discard;
@end

// Parses pairs of ASCII hex digits separated by whitespace. Property-list data
// may also contain angle brackets; the hex editor does not accept them.
NSData *_Nullable WQParseHex(NSString *text, BOOL allowAngleBrackets);

// Hex editor input for exactly `count` bytes (no angle brackets). Text longer
// than WQHexExactInputCharacterLimit(count) is rejected before it is scanned,
// and parsing stops at the first byte past `count`, so the result never holds
// more than `count` bytes. nil for invalid, too short or too long input.
NSUInteger WQHexExactInputCharacterLimit(NSUInteger count);
NSData *_Nullable WQParseHexExactly(NSString *text, NSUInteger count);

// Overflow-safe validation for an in-place patch range.
BOOL WQPatchRangeValid(unsigned long long offset, NSUInteger length, unsigned long long fileSize);

// Documents and Library are always represented. YES means copy from the
// backup; NO means deliberately purge the current part during restore.
NSDictionary<NSString *, NSNumber *> *WQRestorePlan(BOOL hasDocuments, BOOL hasLibrary);

NS_ASSUME_NONNULL_END
