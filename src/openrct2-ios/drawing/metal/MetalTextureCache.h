/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#pragma once

#ifdef OPENRCT2_METAL

    #import <Metal/Metal.h>
    #include <array>
    #include <cstddef>
    #include <cstdint>
    #include <openrct2/drawing/FilterPaletteIds.h>
    #include <openrct2/drawing/ImageIndexType.h>
    #include <mutex>
    #include <optional>
    #include <unordered_map>
    #include <vector>

namespace OpenRCT2::Drawing
{
    struct PaletteMap;
}

namespace OpenRCT2::Ui::Metal
{
    // Location of an image inside the atlas texture array.
    struct AtlasRegion
    {
        uint16_t layer{};
        uint16_t x{};
        uint16_t y{};
        uint16_t width{};
        uint16_t height{};

        bool IsValid() const noexcept
        {
            return width != 0 && height != 0;
        }
    };

    // A palette map stored in the palette texture: mapLength entries from row mapRow onwards.
    struct PaletteRow
    {
        uint16_t row{};
        uint32_t length{};
    };

    struct TextureCacheStats
    {
        size_t images{};
        size_t bitmaps{};
        size_t dynamicPalettes{};
        uint32_t atlasLayers{};
        uint64_t usedTexels{};
    };

    // Shelf allocator for one atlas texture array. Every slot belongs to a power-of-two size
    // class; each shelf (a horizontal strip of one layer) holds slots of a single class, and
    // freed slots return to their class's free list. This packs typical isometric sprites
    // much more tightly than square slots while keeping reuse O(1).
    class AtlasAllocator final
    {
    public:
        static constexpr int32_t kLayerSize = 2048;
        static constexpr int32_t kSmallestSlot = 8;

        struct Slot
        {
            uint16_t layer;
            uint16_t x;
            uint16_t y;
        };

        std::optional<Slot> Allocate(int32_t width, int32_t height, uint32_t maxLayers);
        void Free(const Slot& slot, int32_t width, int32_t height);
        void Reset();

        uint32_t GetLayerCount() const noexcept
        {
            return static_cast<uint32_t>(_layerTop.size());
        }
        uint64_t GetUsedTexels() const noexcept
        {
            return _usedTexels;
        }
        static uint32_t ClassSize(int32_t size);

    private:
        struct Shelf
        {
            uint16_t layer;
            uint16_t y;
            uint16_t nextX;
        };
        struct SizeClass
        {
            std::vector<Slot> freeSlots;
            std::vector<uint32_t> shelves; // Shelves that may still have room.
        };

        std::unordered_map<uint32_t, SizeClass> _classes;
        std::vector<Shelf> _shelves;
        std::vector<uint16_t> _layerTop;
        uint64_t _usedTexels{};
    };

    // GPU resources referenced by draw commands: the R16Uint sprite/text atlas, the palette-map
    // texture and the TrueType blend table. All CPU writes are staged and encoded as blits at
    // the start of the frame's command buffer, so they are ordered after earlier frames that may
    // still read reused slots. Nothing is evicted while a frame is being recorded.
    class TextureCache final
    {
    public:
        explicit TextureCache(id<MTLDevice> device);

        // Eviction and budget enforcement. Call before recording a frame.
        void BeginFrame(uint64_t frame);
        // Encodes texture growth and staged uploads at the start of the frame's command buffer.
        // slot is the frame-in-flight index that owns this frame's staging buffer. Returns false
        // if staging failed; the frame must then be skipped.
        bool Flush(id<MTLCommandBuffer> commandBuffer, uint32_t slot);

        // Atlas images. Invalid regions mean "nothing to draw".
        AtlasRegion GetImage(ImageIndex image);
        // Coverage bitmaps (TrueType), keyed by a caller-provided content hash.
        std::optional<AtlasRegion> FindBitmap(uint64_t key);
        AtlasRegion AddBitmap(uint64_t key, const uint8_t* coverage, int32_t width, int32_t height, size_t pitch);
        // May be called while a frame is recorded, including from paint worker threads (the
        // scrolling-text cache). The slot is only reused after the frame has been submitted.
        void InvalidateImage(ImageIndex image);

        // Uploads the TrueType blend table on first use (it depends on the loaded palette).
        void EnsureBlendTable();

        PaletteRow GetIdentityPalette() const noexcept
        {
            return { 0, 256 };
        }
        std::optional<PaletteRow> GetFilterPalette(Drawing::FilterPaletteID palette);
        // Maps fully described by a small caller key (e.g. remap colours), so lookups need
        // neither hashing nor copying of the content.
        std::optional<PaletteRow> FindKeyedPalette(uint32_t key);
        std::optional<PaletteRow> AddKeyedPalette(uint32_t key, const Drawing::PaletteMap& map);
        // Arbitrary maps of up to 256 entries, keyed by content.
        std::optional<PaletteRow> GetPaletteMap(const Drawing::PaletteMap& map);

        // Serialises cache access while viewport columns are drawn in parallel.
        std::mutex& GetMutex()
        {
            return _mutex;
        }

        id<MTLTexture> GetAtlas() const
        {
            return _atlas;
        }
        id<MTLTexture> GetPalettes() const
        {
            return _palettes;
        }
        id<MTLTexture> GetBlend() const
        {
            return _blend;
        }
        TextureCacheStats GetStats() const;

        static constexpr size_t kFramesInFlight = 3;

    private:
        enum class ImageState : uint8_t
        {
            unknown,
            cached,
            notDrawable,
        };
        enum class UploadTarget : uint8_t
        {
            atlas,
            palettes,
            blend,
        };
        struct ImageEntry
        {
            AtlasRegion region;
            AtlasAllocator::Slot slot{};
            uint32_t lastUsed{};
            ImageState state{};
        };
        struct PendingFree
        {
            AtlasAllocator::Slot slot;
            int32_t width;
            int32_t height;
        };
        struct BitmapEntry
        {
            AtlasRegion region;
            AtlasAllocator::Slot slot{};
            uint32_t lastUsed{};
        };
        struct StaticPalette
        {
            const void* data{};
            PaletteRow row{};
            bool resolved{};
        };
        struct DynamicPalette
        {
            std::array<uint8_t, 256> content{};
            uint16_t length{};
            uint16_t row{};
            uint32_t lastUsed{};
        };
        struct Upload
        {
            size_t offset;
            uint32_t bytesPerRow;
            uint16_t x, y, width, height, layer;
            UploadTarget target;
        };

        id<MTLDevice> _device;
        id<MTLTexture> _atlas;
        id<MTLTexture> _palettes;
        id<MTLTexture> _blend;
        uint32_t _atlasLayers{};
        uint32_t _paletteRows{};
        AtlasAllocator _allocator;
        uint32_t _frame{};
        bool _resetRequested{};
        bool _blendUploaded{};

        std::vector<ImageEntry> _images;
        std::vector<PendingFree> _pendingFree;
        std::mutex _mutex;
        std::unordered_map<uint64_t, BitmapEntry> _bitmaps;

        std::array<StaticPalette, 256> _staticPalettes{};
        std::unordered_map<uint64_t, DynamicPalette> _dynamicPalettes;
        std::vector<uint16_t> _freeRows;
        std::vector<uint16_t> _freeRowsNextFrame;
        uint32_t _nextRow{ 1 };

        std::vector<uint8_t> _staging;
        std::vector<Upload> _uploads;
        std::array<id<MTLBuffer>, kFramesInFlight> _stagingBuffers;

        std::optional<AtlasAllocator::Slot> AllocateSlot(int32_t width, int32_t height);
        uint16_t* StageAtlas(const AtlasAllocator::Slot& slot, int32_t width, int32_t height);
        std::optional<uint16_t> AllocateRows(uint32_t count);
        void StagePaletteRows(uint16_t row, const uint8_t* data, size_t length);
        std::optional<PaletteRow> GetDynamicPalette(uint64_t key, const uint8_t* data, size_t length);
        void EvictBitmaps(uint32_t maxAge, size_t maxCount);
        void EvictImages(uint32_t maxAge);
        void EvictPalettes();
        void ResetAtlas();
    };

    uint64_t HashBytes(const void* data, size_t length, uint64_t seed = 0);
} // namespace OpenRCT2::Ui::Metal

#endif
