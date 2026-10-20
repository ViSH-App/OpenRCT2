/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_IOS
    #import "LauncherBridge.h"

    #include "InnoExtractor.h"

    #include <openrct2/platform/Platform.h>
    #include <openrct2/rct1/Csg.h>
    #include <zip.h>

    #include <set>
    #include <string>
    #include <vector>

namespace
{
    NSError* ImportError(NSString* message)
    {
        return [NSError errorWithDomain:@"OpenRCT2.Launcher" code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
    }

    // Archive names use '/' separators; reject absolute paths and any '..' component.
    bool SafeRelativePath(const std::string& name)
    {
        if (name.empty() || name.front() == '/' || name.find('\\') != std::string::npos)
            return false;
        size_t start = 0;
        while (start <= name.size())
        {
            auto end = name.find('/', start);
            if (end == std::string::npos)
                end = name.size();
            if (name.compare(start, end - start, "..") == 0 && end - start == 2)
                return false;
            start = end + 1;
        }
        return true;
    }
} // namespace

@implementation ORCTLauncherBridge

+ (ORCTRCT2Variant)classifyRCT2AtPath:(NSString*)path
{
    auto variant = OpenRCT2::Platform::classifyGamePath(path.UTF8String);
    return variant ? static_cast<ORCTRCT2Variant>(*variant) : ORCTRCT2VariantNone;
}

+ (BOOL)rct1PresentAtPath:(NSString*)path
{
    return OpenRCT2::Csg1datPresentAtLocation(path.UTF8String);
}

+ (BOOL)rct1UsableAtPath:(NSString*)path
{
    return OpenRCT2::RCT1DataPresentAtLocation(path.UTF8String);
}

+ (BOOL)extractZipAtPath:(NSString*)archive
             toDirectory:(NSString*)directory
                progress:(void (^)(double))progress
               cancelled:(BOOL (^)(void))cancelled
                   error:(NSError**)error
{
    int code = 0;
    zip_t* zip = zip_open(archive.fileSystemRepresentation, ZIP_RDONLY, &code);
    if (!zip)
    {
        if (error)
            *error = ImportError(@"无法打开这个 ZIP 文件，它可能已损坏。");
        return NO;
    }
    auto count = zip_get_num_entries(zip, 0);
    zip_uint64_t total = 0, done = 0;
    for (zip_int64_t i = 0; i < count; i++)
    {
        zip_stat_t stat;
        if (zip_stat_index(zip, i, 0, &stat) == 0 && (stat.valid & ZIP_STAT_SIZE))
            total += stat.size;
    }

    NSFileManager* files = NSFileManager.defaultManager;
    std::vector<char> buffer(1 << 20);
    BOOL ok = YES;
    for (zip_int64_t i = 0; i < count && ok; i++)
    {
        const char* rawName = zip_get_name(zip, i, ZIP_FL_ENC_GUESS);
        std::string name = rawName ? rawName : "";
        if (name.empty() || name.rfind("__MACOSX/", 0) == 0)
            continue;
        if (!SafeRelativePath(name))
        {
            if (error)
                *error = ImportError(@"ZIP 里有不安全的文件路径，已停止导入。");
            ok = NO;
            break;
        }
        zip_uint8_t opsys;
        zip_uint32_t attributes;
        // Symbolic links could point outside the workspace; RCT2 data never needs them.
        if (zip_file_get_external_attributes(zip, i, 0, &opsys, &attributes) == 0 && opsys == ZIP_OPSYS_UNIX
            && ((attributes >> 16) & 0170000) == 0120000)
            continue;

        NSString* target = [directory stringByAppendingPathComponent:@(name.c_str())];
        if (name.back() == '/')
        {
            [files createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        [files createDirectoryAtPath:target.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
        zip_file_t* entry = zip_fopen_index(zip, i, 0);
        FILE* out = entry ? fopen(target.fileSystemRepresentation, "wb") : nullptr;
        if (!out)
        {
            if (entry)
                zip_fclose(entry);
            if (error)
                *error = ImportError(@"解压时无法读取或写入文件，可能是存储空间不足。");
            ok = NO;
            break;
        }
        zip_int64_t read;
        while ((read = zip_fread(entry, buffer.data(), buffer.size())) > 0)
        {
            if (fwrite(buffer.data(), 1, static_cast<size_t>(read), out) != static_cast<size_t>(read))
            {
                read = -1;
                break;
            }
            done += static_cast<zip_uint64_t>(read);
            if (total > 0)
                progress(static_cast<double>(done) / static_cast<double>(total));
            if (cancelled())
            {
                read = -2;
                break;
            }
        }
        fclose(out);
        zip_fclose(entry);
        if (read < 0)
        {
            if (error)
                *error = read == -2 ? ImportError(@"已取消导入。") : ImportError(@"解压失败，可能是存储空间不足或文件已损坏。");
            ok = NO;
        }
    }
    zip_close(zip);
    return ok;
}

+ (BOOL)extractGogInstallerAtPath:(NSString*)installer
                  sliceCandidates:(NSArray<NSString*>*)candidates
                      toDirectory:(NSString*)directory
                          folders:(NSArray<NSString*>*)folders
                         progress:(void (^)(double))progress
                        cancelled:(BOOL (^)(void))cancelled
                            error:(NSError**)error
{
    namespace Inno = OpenRCT2::Inno;
    std::set<std::string> wanted;
    for (NSString* folder in folders)
        wanted.insert(folder.lowercaseString.UTF8String);

    Inno::ExtractOptions options;
    options.Installer = installer.fileSystemRepresentation;
    for (NSString* candidate in candidates)
        options.SliceCandidates.emplace_back(candidate.fileSystemRepresentation);
    options.Destination = directory.fileSystemRepresentation;
    options.Wanted = [&wanted](const std::string& path) {
        NSString* lower = @(path.c_str()).lowercaseString;
        NSRange slash = [lower rangeOfString:@"/"];
        if (slash.location != NSNotFound)
            return wanted.count([lower substringToIndex:slash.location].UTF8String) > 0;
        return [lower hasPrefix:@"goggame-"] && [lower hasSuffix:@".info"];
    };
    options.Progress = [progress](double fraction) { progress(fraction); };
    options.Cancelled = [cancelled]() { return static_cast<bool>(cancelled()); };
    try
    {
        Inno::Extract(options);
        return YES;
    }
    catch (const Inno::Error& failure)
    {
        if (error)
            *error = ImportError(@(failure.what()));
    }
    catch (const Inno::Cancelled&)
    {
        if (error)
            *error = ImportError(@"已取消导入。");
    }
    catch (const std::exception&)
    {
        if (error)
            *error = ImportError(@"解压安装包失败，可能是存储空间不足或文件已损坏。");
    }
    return NO;
}

@end
#endif
