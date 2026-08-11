#import "KicadBoardBridge.h"
#import "EMSConfigBridge+Private.h"

#include "gerber2ems/importer.hpp"
#include "gerber2ems/libkicad_query.hpp"
#include "gerber2ems/paths_config.hpp"

using gerber2ems::PathsConfig;

namespace {

NSError* makeError(const std::string& message) {
    return [NSError errorWithDomain:EMSConfigErrorDomain
                                code:1
                            userInfo:@{NSLocalizedDescriptionKey : @(message.c_str())}];
}

// Every field libkicad_query/importStackup actually reads is set explicitly here; every other
// PathsConfig field (configFile, fabDir, geometryDir, ...) is left default-constructed (empty) --
// none of them are touched by the functions this bridge calls. This is exactly the "populate a
// PathsConfig by hand" escape hatch paths_config.hpp's own doc comment describes: querying
// wherever the user's board actually lives, not a fab/-directory copy of it.
PathsConfig pathsForBoard(NSString* kicadPcbPath, NSString* helperPath) {
    PathsConfig paths;
    paths.fabBoardFile = std::filesystem::path(kicadPcbPath.UTF8String);
    paths.fabProjectFile = paths.fabBoardFile;
    paths.fabProjectFile.replace_extension(".kicad_pro");
    paths.kicadQueryHelperPath = std::filesystem::path(helperPath.UTF8String);
    return paths;
}

NSArray<NSString*>* toNSStringArray(const std::vector<std::string>& values) {
    NSMutableArray<NSString*>* result = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto& value : values) {
        [result addObject:@(value.c_str())];
    }
    return result;
}

} // namespace

@implementation KicadFootprintPin
- (instancetype)initWithNumber:(NSString*)number function:(NSString*)function netName:(NSString*)netName {
    self = [super init];
    if (self) {
        _number = [number copy];
        _function = [function copy];
        _netName = [netName copy];
    }
    return self;
}
@end

@implementation KicadFootprintInfo
- (instancetype)initWithReference:(NSString*)reference
                             value:(NSString*)value
                              pins:(NSArray<KicadFootprintPin*>*)pins {
    self = [super init];
    if (self) {
        _reference = [reference copy];
        _value = [value copy];
        _pins = [pins copy];
    }
    return self;
}
@end

@implementation KicadBoardBridge

+ (nullable NSArray<NSString*>*)netClassesForBoard:(NSString*)kicadPcbPath
                                kicadQueryHelperPath:(NSString*)helperPath
                                               error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath, helperPath);
    auto result = gerber2ems::libkicad_query::netClasses(paths, "Listing net classes");
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return toNSStringArray(*result);
}

+ (nullable NSArray<NSString*>*)allNetsForBoard:(NSString*)kicadPcbPath
                            kicadQueryHelperPath:(NSString*)helperPath
                                           error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath, helperPath);
    auto result = gerber2ems::libkicad_query::allNets(paths, "Listing nets");
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return toNSStringArray(*result);
}

+ (nullable NSArray<NSString*>*)netsInNetClassForBoard:(NSString*)kicadPcbPath
                                                netClass:(NSString*)netClass
                                    kicadQueryHelperPath:(NSString*)helperPath
                                                   error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath, helperPath);
    auto result = gerber2ems::libkicad_query::netsInNetClass(paths, netClass.UTF8String, "Listing nets in net class");
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return toNSStringArray(*result);
}

+ (nullable NSArray<KicadFootprintInfo*>*)footprintsForBoard:(NSString*)kicadPcbPath
                                          kicadQueryHelperPath:(NSString*)helperPath
                                                         error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath, helperPath);
    auto result = gerber2ems::libkicad_query::footprints(paths, "Listing footprints");
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    NSMutableArray<KicadFootprintInfo*>* footprints = [NSMutableArray arrayWithCapacity:result->size()];
    for (const auto& footprint : *result) {
        NSMutableArray<KicadFootprintPin*>* pins = [NSMutableArray arrayWithCapacity:footprint.pins.size()];
        for (const auto& pin : footprint.pins) {
            [pins addObject:[[KicadFootprintPin alloc] initWithNumber:@(pin.number.c_str())
                                                               function:@(pin.function.c_str())
                                                                netName:@(pin.netName.c_str())]];
        }
        [footprints addObject:[[KicadFootprintInfo alloc] initWithReference:@(footprint.reference.c_str())
                                                                          value:@(footprint.value.c_str())
                                                                           pins:pins]];
    }
    return footprints;
}

+ (BOOL)linkKicadPCB:(NSString*)kicadPcbPath
               config:(EMSConfigBridge*)config
 kicadQueryHelperPath:(NSString*)helperPath
                error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath, helperPath);
    if (auto result = gerber2ems::importStackup(paths, config.cxxConfig); !result) {
        if (error != nil) *error = makeError(result.error());
        return NO;
    }
    config.kicadPcbPath = kicadPcbPath;
    return YES;
}

@end
