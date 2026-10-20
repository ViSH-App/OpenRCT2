/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#pragma once

#ifdef OPENRCT2_METAL

    #include "MetalShaderTypes.h"

    #include <atomic>
    #include <memory>
    #include <mutex>
    #include <openrct2/drawing/Font.h>
    #include <openrct2/drawing/IDrawingContext.h>
    #include <openrct2/drawing/IDrawingEngine.h>
    #include <openrct2/drawing/RenderTarget.h>
    #include <optional>
    #include <string>
    #include <vector>

namespace OpenRCT2::Ui::Metal
{
    class TextureCache;
    struct AtlasRegion;
    struct PaletteRow;

    // A canvas-to-canvas move in logical pixels (CopyRect).
    struct CopyOperation
    {
        int32_t x, y, width, height, dx, dy;
    };

    // Debug markers splitting a frame for OPENRCT2_METAL_VERIFY_DIRTY.
    enum class SegmentMarker : uint8_t
    {
        none,
        snapshotCanvas, // Read the canvas back after this segment.
        verifyCanvas,   // Draw this segment into the verification canvas from scratch.
    };

    // Commands of one frame in submission order, split where canvas copies must happen.
    struct RecordedFrame
    {
        struct Segment
        {
            uint32_t end;
            std::optional<CopyOperation> copy; // Applied after the segment's commands.
            SegmentMarker marker{};
        };
        std::vector<DrawCommand> commands;
        std::vector<Segment> segments;
    };

    // Records IDrawingContext calls as GPU commands. Pixel semantics follow
    // X8DrawingContext (X8DrawingEngine.cpp, Drawing.Sprite.*.cpp, BlitPixel): the canvas has
    // one pixel per logical pixel, and each samples its source at its top-left corner.
    //
    // While viewport columns are drawn in parallel each thread appends to its own list. Every
    // command takes a ticket from one atomic counter, so merging by ticket reproduces the
    // order each thread issued, and commands that are concurrent are in disjoint columns.
    class DrawingContext final : public Drawing::IDrawingContext
    {
    public:
        explicit DrawingContext(TextureCache& textureCache);
        ~DrawingContext() override;

        void SetTarget(const Drawing::RenderTarget& mainRT);
        void BeginFrame(bool threadSafe);
        void AddCopy(const CopyOperation& copy);
        void AddMarker(SegmentMarker marker);
        // Merges the per-thread lists. Valid until the next BeginFrame.
        RecordedFrame& EndFrame();
        bool IsActive() const noexcept
        {
            return _active;
        }

        void Clear(Drawing::RenderTarget& rt, Drawing::PaletteIndex colour) override;
        void FillRect(
            Drawing::RenderTarget& rt, Drawing::PaletteIndex colour, int32_t left, int32_t top, int32_t right,
            int32_t bottom, bool crossHatch = false) override;
        void FilterRect(
            Drawing::RenderTarget& rt, Drawing::FilterPaletteID palette, int32_t left, int32_t top, int32_t right,
            int32_t bottom) override;
        void DrawLine(Drawing::RenderTarget& rt, Drawing::PaletteIndex colour, const ScreenLine& line) override;
        void DrawSprite(Drawing::RenderTarget& rt, ImageId image, int32_t x, int32_t y) override;
        void DrawSpriteRawMasked(
            Drawing::RenderTarget& rt, int32_t x, int32_t y, ImageId maskImage, ImageId colourImage) override;
        void DrawSpriteSolid(
            Drawing::RenderTarget& rt, ImageId image, int32_t x, int32_t y, Drawing::PaletteIndex colour) override;
        void DrawGlyph(
            Drawing::RenderTarget& rt, ImageId image, int32_t x, int32_t y, const Drawing::PaletteMap& palette) override;
        void DrawTTFBitmap(
            Drawing::RenderTarget& rt, const Drawing::TextDrawInfo& info, TTFSurface* surface, int32_t x, int32_t y,
            uint8_t hintingThreshold) override;

    private:
        struct ThreadList
        {
            std::vector<DrawCommand> commands;
            std::vector<uint32_t> tickets;
        };
        struct Boundary
        {
            uint32_t ticket;
            std::optional<CopyOperation> copy;
            SegmentMarker marker{};
        };
        struct RemapInfo
        {
            uint32_t flags{};
            uint16_t row{};
            uint32_t length{};
            bool zeroFree{};
        };

        TextureCache& _textureCache;
        Drawing::RenderTarget _mainRT{};
        const uint64_t _generation;
        bool _active{};
        bool _threadSafe{};
        std::atomic<uint32_t> _ticket{};
        std::mutex _listsMutex;
        std::vector<std::unique_ptr<ThreadList>> _lists;
        std::vector<Boundary> _boundaries;
        RecordedFrame _frame;
        uint64_t _frameNumber{};

        ThreadList& LocalList();
        ScreenCoordsXY Origin(const Drawing::RenderTarget& rt) const;
        // Returns false if the command was clipped away.
        bool Push(const Drawing::RenderTarget& rt, DrawCommand command);
        std::unique_lock<std::mutex> LockCache();
        void DrawImage(
            Drawing::RenderTarget& rt, ImageId image, const ScreenCoordsXY& coords, const RemapInfo& remap);
        RemapInfo RemapForImage(ImageId image);
        void PushText(
            Drawing::RenderTarget& rt, const AtlasRegion& region, int32_t x, int32_t y, Drawing::PaletteIndex colour,
            uint8_t threshold);
        void PushTextPasses(
            Drawing::RenderTarget& rt, const Drawing::TextDrawInfo& info, const AtlasRegion& region, int32_t x,
            int32_t y, uint8_t threshold);
        void MergeLists();
    };
} // namespace OpenRCT2::Ui::Metal

#endif
