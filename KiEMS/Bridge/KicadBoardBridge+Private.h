// C++ accessors shared between the bridges' own .mm files. Never imported from the Swift bridging
// header -- see EMSConfigBridge+Private.h.
#import "KicadBoardBridge.h"

#include "submodules/libkicad/libkicad.hpp"

NS_ASSUME_NONNULL_BEGIN

@interface KicadRuntime ()
/// Valid for as long as this KicadRuntime is; hold a strong reference to it for at least as long
/// as any libkicad::Board created from this.
@property (nonatomic, readonly) libkicad::Runtime& cxxRuntime;
@end

@interface KicadBoardBridge ()
@property (nonatomic, readonly) const libkicad::Board& cxxBoard;
@end

NS_ASSUME_NONNULL_END
