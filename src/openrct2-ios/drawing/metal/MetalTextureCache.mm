/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_METAL

    #include "MetalTextureCache.h"

    #include "MetalShaderTypes.h"

    #include <algorithm>
    #include <bit>
    #include <cstring>
    #include <openrct2/Diagnostic.h>
    #include <openrct2/core/EnumUtils.hpp>
    #include <openrct2/drawing/BlendColourMap.h>
    #include <openrct2/drawing/Drawing.Sprite.h>
    #include <openrct2/drawing/Drawing.h>
    #include <openrct2/drawing/G1Element.h>
    #include <openrct2/drawing/PaletteMap.h>

using namespace OpenRCT2;
using namespace OpenRCT2::Drawing;
using namespace OpenRCT2::Ui::Metal;

namespace
{
    constexpr uint32_t kInitialAtlasLayers = 4;
    // Soft budget: above it, images unused for kImageMaxAge frames are released.
    constexpr uint32_t kAtlasLayerBudget = 12;
    // Hard limit (8 MiB per layer). Reaching it forces a full atlas reset at the next frame.
    constexpr uint32_t kMaxAtlasLayers = 32;
    constexpr uint32_t kImageMaxAge = 600;
    constexpr uint32_t kBitmapMaxAge = 300;
    constexpr size_t kMaxBitmaps = 4096;
    constexpr uint32_t kInitialPaletteRows = 1024;
    constexpr uint32_t kMaxPaletteRows = 8192;
    constexpr size_t kMaxDynamicPalettes = 1536;
    constexpr uint32_t kBlendRows = 256;

    id<MTLTexture> CreateAtlasTexture(id<MTLDevice> device, uint32_t layers)
    {
        auto descriptor = [MTLTextureDescriptor new];
        descriptor.textureType = MTLTextureType2DArray;
        descriptor.pixelFormat = MTLPixelFormatR16Uint;
        descriptor.width = AtlasAllocator::kLayerSize;
        descriptor.height = AtlasAllocator::kLayerSize;
        descriptor.arrayLength = layers;
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageShaderRead;
        auto texture = [device newTextureWithDescriptor:descriptor];
        texture.label = @"OpenRCT2 sprite and text atlas";
        return texture;
    }

    id<MTLTexture> CreateIndexTexture(id<MTLDevice> device, uint32_t width, uint32_t height, NSString* label)
    {
        auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                                                             width:width
                                                                            height:height
                                                                         mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageShaderRead;
        auto texture = [device newTextureWithDescriptor:descriptor];
        texture.label = label;
        return texture;
    }
} // namespace

uint64_t OpenRCT2::Ui::Metal::HashBytes(const void* data, size_t length, uint64_t seed)
{
    // 64-bit multiply-xorshift over 8-byte words; collisions are additionally guarded by the
    // callers that keep content for verification.
    constexpr uint64_t kMultiplier = 0x9E3779B97F4A7C15ull;
    uint64_t hash = seed ^ (length * kMultiplier);
    const auto* bytes = static_cast<const uint8_t*>(data);
    size_t i = 0;
    for (; i + 8 <= length; i += 8)
    {
        uint64_t word;
        std::memcpy(&word, bytes + i, sizeof(word));
        hash = (hash ^ word) * kMultiplier;
        hash ^= hash >> 29;
    }
    uint64_t tail = 0;
    std::memcpy(&tail, bytes + i, length - i);
    hash = (hash ^ tail) * kMultiplier;
    return hash ^ (hash >> 32);
}

// ---------------------------------------------------------------------------------------
// AtlasAllocator

uint32_t AtlasAllocator::ClassSize(int32_t size)
{
    return std::bit_ceil(static_cast<uint32_t>(std::max(size, kSmallestSlot)));
}

std::optional<AtlasAllocator::Slot> AtlasAllocator::Allocate(int32_t width, int32_t height, uint32_t maxLayers)
{
    if (width <= 0 || height <= 0 || width > kLayerSize || height > kLayerSize)
        return std::nullopt;
    const auto classWidth = ClassSize(width);
    const auto classHeight = ClassSize(height);
    auto& sizeClass = _classes[(std::countr_zero(classWidth) << 8) | std::countr_zero(classHeight)];
    _usedTexels += static_cast<uint64_t>(classWidth) * classHeight;

    if (!sizeClass.freeSlots.empty())
    {
        auto slot = sizeClass.freeSlots.back();
        sizeClass.freeSlots.pop_back();
        return slot;
    }
    while (!sizeClass.shelves.empty())
    {
        auto& shelf = _shelves[sizeClass.shelves.back()];
        if (shelf.nextX + classWidth <= static_cast<uint32_t>(kLayerSize))
        {
            Slot slot{ shelf.layer, shelf.nextX, shelf.y };
            shelf.nextX += classWidth;
            return slot;
        }
        sizeClass.shelves.pop_back();
    }
    // Open a new shelf in the first layer with enough vertical space.
    auto layer = std::find_if(_layerTop.begin(), _layerTop.end(), [classHeight](uint16_t top) {
        return top + classHeight <= static_cast<uint32_t>(kLayerSize);
    });
    if (layer == _layerTop.end())
    {
        if (_layerTop.size() >= maxLayers)
        {
            _usedTexels -= static_cast<uint64_t>(classWidth) * classHeight;
            return std::nullopt;
        }
        _layerTop.push_back(0);
        layer = _layerTop.end() - 1;
    }
    Shelf shelf{ static_cast<uint16_t>(layer - _layerTop.begin()), *layer, static_cast<uint16_t>(classWidth) };
    *layer += classHeight;
    _shelves.push_back(shelf);
    sizeClass.shelves.push_back(static_cast<uint32_t>(_shelves.size() - 1));
    return Slot{ shelf.layer, 0, shelf.y };
}

void AtlasAllocator::Free(const Slot& slot, int32_t width, int32_t height)
{
    const auto classWidth = ClassSize(width);
    const auto classHeight = ClassSize(height);
    _classes[(std::countr_zero(classWidth) << 8) | std::countr_zero(classHeight)].freeSlots.push_back(slot);
    _usedTexels -= static_cast<uint64_t>(classWidth) * classHeight;
}

void AtlasAllocator::Reset()
{
    _classes.clear();
    _shelves.clear();
    _layerTop.clear();
    _usedTexels = 0;
}

// ---------------------------------------------------------------------------------------
// TextureCache

TextureCache::TextureCache(id<MTLDevice> device)
    : _device(device)
{
    _atlasLayers = kInitialAtlasLayers;
    _atlas = CreateAtlasTexture(device, _atlasLayers);
    _paletteRows = kInitialPaletteRows;
    _palettes = CreateIndexTexture(device, kPaletteRowWidth, _paletteRows, @"OpenRCT2 palette maps");
    _blend = CreateIndexTexture(device, kPaletteRowWidth, kBlendRows, @"OpenRCT2 TrueType blend table");

    // Row 0: identity map, used by images whose remap palette does not exist.
    std::array<uint8_t, 256> identity;
    for (size_t i = 0; i < identity.size(); ++i)
        identity[i] = static_cast<uint8_t>(i);
    StagePaletteRows(0, identity.data(), identity.size());
}

void TextureCache::BeginFrame(uint64_t frame)
{
    _frame = static_cast<uint32_t>(frame);
    // Slots freed while the previous frame was recorded may still have been referenced by its
    // commands; they only become reusable now.
    for (const auto& pending : _pendingFree)
        _allocator.Free(pending.slot, pending.width, pending.height);
    _pendingFree.clear();

    if (_resetRequested)
    {
        ResetAtlas();
        _resetRequested = false;
    }
    if ((_frame & 63) == 0)
        EvictBitmaps(kBitmapMaxAge, kMaxBitmaps);
    else if (_bitmaps.size() > kMaxBitmaps)
        EvictBitmaps(kBitmapMaxAge, kMaxBitmaps);
    if (_allocator.GetLayerCount() > kAtlasLayerBudget && (_frame & 63) == 0)
        EvictImages(kImageMaxAge);
    if (_dynamicPalettes.size() > kMaxDynamicPalettes)
        EvictPalettes();
}

std::optional<AtlasAllocator::Slot> TextureCache::AllocateSlot(int32_t width, int32_t height)
{
    auto slot = _allocator.Allocate(width, height, kMaxAtlasLayers);
    if (!slot)
    {
        // Fragmentation or a working set beyond the hard limit: rebuild from scratch next frame.
        if (!_resetRequested)
            LOG_WARNING("Metal atlas exhausted (%u layers); it will be rebuilt", _allocator.GetLayerCount());
        _resetRequested = true;
    }
    return slot;
}

uint16_t* TextureCache::StageAtlas(const AtlasAllocator::Slot& slot, int32_t width, int32_t height)
{
    const size_t offset = (_staging.size() + 3) & ~size_t{ 3 };
    const size_t bytes = static_cast<size_t>(width) * height * sizeof(uint16_t);
    _staging.resize(offset + bytes);
    _uploads.push_back(
        { offset, static_cast<uint32_t>(width * sizeof(uint16_t)), slot.x, slot.y, static_cast<uint16_t>(width),
          static_cast<uint16_t>(height), slot.layer, UploadTarget::atlas });
    auto* pixels = reinterpret_cast<uint16_t*>(_staging.data() + offset);
    std::fill_n(pixels, static_cast<size_t>(width) * height, uint16_t{ 0 });
    return pixels;
}

ImageInterior TextureCache::FindInterior(const uint16_t* texels, int32_t width, int32_t height)
{
    // Bands of rows sharing a fully opaque interval: each row contributes its longest run of
    // covered, non-zero texels; a band closes when the common interval would shrink below 3/4
    // of its widest member. The largest bands are kept.
    struct Band
    {
        int32_t begin, end, top, bottom;
    };
    std::vector<Band> bands;
    Band current{ 0, 0, 0, 0 };
    int32_t widest = 0;
    auto close = [&](int32_t row) {
        if (current.end - current.begin >= 2 && row > current.top)
        {
            current.bottom = row;
            bands.push_back(current);
        }
        widest = 0;
        current = { 0, 0, row, row };
    };
    for (int32_t y = 0; y < height; ++y)
    {
        int32_t bestBegin = 0, bestEnd = 0;
        for (int32_t x = 0; x < width;)
        {
            const auto texel = texels[y * width + x];
            if ((texel & kAtlasCoverage) == 0 || (texel & kAtlasIndexMask) == 0)
            {
                ++x;
                continue;
            }
            const int32_t begin = x;
            while (x < width && (texels[y * width + x] & kAtlasCoverage) != 0 && (texels[y * width + x] & kAtlasIndexMask) != 0)
                ++x;
            if (x - begin > bestEnd - bestBegin)
            {
                bestBegin = begin;
                bestEnd = x;
            }
        }
        if (bestEnd - bestBegin < 2)
        {
            close(y + 1);
            continue;
        }
        if (current.end == current.begin)
        {
            current = { bestBegin, bestEnd, y, y };
            widest = bestEnd - bestBegin;
            continue;
        }
        const int32_t begin = std::max(current.begin, bestBegin);
        const int32_t end = std::min(current.end, bestEnd);
        const int32_t candidateWidest = std::max(widest, bestEnd - bestBegin);
        if (end - begin >= 2 && (end - begin) * 4 >= candidateWidest * 3)
        {
            current.begin = begin;
            current.end = end;
            widest = candidateWidest;
        }
        else
        {
            close(y);
            current = { bestBegin, bestEnd, y, y };
            widest = bestEnd - bestBegin;
        }
    }
    close(height);
    std::sort(bands.begin(), bands.end(), [](const Band& a, const Band& b) {
        return (a.end - a.begin) * (a.bottom - a.top) > (b.end - b.begin) * (b.bottom - b.top);
    });
    ImageInterior interior;
    for (const auto& band : bands)
    {
        if (interior.count == ImageInterior::kMaxRects)
            break;
        interior.rects[interior.count++] = { static_cast<uint16_t>(band.begin), static_cast<uint16_t>(band.top),
                                             static_cast<uint16_t>(band.end), static_cast<uint16_t>(band.bottom) };
    }
    return interior;
}

bool TextureCache::IsZeroFree(const uint8_t* data, size_t length)
{
    if (length < 256)
        return false;
    for (size_t i = 1; i < 256; ++i)
        if (data[i] == 0)
            return false;
    return true;
}

AtlasRegion TextureCache::GetImage(ImageIndex image, ImageInterior* interior)
{
    if (image >= _images.size())
    {
        if (image >= (1u << 24))
            return {};
        _images.resize(std::max<size_t>(image + 1, _images.size() * 3 / 2));
    }
    auto& entry = _images[image];
    if (entry.state == ImageState::cached)
    {
        entry.lastUsed = _frame;
        if (interior != nullptr)
            *interior = entry.interior;
        return entry.region;
    }
    if (entry.state == ImageState::notDrawable)
        return {};

    const auto* g1 = GfxGetG1Element(image);
    if (g1 == nullptr || g1->width <= 0 || g1->height <= 0 || g1->flags.has(G1Flag::isPalette)
        || (!g1->flags.has(G1Flag::hasRLECompression) && g1->flags.has(G1Flag::one)))
    {
        entry.state = ImageState::notDrawable;
        return {};
    }
    const int32_t width = g1->width;
    const int32_t height = g1->height;
    auto slot = AllocateSlot(width, height);
    if (!slot)
        return {};

    // Decode source assets only; no screen pixels are composed on the CPU. The coverage bit
    // keeps RLE holes distinct from palette index 0.
    auto* output = StageAtlas(*slot, width, height);
    if (g1->flags.has(G1Flag::hasRLECompression))
    {
        for (int32_t y = 0; y < height; ++y)
        {
            const uint8_t* run = g1->offset + (g1->offset[y * 2] | (g1->offset[y * 2 + 1] << 8));
            bool last = false;
            do
            {
                uint8_t length = *run++;
                const uint8_t start = *run++;
                last = (length & 0x80) != 0;
                length &= 0x7f;
                for (int32_t x = 0; x < length && x + start < width; ++x)
                    output[y * width + x + start] = static_cast<uint16_t>(kAtlasCoverage | run[x]);
                run += length;
            } while (!last);
        }
    }
    else
    {
        for (size_t i = 0; i < static_cast<size_t>(width) * height; ++i)
            output[i] = static_cast<uint16_t>(kAtlasCoverage | g1->offset[i]);
    }

    entry.slot = *slot;
    entry.region = { slot->layer, slot->x, slot->y, static_cast<uint16_t>(width), static_cast<uint16_t>(height) };
    entry.state = ImageState::cached;
    entry.lastUsed = _frame;
    entry.interior = FindInterior(output, width, height);
    if (interior != nullptr)
        *interior = entry.interior;
    return entry.region;
}

void TextureCache::InvalidateImage(ImageIndex image)
{
    std::scoped_lock lock(_mutex);
    if (image >= _images.size())
        return;
    auto& entry = _images[image];
    if (entry.state == ImageState::cached)
        _pendingFree.push_back({ entry.slot, entry.region.width, entry.region.height });
    entry.state = ImageState::unknown;
}

std::optional<AtlasRegion> TextureCache::FindBitmap(uint64_t key)
{
    auto found = _bitmaps.find(key);
    if (found == _bitmaps.end())
        return std::nullopt;
    found->second.lastUsed = _frame;
    return found->second.region;
}

AtlasRegion TextureCache::AddBitmap(uint64_t key, const uint8_t* coverage, int32_t width, int32_t height, size_t pitch)
{
    auto slot = AllocateSlot(width, height);
    if (!slot)
        return {};
    auto* output = StageAtlas(*slot, width, height);
    for (int32_t y = 0; y < height; ++y)
        for (int32_t x = 0; x < width; ++x)
            output[y * width + x] = static_cast<uint16_t>(kAtlasCoverage | coverage[y * pitch + x]);
    AtlasRegion region{ slot->layer, slot->x, slot->y, static_cast<uint16_t>(width), static_cast<uint16_t>(height) };
    _bitmaps[key] = { region, *slot, _frame };
    return region;
}

void TextureCache::EvictBitmaps(uint32_t maxAge, size_t maxCount)
{
    std::vector<std::pair<uint32_t, uint64_t>> byAge;
    for (auto it = _bitmaps.begin(); it != _bitmaps.end();)
    {
        if (_frame - it->second.lastUsed > maxAge)
        {
            _allocator.Free(it->second.slot, it->second.region.width, it->second.region.height);
            it = _bitmaps.erase(it);
        }
        else
        {
            if (_bitmaps.size() > maxCount)
                byAge.emplace_back(it->second.lastUsed, it->first);
            ++it;
        }
    }
    if (_bitmaps.size() <= maxCount)
        return;
    // Still over the limit: drop the least recently used, but never anything used this frame.
    std::sort(byAge.begin(), byAge.end());
    const size_t target = maxCount * 3 / 4;
    for (const auto& [lastUsed, key] : byAge)
    {
        if (_bitmaps.size() <= target || lastUsed == _frame)
            break;
        auto found = _bitmaps.find(key);
        _allocator.Free(found->second.slot, found->second.region.width, found->second.region.height);
        _bitmaps.erase(found);
    }
}

void TextureCache::EvictImages(uint32_t maxAge)
{
    size_t evicted = 0;
    for (auto& entry : _images)
    {
        if (entry.state == ImageState::cached && _frame - entry.lastUsed > maxAge)
        {
            _allocator.Free(entry.slot, entry.region.width, entry.region.height);
            entry.state = ImageState::unknown;
            ++evicted;
        }
    }
    if (evicted != 0)
        LOG_VERBOSE("Metal atlas released %zu idle images", evicted);
}

void TextureCache::ResetAtlas()
{
    for (auto& entry : _images)
        if (entry.state == ImageState::cached)
            entry.state = ImageState::unknown;
    _bitmaps.clear();
    _allocator.Reset();
    LOG_INFO("Metal atlas reset");
}

// ---------------------------------------------------------------------------------------
// Palette maps

std::optional<uint16_t> TextureCache::AllocateRows(uint32_t count)
{
    if (count == 1 && !_freeRows.empty())
    {
        auto row = _freeRows.back();
        _freeRows.pop_back();
        return row;
    }
    if (_nextRow + count > kMaxPaletteRows)
        return std::nullopt;
    auto row = static_cast<uint16_t>(_nextRow);
    _nextRow += count;
    return row;
}

void TextureCache::StagePaletteRows(uint16_t row, const uint8_t* data, size_t length)
{
    const uint32_t rows = static_cast<uint32_t>((length + kPaletteRowWidth - 1) / kPaletteRowWidth);
    const size_t offset = (_staging.size() + 3) & ~size_t{ 3 };
    _staging.resize(offset + rows * kPaletteRowWidth);
    std::memcpy(_staging.data() + offset, data, length);
    std::fill(_staging.begin() + offset + length, _staging.end(), uint8_t{ 0 });
    _uploads.push_back(
        { offset, kPaletteRowWidth, 0, row, static_cast<uint16_t>(kPaletteRowWidth), static_cast<uint16_t>(rows), 0,
          UploadTarget::palettes });
}

std::optional<PaletteRow> TextureCache::GetFilterPalette(FilterPaletteID palette)
{
    const auto id = static_cast<uint32_t>(EnumValue(palette));
    if (id >= _staticPalettes.size())
        return std::nullopt;
    auto map = GetPaletteMapForColour(palette);
    if (!map)
        return std::nullopt;
    const auto data = map->GetData();
    auto& entry = _staticPalettes[id];
    // Filter palettes are g1 images: stable unless the graphics are reloaded, which also
    // replaces the data pointer.
    if (entry.resolved && entry.data == data.data() && entry.row.length == data.size())
        return entry.row;
    const auto rows = static_cast<uint32_t>((data.size() + kPaletteRowWidth - 1) / kPaletteRowWidth);
    auto row = AllocateRows(rows);
    if (!row)
        return std::nullopt;
    const auto* bytes = reinterpret_cast<const uint8_t*>(data.data());
    StagePaletteRows(*row, bytes, data.size());
    entry = { data.data(), { *row, static_cast<uint32_t>(data.size()), IsZeroFree(bytes, data.size()) }, true };
    return entry.row;
}

std::optional<PaletteRow> TextureCache::GetDynamicPalette(uint64_t key, const uint8_t* data, size_t length)
{
    auto found = _dynamicPalettes.find(key);
    if (found != _dynamicPalettes.end())
    {
        auto& entry = found->second;
        if (entry.length == length && std::memcmp(entry.content.data(), data, length) == 0)
        {
            entry.lastUsed = _frame;
            return PaletteRow{ entry.row, entry.length, entry.zeroFree };
        }
    }
    auto row = AllocateRows(1);
    if (!row)
    {
        LOG_WARNING("Metal palette-map texture is full");
        return std::nullopt;
    }
    StagePaletteRows(*row, data, length);
    if (found != _dynamicPalettes.end())
    {
        // Hash collision with different content: keep the existing entry, use an uncached row.
        _freeRowsNextFrame.push_back(*row);
        return PaletteRow{ *row, static_cast<uint32_t>(length), IsZeroFree(data, length) };
    }
    DynamicPalette entry;
    std::memcpy(entry.content.data(), data, length);
    entry.length = static_cast<uint16_t>(length);
    entry.row = *row;
    entry.lastUsed = _frame;
    entry.zeroFree = IsZeroFree(data, length);
    _dynamicPalettes.emplace(key, entry);
    return PaletteRow{ *row, static_cast<uint32_t>(length), entry.zeroFree };
}

std::optional<PaletteRow> TextureCache::FindKeyedPalette(uint32_t key)
{
    auto found = _dynamicPalettes.find((uint64_t{ 1 } << 63) | key);
    if (found == _dynamicPalettes.end())
        return std::nullopt;
    found->second.lastUsed = _frame;
    return PaletteRow{ found->second.row, found->second.length, found->second.zeroFree };
}

std::optional<PaletteRow> TextureCache::AddKeyedPalette(uint32_t key, const PaletteMap& map)
{
    const auto data = map.GetData();
    return GetDynamicPalette(
        (uint64_t{ 1 } << 63) | key, reinterpret_cast<const uint8_t*>(data.data()), std::min<size_t>(data.size(), 256));
}

std::optional<PaletteRow> TextureCache::GetPaletteMap(const PaletteMap& map)
{
    const auto data = map.GetData();
    if (data.size() > kPaletteRowWidth)
        return std::nullopt;
    const auto* bytes = reinterpret_cast<const uint8_t*>(data.data());
    return GetDynamicPalette(HashBytes(bytes, data.size()) & ~(uint64_t{ 1 } << 63), bytes, data.size());
}

void TextureCache::EvictPalettes()
{
    std::vector<std::pair<uint32_t, uint64_t>> byAge;
    byAge.reserve(_dynamicPalettes.size());
    for (const auto& [key, entry] : _dynamicPalettes)
        byAge.emplace_back(entry.lastUsed, key);
    std::sort(byAge.begin(), byAge.end());
    const size_t target = kMaxDynamicPalettes * 3 / 4;
    for (const auto& [lastUsed, key] : byAge)
    {
        if (_dynamicPalettes.size() <= target)
            break;
        auto found = _dynamicPalettes.find(key);
        _freeRows.push_back(found->second.row);
        _dynamicPalettes.erase(found);
    }
}

void TextureCache::EnsureBlendTable()
{
    #ifndef DISABLE_TTF
    if (_blendUploaded)
        return;
    const auto* blend = GetBlendColourMap();
    if (blend == nullptr)
        return;
    const size_t offset = (_staging.size() + 3) & ~size_t{ 3 };
    _staging.resize(offset + sizeof(*blend));
    std::memcpy(_staging.data() + offset, blend->data(), sizeof(*blend));
    _uploads.push_back(
        { offset, kPaletteRowWidth, 0, 0, static_cast<uint16_t>(kPaletteRowWidth), static_cast<uint16_t>(kBlendRows), 0,
          UploadTarget::blend });
    _blendUploaded = true;
    #endif
}

// ---------------------------------------------------------------------------------------
// Upload encoding

bool TextureCache::Flush(id<MTLCommandBuffer> commandBuffer, uint32_t slot)
{
    // Hash-collision rows were only valid for the frame just recorded.
    _freeRows.insert(_freeRows.end(), _freeRowsNextFrame.begin(), _freeRowsNextFrame.end());
    _freeRowsNextFrame.clear();

    const bool growAtlas = _allocator.GetLayerCount() > _atlasLayers;
    const bool growPalettes = _nextRow > _paletteRows;
    if (_uploads.empty() && !growAtlas && !growPalettes)
        return true;

    auto blit = [commandBuffer blitCommandEncoder];
    blit.label = @"OpenRCT2 texture uploads";
    if (growAtlas)
    {
        auto layers = _atlasLayers;
        while (layers < _allocator.GetLayerCount())
            layers *= 2;
        layers = std::min(layers, kMaxAtlasLayers);
        auto atlas = CreateAtlasTexture(_device, layers);
        if (atlas == nil)
        {
            [blit endEncoding];
            LOG_ERROR("Unable to grow the Metal atlas to %u layers", layers);
            _resetRequested = true;
            return false;
        }
        for (uint32_t layer = 0; layer < _atlasLayers; ++layer)
            [blit copyFromTexture:_atlas
                      sourceSlice:layer
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(AtlasAllocator::kLayerSize, AtlasAllocator::kLayerSize, 1)
                        toTexture:atlas
                 destinationSlice:layer
                 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
        LOG_INFO("Metal atlas grown to %u layers", layers);
        _atlas = atlas;
        _atlasLayers = layers;
    }
    if (growPalettes)
    {
        auto rows = _paletteRows;
        while (rows < _nextRow)
            rows *= 2;
        auto palettes = CreateIndexTexture(_device, kPaletteRowWidth, rows, @"OpenRCT2 palette maps");
        if (palettes == nil)
        {
            [blit endEncoding];
            LOG_ERROR("Unable to grow the Metal palette-map texture");
            return false;
        }
        [blit copyFromTexture:_palettes
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(kPaletteRowWidth, _paletteRows, 1)
                    toTexture:palettes
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        _palettes = palettes;
        _paletteRows = rows;
    }

    if (!_uploads.empty())
    {
        auto& staging = _stagingBuffers[slot % _stagingBuffers.size()];
        if (staging == nil || staging.length < _staging.size())
        {
            staging = [_device newBufferWithLength:std::bit_ceil(std::max<size_t>(_staging.size(), 1 << 16))
                                           options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
            if (staging == nil)
            {
                [blit endEncoding];
                LOG_ERROR("Unable to allocate %zu bytes of Metal upload staging", _staging.size());
                return false;
            }
            staging.label = @"OpenRCT2 upload staging";
        }
        std::memcpy(staging.contents, _staging.data(), _staging.size());
        for (const auto& upload : _uploads)
        {
            id<MTLTexture> target = upload.target == UploadTarget::atlas
                ? _atlas
                : (upload.target == UploadTarget::palettes ? _palettes : _blend);
            [blit copyFromBuffer:staging
                       sourceOffset:upload.offset
                  sourceBytesPerRow:upload.bytesPerRow
                sourceBytesPerImage:static_cast<NSUInteger>(upload.bytesPerRow) * upload.height
                         sourceSize:MTLSizeMake(upload.width, upload.height, 1)
                          toTexture:target
                   destinationSlice:upload.layer
                   destinationLevel:0
                  destinationOrigin:MTLOriginMake(upload.x, upload.y, 0)];
        }
        _uploads.clear();
        _staging.clear();
    }
    [blit endEncoding];
    return true;
}

TextureCacheStats TextureCache::GetStats() const
{
    TextureCacheStats stats;
    stats.images = static_cast<size_t>(std::count_if(
        _images.begin(), _images.end(), [](const ImageEntry& entry) { return entry.state == ImageState::cached; }));
    stats.bitmaps = _bitmaps.size();
    stats.dynamicPalettes = _dynamicPalettes.size();
    stats.atlasLayers = _atlasLayers;
    stats.usedTexels = _allocator.GetUsedTexels();
    return stats;
}

#endif
