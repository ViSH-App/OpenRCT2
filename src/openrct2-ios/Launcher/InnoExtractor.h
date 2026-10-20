/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#pragma once

// A minimal Inno Setup extractor for GOG installers (setup_*.exe plus setup_*-N.bin slices).
// Supports setup data versions 5.5.0 up to 6.4.x without encryption, which covers the GOG
// releases of RollerCoaster Tycoon 1 and 2. The format follows innoextract's documentation
// of it (https://github.com/dscharrer/innoextract); no innoextract code is used.

#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace OpenRCT2::Inno
{
    // The message is meant for the user: what() is a localization key in which "%@" stands for the argument.
    struct Error : std::runtime_error
    {
        std::string argument;
        explicit Error(const std::string& message, std::string argument_ = {})
            : std::runtime_error(message)
            , argument(std::move(argument_))
        {
        }
    };

    struct Cancelled : std::exception
    {
    };

    struct Installer
    {
        std::string Version;
        std::string AppName;
        // Every slice file the installer needs, by name, e.g. setup_x-1.bin.
        std::vector<std::string> Slices;
    };

    // True when the file starts like a Windows executable that carries Inno Setup data.
    bool IsInstaller(const std::string& path);

    // Reads the installer's headers; throws Error when it is not a supported Inno installer.
    Installer Inspect(const std::string& installerPath);

    struct ExtractOptions
    {
        std::string Installer;
        // Files that may be the installer's .bin slices; matched by name, ignoring case.
        std::vector<std::string> SliceCandidates;
        std::string Destination;
        // Called with the path below the application folder, using '/' separators.
        std::function<bool(const std::string& path)> Wanted;
        std::function<void(double fraction)> Progress;
        std::function<bool()> Cancelled;
    };

    // Slice names from Inspect() that none of the candidates provides.
    std::vector<std::string> MissingSlices(const Installer& installer, const std::vector<std::string>& candidates);

    // Writes the wanted files of the application folder below Destination; returns how many.
    size_t Extract(const ExtractOptions& options);
} // namespace OpenRCT2::Inno
