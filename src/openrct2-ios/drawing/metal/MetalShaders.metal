// Copyright (c) 2026 OpenRCT2 developers. GPL-3.0.
#include <metal_stdlib>

#include "MetalShaderTypes.h"

using namespace metal;
using namespace OpenRCT2::Ui::Metal;

// The canvas holds one palette index per logical pixel, as X8DrawingEngine's buffer, and is
// scaled to the display by a whole number at presentation. Pixel p samples a command's source
// at its top-left corner. Both rasterizers below share the per-pixel operation, so they only
// differ in how they find and order commands.

constant int kNoWrite = -1;

// Command fields that matter once coverage of a pixel is known.
struct CommandState
{
    float2 origin;
    float2 scale;
    uint flags;
    uint mapLength;
    uint layer, mapRow;
    uint2 atlas, size;
    uint maskLayer;
    uint2 mask, maskSize;
    uint colour, threshold;
};

inline CommandState stateFromCommand(DrawCommand c)
{
    CommandState s;
    s.origin = float2(c.originX, c.originY);
    s.scale = float2(c.scaleX, c.scaleY);
    s.flags = c.flags;
    s.mapLength = c.mapLength;
    s.layer = c.layer;
    s.mapRow = c.mapRow;
    s.atlas = uint2(c.atlasX, c.atlasY);
    s.size = uint2(c.width, c.height);
    s.maskLayer = c.maskLayer;
    s.mask = uint2(c.maskX, c.maskY);
    s.maskSize = uint2(c.maskWidth, c.maskHeight);
    s.colour = c.colour;
    s.threshold = c.threshold;
    return s;
}

inline uint paletteEntry(texture2d<uint, access::read> palettes, uint row, uint index)
{
    return palettes.read(uint2(index % kPaletteRowWidth, row + index / kPaletteRowWidth)).r;
}

// Returns the new palette index for this pixel, or kNoWrite to leave it unchanged.
// Semantics follow X8DrawingContext / BlitPixel (see MetalDrawingContext.mm).
inline int resolvePixel(
    thread const CommandState& c, float2 point, int2 logical, uint destination,
    texture2d_array<ushort, access::read> atlas, texture2d<uint, access::read> palettes,
    texture2d<uint, access::read> blend)
{
    const uint kind = c.flags & kCommandKindMask;
    if (kind == kCommandFill)
    {
        if ((c.flags & kCommandCrossHatch) != 0 && ((logical.x - int(c.origin.x) + logical.y - int(c.origin.y)) & 1) != 0)
            return kNoWrite;
        return int(c.colour);
    }
    if (kind == kCommandFilter)
        return destination < c.mapLength ? int(paletteEntry(palettes, c.mapRow, destination)) : kNoWrite;

    const float2 source = (point - c.origin) * c.scale;
    const int sx = int(floor(source.x));
    const int sy = int(floor(source.y));
    if (sx < 0 || sy < 0 || sx >= int(c.size.x) || sy >= int(c.size.y))
        return kNoWrite;
    const uint texel = atlas.read(c.atlas + uint2(sx, sy), c.layer).r;
    if ((texel & kAtlasCoverage) == 0)
        return kNoWrite;
    uint sample = texel & kAtlasIndexMask;

    if (kind == kCommandText)
    {
        if (sample == 0)
            return kNoWrite;
        if (c.threshold == 0 || sample > kTextSolidCoverage)
            return int(c.colour);
        if (sample > c.threshold)
            return int(blend.read(uint2(destination, c.colour)).r);
        return kNoWrite;
    }

    if ((c.flags & kCommandMasked) != 0)
    {
        if (uint(sx) >= c.maskSize.x || uint(sy) >= c.maskSize.y)
            return kNoWrite;
        sample &= atlas.read(c.mask + uint2(sx, sy), c.maskLayer).r & kAtlasIndexMask;
    }
    const bool transparent = (c.flags & kCommandTransparent) != 0;
    if (transparent && sample == 0)
        return kNoWrite;
    const bool remapSource = (c.flags & kCommandRemapSource) != 0;
    const bool remapDestination = (c.flags & kCommandRemapDestination) != 0;
    if (!remapSource && !remapDestination)
        return int(sample);
    uint index = sample;
    if (remapDestination)
        index = remapSource ? (sample - 1) * kPaletteRowWidth + destination : destination;
    if (index >= c.mapLength)
        return kNoWrite;
    sample = paletteEntry(palettes, c.mapRow, index);
    if (transparent && sample == 0)
        return kNoWrite;
    return int(sample);
}

// ---------------------------------------------------------------------------------------
// Instanced-quad rasterizer. One instance per command; the rasterizer clips exactly to the
// command's clip rectangle and the depth test (two-pass mode) discards hidden fragments.

struct RasterVertex
{
    float4 position [[position]];
    float4 sampling [[flat]]; // origin.xy, scale.xy
    uint4 source [[flat]];    // flags, mapLength, layer | mapRow << 16, atlasX | atlasY << 16
    uint4 extra [[flat]];     // size, maskLayer | colour << 16 | threshold << 24, mask, maskSize
};

struct RasterOutput
{
    uint colour [[color(0)]];
};

vertex RasterVertex rasterVertex(
    uint vertexId [[vertex_id]], uint instanceId [[instance_id]],
    device const DrawCommand* commands [[buffer(kBufferCommands)]],
    device const uint* order [[buffer(kBufferOrder)]], constant FrameUniforms& frame [[buffer(kBufferUniforms)]])
{
    const uint index = order[instanceId];
    const DrawCommand c = commands[index];
    // The command's clip rectangle.
    const float x = (vertexId & 1) != 0 ? c.right : c.left;
    const float y = (vertexId & 2) != 0 ? c.bottom : c.top;
    RasterVertex out;
    out.position = float4(
        x / float(frame.width) * 2.0f - 1.0f, 1.0f - y / float(frame.height) * 2.0f,
        float(kDepthOrigin - index) * (1.0f / 16777216.0f), 1.0f);
    out.sampling = float4(c.originX, c.originY, c.scaleX, c.scaleY);
    out.source = uint4(c.flags, c.mapLength, uint(c.layer) | (uint(c.mapRow) << 16), uint(c.atlasX) | (uint(c.atlasY) << 16));
    out.extra = uint4(
        uint(c.width) | (uint(c.height) << 16), uint(c.maskLayer) | (uint(c.colour) << 16) | (uint(c.threshold) << 24),
        uint(c.maskX) | (uint(c.maskY) << 16), uint(c.maskWidth) | (uint(c.maskHeight) << 16));
    return out;
}

inline CommandState stateFromVertex(RasterVertex in)
{
    CommandState s;
    s.origin = in.sampling.xy;
    s.scale = in.sampling.zw;
    s.flags = in.source.x;
    s.mapLength = in.source.y;
    s.layer = in.source.z & 0xffffu;
    s.mapRow = in.source.z >> 16;
    s.atlas = uint2(in.source.w & 0xffffu, in.source.w >> 16);
    s.size = uint2(in.extra.x & 0xffffu, in.extra.x >> 16);
    s.maskLayer = in.extra.y & 0xffffu;
    s.colour = (in.extra.y >> 16) & 0xffu;
    s.threshold = in.extra.y >> 24;
    s.mask = uint2(in.extra.z & 0xffffu, in.extra.z >> 16);
    s.maskSize = uint2(in.extra.w & 0xffffu, in.extra.w >> 16);
    return s;
}

// Profiling variants (OPENRCT2_METAL_PROFILE): 1 skips palette remaps, 3 never discards.
// Only for measuring where full-frame time goes; 3 does not produce correct images.
constant uint kProfileModeConstant [[function_constant(0)]];
constant uint kProfileMode = is_function_constant_defined(kProfileModeConstant) ? kProfileModeConstant : 0;

// Commands whose result does not depend on the destination. In two-pass mode these are
// drawn latest-first with depth writes, so earlier commands hidden behind them never shade.
fragment RasterOutput rasterIndependent(
    RasterVertex in [[stage_in]], texture2d_array<ushort, access::read> atlas [[texture(kTextureAtlas)]],
    texture2d<uint, access::read> palettes [[texture(kTexturePalettes)]],
    texture2d<uint, access::read> blend [[texture(kTextureBlend)]])
{
    const int2 pixel = int2(in.position.xy);
    CommandState c = stateFromVertex(in);
    if (kProfileMode == 1)
        c.flags &= ~(kCommandRemapSource | kCommandRemapDestination);
    const int colour = resolvePixel(c, float2(pixel), pixel, 0u, atlas, palettes, blend);
    if (colour == kNoWrite)
    {
        if (kProfileMode == 3)
            return { 0u };
        discard_fragment();
    }
    return { uint(colour) };
}

// Commands that write every pixel they cover (kCommandOpaque: plain fills and the opaque
// interiors of sprites). Without a discard path the GPU's hidden-surface removal can skip
// everything they hide before it is shaded.
fragment RasterOutput rasterOpaque(
    RasterVertex in [[stage_in]], texture2d_array<ushort, access::read> atlas [[texture(kTextureAtlas)]],
    texture2d<uint, access::read> palettes [[texture(kTexturePalettes)]],
    texture2d<uint, access::read> blend [[texture(kTextureBlend)]])
{
    const int2 pixel = int2(in.position.xy);
    const CommandState c = stateFromVertex(in);
    const int colour = resolvePixel(c, float2(pixel), pixel, 0u, atlas, palettes, blend);
    return { uint(max(colour, 0)) };
}

// Commands that read the destination (palette filters, glass/water, hinted text). Apple GPUs
// execute overlapping fragments that read the attachment in primitive order, so programmable
// blending gives exact painter's-algorithm semantics within the render pass.
fragment RasterOutput rasterDependent(
    RasterVertex in [[stage_in]], uint destination [[color(0)]],
    texture2d_array<ushort, access::read> atlas [[texture(kTextureAtlas)]],
    texture2d<uint, access::read> palettes [[texture(kTexturePalettes)]],
    texture2d<uint, access::read> blend [[texture(kTextureBlend)]])
{
    const int2 pixel = int2(in.position.xy);
    const CommandState c = stateFromVertex(in);
    const int colour = resolvePixel(c, float2(pixel), pixel, destination, atlas, palettes, blend);
    if (colour == kNoWrite)
        discard_fragment();
    return { uint(colour) };
}

// ---------------------------------------------------------------------------------------
// Presentation: palette lookup of the indexed canvas, each logical pixel a scale × scale square.

struct PresentVertex
{
    float4 position [[position]];
};

vertex PresentVertex presentVertex(uint vertexId [[vertex_id]])
{
    const float2 positions[] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    return { float4(positions[vertexId], 0, 1) };
}

fragment float4 presentFragment(
    PresentVertex in [[stage_in]], texture2d<uint, access::read> canvas [[texture(kTextureCanvas)]],
    constant uchar4* palette [[buffer(kBufferPalette)]], constant PresentUniforms& present [[buffer(kBufferUniforms)]])
{
    const uint2 pixel = (uint2(in.position.xy) - uint2(present.offsetX, present.offsetY)) / present.scale;
    return float4(palette[canvas.read(pixel).r]) * (1.0f / 255.0f);
}

// ---------------------------------------------------------------------------------------
// CRT presentation, in two passes. crtSignal decodes the canvas (the game's own resolution, the
// "video signal") into a linear-light texture of the same size, using a palette already decoded
// with the CRT gamma. crtFragment then draws every output pixel from the two nearest scanlines
// with two bilinear fetches.
//
// The beam profile is precomputed per scale into a small table (see CrtBeamTable in
// MetalDrawingEngine.mm), indexed by intensity and distance from the beam centre.

fragment half4 crtSignal(
    PresentVertex in [[stage_in]], texture2d<uint, access::read> canvas [[texture(kTextureCanvas)]],
    constant half4* palette [[buffer(kBufferPalette)]])
{
    return palette[canvas.read(uint2(in.position.xy)).r];
}

fragment float4 crtFragment(
    PresentVertex in [[stage_in]], texture2d<half> signal [[texture(kTextureCanvas)]],
    texture2d<half> beams [[texture(kTextureCrtBeams)]], constant CrtUniforms& u [[buffer(kBufferUniforms)]])
{
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    const float2 pixel = in.position.xy - float2(u.offsetX, u.offsetY);
    const float2 position = pixel * u.logicalPerPixel;

    // Horizontal band limit: bilinear between neighbouring signal samples, with the transition
    // steepened around the pixel edge by `sharpness` (1 is plain linear interpolation).
    const float x = position.x - 0.5f;
    const float column = floor(x);
    const float blend = saturate((x - column - 0.5f) * u.sharpness + 0.5f);
    const float s = (column + 0.5f + blend) / float(u.logicalWidth);

    const float y = position.y - 0.5f - u.beamPhase;
    const float row = floor(y);
    const float offset = y - row;
    const half3 upper = signal.sample(bilinear, float2(s, (row + 0.5f) / float(u.logicalHeight))).rgb;
    const half3 lower = signal.sample(bilinear, float2(s, (row + 1.5f) / float(u.logicalHeight))).rgb;

    // Beam light for (intensity, distance), see CrtBeamTable. Texel centres span both ranges.
    const float2 scale = float2(kCrtBeamIntensities - 1, kCrtBeamDistances - 1) / float2(kCrtBeamIntensities, kCrtBeamDistances);
    const float2 bias = 0.5f / float2(kCrtBeamIntensities, kCrtBeamDistances);
    const half upperLight = beams.sample(bilinear, float2(sqrt(float(max3(upper.r, upper.g, upper.b))), offset) * scale + bias).r;
    const half lowerLight = beams.sample(bilinear, float2(sqrt(float(max3(lower.r, lower.g, lower.b))), 1.0f - offset) * scale + bias).r;
    half3 colour = upper * upperLight + lower * lowerLight;
    colour = pow(saturate(colour), half(1.0f / u.outputGamma));
    // Interleaved gradient noise hides 8-bit banding in the dark gaps between scanlines.
    const half noise = half(fract(52.9829189f * fract(dot(in.position.xy, float2(0.06711056f, 0.00583715f)))));
    return float4(float3(colour + (noise - 0.5h) / 255.0h), 1);
}

// ---------------------------------------------------------------------------------------
// Reference rasterizer for OPENRCT2_METAL_COMPARE_GPU. One thread per pixel walks the
// commands binned to its tile in submission order, starting from the persistent reference
// canvas. It is deliberately simple and is never used for normal frames.

kernel void referenceRasterize(
    device const DrawCommand* commands [[buffer(kReferenceCommands)]],
    constant FrameUniforms& frame [[buffer(kReferenceUniforms)]],
    device const uint2* tileRanges [[buffer(kReferenceTileRanges)]],
    device const uint* tileIndices [[buffer(kReferenceTileIndices)]],
    constant ReferenceSegment& segment [[buffer(kReferenceSegment)]],
    device uchar* canvas [[buffer(kReferenceCanvas)]],
    texture2d_array<ushort, access::read> atlas [[texture(kTextureAtlas)]],
    texture2d<uint, access::read> palettes [[texture(kTexturePalettes)]],
    texture2d<uint, access::read> blend [[texture(kTextureBlend)]], uint2 pixel [[thread_position_in_grid]])
{
    if (pixel.x >= frame.width || pixel.y >= frame.height)
        return;
    const int2 logical = int2(pixel);
    const float2 point = float2(pixel);
    const uint2 range = tileRanges[(pixel.y / kReferenceTileSize) * frame.tilesAcross + pixel.x / kReferenceTileSize];
    const uint offset = pixel.y * frame.width + pixel.x;
    uint colour = canvas[offset];
    for (uint i = range.x; i < range.y; ++i)
    {
        const uint index = tileIndices[i];
        if (index < segment.begin || index >= segment.end)
            continue;
        const DrawCommand c = commands[index];
        if (logical.x < c.left || logical.y < c.top || logical.x >= c.right || logical.y >= c.bottom)
            continue;
        const CommandState state = stateFromCommand(c);
        const int result = resolvePixel(state, point, logical, colour, atlas, palettes, blend);
        if (result != kNoWrite)
            colour = uint(result);
    }
    canvas[offset] = uchar(colour);
}

// Moves a rectangle of the reference canvas through a scratch buffer (CopyRect).
kernel void referenceCopy(
    device const uchar* source [[buffer(0)]], device uchar* destination [[buffer(1)]],
    constant ReferenceCopy& region [[buffer(2)]], uint2 pixel [[thread_position_in_grid]])
{
    if (pixel.x >= region.width || pixel.y >= region.height)
        return;
    destination[(region.destinationY + pixel.y) * region.stride + region.destinationX + pixel.x]
        = source[(region.sourceY + pixel.y) * region.stride + region.sourceX + pixel.x];
}
