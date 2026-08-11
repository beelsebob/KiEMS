// Objective-C interface over libkicad_query's net/footprint listing queries and stackup import.
// Swift-visible; never exposes a C++ type.
#import <Foundation/Foundation.h>

#import "EMSConfigBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface KicadFootprintPin : NSObject
@property (nonatomic, copy, readonly) NSString* number;
/// Empty if the pad has no assigned schematic pin function.
@property (nonatomic, copy, readonly) NSString* function;
/// Empty if the pad isn't connected to any net.
@property (nonatomic, copy, readonly) NSString* netName;
@end

@interface KicadFootprintInfo : NSObject
@property (nonatomic, copy, readonly) NSString* reference;
/// KiCad's "Value" field text (e.g. "100nF", "10k") -- empty if unset.
@property (nonatomic, copy, readonly) NSString* value;
@property (nonatomic, copy, readonly) NSArray<KicadFootprintPin*>* pins;
@end

/// Board-browsing operations, queried directly against wherever the user's KiCad project actually
/// lives -- never against a copy (see EMSConfigBridge's kicadPcbPath doc comment). Every method
/// here derives the sibling .kicad_pro path from `kicadPcbPath` the same way KiCad itself does
/// (same directory, same base name). `helperPath` is the libkicad_smoketest-based query helper
/// binary this app bundles -- see AppPaths.swift.
@interface KicadBoardBridge : NSObject

+ (nullable NSArray<NSString*>*)netClassesForBoard:(NSString*)kicadPcbPath
                                kicadQueryHelperPath:(NSString*)helperPath
                                               error:(NSError**)error;

+ (nullable NSArray<NSString*>*)allNetsForBoard:(NSString*)kicadPcbPath
                            kicadQueryHelperPath:(NSString*)helperPath
                                           error:(NSError**)error;

+ (nullable NSArray<NSString*>*)netsInNetClassForBoard:(NSString*)kicadPcbPath
                                                netClass:(NSString*)netClass
                                    kicadQueryHelperPath:(NSString*)helperPath
                                                   error:(NSError**)error;

+ (nullable NSArray<KicadFootprintInfo*>*)footprintsForBoard:(NSString*)kicadPcbPath
                                          kicadQueryHelperPath:(NSString*)helperPath
                                                         error:(NSError**)error;

/// Stores `kicadPcbPath` on `config` (EMSConfigBridge.kicadPcbPath) and imports the board's
/// stackup into it. Purely a read-only query against the board plus an in-memory config edit --
/// touches no filesystem location other than `kicadPcbPath`/its sibling .kicad_pro, so it works
/// equally well on a document that's never been saved.
+ (BOOL)linkKicadPCB:(NSString*)kicadPcbPath
               config:(EMSConfigBridge*)config
 kicadQueryHelperPath:(NSString*)helperPath
                error:(NSError**)error;

@end

NS_ASSUME_NONNULL_END
