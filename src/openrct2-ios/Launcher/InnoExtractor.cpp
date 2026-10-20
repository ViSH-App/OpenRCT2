/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#include "InnoExtractor.h"

#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <lzma-sdk/Lzma2Dec.h>
#include <lzma-sdk/LzmaDec.h>
#include <map>
#include <memory>
#include <optional>
#include <tuple>
#include <zlib.h>

namespace fs = std::filesystem;

namespace OpenRCT2::Inno
{
    namespace
    {
        constexpr uint32_t MakeVersion(uint32_t a, uint32_t b, uint32_t c, uint32_t d = 0)
        {
            return (a << 24) | (b << 16) | (c << 8) | d;
        }

        constexpr uint32_t kOldestSupported = MakeVersion(5, 5, 0);
        constexpr uint32_t kFirstUnsupported = MakeVersion(6, 5, 0);

        struct Version
        {
            uint32_t Value = 0;
            bool Unicode = false;
            bool operator>=(uint32_t other) const
            {
                return Value >= other;
            }
            bool operator<(uint32_t other) const
            {
                return Value < other;
            }
        };

        enum class Compression : uint8_t
        {
            Stored,
            Zlib,
            BZip2,
            LZMA1,
            LZMA2,
        };

        void* LzmaAlloc(ISzAllocPtr, size_t size)
        {
            return std::malloc(size);
        }
        void LzmaFree(ISzAllocPtr, void* address)
        {
            std::free(address);
        }
        const ISzAlloc g_Alloc = { LzmaAlloc, LzmaFree };

        std::string Lower(std::string text)
        {
            std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return std::tolower(c); });
            return text;
        }

        // MARK: Reading

        // Bounds-checked little-endian reads from a decompressed header block.
        class Cursor
        {
        public:
            explicit Cursor(const std::vector<uint8_t>& data)
                : _data(data)
            {
            }

            template<typename T>
            T Load()
            {
                T value{};
                std::memcpy(&value, Take(sizeof(T)), sizeof(T));
                return value;
            }
            uint8_t U8()
            {
                return Load<uint8_t>();
            }
            uint32_t U32()
            {
                return Load<uint32_t>();
            }
            uint64_t U64()
            {
                return Load<uint64_t>();
            }
            void Skip(size_t count)
            {
                Take(count);
            }
            std::string Bytes(size_t count)
            {
                auto start = Take(count);
                return std::string(reinterpret_cast<const char*>(start), count);
            }
            // Strings are a 32-bit byte length followed by UTF-16LE or ANSI text.
            std::string String()
            {
                return Bytes(U32());
            }
            void SkipStrings(int count)
            {
                for (int i = 0; i < count; i++)
                    String();
            }
            bool AtEnd() const
            {
                return _position == _data.size();
            }

        private:
            const uint8_t* Take(size_t count)
            {
                if (count > _data.size() - _position)
                    throw std::out_of_range("header");
                auto start = _data.data() + _position;
                _position += count;
                return start;
            }

            const std::vector<uint8_t>& _data;
            size_t _position = 0;
        };

        // Flag sets are stored as bytes, with a three-byte set padded to four.
        void SkipFlags(Cursor& cursor, int count)
        {
            int bytes = (count + 7) / 8;
            cursor.Skip(bytes == 3 ? 4 : bytes);
        }

        bool FlagSet(const std::string& flags, int index)
        {
            return (static_cast<uint8_t>(flags[index / 8]) >> (index % 8)) & 1;
        }

        std::string ReadFlags(Cursor& cursor, int count)
        {
            int bytes = (count + 7) / 8;
            auto flags = cursor.Bytes(bytes);
            if (bytes == 3)
                cursor.Skip(1);
            return flags;
        }

        std::string ToUtf8(const std::string& raw, bool unicode)
        {
            std::string result;
            auto append = [&result](uint32_t c) {
                if (c < 0x80)
                    result += char(c);
                else if (c < 0x800)
                    result += char(0xC0 | (c >> 6)), result += char(0x80 | (c & 0x3F));
                else if (c < 0x10000)
                    result += char(0xE0 | (c >> 12)), result += char(0x80 | ((c >> 6) & 0x3F)), result += char(0x80 | (c & 0x3F));
                else
                    result += char(0xF0 | (c >> 18)), result += char(0x80 | ((c >> 12) & 0x3F)),
                        result += char(0x80 | ((c >> 6) & 0x3F)), result += char(0x80 | (c & 0x3F));
            };
            if (!unicode)
            {
                // ANSI installers: game paths are ASCII; Latin-1 is close enough for the rest.
                for (unsigned char c : raw)
                    append(c);
                return result;
            }
            for (size_t i = 0; i + 1 < raw.size(); i += 2)
            {
                uint32_t c = uint8_t(raw[i]) | (uint32_t(uint8_t(raw[i + 1])) << 8);
                if (c >= 0xD800 && c < 0xDC00 && i + 3 < raw.size())
                {
                    uint32_t low = uint8_t(raw[i + 2]) | (uint32_t(uint8_t(raw[i + 3])) << 8);
                    if (low >= 0xDC00 && low < 0xE000)
                    {
                        c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
                        i += 2;
                    }
                }
                append(c);
            }
            return result;
        }

        std::ifstream OpenInput(const std::string& path)
        {
            std::ifstream stream(path, std::ios::binary);
            if (!stream)
                throw Error("无法读取「" + fs::path(path).filename().string() + "」。");
            return stream;
        }

        template<typename T>
        T LoadFrom(std::istream& stream)
        {
            T value{};
            stream.read(reinterpret_cast<char*>(&value), sizeof(T));
            return value;
        }

        // MARK: Setup loader

        struct LoaderOffsets
        {
            uint32_t Header = 0;
            uint32_t Data = 0;
        };

        // The 5.1.5+ loader table lives in resource 11111; scanning the resource section for its
        // magic and checking the table's CRC avoids walking the resource directory.
        std::optional<LoaderOffsets> ParseLoaderTable(const uint8_t* table, size_t available)
        {
            constexpr size_t kSize = 12 + 4 * 8;
            if (available < kSize)
                return std::nullopt;
            uint32_t fields[8];
            std::memcpy(fields, table + 12, sizeof(fields));
            // revision, unknown, exe offset, exe size, exe crc, header offset, data offset, table crc
            if (fields[0] != 1 || crc32(0, table, 12 + 4 * 7) != fields[7])
                return std::nullopt;
            return LoaderOffsets{ fields[5], fields[6] };
        }

        LoaderOffsets FindLoaderOffsets(std::ifstream& stream)
        {
            static const uint8_t kMagics[][12] = {
                { 'r', 'D', 'l', 'P', 't', 'S', 0xcd, 0xe6, 0xd7, '{', 0x0b, '*' },
                { 'n', 'S', '5', 'W', '7', 'd', 'T', 0x83, 0xaa, 0x1b, 0x0f, 'j' },
            };
            stream.seekg(0x3C);
            auto peOffset = LoadFrom<uint32_t>(stream);
            stream.seekg(peOffset);
            if (LoadFrom<uint32_t>(stream) != 0x00004550) // "PE\0\0"
                throw Error("这个 .exe 不是 Inno Setup 安装包。");
            stream.seekg(peOffset + 6);
            auto sectionCount = LoadFrom<uint16_t>(stream);
            stream.seekg(peOffset + 20);
            auto optionalSize = LoadFrom<uint16_t>(stream);
            auto sectionTable = peOffset + 24 + optionalSize;
            for (uint16_t i = 0; i < sectionCount && stream; i++)
            {
                stream.seekg(sectionTable + i * 40);
                char name[8];
                stream.read(name, 8);
                stream.seekg(sectionTable + i * 40 + 16);
                auto rawSize = LoadFrom<uint32_t>(stream);
                auto rawOffset = LoadFrom<uint32_t>(stream);
                if (std::strncmp(name, ".rsrc", 8) != 0 || rawSize > 64 * 1024 * 1024)
                    continue;
                std::vector<uint8_t> section(rawSize);
                stream.seekg(rawOffset);
                stream.read(reinterpret_cast<char*>(section.data()), rawSize);
                section.resize(size_t(stream.gcount()));
                for (size_t at = 0; at + 12 <= section.size(); at++)
                {
                    for (auto& magic : kMagics)
                    {
                        if (std::memcmp(section.data() + at, magic, 12) == 0)
                        {
                            if (auto offsets = ParseLoaderTable(section.data() + at, section.size() - at))
                                return *offsets;
                        }
                    }
                }
            }
            stream.clear();
            throw Error("这个 .exe 不是 Inno Setup 安装包，或者版本太旧。");
        }

        // MARK: Header blocks

        std::vector<uint8_t> DecodeLzma1(const std::vector<uint8_t>& input)
        {
            if (input.size() < LZMA_PROPS_SIZE)
                throw std::runtime_error("lzma");
            CLzmaDec decoder;
            LzmaDec_CONSTRUCT(&decoder);
            if (LzmaDec_Allocate(&decoder, input.data(), LZMA_PROPS_SIZE, &g_Alloc) != SZ_OK)
                throw std::runtime_error("lzma");
            LzmaDec_Init(&decoder);
            std::vector<uint8_t> output;
            size_t inPos = LZMA_PROPS_SIZE;
            uint8_t buffer[1 << 16];
            for (;;)
            {
                SizeT outSize = sizeof(buffer), inSize = input.size() - inPos;
                ELzmaStatus status;
                auto result = LzmaDec_DecodeToBuf(&decoder, buffer, &outSize, input.data() + inPos, &inSize, LZMA_FINISH_ANY, &status);
                inPos += inSize;
                output.insert(output.end(), buffer, buffer + outSize);
                if (result != SZ_OK)
                {
                    LzmaDec_Free(&decoder, &g_Alloc);
                    throw std::runtime_error("lzma");
                }
                if (status == LZMA_STATUS_FINISHED_WITH_MARK || (outSize == 0 && inSize == 0))
                    break;
            }
            LzmaDec_Free(&decoder, &g_Alloc);
            return output;
        }

        // A block is a CRC-checked header, then 4096-byte chunks that each start with their CRC.
        std::vector<uint8_t> ReadBlock(std::istream& stream)
        {
            uint8_t header[9];
            stream.read(reinterpret_cast<char*>(header), sizeof(header));
            uint32_t expected, storedSize;
            std::memcpy(&expected, header, 4);
            std::memcpy(&storedSize, header + 4, 4);
            if (!stream || crc32(0, header + 4, 5) != expected || storedSize > 256 * 1024 * 1024)
                throw std::runtime_error("block");
            bool compressed = header[8] != 0;
            std::vector<uint8_t> stored(storedSize);
            stream.read(reinterpret_cast<char*>(stored.data()), storedSize);
            if (!stream)
                throw std::runtime_error("block");
            std::vector<uint8_t> payload;
            for (size_t at = 0; at < stored.size();)
            {
                if (stored.size() - at < 5)
                    throw std::runtime_error("block");
                uint32_t crc;
                std::memcpy(&crc, stored.data() + at, 4);
                size_t length = std::min<size_t>(4096, stored.size() - at - 4);
                if (crc32(0, stored.data() + at + 4, uInt(length)) != crc)
                    throw std::runtime_error("block crc");
                payload.insert(payload.end(), stored.data() + at + 4, stored.data() + at + 4 + length);
                at += 4 + length;
            }
            return compressed ? DecodeLzma1(payload) : payload;
        }

        Version ParseVersion(const char (&text)[64])
        {
            std::string name(text, strnlen(text, 64));
            if (name.find("Inno Setup") == std::string::npos)
                throw Error("无法识别这个安装包的格式。");
            Version version;
            for (size_t open = name.find('('); open != std::string::npos; open = name.find('(', open + 1))
            {
                unsigned a, b, c, d = 0;
                int used = 0;
                if (std::sscanf(name.c_str() + open, "(%u.%u.%u%n", &a, &b, &c, &used) == 3)
                {
                    const char* rest = name.c_str() + open + used;
                    if (*rest == '.')
                        std::sscanf(rest, ".%u", &d);
                    version.Value = std::max(version.Value, MakeVersion(a, b, c, d));
                }
            }
            version.Unicode = version >= MakeVersion(6, 3, 0) || name.find("(u)") != std::string::npos
                || name.find("(U)") != std::string::npos;
            if (version.Value == 0)
                throw Error("无法识别这个安装包的格式。");
            return version;
        }

        // MARK: Entries

        struct FileEntry
        {
            std::string Destination;
            std::string Languages;
            // GOG Galaxy installers describe the real files in these scripted conditions.
            std::string Check;
            std::string AfterInstall;
            std::string BeforeInstall;
            uint32_t Location;
        };

        struct DataEntry
        {
            uint32_t FirstSlice;
            uint32_t LastSlice;
            uint32_t ChunkOffset;
            uint64_t FileOffset;
            uint64_t FileSize;
            uint64_t ChunkSize;
            std::string Checksum; // SHA-1, or SHA-256 from 6.4.0
            bool Encrypted;
            bool Compressed;
            bool CallFilter;
        };

        struct Setup
        {
            Version Ver;
            std::string AppName;
            uint32_t SlicesPerDisk = 1;
            Compression Method = Compression::Stored;
            bool Encrypted = false;
            std::vector<FileEntry> Files;
            std::vector<DataEntry> Data;
        };

        // Skips the condition strings shared by directories, files, icons and the like.
        void SkipCondition(Cursor& c)
        {
            c.SkipStrings(6); // components, tasks, languages, check, after/before install
        }

        void SkipWindowsVersions(Cursor& c)
        {
            c.Skip(20); // minimum and only-below, each a Windows and NT version plus service pack
        }

        void ParsePrimary(const std::vector<uint8_t>& block, Setup& setup)
        {
            const Version& v = setup.Ver;
            Cursor c(block);
            setup.AppName = ToUtf8(c.String(), v.Unicode);
            c.SkipStrings(26); // versioned name through close-applications filter
            if (v >= MakeVersion(5, 5, 6))
                c.SkipStrings(1); // setup mutex
            if (v >= MakeVersion(5, 6, 1))
                c.SkipStrings(2); // changes environment / associations
            if (v >= MakeVersion(6, 3, 0))
                c.SkipStrings(2); // architecture expressions
            c.SkipStrings(4);     // license, info before/after, compiled code
            if (!v.Unicode)
                c.Skip(32); // lead bytes
            uint32_t languages = c.U32(), messages = c.U32(), permissions = c.U32(), types = c.U32(),
                     components = c.U32(), tasks = c.U32(), directories = c.U32(), files = c.U32();
            c.Skip(4); // data entry count, read again from the second block
            uint32_t icons = c.U32(), inis = c.U32(), registry = c.U32(), deletes = c.U32(), uninstallDeletes = c.U32(),
                     runs = c.U32(), uninstallRuns = c.U32();
            SkipWindowsVersions(c);
            if (v < MakeVersion(6, 4, 0, 1))
                c.Skip(8); // background colours
            if (v < MakeVersion(5, 5, 7))
                c.Skip(4); // image background colour
            if (v >= MakeVersion(6, 0, 0))
                c.Skip(9); // wizard style and resize percentages
            if (v >= MakeVersion(5, 5, 7))
                c.Skip(1); // image alpha format
            c.Skip(v >= MakeVersion(6, 4, 0) ? 4 + 44 : 20 + 8); // password check and salt
            c.Skip(8);                                            // extra disk space
            setup.SlicesPerDisk = c.U32();
            c.Skip(3); // uninstall log mode, dir exists warning, privileges
            if (v >= MakeVersion(5, 7, 0))
                c.Skip(1); // privilege overrides
            c.Skip(2);     // language dialog and detection
            auto method = c.U8();
            if (method > uint8_t(Compression::LZMA2))
                throw Error("这个安装包使用了未知的压缩方式。");
            setup.Method = Compression(method);
            if (v < MakeVersion(6, 3, 0))
                c.Skip(2); // architectures allowed / 64-bit
            c.Skip(2 + 8); // dir and group page settings, uninstall display size
            if (v.Value == MakeVersion(5, 5, 0, 1))
                c.Skip(1);

            int flags = 5, encryption;
            if (v < MakeVersion(6, 4, 0, 1))
                flags += 4;
            flags += 4 + 1;
            if (v < MakeVersion(5, 6, 1))
                flags++;
            if (v < MakeVersion(6, 4, 0, 1))
                flags++;
            flags += 3 + 6 + 2 + 1 + 2 + 1 + 1 + 1 + 1 + 1 + 2;
            encryption = flags++;
            if (v < MakeVersion(5, 6, 1))
                flags++;
            if (!v.Unicode)
                flags++;
            flags += 4 + 3;
            if (v >= MakeVersion(5, 5, 7))
                flags++;
            if (v >= MakeVersion(6, 0, 0))
                flags += 3;
            if (v >= MakeVersion(6, 3, 0))
                flags++;
            setup.Encrypted = FlagSet(ReadFlags(c, flags), encryption);

            for (uint32_t i = 0; i < languages; i++)
            {
                c.SkipStrings(2);
                if (v.Value == MakeVersion(5, 5, 7, 1))
                    c.SkipStrings(1);
                c.SkipStrings(8);
                c.Skip(4 + (v.Unicode ? 0 : 4) + 16 + (v.Value == MakeVersion(5, 5, 7, 1) ? 4 : 0) + 1);
            }
            for (uint32_t i = 0; i < messages; i++)
                c.SkipStrings(2), c.Skip(4);
            for (uint32_t i = 0; i < permissions; i++)
                c.SkipStrings(1);
            for (uint32_t i = 0; i < types; i++)
                c.SkipStrings(4), SkipWindowsVersions(c), c.Skip(1 + 1 + 8);
            for (uint32_t i = 0; i < components; i++)
                c.SkipStrings(5), c.Skip(8 + 4 + 1), SkipWindowsVersions(c), c.Skip(1 + 8);
            for (uint32_t i = 0; i < tasks; i++)
                c.SkipStrings(6), c.Skip(4 + 1), SkipWindowsVersions(c), c.Skip(1);
            for (uint32_t i = 0; i < directories; i++)
                c.SkipStrings(1), SkipCondition(c), c.Skip(4), SkipWindowsVersions(c), c.Skip(2 + 1);
            for (uint32_t i = 0; i < files; i++)
            {
                c.SkipStrings(1); // source
                FileEntry file;
                file.Destination = ToUtf8(c.String(), v.Unicode);
                c.SkipStrings(2); // font name, assembly name
                c.SkipStrings(2); // components, tasks
                file.Languages = ToUtf8(c.String(), v.Unicode);
                file.Check = ToUtf8(c.String(), v.Unicode);
                file.AfterInstall = ToUtf8(c.String(), v.Unicode);
                file.BeforeInstall = ToUtf8(c.String(), v.Unicode);
                SkipWindowsVersions(c);
                file.Location = c.U32();
                c.Skip(4 + 8 + 2); // attributes, external size, permission
                SkipFlags(c, 32);
                c.Skip(1); // file type
                setup.Files.push_back(std::move(file));
            }

            // The rest is only parsed to confirm the version-dependent layout was read correctly.
            for (uint32_t i = 0; i < icons; i++)
            {
                c.SkipStrings(6), SkipCondition(c), c.SkipStrings(1); // app user model id
                if (v >= MakeVersion(6, 1, 0))
                    c.Skip(16);
                SkipWindowsVersions(c);
                c.Skip(4 + 4 + 1 + 2);
                SkipFlags(c, 8);
            }
            for (uint32_t i = 0; i < inis; i++)
                c.SkipStrings(4), SkipCondition(c), SkipWindowsVersions(c), SkipFlags(c, 5);
            for (uint32_t i = 0; i < registry; i++)
                c.SkipStrings(3), SkipCondition(c), SkipWindowsVersions(c), c.Skip(4 + 2 + 1), SkipFlags(c, 12);
            for (uint32_t i = 0; i < deletes + uninstallDeletes; i++)
                c.SkipStrings(1), SkipCondition(c), SkipWindowsVersions(c), c.Skip(1);
            for (uint32_t i = 0; i < runs + uninstallRuns; i++)
            {
                c.SkipStrings(7), SkipCondition(c), SkipWindowsVersions(c), c.Skip(4 + 1);
                SkipFlags(c, 10 + (v >= MakeVersion(6, 1, 0)) + (v >= MakeVersion(6, 3, 0)));
            }
            for (int set = 0; set < 2; set++)
            {
                uint32_t images = v >= MakeVersion(5, 6, 0) ? c.U32() : 1;
                c.SkipStrings(int(images));
            }
            if (setup.Method == Compression::BZip2 || setup.Method == Compression::Zlib)
                c.SkipStrings(1); // decompressor DLL
            if (setup.Encrypted && v < MakeVersion(6, 4, 0))
                c.SkipStrings(1); // decryption DLL
            if (!c.AtEnd())
                throw std::runtime_error("trailing header data");
        }

        void ParseData(const std::vector<uint8_t>& block, Setup& setup)
        {
            const Version& v = setup.Ver;
            Cursor c(block);
            while (!c.AtEnd())
            {
                DataEntry data;
                data.FirstSlice = c.U32();
                data.LastSlice = c.U32();
                data.ChunkOffset = c.U32();
                data.FileOffset = c.U64();
                data.FileSize = c.U64();
                data.ChunkSize = c.U64();
                data.Checksum = c.Bytes(v >= MakeVersion(6, 4, 0) ? 32 : 20);
                c.Skip(8 + 8); // file time, file version
                int count = 9 + (v >= MakeVersion(5, 5, 7) && v < MakeVersion(6, 3, 0) ? 2 : 0);
                auto flags = ReadFlags(c, count);
                if (v >= MakeVersion(6, 3, 0))
                    c.Skip(1); // sign mode
                data.CallFilter = FlagSet(flags, 4);
                data.Encrypted = FlagSet(flags, 6);
                data.Compressed = FlagSet(flags, 7);
                setup.Data.push_back(std::move(data));
            }
        }

        struct Loaded
        {
            Setup Info;
            LoaderOffsets Offsets;
        };

        Loaded Load(const std::string& path)
        {
            auto stream = OpenInput(path);
            Loaded loaded;
            loaded.Offsets = FindLoaderOffsets(stream);
            stream.seekg(loaded.Offsets.Header);
            char name[64];
            stream.read(name, sizeof(name));
            if (!stream)
                throw Error("安装包已损坏或不完整。");
            auto version = ParseVersion(name);
            if (version < kOldestSupported || version >= kFirstUnsupported)
                throw Error("暂不支持这个版本的安装包（Inno Setup " + std::to_string(version.Value >> 24) + "."
                            + std::to_string((version.Value >> 16) & 0xFF) + "." + std::to_string((version.Value >> 8) & 0xFF)
                            + "）。请改为导入解包后的文件夹。");

            std::vector<uint8_t> primary, data;
            try
            {
                primary = ReadBlock(stream);
                data = ReadBlock(stream);
            }
            catch (const std::exception&)
            {
                throw Error("安装包已损坏或不完整。");
            }
            // Some version strings were reused by modified builds with an extra field.
            std::vector<uint32_t> attempts{ version.Value };
            if (version.Value == MakeVersion(5, 5, 0) || version.Value == MakeVersion(5, 5, 7))
                attempts.push_back(version.Value | 1);
            for (auto attempt : attempts)
            {
                Setup setup;
                setup.Ver = { attempt, version.Unicode };
                try
                {
                    ParsePrimary(primary, setup);
                    ParseData(data, setup);
                }
                catch (const std::exception&)
                {
                    continue;
                }
                bool consistent = std::all_of(setup.Files.begin(), setup.Files.end(), [&](const FileEntry& file) {
                    return file.Location == UINT32_MAX || file.Location < setup.Data.size();
                });
                if (!consistent)
                    continue;
                if (setup.Encrypted)
                    throw Error("这个安装包有密码保护，暂不支持。");
                loaded.Info = std::move(setup);
                return loaded;
            }
            throw Error("无法读取这个安装包的文件列表，可能是不支持的变体。请改为导入解包后的文件夹。");
        }

        std::vector<std::string> SliceNames(const Loaded& loaded, const std::string& installerPath)
        {
            std::vector<std::string> names;
            if (loaded.Offsets.Data != 0)
                return names; // single-file installer: the data is inside the .exe
            uint32_t count = 0;
            for (auto& data : loaded.Info.Data)
                count = std::max(count, data.LastSlice + 1);
            auto base = fs::path(installerPath).stem().string();
            uint32_t perDisk = std::max<uint32_t>(1, loaded.Info.SlicesPerDisk);
            for (uint32_t slice = 0; slice < count; slice++)
            {
                if (perDisk == 1)
                    names.push_back(base + "-" + std::to_string(slice + 1) + ".bin");
                else
                    names.push_back(base + "-" + std::to_string(slice / perDisk + 1) + char('a' + slice % perDisk) + ".bin");
            }
            return names;
        }

        std::optional<std::string> FindCandidate(const std::string& name, const std::vector<std::string>& candidates)
        {
            auto wanted = Lower(name);
            for (auto& candidate : candidates)
                if (Lower(fs::path(candidate).filename().string()) == wanted)
                    return candidate;
            return std::nullopt;
        }

        // MARK: Slices and chunks

        // Reads the data area that continues across the .bin slices, or inside a single-file .exe.
        class SliceReader
        {
        public:
            SliceReader(std::vector<std::string> paths, std::string installer, uint32_t dataOffset)
                : _paths(std::move(paths))
                , _installer(std::move(installer))
                , _dataOffset(dataOffset)
            {
            }

            void Seek(uint32_t slice, uint64_t offset)
            {
                Open(slice);
                _stream.seekg(std::streamoff(offset + _dataOffset));
                if (!_stream || offset + _dataOffset > _size)
                    throw Error("安装包数据不完整。");
            }

            size_t Read(uint8_t* buffer, size_t count)
            {
                size_t done = 0;
                while (done < count)
                {
                    uint64_t position = uint64_t(_stream.tellg());
                    if (position >= _size)
                    {
                        if (_dataOffset != 0)
                            break;
                        Open(_slice + 1);
                        continue;
                    }
                    size_t chunk = size_t(std::min<uint64_t>(count - done, _size - position));
                    _stream.read(reinterpret_cast<char*>(buffer + done), std::streamsize(chunk));
                    if (_stream.gcount() <= 0)
                        break;
                    done += size_t(_stream.gcount());
                }
                return done;
            }

        private:
            void Open(uint32_t slice)
            {
                if (_stream.is_open() && slice == _slice)
                    return;
                _stream.close();
                _stream.clear();
                _slice = slice;
                if (_dataOffset != 0)
                {
                    if (slice != 0)
                        throw Error("安装包数据不完整。");
                    _stream.open(_installer, std::ios::binary | std::ios::ate);
                    _size = uint64_t(_stream.tellg());
                    return;
                }
                if (slice >= _paths.size())
                    throw Error("安装包数据不完整，缺少 .bin 文件。");
                _stream.open(_paths[slice], std::ios::binary | std::ios::ate);
                if (!_stream)
                    throw Error("无法读取「" + fs::path(_paths[slice]).filename().string() + "」。");
                auto fileSize = uint64_t(_stream.tellg());
                _stream.seekg(0);
                char magic[8];
                _stream.read(magic, 8);
                _size = LoadFrom<uint32_t>(_stream);
                if (!_stream || (std::memcmp(magic, "idska32\x1a", 8) != 0 && std::memcmp(magic, "idska16\x1a", 8) != 0)
                    || _size > fileSize)
                    throw Error("「" + fs::path(_paths[slice]).filename().string() + "」不是这个安装包的数据文件，或者已损坏。");
            }

            std::vector<std::string> _paths;
            std::string _installer;
            uint32_t _dataOffset;
            std::ifstream _stream;
            uint32_t _slice = 0;
            uint64_t _size = 0;
        };

        // Decompresses one chunk: "zlb\x1a", then ChunkSize bytes in the setup's compression.
        class ChunkReader
        {
        public:
            ChunkReader(SliceReader& slices, const DataEntry& entry, Compression method, std::function<void(size_t)> consumed)
                : _slices(slices)
                , _remaining(entry.ChunkSize)
                , _method(entry.Compressed ? method : Compression::Stored)
                , _consumed(std::move(consumed))
            {
                _slices.Seek(entry.FirstSlice, entry.ChunkOffset);
                uint8_t magic[4];
                if (_slices.Read(magic, 4) != 4 || std::memcmp(magic, "zlb\x1a", 4) != 0)
                    throw Error("安装包数据已损坏。");
                switch (_method)
                {
                    case Compression::Stored:
                        break;
                    case Compression::Zlib:
                        _zlib = std::make_unique<z_stream>();
                        if (inflateInit(_zlib.get()) != Z_OK)
                            throw Error("解压失败。");
                        break;
                    case Compression::LZMA1:
                    {
                        uint8_t props[LZMA_PROPS_SIZE];
                        if (Fill(props, sizeof(props)) != sizeof(props))
                            throw Error("安装包数据已损坏。");
                        LzmaDec_CONSTRUCT(&_lzma);
                        if (LzmaDec_Allocate(&_lzma, props, LZMA_PROPS_SIZE, &g_Alloc) != SZ_OK)
                            throw Error("安装包数据已损坏。");
                        LzmaDec_Init(&_lzma);
                        _lzmaReady = true;
                        break;
                    }
                    case Compression::LZMA2:
                    {
                        uint8_t prop;
                        if (Fill(&prop, 1) != 1)
                            throw Error("安装包数据已损坏。");
                        Lzma2Dec_CONSTRUCT(&_lzma2);
                        if (Lzma2Dec_Allocate(&_lzma2, prop, &g_Alloc) != SZ_OK)
                            throw Error("安装包数据已损坏。");
                        Lzma2Dec_Init(&_lzma2);
                        _lzma2Ready = true;
                        break;
                    }
                    case Compression::BZip2:
                        throw Error("暂不支持 BZip2 压缩的安装包。");
                }
            }

            ~ChunkReader()
            {
                if (_zlib)
                    inflateEnd(_zlib.get());
                if (_lzmaReady)
                    LzmaDec_Free(&_lzma, &g_Alloc);
                if (_lzma2Ready)
                    Lzma2Dec_Free(&_lzma2, &g_Alloc);
            }

            uint64_t Remaining() const
            {
                return _remaining;
            }

            // Reads exactly count bytes of decompressed data or throws.
            void Read(uint8_t* out, size_t count)
            {
                while (count > 0)
                {
                    size_t produced = Decode(out, count);
                    if (produced == 0)
                        throw Error("安装包数据已损坏或不完整。");
                    out += produced;
                    count -= produced;
                }
            }

        private:
            // Raw chunk bytes, limited to the chunk's size.
            size_t Fill(uint8_t* buffer, size_t count)
            {
                count = size_t(std::min<uint64_t>(count, _remaining));
                size_t read = _slices.Read(buffer, count);
                _remaining -= read;
                _consumed(read);
                return read;
            }

            bool Refill()
            {
                if (_inPos < _inSize)
                    return true;
                _inPos = 0;
                _inSize = Fill(_in.data(), _in.size());
                return _inSize > 0;
            }

            size_t Decode(uint8_t* out, size_t count)
            {
                if (_method == Compression::Stored)
                    return Fill(out, count);
                for (;;)
                {
                    bool more = Refill();
                    SizeT inSize = _inSize - _inPos, outSize = count;
                    if (_method == Compression::Zlib)
                    {
                        _zlib->next_in = _in.data() + _inPos;
                        _zlib->avail_in = uInt(inSize);
                        _zlib->next_out = out;
                        _zlib->avail_out = uInt(std::min<size_t>(count, UINT32_MAX));
                        int result = inflate(_zlib.get(), Z_NO_FLUSH);
                        if (result != Z_OK && result != Z_STREAM_END && result != Z_BUF_ERROR)
                            throw Error("安装包数据已损坏。");
                        _inPos += inSize - _zlib->avail_in;
                        size_t produced = std::min<size_t>(count, UINT32_MAX) - _zlib->avail_out;
                        if (produced > 0 || !more || result == Z_STREAM_END)
                            return produced;
                        continue;
                    }
                    ELzmaStatus status;
                    SRes result = _method == Compression::LZMA1
                        ? LzmaDec_DecodeToBuf(&_lzma, out, &outSize, _in.data() + _inPos, &inSize, LZMA_FINISH_ANY, &status)
                        : Lzma2Dec_DecodeToBuf(&_lzma2, out, &outSize, _in.data() + _inPos, &inSize, LZMA_FINISH_ANY, &status);
                    if (result != SZ_OK)
                        throw Error("安装包数据已损坏。");
                    _inPos += inSize;
                    if (outSize > 0 || !more || status == LZMA_STATUS_FINISHED_WITH_MARK)
                        return outSize;
                }
            }

            SliceReader& _slices;
            uint64_t _remaining;
            Compression _method;
            std::function<void(size_t)> _consumed;
            std::array<uint8_t, 1 << 16> _in{};
            size_t _inPos = 0, _inSize = 0;
            std::unique_ptr<z_stream> _zlib;
            CLzmaDec _lzma{};
            CLzma2Dec _lzma2{};
            bool _lzmaReady = false, _lzma2Ready = false;
        };

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // SHA-1 is only a file checksum here.
        class Digest
        {
        public:
            explicit Digest(bool sha256)
                : _sha256(sha256)
            {
                sha256 ? CC_SHA256_Init(&_ctx256) : CC_SHA1_Init(&_ctx1);
            }
            void Update(const uint8_t* data, size_t size)
            {
                _sha256 ? CC_SHA256_Update(&_ctx256, data, CC_LONG(size)) : CC_SHA1_Update(&_ctx1, data, CC_LONG(size));
            }
            std::string Final()
            {
                std::string out(_sha256 ? CC_SHA256_DIGEST_LENGTH : CC_SHA1_DIGEST_LENGTH, '\0');
                auto bytes = reinterpret_cast<unsigned char*>(out.data());
                _sha256 ? CC_SHA256_Final(bytes, &_ctx256) : CC_SHA1_Final(bytes, &_ctx1);
                return out;
            }

        private:
            bool _sha256;
            CC_SHA1_CTX _ctx1{};
            CC_SHA256_CTX _ctx256{};
        };
#pragma clang diagnostic pop

        // "Data\ch.dat" (or "{app}\Data\ch.dat") -> "Data/ch.dat"; other folders and unsafe paths are dropped.
        std::optional<std::string> AppRelativePath(std::string path, bool requireAppPrefix)
        {
            constexpr std::string_view kApp = "{app}\\";
            bool prefixed = path.size() > kApp.size() && Lower(path.substr(0, kApp.size())) == kApp;
            if (prefixed)
                path = path.substr(kApp.size());
            else if (requireAppPrefix)
                return std::nullopt;
            std::replace(path.begin(), path.end(), '\\', '/');
            if (path.empty() || path.find(':') != std::string::npos || path.front() == '/')
                return std::nullopt;
            for (size_t start = 0; start <= path.size();)
            {
                auto end = path.find('/', start);
                if (end == std::string::npos)
                    end = path.size();
                auto part = std::string_view(path).substr(start, end - start);
                if (part.empty() || part == "." || part == ".." || part.find('{') != std::string_view::npos)
                    return std::nullopt;
                start = end + 1;
            }
            return path;
        }

        // Arguments of a call such as before_install('abc', 'Data\ch.dat', 2); empty when it is another call.
        std::vector<std::string> ParseCall(const std::string& code, std::string_view name)
        {
            std::vector<std::string> arguments;
            size_t at = code.find_first_not_of(" \t\r\n");
            if (at == std::string::npos || code.compare(at, name.size(), name) != 0)
                return arguments;
            at = code.find_first_not_of(" \t\r\n", at + name.size());
            if (at == std::string::npos || code[at] != '(')
                return arguments;
            at++;
            for (;;)
            {
                at = code.find_first_not_of(" \t\r\n", at);
                if (at == std::string::npos)
                    return {};
                if (code[at] == ')' && arguments.empty())
                    return arguments;
                std::string argument;
                if (code[at] == '\'')
                {
                    // Pascal strings: '' is an escaped quote.
                    for (at++;; at++)
                    {
                        if (at >= code.size())
                            return {};
                        if (code[at] == '\'')
                        {
                            if (at + 1 < code.size() && code[at + 1] == '\'')
                                argument += '\'', at++;
                            else
                                break;
                        }
                        else
                            argument += code[at];
                    }
                    at++;
                }
                else
                {
                    auto end = code.find_first_of(" \t\r\n,)", at);
                    if (end == std::string::npos)
                        return {};
                    argument = code.substr(at, end - at);
                    at = end;
                }
                arguments.push_back(std::move(argument));
                at = code.find_first_not_of(" \t\r\n", at);
                if (at == std::string::npos)
                    return {};
                if (code[at] == ')')
                    return arguments;
                if (code[at] != ',')
                    return {};
                at++;
            }
        }

        std::vector<std::string> ParseAnyCall(const std::string& code, std::string_view name, std::string_view dependency)
        {
            auto arguments = ParseCall(code, name);
            return arguments.empty() ? ParseCall(code, dependency) : arguments;
        }

        // Language-specific copies of one path: prefer English, then language-neutral files.
        // Inno lists languages as names; GOG Galaxy as "en-US#de-DE#" with "!" for exclusions.
        int LanguageRank(const std::string& languages)
        {
            auto lower = Lower(languages);
            if (lower.empty())
                return 1;
            for (size_t start = 0; start < lower.size();)
            {
                auto end = lower.find_first_of("# ,", start);
                if (end == std::string::npos)
                    end = lower.size();
                auto token = std::string_view(lower).substr(start, end - start);
                if (token == "en-us" || token == "en" || token == "english")
                    return 0;
                start = end + 1;
            }
            return 2;
        }

        // One file of the application folder, assembled from one or more data entries in order.
        struct Output
        {
            std::string Path;
            int Rank = 1;
            struct Part
            {
                uint32_t Location;
                uint64_t Offset;
                uint64_t Size;
                bool Zlib; // GOG Galaxy parts are separately zlib-compressed
            };
            std::vector<Part> Parts;
            uint64_t Size = 0;
        };

        std::vector<Output> CollectOutputs(const Setup& setup)
        {
            std::vector<Output> outputs;
            Output* galaxy = nullptr;
            size_t remainingParts = 0;
            for (auto& file : setup.Files)
            {
                auto start = ParseAnyCall(file.BeforeInstall, "before_install", "before_install_dependency");
                if (!start.empty())
                {
                    // before_install(md5, path, part count) opens a file made of the following parts.
                    galaxy = nullptr;
                    remainingParts = 0;
                    auto path = AppRelativePath(start.size() >= 2 && !start[1].empty() ? start[1] : file.Destination, false);
                    if (path && start.size() >= 3)
                    {
                        Output output;
                        output.Path = *path;
                        auto check = ParseAnyCall(file.Check, "check_if_install", "check_if_install_dependency");
                        output.Rank = LanguageRank(!check.empty() ? check[0] : file.Languages);
                        outputs.push_back(std::move(output));
                        galaxy = &outputs.back();
                        remainingParts = std::max<size_t>(1, std::strtoull(start[2].c_str(), nullptr, 10));
                    }
                }
                auto part = ParseAnyCall(file.AfterInstall, "after_install", "after_install_dependency");
                if (!part.empty())
                {
                    // after_install(md5, compressed size, size) is one part of the open file.
                    if (galaxy && remainingParts > 0 && part.size() >= 3 && file.Location < setup.Data.size())
                    {
                        uint64_t size = std::strtoull(part[2].c_str(), nullptr, 10);
                        galaxy->Parts.push_back({ file.Location, galaxy->Size, size, true });
                        galaxy->Size += size;
                        if (--remainingParts == 0)
                            galaxy = nullptr;
                    }
                    continue;
                }
                if (!start.empty() || file.Location >= setup.Data.size())
                    continue;
                if (auto path = AppRelativePath(file.Destination, true))
                {
                    Output output;
                    output.Path = *path;
                    output.Rank = LanguageRank(file.Languages);
                    output.Size = setup.Data[file.Location].FileSize;
                    output.Parts.push_back({ file.Location, 0, output.Size, false });
                    outputs.push_back(std::move(output));
                }
            }
            // Drop files whose parts did not all appear.
            std::erase_if(outputs, [](const Output& output) { return output.Parts.empty(); });
            return outputs;
        }

        // Where one data entry's bytes go: a range of an output file, inflated first for Galaxy parts.
        class PartWriter
        {
        public:
            PartWriter(const fs::path& path, const Output::Part& part)
                : _path(path)
                , _expected(part.Size)
            {
                std::error_code error;
                fs::create_directories(path.parent_path(), error);
                if (!fs::exists(path))
                    std::ofstream(path, std::ios::binary);
                _file.open(path, std::ios::binary | std::ios::in | std::ios::out);
                _file.seekp(std::streamoff(part.Offset));
                if (!_file)
                    throw Error("无法写入「" + path.filename().string() + "」，可能是存储空间不足。");
                if (part.Zlib)
                {
                    _zlib = std::make_unique<z_stream>();
                    if (inflateInit(_zlib.get()) != Z_OK)
                        throw Error("解压失败。");
                }
            }

            ~PartWriter()
            {
                if (_zlib)
                    inflateEnd(_zlib.get());
            }

            void Write(const uint8_t* data, size_t size)
            {
                if (!_zlib)
                {
                    Put(data, size);
                    return;
                }
                _zlib->next_in = const_cast<uint8_t*>(data);
                _zlib->avail_in = uInt(size);
                while (_zlib->avail_in > 0 && !_ended)
                {
                    uint8_t out[1 << 16];
                    _zlib->next_out = out;
                    _zlib->avail_out = sizeof(out);
                    int result = inflate(_zlib.get(), Z_NO_FLUSH);
                    if (result != Z_OK && result != Z_STREAM_END)
                        throw Error("「" + _path.filename().string() + "」解压失败，安装包可能已损坏。");
                    Put(out, sizeof(out) - _zlib->avail_out);
                    _ended = result == Z_STREAM_END;
                }
            }

            void Finish()
            {
                _file.close();
                if (!_file)
                    throw Error("写入文件失败，可能是存储空间不足。");
                if ((_zlib && !_ended) || _written != _expected)
                    throw Error("「" + _path.filename().string() + "」不完整，安装包可能已损坏。");
            }

        private:
            void Put(const uint8_t* data, size_t size)
            {
                _file.write(reinterpret_cast<const char*>(data), std::streamsize(size));
                _written += size;
            }

            fs::path _path;
            uint64_t _expected;
            std::fstream _file;
            std::unique_ptr<z_stream> _zlib;
            bool _ended = false;
            uint64_t _written = 0;
        };
    } // namespace

    bool IsInstaller(const std::string& path)
    {
        std::ifstream stream(path, std::ios::binary);
        char head[2]{};
        stream.read(head, 2);
        return stream && head[0] == 'M' && head[1] == 'Z';
    }

    Installer Inspect(const std::string& installerPath)
    {
        auto loaded = Load(installerPath);
        Installer installer;
        auto& v = loaded.Info.Ver.Value;
        installer.Version = std::to_string(v >> 24) + "." + std::to_string((v >> 16) & 0xFF) + "." + std::to_string((v >> 8) & 0xFF);
        installer.AppName = loaded.Info.AppName;
        installer.Slices = SliceNames(loaded, installerPath);
        return installer;
    }

    std::vector<std::string> MissingSlices(const Installer& installer, const std::vector<std::string>& candidates)
    {
        std::vector<std::string> missing;
        for (auto& name : installer.Slices)
            if (!FindCandidate(name, candidates))
                missing.push_back(name);
        return missing;
    }

    size_t Extract(const ExtractOptions& options)
    {
        auto loaded = Load(options.Installer);
        const auto& setup = loaded.Info;

        std::vector<std::string> slicePaths;
        for (auto& name : SliceNames(loaded, options.Installer))
        {
            auto path = FindCandidate(name, options.SliceCandidates);
            if (!path)
                throw Error("还缺少「" + name + "」。请选择安装包所在的文件夹，或同时选中 .exe 和 .bin 文件。");
            slicePaths.push_back(*path);
        }

        // One output per path, preferring English copies; then find which data entries feed them.
        std::map<std::string, Output> byPath;
        for (auto& output : CollectOutputs(setup))
        {
            if (options.Wanted && !options.Wanted(output.Path))
                continue;
            auto key = Lower(output.Path);
            auto existing = byPath.find(key);
            if (existing == byPath.end() || output.Rank < existing->second.Rank)
                byPath[key] = std::move(output);
        }
        if (byPath.empty())
            throw Error("安装包里没有找到游戏数据。");

        std::map<uint32_t, std::vector<std::pair<const Output*, Output::Part>>> consumers; // data entry -> parts
        for (auto& [key, output] : byPath)
            for (auto& part : output.Parts)
                consumers[part.Location].emplace_back(&output, part);

        // Chunks are solid: data entries inside one are read in order of their offset.
        using ChunkKey = std::tuple<uint32_t, uint32_t, uint64_t>;
        std::map<ChunkKey, std::vector<uint32_t>> chunks;
        for (auto& [location, parts] : consumers)
        {
            auto& data = setup.Data[location];
            if (data.Encrypted)
                throw Error("这个安装包有密码保护，暂不支持。");
            if (data.CallFilter)
                throw Error("这个安装包里的游戏文件使用了暂不支持的编码方式。");
            chunks[{ data.FirstSlice, data.ChunkOffset, data.ChunkSize }].push_back(location);
        }

        // Progress counts compressed bytes; a chunk's unread tail is counted when it is left.
        uint64_t total = 0, done = 0;
        for (auto& [key, locations] : chunks)
            total += std::get<2>(key);
        auto report = [&](size_t bytes) {
            done += bytes;
            if (options.Cancelled && options.Cancelled())
                throw Cancelled();
            if (options.Progress)
                options.Progress(std::min(1.0, double(done) / double(std::max<uint64_t>(total, 1))));
        };

        SliceReader slices(slicePaths, options.Installer, loaded.Offsets.Data);
        std::vector<uint8_t> buffer(1 << 18);
        for (auto& [key, locations] : chunks)
        {
            std::sort(locations.begin(), locations.end(), [&](uint32_t a, uint32_t b) {
                return setup.Data[a].FileOffset < setup.Data[b].FileOffset;
            });
            auto& first = setup.Data[locations.front()];
            ChunkReader chunk(slices, first, setup.Method, report);
            uint64_t position = 0;
            for (auto location : locations)
            {
                auto& data = setup.Data[location];
                if (data.FileOffset < position)
                    throw Error("安装包数据已损坏。");
                for (uint64_t skip = data.FileOffset - position; skip > 0;)
                {
                    size_t step = size_t(std::min<uint64_t>(skip, buffer.size()));
                    chunk.Read(buffer.data(), step);
                    skip -= step;
                }
                std::vector<std::unique_ptr<PartWriter>> writers;
                for (auto& [output, part] : consumers[location])
                    writers.push_back(std::make_unique<PartWriter>(fs::path(options.Destination) / output->Path, part));
                Digest digest(data.Checksum.size() == 32);
                for (uint64_t left = data.FileSize; left > 0;)
                {
                    size_t step = size_t(std::min<uint64_t>(left, buffer.size()));
                    chunk.Read(buffer.data(), step);
                    digest.Update(buffer.data(), step);
                    for (auto& writer : writers)
                        writer->Write(buffer.data(), step);
                    left -= step;
                }
                if (digest.Final() != data.Checksum)
                    throw Error("「" + consumers[location].front().first->Path + "」校验失败，安装包可能已损坏。");
                for (auto& writer : writers)
                    writer->Finish();
                position = data.FileOffset + data.FileSize;
            }
            report(size_t(chunk.Remaining()));
        }
        return byPath.size();
    }
} // namespace OpenRCT2::Inno
