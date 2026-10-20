/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Matches OpenRCT2::RCT2Variant; ORCTRCT2VariantNone when the folder holds no RCT2 data.
typedef NS_ENUM(NSInteger, ORCTRCT2Variant) {
    ORCTRCT2VariantNone = -1,
    ORCTRCT2VariantOriginal = 0,
    ORCTRCT2VariantClassicWindows = 1,
    ORCTRCT2VariantClassicMac = 2,
    ORCTRCT2VariantClassicPlusMac = 3,
};

// The engine's own data checks, for the launcher that runs before the engine starts.
@interface ORCTLauncherBridge : NSObject
+ (ORCTRCT2Variant)classifyRCT2AtPath:(NSString*)path;
// CSG1.DAT is present, whether or not it is the Loopy Landscapes version the engine can use.
+ (BOOL)rct1PresentAtPath:(NSString*)path;
+ (BOOL)rct1UsableAtPath:(NSString*)path;
// Extracts a ZIP archive into an empty directory, rejecting entries that would escape it.
+ (BOOL)extractZipAtPath:(NSString*)archive
             toDirectory:(NSString*)directory
                progress:(void (^)(double fraction))progress
               cancelled:(BOOL (^)(void))cancelled
                   error:(NSError**)error;
@end

NS_ASSUME_NONNULL_END
