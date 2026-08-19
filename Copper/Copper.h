//
//  Copper.h
//  Copper
//
//  Created by Thomas Davie on 8/14/26.
//

#import <Foundation/Foundation.h>

//! Project version number for Copper.
FOUNDATION_EXPORT double CopperVersionNumber;

//! Project version string for Copper.
FOUNDATION_EXPORT const unsigned char CopperVersionString[];

// In this header, you should import all the public headers of your framework using statements like #import <Copper/PublicHeader.h>
//
// CopperFDTDRunner.h is deliberately NOT imported here -- it isn't marked as a framework Public
// header (see its own file comment: it must stay includable via a plain relative header search
// path, like every other Copper/ source file, from a translation unit that already has the
// *installed* openEMS/CSXCAD headers in scope, which importing it through this Objective-C
// umbrella wouldn't preserve). Include "CopperFDTDRunner.h" directly instead.
