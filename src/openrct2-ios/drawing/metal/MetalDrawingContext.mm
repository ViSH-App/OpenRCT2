/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_METAL

    #include "MetalDrawingContext.h"

    #include "MetalDebugOptions.h"
    #include "MetalTextureCache.h"

    #include <algorithm>
    #include <array>
    #include <cmath>
    #include <cstring>
    #include <openrct2/Diagnostic.h>
    #include <openrct2/config/Config.h>
    #include <openrct2/core/EnumUtils.hpp>
    #include <openrct2/drawing/Drawing.Sprite.h>
    #include <openrct2/drawing/Drawing.String.h>
    #include <openrct2/drawing/Drawing.h>
    #include <openrct2/drawing/Font.h>
    #include <openrct2/drawing/G1Element.h>
    #include <openrct2/drawing/PaletteMap.h>
    #include <openrct2/drawing/TTF.h>
    #include <openrct2/interface/ScreenCoords.hpp>
    #include <openrct2/platform/Platform.h>

using namespace OpenRCT2;
using namespace OpenRCT2::Drawing;
using namespace OpenRCT2::Ui::Metal;

namespace
{
    // Bitmap-cache key tags: core TTF surfaces (keyed by pixels) and Retina text (keyed by
    // font, size and string) share the atlas but never each other's keys.
    constexpr uint64_t kLogicalTextTag = uint64_t{ 1 } << 62;
    constexpr uint64_t kRetinaTextTag = uint64_t{ 1 } << 61;
    constexpr uint64_t kTagMask = kLogicalTextTag | kRetinaTextTag;
    // Keyed palette maps (TextureCache::FindKeyedPalette).
    constexpr uint32_t kKeySecondaryRemap = 1u << 24;
    constexpr uint32_t kKeySolidColour = 2u << 24;
    constexpr size_t kMaxRetinaFaces = 8;
    // Opaque interior rectangles emitted per sprite, and their minimum logical area.
    constexpr int32_t kMaxInteriorRects = 12;
    constexpr int32_t kMinInteriorArea = 24;
    // Length of each colour's remap range (Drawing.Sprite.cpp kPaletteLengthRemap).
    constexpr size_t kPaletteLengthRemap = 12;

    std::atomic<uint64_t> gNextGeneration{ 1 };

    struct ThreadSlot
    {
        uint64_t generation{};
        void* list{};
    };
    thread_local ThreadSlot tThreadSlot;

    int16_t ClampLogical(int32_t value)
    {
        return static_cast<int16_t>(std::clamp<int32_t>(value, INT16_MIN, INT16_MAX));
    }
} // namespace

DrawingContext::DrawingContext(TextureCache& textureCache)
    : _textureCache(textureCache)
    , _generation(gNextGeneration.fetch_add(1))
{
}

DrawingContext::~DrawingContext()
{
    #ifndef DISABLE_TTF
    for (auto& [key, face] : _retinaFaces)
        TTF_CloseFont(face.font);
    if (_ownsTTF)
        TTF_Quit();
    #endif
}

void DrawingContext::SetTarget(const RenderTarget& mainRT, uint32_t rasterWidth, uint32_t rasterHeight)
{
    _mainRT = mainRT;
    _density = std::max(
        static_cast<float>(rasterWidth) / std::max(mainRT.width, 1), static_cast<float>(rasterHeight) / std::max(mainRT.height, 1));
}

void DrawingContext::BeginFrame(bool threadSafe)
{
    _active = true;
    _threadSafe = threadSafe;
    _ticket.store(0, std::memory_order_relaxed);
    for (auto& list : _lists)
    {
        list->commands.clear();
        list->tickets.clear();
    }
    _boundaries.clear();
    ++_frameNumber;
}

void DrawingContext::AddCopy(const CopyOperation& copy)
{
    _boundaries.push_back({ _ticket.load(std::memory_order_relaxed), copy, SegmentMarker::none });
}

void DrawingContext::AddMarker(SegmentMarker marker)
{
    _boundaries.push_back({ _ticket.load(std::memory_order_relaxed), std::nullopt, marker });
}

RecordedFrame& DrawingContext::EndFrame()
{
    _active = false;
    MergeLists();
    return _frame;
}

void DrawingContext::MergeLists()
{
    _frame.commands.clear();
    _frame.segments.clear();
    std::vector<std::pair<const ThreadList*, size_t>> heads;
    for (const auto& list : _lists)
        if (!list->commands.empty())
            heads.emplace_back(list.get(), 0);
    size_t total = 0;
    for (const auto& [list, position] : heads)
        total += list->commands.size();
    _frame.commands.reserve(total);

    size_t boundary = 0;
    for (;;)
    {
        // Pick the earliest ticket among the thread lists (usually there is only one list).
        size_t best = heads.size();
        uint32_t ticket = UINT32_MAX;
        for (size_t i = 0; i < heads.size(); ++i)
        {
            const auto& [list, position] = heads[i];
            if (position < list->tickets.size() && list->tickets[position] < ticket)
            {
                ticket = list->tickets[position];
                best = i;
            }
        }
        while (boundary < _boundaries.size() && (best == heads.size() || _boundaries[boundary].ticket <= ticket))
        {
            _frame.segments.push_back(
                { static_cast<uint32_t>(_frame.commands.size()), _boundaries[boundary].copy, _boundaries[boundary].marker });
            ++boundary;
        }
        if (best == heads.size())
            break;
        auto& [list, position] = heads[best];
        // Copy the run of this list that precedes every other list's head and the next boundary.
        uint32_t limit = boundary < _boundaries.size() ? _boundaries[boundary].ticket : UINT32_MAX;
        for (size_t i = 0; i < heads.size(); ++i)
            if (i != best && heads[i].second < heads[i].first->tickets.size())
                limit = std::min(limit, heads[i].first->tickets[heads[i].second]);
        const size_t begin = position;
        while (position < list->tickets.size() && list->tickets[position] < limit)
            ++position;
        _frame.commands.insert(
            _frame.commands.end(), list->commands.begin() + begin, list->commands.begin() + position);
    }
    _frame.segments.push_back({ static_cast<uint32_t>(_frame.commands.size()), std::nullopt });
}

DrawingContext::ThreadList& DrawingContext::LocalList()
{
    if (tThreadSlot.generation == _generation)
        return *static_cast<ThreadList*>(tThreadSlot.list);
    std::scoped_lock lock(_listsMutex);
    _lists.push_back(std::make_unique<ThreadList>());
    tThreadSlot = { _generation, _lists.back().get() };
    return *_lists.back();
}

ScreenCoordsXY DrawingContext::Origin(const RenderTarget& rt) const
{
    const auto offset = rt.bits - _mainRT.bits;
    return { static_cast<int32_t>(offset % _mainRT.width), static_cast<int32_t>(offset / _mainRT.width) };
}

std::unique_lock<std::mutex> DrawingContext::LockCache()
{
    return _threadSafe ? std::unique_lock<std::mutex>(_textureCache.GetMutex()) : std::unique_lock<std::mutex>();
}

bool DrawingContext::Push(const RenderTarget& rt, DrawCommand command)
{
    // command.left..bottom arrive unclipped in int16 range; clip to the target and canvas.
    const auto offset = rt.bits - _mainRT.bits;
    if (offset < 0 || offset >= static_cast<ptrdiff_t>(_mainRT.width) * _mainRT.height)
        return false;
    const auto origin = Origin(rt);
    const int32_t left = std::max<int32_t>({ command.left, origin.x, 0 });
    const int32_t top = std::max<int32_t>({ command.top, origin.y, 0 });
    const int32_t right = std::min<int32_t>({ command.right, origin.x + rt.width, _mainRT.width });
    const int32_t bottom = std::min<int32_t>({ command.bottom, origin.y + rt.height, _mainRT.height });
    if (left >= right || top >= bottom)
        return false;
    command.left = static_cast<int16_t>(left);
    command.top = static_cast<int16_t>(top);
    command.right = static_cast<int16_t>(right);
    command.bottom = static_cast<int16_t>(bottom);

    const auto kind = command.flags & kCommandKindMask;
    if (kind == kCommandFilter || (kind == kCommandSprite && (command.flags & kCommandRemapDestination) != 0)
        || (kind == kCommandText && command.threshold != 0))
        command.flags |= kCommandReadsDestination;
    else if (kind == kCommandFill && (command.flags & kCommandCrossHatch) == 0)
        command.flags |= kCommandOpaque;

    auto& list = LocalList();
    list.commands.push_back(command);
    list.tickets.push_back(_ticket.fetch_add(1, std::memory_order_relaxed));
    return true;
}

// ---------------------------------------------------------------------------------------
// Rectangles and lines

void DrawingContext::Clear(RenderTarget& rt, PaletteIndex colour)
{
    FillRect(rt, colour, rt.x, rt.y, rt.x + rt.width - 1, rt.y + rt.height - 1, false);
}

void DrawingContext::FillRect(
    RenderTarget& rt, PaletteIndex colour, int32_t left, int32_t top, int32_t right, int32_t bottom, bool crossHatch)
{
    const auto origin = Origin(rt);
    DrawCommand c{};
    c.flags = kCommandFill | (crossHatch ? kCommandCrossHatch : 0);
    c.colour = EnumValue(colour);
    // The cross-hatch phase is anchored at the unclipped top-left corner.
    c.originX = static_cast<float>(left - rt.x + origin.x);
    c.originY = static_cast<float>(top - rt.y + origin.y);
    c.left = ClampLogical(left - rt.x + origin.x);
    c.top = ClampLogical(top - rt.y + origin.y);
    c.right = ClampLogical(right - rt.x + origin.x + 1);
    c.bottom = ClampLogical(bottom - rt.y + origin.y + 1);
    Push(rt, c);
}

void DrawingContext::FilterRect(
    RenderTarget& rt, FilterPaletteID palette, int32_t left, int32_t top, int32_t right, int32_t bottom)
{
    std::optional<PaletteRow> row;
    {
        auto lock = LockCache();
        row = _textureCache.GetFilterPalette(palette);
    }
    if (!row)
        return;
    const auto origin = Origin(rt);
    DrawCommand c{};
    c.flags = kCommandFilter;
    c.mapRow = row->row;
    c.mapLength = row->length;
    c.left = ClampLogical(left - rt.x + origin.x);
    c.top = ClampLogical(top - rt.y + origin.y);
    c.right = ClampLogical(right - rt.x + origin.x + 1);
    c.bottom = ClampLogical(bottom - rt.y + origin.y + 1);
    Push(rt, c);
}

// Bresenham walk of GfxDrawLineSoftware, emitting its horizontal spans as fills.
void DrawingContext::DrawLine(RenderTarget& rt, PaletteIndex colour, const ScreenLine& line)
{
    auto span = [&](const ScreenCoordsXY& point, int32_t length) {
        const auto origin = Origin(rt);
        DrawCommand c{};
        c.flags = kCommandFill;
        c.colour = EnumValue(colour);
        c.originX = static_cast<float>(point.x - rt.x + origin.x);
        c.originY = static_cast<float>(point.y - rt.y + origin.y);
        c.left = ClampLogical(point.x - rt.x + origin.x);
        c.top = ClampLogical(point.y - rt.y + origin.y);
        c.right = ClampLogical(point.x - rt.x + origin.x + std::max(length, 1));
        c.bottom = ClampLogical(point.y - rt.y + origin.y + 1);
        Push(rt, c);
    };
    const ZoomLevel zoom = rt.zoom_level;
    int32_t x1 = zoom.ApplyInversedTo(line.getX1());
    int32_t x2 = zoom.ApplyInversedTo(line.getX2());
    int32_t y1 = zoom.ApplyInversedTo(line.getY1());
    int32_t y2 = zoom.ApplyInversedTo(line.getY2());
    // Check to make sure the line is within the drawing area
    if ((x1 < rt.x) && (x2 < rt.x))
        return;
    if ((y1 < rt.y) && (y2 < rt.y))
        return;
    if ((x1 > (rt.x + rt.width)) && (x2 > (rt.x + rt.width)))
        return;
    if ((y1 > (rt.y + rt.height)) && (y2 > (rt.y + rt.height)))
        return;

    // If vertical plot points upwards
    const bool steep = std::abs(y2 - y1) > std::abs(x2 - x1);
    if (steep)
    {
        std::swap(x1, y1);
        std::swap(x2, y2);
    }
    // If line is right to left swap direction
    if (x1 > x2)
    {
        std::swap(x1, x2);
        std::swap(y1, y2);
    }

    const int32_t deltaX = x2 - x1;
    const int32_t deltaY = std::abs(y2 - y1);
    int32_t error = deltaX / 2;
    const int32_t yStep = y1 < y2 ? 1 : -1;
    int32_t y = y1;
    for (int32_t x = x1, xStart = x1, length = 1; x < x2; ++x, ++length)
    {
        // Vertical lines are drawn 1 pixel at a time
        if (steep)
            span({ y, x }, 1);

        error -= deltaY;
        if (error < 0)
        {
            // Non vertical lines are drawn with as many pixels in a horizontal line as possible
            if (!steep)
                span({ xStart, y }, length);

            // Reset non vertical line vars
            xStart = x + 1;
            length = 0; // NB: will be incremented in next iteration
            y += yStep;
            error += deltaX;
        }

        // Catch the case of the last line
        if (x + 1 == x2 && !steep)
            span({ xStart, y }, length);
    }
}

// ---------------------------------------------------------------------------------------
// Sprites

DrawingContext::RemapInfo DrawingContext::RemapForImage(ImageId image)
{
    // Equivalent to GfxDrawSpriteGetPalette.
    RemapInfo remap;
    if (image.HasPrimary())
        remap.flags |= kCommandRemapSource;
    if (image.IsBlended())
        remap.flags |= kCommandRemapDestination;
    if (remap.flags == 0)
        return remap;

    std::optional<PaletteRow> row;
    auto lock = LockCache();
    if (image.HasSecondary())
    {
        const uint32_t key = kKeySecondaryRemap | EnumValue(image.GetPrimary()) | (EnumValue(image.GetSecondary()) << 8)
            | (image.HasTertiary() ? (EnumValue(image.GetTertiary()) << 16) | (1u << 23) : 0);
        row = _textureCache.FindKeyedPalette(key);
        if (!row)
        {
            // kSecondaryRemapPalette and kTertiaryRemapPalette are identical: identity with
            // indices 1-3 mapped to 243-245, then the remap ranges copied from each colour.
            std::array<PaletteIndex, 256> colours;
            for (size_t i = 0; i < colours.size(); ++i)
                colours[i] = static_cast<PaletteIndex>(i);
            colours[1] = static_cast<PaletteIndex>(0xF3);
            colours[2] = static_cast<PaletteIndex>(0xF4);
            colours[3] = static_cast<PaletteIndex>(0xF5);
            PaletteMap map(colours);
            auto copy = [&](Colour source, PaletteIndex destination) {
                auto remapMap = GetPaletteMapForColour(static_cast<FilterPaletteID>(source));
                if (remapMap)
                    map.Copy(destination, *remapMap, PaletteIndex::primaryRemap0, kPaletteLengthRemap);
            };
            if (image.HasTertiary())
                copy(image.GetTertiary(), PaletteIndex::tertiaryRemap0);
            copy(image.GetPrimary(), PaletteIndex::primaryRemap0);
            copy(image.GetSecondary(), PaletteIndex::secondaryRemap0);
            row = _textureCache.AddKeyedPalette(key, map);
        }
    }
    else
    {
        auto paletteId = image.GetRemap();
        if (!image.IsBlended())
            paletteId &= 0x7F;
        row = _textureCache.GetFilterPalette(static_cast<FilterPaletteID>(paletteId));
        if (!row)
            row = _textureCache.GetIdentityPalette();
    }
    if (!row)
        return { 0xFFFFFFFFu };
    remap.row = row->row;
    remap.length = row->length;
    remap.zeroFree = row->zeroFree;
    return remap;
}

void DrawingContext::DrawImage(RenderTarget& rt, ImageId image, const ScreenCoordsXY& coords, const RemapInfo& remap)
{
    if (remap.flags == 0xFFFFFFFFu)
        return;
    const auto* g1 = GfxGetG1Element(image);
    if (g1 == nullptr)
        return;
    // Pre-minified variants, as GfxDrawSpritePaletteSetSoftware: each step halves the
    // coordinates and lowers the zoom by one, until an image without a zoomed variant.
    auto zoom = static_cast<int8_t>(rt.zoom_level);
    auto index = image.GetIndex();
    auto position = coords;
    while (zoom > 0 && g1->flags.has(G1Flag::hasZoomSprite))
    {
        index -= g1->zoomedOffset;
        position = { position.x / 2, position.y / 2 };
        --zoom;
        g1 = GfxGetG1Element(index);
        if (g1 == nullptr)
            return;
    }
    if (zoom > 0 && g1->flags.has(G1Flag::noZoomDraw))
        return;

    AtlasRegion region;
    ImageInterior interior;
    {
        auto lock = LockCache();
        region = _textureCache.GetImage(index, &interior);
    }
    if (!region.IsValid())
        return;

    // Unrounded logical position: sprites are sampled at raster density without seams.
    const auto origin = Origin(rt);
    const float step = std::ldexp(1.0f, zoom);
    DrawCommand c{};
    c.originX = (position.x + g1->xOffset) / step - rt.x + origin.x;
    c.originY = (position.y + g1->yOffset) / step - rt.y + origin.y;
    c.scaleX = step;
    c.scaleY = step;
    c.left = ClampLogical(static_cast<int32_t>(std::floor(c.originX)));
    c.top = ClampLogical(static_cast<int32_t>(std::floor(c.originY)));
    c.right = ClampLogical(static_cast<int32_t>(std::ceil(c.originX + region.width / step)));
    c.bottom = ClampLogical(static_cast<int32_t>(std::ceil(c.originY + region.height / step)));
    c.layer = region.layer;
    c.atlasX = region.x;
    c.atlasY = region.y;
    c.width = region.width;
    c.height = region.height;
    c.flags = kCommandSprite | remap.flags;
    // BMP sprites without transparency and RLE sprites at zoom 0 copy palette index 0.
    if (remap.flags != 0
        || (g1->flags.has(G1Flag::hasRLECompression) ? zoom != 0 : g1->flags.has(G1Flag::hasTransparency)))
        c.flags |= kCommandTransparent;
    c.mapRow = remap.row;
    c.mapLength = remap.length;
    if (!Push(rt, c))
        return;

    // Fully opaque interior rectangles follow the sprite as separate commands drawn without
    // discard. They write exactly the texels the sprite writes there, so the image is
    // unchanged; the sprite itself is then depth-rejected inside them and only shades its
    // edges. Each rectangle is shrunk to whole logical pixels such that every raster pixel it
    // covers samples a texel inside the rectangle: positions are multiples of 1/8 logical pixel
    // and float rounding is monotonic, so ceil() suffices at the left/top edge, while the
    // right/bottom edge must stay strictly inside.
    if ((remap.flags & kCommandRemapDestination) != 0 || ((remap.flags & kCommandRemapSource) != 0 && !remap.zeroFree))
        return;
    auto innerEnd = [](double edge) {
        const double whole = std::floor(edge);
        return static_cast<int32_t>(whole == edge ? whole - 1 : whole);
    };
    const auto maxRects = DebugOptions::Get().interiorRects >= 0 ? DebugOptions::Get().interiorRects : kMaxInteriorRects;
    for (int32_t i = 0; i < std::min<int32_t>(interior.count, maxRects); ++i)
    {
        const auto& rect = interior.rects[i];
        const auto left = static_cast<int32_t>(std::ceil(static_cast<double>(c.originX) + rect.x0 / static_cast<double>(step)));
        const auto top = static_cast<int32_t>(std::ceil(static_cast<double>(c.originY) + rect.y0 / static_cast<double>(step)));
        const auto right = innerEnd(static_cast<double>(c.originX) + rect.x1 / static_cast<double>(step));
        const auto bottom = innerEnd(static_cast<double>(c.originY) + rect.y1 / static_cast<double>(step));
        // Small rectangles cost more to record and draw than the fragments they save.
        if (left >= right || top >= bottom || (right - left) * (bottom - top) < kMinInteriorArea)
            continue;
        DrawCommand opaque = c;
        opaque.flags |= kCommandOpaque;
        opaque.left = ClampLogical(left);
        opaque.top = ClampLogical(top);
        opaque.right = ClampLogical(right);
        opaque.bottom = ClampLogical(bottom);
        Push(rt, opaque);
    }
}

void DrawingContext::DrawSprite(RenderTarget& rt, ImageId image, int32_t x, int32_t y)
{
    if (!image.HasValue())
        return;
    DrawImage(rt, image, { x, y }, RemapForImage(image));
}

void DrawingContext::DrawGlyph(RenderTarget& rt, ImageId image, int32_t x, int32_t y, const PaletteMap& palette)
{
    RemapInfo remap;
    if (image.HasPrimary())
        remap.flags |= kCommandRemapSource;
    if (image.IsBlended())
        remap.flags |= kCommandRemapDestination;
    if (remap.flags != 0)
    {
        std::optional<PaletteRow> row;
        {
            auto lock = LockCache();
            row = _textureCache.GetPaletteMap(palette);
        }
        if (!row)
            return;
        remap.row = row->row;
        remap.length = row->length;
        remap.zeroFree = row->zeroFree;
    }
    DrawImage(rt, image, { x, y }, remap);
}

void DrawingContext::DrawSpriteSolid(RenderTarget& rt, ImageId image, int32_t x, int32_t y, PaletteIndex colour)
{
    std::optional<PaletteRow> row;
    {
        auto lock = LockCache();
        const uint32_t key = kKeySolidColour | EnumValue(colour);
        row = _textureCache.FindKeyedPalette(key);
        if (!row)
        {
            std::array<PaletteIndex, 256> colours;
            colours.fill(colour);
            colours[0] = PaletteIndex::transparent;
            row = _textureCache.AddKeyedPalette(key, PaletteMap(colours));
        }
    }
    if (!row)
        return;
    // As X8DrawingContext: drawn through a primary-remapped image id.
    DrawImage(
        rt, ImageId(image.GetIndex(), Colour::black), { x, y }, { kCommandRemapSource, row->row, row->length, row->zeroFree });
}

void DrawingContext::DrawSpriteRawMasked(RenderTarget& rt, int32_t x, int32_t y, ImageId maskImage, ImageId colourImage)
{
    const auto* mask = GfxGetG1Element(maskImage);
    const auto* colour = GfxGetG1Element(colourImage);
    if (mask == nullptr || colour == nullptr)
        return;
    // Masking only supports BMP images; the software renderer falls back to the colour image.
    if (mask->flags.has(G1Flag::hasRLECompression) || colour->flags.has(G1Flag::hasRLECompression))
    {
        DrawSprite(rt, colourImage, x, y);
        return;
    }
    AtlasRegion maskRegion, colourRegion;
    {
        auto lock = LockCache();
        maskRegion = _textureCache.GetImage(maskImage.GetIndex());
        colourRegion = _textureCache.GetImage(colourImage.GetIndex());
    }
    if (!maskRegion.IsValid() || !colourRegion.IsValid())
        return;
    const auto origin = Origin(rt);
    const auto zoom = static_cast<int8_t>(rt.zoom_level);
    const float step = std::ldexp(1.0f, zoom);
    DrawCommand c{};
    c.flags = kCommandSprite | kCommandMasked | kCommandTransparent;
    c.originX = (x + mask->xOffset) / step - rt.x + origin.x;
    c.originY = (y + mask->yOffset) / step - rt.y + origin.y;
    c.scaleX = step;
    c.scaleY = step;
    c.left = ClampLogical(static_cast<int32_t>(std::floor(c.originX)));
    c.top = ClampLogical(static_cast<int32_t>(std::floor(c.originY)));
    c.right = ClampLogical(static_cast<int32_t>(std::ceil(c.originX + std::min(mask->width, colour->width) / step)));
    c.bottom = ClampLogical(static_cast<int32_t>(std::ceil(c.originY + std::min(mask->height, colour->height) / step)));
    c.layer = colourRegion.layer;
    c.atlasX = colourRegion.x;
    c.atlasY = colourRegion.y;
    c.width = colourRegion.width;
    c.height = colourRegion.height;
    c.maskLayer = maskRegion.layer;
    c.maskX = maskRegion.x;
    c.maskY = maskRegion.y;
    c.maskWidth = maskRegion.width;
    c.maskHeight = maskRegion.height;
    Push(rt, c);
}

// ---------------------------------------------------------------------------------------
// TrueType text

void DrawingContext::PushText(
    RenderTarget& rt, const AtlasRegion& region, int32_t x, int32_t y, PaletteIndex colour, uint8_t threshold,
    int32_t logicalWidth, int32_t logicalHeight)
{
    const auto origin = Origin(rt);
    const int32_t left = x - rt.x + origin.x;
    const int32_t top = y - rt.y + origin.y;
    const int32_t width = logicalWidth != 0 ? logicalWidth : region.width;
    const int32_t height = logicalHeight != 0 ? logicalHeight : region.height;
    DrawCommand c{};
    c.flags = kCommandText;
    c.colour = EnumValue(colour);
    c.threshold = threshold;
    c.originX = static_cast<float>(left);
    c.originY = static_cast<float>(top);
    c.scaleX = static_cast<float>(region.width) / width;
    c.scaleY = static_cast<float>(region.height) / height;
    c.left = ClampLogical(left);
    c.top = ClampLogical(top);
    c.right = ClampLogical(left + width);
    c.bottom = ClampLogical(top + height);
    c.layer = region.layer;
    c.atlasX = region.x;
    c.atlasY = region.y;
    c.width = region.width;
    c.height = region.height;
    if (threshold != 0)
    {
        auto lock = LockCache();
        _textureCache.EnsureBlendTable();
    }
    Push(rt, c);
}

// Pass structure of X8DrawingContext::DrawTTFBitmap: outline and inset passes in the shadow
// colour without hinting, then the fill with the font's hinting threshold.
void DrawingContext::PushTextPasses(
    RenderTarget& rt, const TextDrawInfo& info, const AtlasRegion& region, int32_t x, int32_t y, uint8_t threshold,
    int32_t logicalWidth, int32_t logicalHeight)
{
    if (info.colourFlags.has(ColourFlag::withOutline))
    {
        constexpr std::array<ScreenCoordsXY, 4> kOutline{ { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } };
        for (const auto& delta : kOutline)
            PushText(rt, region, x + delta.x, y + delta.y, info.palette.shadowOutline, 0, logicalWidth, logicalHeight);
    }
    if (info.colourFlags.has(ColourFlag::inset))
        PushText(rt, region, x + 1, y + 1, info.palette.shadowOutline, 0, logicalWidth, logicalHeight);
    PushText(rt, region, x, y, info.palette.fill, threshold, logicalWidth, logicalHeight);
}

void DrawingContext::DrawTTFBitmap(
    RenderTarget& rt, const TextDrawInfo& info, TTFSurface* surface, int32_t x, int32_t y, uint8_t hintingThreshold)
{
    #ifndef DISABLE_TTF
    if (surface == nullptr || surface->w <= 0 || surface->h <= 0)
        return;
    // Core TTF surfaces are recycled, so they are keyed by content rather than address.
    const auto* pixels = static_cast<const uint8_t*>(surface->pixels);
    const size_t size = static_cast<size_t>(surface->w) * surface->h;
    const uint64_t key = (HashBytes(pixels, size, (static_cast<uint64_t>(surface->w) << 32) | surface->h) & ~kTagMask)
        | kLogicalTextTag;
    AtlasRegion region;
    {
        auto lock = LockCache();
        auto found = _textureCache.FindBitmap(key);
        region = found ? *found : _textureCache.AddBitmap(key, pixels, surface->w, surface->h, surface->w);
    }
    if (region.IsValid())
        PushTextPasses(rt, info, region, x, y, hintingThreshold, 0, 0);
    #endif
}

TTF_Font* DrawingContext::GetRetinaFace(const TTFFontDescriptor& fontDesc, int32_t pointSize, bool hinting)
{
    #ifndef DISABLE_TTF
    if (!_ownsTTF)
    {
        if (TTF_Init() != 0)
            return nullptr;
        _ownsTTF = true;
    }
    auto key = std::string(fontDesc.filename) + ":" + std::to_string(pointSize);
    auto found = _retinaFaces.find(key);
    if (found == _retinaFaces.end())
    {
        if (_retinaFaces.size() >= kMaxRetinaFaces)
        {
            auto oldest = std::min_element(_retinaFaces.begin(), _retinaFaces.end(), [](const auto& a, const auto& b) {
                return a.second.lastUsed < b.second.lastUsed;
            });
            TTF_CloseFont(oldest->second.font);
            _retinaFaces.erase(oldest);
        }
        const auto path = Platform::GetFontPath(fontDesc);
        auto* font = TTF_OpenFont(path.c_str(), pointSize);
        if (font == nullptr)
            return nullptr;
        found = _retinaFaces.emplace(std::move(key), RetinaFace{ font }).first;
        LOG_VERBOSE(
            "Metal Retina font: %s logical=%d raster=%d pt density=%.3f", fontDesc.font_name, fontDesc.ptSize, pointSize,
            _density);
    }
    auto& face = found->second;
    face.lastUsed = _frameNumber;
    // Same hinting mode as TTFToggleHinting: light hinting for shaded rendering.
    const int mode = hinting ? 1 : 0;
    if (face.hinting != mode)
    {
        TTF_SetFontHinting(face.font, mode);
        face.hinting = mode;
    }
    return face.font;
    #else
    return nullptr;
    #endif
}

bool DrawingContext::TryDrawTTFText(
    RenderTarget& rt, const TextDrawInfo& info, const TTFFontDescriptor& fontDesc, std::string_view text,
    const TTFSurface& logical, int32_t x, int32_t y)
{
    #ifndef DISABLE_TTF
    if (logical.w <= 0 || logical.h <= 0 || _density <= 1.0f || rt.zoom_level != ZoomLevel{ 0 })
        return false;
    // The CRT effect draws one scanline per logical row; Retina glyph pixels would straddle them.
    if (Config::Get().general.crtEffect)
        return false;
    // Same hinting policy as the core's logical surfaces (TTFToggleHinting, ttfDrawStringRaw).
    const bool enableHinting = Config::Get().fonts.enableHinting;
    const bool useHinting = enableHinting && fontDesc.hinting_threshold != 0;
    const auto threshold = static_cast<uint8_t>(enableHinting ? fontDesc.hinting_threshold : 0);
    // Pixel fonts (no hinting threshold) need a whole-number multiple: the density is slightly above an
    // integer (e.g. 2266 / 755), and ceil would make 12pt at 3x render at 37pt with uneven pixels.
    const auto pointSize = fontDesc.hinting_threshold != 0
        ? static_cast<int32_t>(std::ceil(fontDesc.ptSize * _density))
        : fontDesc.ptSize * std::max(1, static_cast<int32_t>(std::lround(_density)));

    uint64_t key = HashBytes(text.data(), text.size(), HashBytes(fontDesc.filename, std::strlen(fontDesc.filename)));
    key = (HashBytes(&key, sizeof(key), (static_cast<uint64_t>(pointSize) << 1) | (useHinting ? 1 : 0)) & ~kTagMask)
        | kRetinaTextTag;
    AtlasRegion region;
    {
        auto lock = LockCache();
        auto found = _textureCache.FindBitmap(key);
        if (found)
        {
            region = *found;
        }
        else
        {
            auto* font = GetRetinaFace(fontDesc, pointSize, useHinting);
            if (font == nullptr)
                return false;
            auto* surface = TTF_RenderUTF8(font, std::string(text).c_str(), useHinting);
            if (surface == nullptr)
                return false;
            if (surface->w <= AtlasAllocator::kLayerSize && surface->h <= AtlasAllocator::kLayerSize)
                region = _textureCache.AddBitmap(
                    key, static_cast<const uint8_t*>(surface->pixels), surface->w, surface->h, surface->w);
            TTFFreeSurface(surface);
        }
    }
    if (!region.IsValid())
        return false; // Too large for the atlas: use the logical bitmap.
    PushTextPasses(rt, info, region, x, y, threshold, logical.w, logical.h);
    return true;
    #else
    return false;
    #endif
}

#endif
