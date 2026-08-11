// Internal accessor shared only between this bridge's own .mm implementation files (e.g.
// KicadBoardBridge.mm, which needs to hand a live gerber2ems::EMSConfig& to importStackup()).
// Never imported from the Swift bridging header -- it's the one place a C++ reference type
// crosses an Objective-C interface boundary, which Swift can't see at all.
#import "EMSConfigBridge.h"

#include "gerber2ems/config.hpp"

NS_ASSUME_NONNULL_BEGIN

@interface EMSConfigBridge (Private)
- (gerber2ems::EMSConfig&)cxxConfig;
@end

NS_ASSUME_NONNULL_END
