/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#pragma once

#ifdef OPENRCT2_METAL

    #include <cstdint>
    #include <cstdlib>
    #include <cstring>

namespace OpenRCT2::Ui::Metal
{
    enum class RasterMode
    {
        // Destination-independent commands latest-first with depth writes, then
        // destination-dependent commands in order with a read-only depth test (default).
        twoPass,
        // Every command in submission order through the programmable-blending pipeline.
        singlePass,
    };

    // Developer switches for the Metal renderer. They are read once, from the launch
    // environment (Xcode scheme → Run → Arguments), and only exist for validation and
    // profiling; normal builds use the defaults.
    //
    //   OPENRCT2_METAL_COMPARE_GPU=1     Also draw every frame with the reference compute
    //                                    rasterizer and compare indices pixel by pixel.
    //   OPENRCT2_METAL_RASTER=single     Use RasterMode::singlePass.
    //   OPENRCT2_METAL_FULL_REDRAW=1     Ignore dirty regions; redraw every frame.
    //   OPENRCT2_METAL_SERIAL=1          Do not offer parallel viewport drawing.
    //   OPENRCT2_METAL_DIRTY_BLOCK=n     Dirty-region block size in logical pixels (16-256).
    struct DebugOptions
    {
        bool compareWithReference{};
        RasterMode rasterMode{ RasterMode::twoPass };
        bool fullRedraw{};
        bool serialDrawing{};
        uint32_t dirtyBlockSize{};

        static const DebugOptions& Get()
        {
            static const DebugOptions options = [] {
                DebugOptions result;
                result.compareWithReference = std::getenv("OPENRCT2_METAL_COMPARE_GPU") != nullptr;
                const char* raster = std::getenv("OPENRCT2_METAL_RASTER");
                if (raster != nullptr && std::strcmp(raster, "single") == 0)
                    result.rasterMode = RasterMode::singlePass;
                result.fullRedraw = std::getenv("OPENRCT2_METAL_FULL_REDRAW") != nullptr;
                result.serialDrawing = std::getenv("OPENRCT2_METAL_SERIAL") != nullptr;
                if (const char* block = std::getenv("OPENRCT2_METAL_DIRTY_BLOCK"))
                    result.dirtyBlockSize = static_cast<uint32_t>(std::strtoul(block, nullptr, 10));
                return result;
            }();
            return options;
        }
    };
} // namespace OpenRCT2::Ui::Metal

#endif
