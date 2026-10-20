/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_IOS
    #include <openrct2/platform/Platform.h>

    #include <openrct2/core/Path.hpp>
    #include <openrct2/drawing/Font.h>
    #include <openrct2/localisation/Language.h>

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
    // The game's first language is the launcher's, which iOS picks from the app's localizations by the
    // user's language settings; English when none of them matches.
    uint16_t GetLocaleLanguage()
    {
        NSString* launcher = NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en";
        NSString* region = NSLocale.currentLocale.countryCode ?: @"";
        std::string locale;
        if ([launcher isEqualToString:@"zh-Hans"])
            locale = "zh-CN";
        else if ([launcher isEqualToString:@"zh-Hant"])
            locale = "zh-TW";
        else if ([launcher isEqualToString:@"en"])
            locale = [region isEqualToString:@"US"] ? "en-US" : "en-GB";
        else if ([launcher isEqualToString:@"fr"])
            locale = [region isEqualToString:@"CA"] ? "fr-CA" : "fr-FR";
        else
            locale = [launcher componentsSeparatedByString:@"-"].firstObject.UTF8String;
        for (uint16_t i = 1; i < LANGUAGE_COUNT; i++)
        {
            std::string_view candidate = LanguagesDescriptors[i].locale;
            if (candidate == locale || (locale.size() == 2 && candidate.substr(0, 3) == locale + "-"))
                return i;
        }
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
    // The launcher imports original game data here, out of sight of the Files app.
    static std::string GameDataPath(const char* slot)
    {
        NSString* support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        return Path::Combine(support.UTF8String, "GameData", slot);
    }
    std::vector<std::string> GetSearchablePathsRCT1()
    {
        return { GameDataPath("rct1") };
    }
    std::vector<std::string> GetSearchablePathsRCT2()
    {
        return { GameDataPath("rct2") };
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
