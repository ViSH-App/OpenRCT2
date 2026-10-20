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
    //   OPENRCT2_METAL_PARALLEL=1        Offer parallel viewport drawing (slower on the iPad mini
    //                                    measurements; see VALIDATION.md).
    //   OPENRCT2_METAL_INTERIOR=n        Opaque interior rectangles per sprite (0 disables).
    //   OPENRCT2_METAL_COARSEN=n         Re-merge dirty regions on a 64-pixel grid when they
    //                                    need more than n rectangles (0 never).
    //   OPENRCT2_METAL_DIRTY_BLOCK=n     Dirty-region block size in logical pixels (16-256).
    //   OPENRCT2_METAL_FULL_AREA=f       Redraw the whole screen instead when dirty regions cover
    //                                    at least this fraction of it (0-1).
    //   OPENRCT2_METAL_MAX_RECTS=n       ... or when they need more than n rectangles.
    //   OPENRCT2_METAL_DIRTY_PAD=n       Expand every invalidated rectangle by n logical pixels.
    //   OPENRCT2_METAL_VERIFY_DIRTY=1    Every 30th frame, redraw the whole screen into a second
    //                                    canvas within the same frame and compare it with the
    //                                    dirty-region canvas (detects missed invalidations).
    //   OPENRCT2_METAL_PROFILE=n         Fragment-shader profiling variant (see MetalShaders.metal).
    //   OPENRCT2_METAL_SHADED_SHOT=n     Every n drawn frames, save the shaded canvas (day-night and
    //                                    lights, without CRT) to Documents/metal-shaded-<frame>.png.
    struct DebugOptions
    {
        bool compareWithReference{};
        RasterMode rasterMode{ RasterMode::twoPass };
        bool fullRedraw{};
        bool parallelDrawing{};
        int32_t interiorRects{ -1 };
        int32_t coarsenRects{ -1 };
        uint32_t dirtyBlockSize{};
        float fullRedrawArea{ -1.0f };
        int32_t maxDirtyRects{ -1 };
        uint32_t profileMode{};
        bool verifyDirty{};
        uint32_t shadedShotInterval{};
        int32_t dirtyPad{ -1 };

        static const DebugOptions& Get()
        {
            static const DebugOptions options = [] {
                DebugOptions result;
                result.compareWithReference = std::getenv("OPENRCT2_METAL_COMPARE_GPU") != nullptr;
                const char* raster = std::getenv("OPENRCT2_METAL_RASTER");
                if (raster != nullptr && std::strcmp(raster, "single") == 0)
                    result.rasterMode = RasterMode::singlePass;
                result.fullRedraw = std::getenv("OPENRCT2_METAL_FULL_REDRAW") != nullptr;
                result.parallelDrawing = std::getenv("OPENRCT2_METAL_PARALLEL") != nullptr;
                if (const char* coarsen = std::getenv("OPENRCT2_METAL_COARSEN"))
                    result.coarsenRects = static_cast<int32_t>(std::strtol(coarsen, nullptr, 10));
                if (const char* interior = std::getenv("OPENRCT2_METAL_INTERIOR"))
                    result.interiorRects = static_cast<int32_t>(std::strtol(interior, nullptr, 10));
                if (const char* block = std::getenv("OPENRCT2_METAL_DIRTY_BLOCK"))
                    result.dirtyBlockSize = static_cast<uint32_t>(std::strtoul(block, nullptr, 10));
                if (const char* area = std::getenv("OPENRCT2_METAL_FULL_AREA"))
                    result.fullRedrawArea = std::strtof(area, nullptr);
                result.verifyDirty = std::getenv("OPENRCT2_METAL_VERIFY_DIRTY") != nullptr;
                if (const char* shot = std::getenv("OPENRCT2_METAL_SHADED_SHOT"))
                    result.shadedShotInterval = static_cast<uint32_t>(std::strtoul(shot, nullptr, 10));
                if (const char* pad = std::getenv("OPENRCT2_METAL_DIRTY_PAD"))
                    result.dirtyPad = static_cast<int32_t>(std::strtol(pad, nullptr, 10));
                if (const char* profile = std::getenv("OPENRCT2_METAL_PROFILE"))
                    result.profileMode = static_cast<uint32_t>(std::strtoul(profile, nullptr, 10));
                if (const char* rects = std::getenv("OPENRCT2_METAL_MAX_RECTS"))
                    result.maxDirtyRects = static_cast<int32_t>(std::strtol(rects, nullptr, 10));
                return result;
            }();
            return options;
        }
    };
} // namespace OpenRCT2::Ui::Metal

#endif
