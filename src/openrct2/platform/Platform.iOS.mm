/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_IOS
    #include "Platform.h"

    #include "../core/Path.hpp"
    #include "../drawing/Font.h"
    #include "../localisation/Language.h"

    #import <CoreText/CoreText.h>
    #import <Foundation/Foundation.h>

namespace OpenRCT2::Platform
{
    std::string GetFolderPath(SpecialFolder folder)
    {
        NSSearchPathDirectory directory;
        switch (folder)
        {
            case SpecialFolder::userHome:
                return NSHomeDirectory().UTF8String;
            // Config::Save uses userData while startup reads userConfig. Keep them together.
            case SpecialFolder::userData:
            case SpecialFolder::userConfig:
                directory = NSDocumentDirectory;
                break;
            case SpecialFolder::userCache:
                directory = NSCachesDirectory;
                break;
            default:
                return {};
        }
        return NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES).firstObject.UTF8String;
    }
    std::string GetInstallPath()
    {
        return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"data"].UTF8String;
    }
    std::string GetDocsPath()
    {
        return GetInstallPath();
    }
    std::string GetCurrentExecutablePath()
    {
        return NSBundle.mainBundle.executablePath.UTF8String;
    }
    u8string StrDecompToPrecomp(u8string_view input)
    {
        return [NSString stringWithUTF8String:std::string(input).c_str()].precomposedStringWithCanonicalMapping.UTF8String;
    }
    bool HandleSpecialCommandLineArgument(const char*)
    {
        return false;
    }
    uint16_t GetLocaleLanguage()
    {
        return LANGUAGE_ENGLISH_UK;
    }
    CurrencyType GetLocaleCurrency()
    {
        return GetCurrencyValue(NSLocale.currentLocale.currencyCode.UTF8String);
    }
    MeasurementFormat GetLocaleMeasurementFormat()
    {
        return MeasurementFormat::metric;
    }
    SteamPaths GetSteamPaths()
    {
        return {};
    }
    std::vector<std::string> GetSearchablePathsRCT1()
    {
        return {};
    }
    std::vector<std::string> GetSearchablePathsRCT2()
    {
        return { Path::Combine(GetFolderPath(SpecialFolder::userData), "RCT2") };
    }
    std::string GetFontPath(const TTFFontDescriptor& font)
    {
        auto bundled = Path::Combine(GetInstallPath(), "fonts", font.filename);
        if ([NSFileManager.defaultManager isReadableFileAtPath:[NSString stringWithUTF8String:bundled.c_str()]])
        {
            fprintf(stderr, "iPad font: %s (%d pt), bundled font loaded\n", font.font_name, font.ptSize);
            return bundled;
        }
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithNameAndSize(
            static_cast<CFStringRef>([NSString stringWithUTF8String:font.font_name]), 0);
        auto url = static_cast<CFURLRef>(CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute));
        std::string result = url ? [static_cast<NSURL*>(CFBridgingRelease(url)) path].UTF8String : "";
        CFRelease(descriptor);
        return result;
    }
} // namespace OpenRCT2::Platform
#endif
