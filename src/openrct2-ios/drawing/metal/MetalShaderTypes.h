/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#pragma once

// Types and constants shared by the Objective-C++ renderer and MetalShaders.metal.
// Both compilers see exactly the same layout: every field is a scalar with natural
// alignment, so neither side inserts SIMD padding.

#ifdef __METAL_VERSION__
    #include <metal_stdlib>
    #define METAL_CONSTANT constant
typedef uint MetalUInt;
typedef int MetalInt;
typedef ushort MetalUShort;
typedef short MetalShort;
typedef uchar MetalUChar;
#else
    #include <cstdint>
    #define METAL_CONSTANT constexpr
typedef uint32_t MetalUInt;
typedef int32_t MetalInt;
typedef uint16_t MetalUShort;
typedef int16_t MetalShort;
typedef uint8_t MetalUChar;
#endif

namespace OpenRCT2
{
    namespace Ui
    {
        namespace Metal
        {
            // DrawCommand::flags. The low bits hold the command kind; the rest are modifiers.
            METAL_CONSTANT MetalUInt kCommandKindMask = 0x3u;
            METAL_CONSTANT MetalUInt kCommandFill = 0u;   // Solid palette index, optionally cross-hatched.
            METAL_CONSTANT MetalUInt kCommandFilter = 1u; // Remaps the destination through a palette row.
            METAL_CONSTANT MetalUInt kCommandSprite = 2u; // Indexed atlas image.
            METAL_CONSTANT MetalUInt kCommandText = 3u;   // TrueType coverage bitmap.

            METAL_CONSTANT MetalUInt kCommandCrossHatch = 1u << 4;       // Fill: skip odd checkerboard pixels.
            METAL_CONSTANT MetalUInt kCommandTransparent = 1u << 5;      // Sprite: palette index 0 is a hole.
            METAL_CONSTANT MetalUInt kCommandRemapSource = 1u << 6;      // Sprite: map[source].
            METAL_CONSTANT MetalUInt kCommandRemapDestination = 1u << 7; // Sprite: glass/water blend with dst.
            METAL_CONSTANT MetalUInt kCommandMasked = 1u << 8;           // Sprite: AND with a second atlas image.
            // CPU-side classification, ignored by the shaders: the result depends on the
            // destination pixel (filters, glass/water blends, hinted text).
            METAL_CONSTANT MetalUInt kCommandReadsDestination = 1u << 31;
            // CPU-side classification: every covered pixel is written (no discard), so the
            // command can use the opaque pipeline and hidden-surface removal.
            METAL_CONSTANT MetalUInt kCommandOpaque = 1u << 30;

            // Atlas texels are R16Uint: palette index in the low byte, plus a coverage bit.
            // The coverage bit distinguishes RLE holes from encoded palette index 0, which the
            // software renderer copies at zoom 0.
            METAL_CONSTANT MetalUInt kAtlasCoverage = 0x100u;
            METAL_CONSTANT MetalUInt kAtlasIndexMask = 0xffu;

            // TrueType coverage at or above this value always uses the full text colour.
            METAL_CONSTANT MetalUInt kTextSolidCoverage = 180u;

            // Depth for command i is (kDepthOrigin - i) / 2^24: exactly representable and strictly
            // decreasing, so a LESS test keeps the latest command that wrote a pixel.
            METAL_CONSTANT MetalUInt kDepthOrigin = 0xFFFFFFu;
            METAL_CONSTANT MetalUInt kMaxCommandsPerPass = kDepthOrigin;

            // Rows of the palette-map texture are 256 entries wide.
            METAL_CONSTANT MetalUInt kPaletteRowWidth = 256u;

            // Reference rasterizer tiles (logical pixels).
            METAL_CONSTANT MetalUInt kReferenceTileSize = 16u;

            // One recorded drawing operation, in logical (UI) pixels. 56 bytes.
            struct DrawCommand
            {
                // Source sampling: texel = floor((point - origin) * scale), where point is the
                // logical position of the raster pixel centre. Fills store their pattern origin.
                float originX;
                float originY;
                float scaleX;
                float scaleY;
                MetalUInt flags;
                MetalUInt mapLength; // Entries in the palette map starting at mapRow.
                // Logical clip rectangle, right/bottom exclusive.
                MetalShort left;
                MetalShort top;
                MetalShort right;
                MetalShort bottom;
                // Source image (sprites and text).
                MetalUShort layer;
                MetalUShort atlasX;
                MetalUShort atlasY;
                MetalUShort width;
                MetalUShort height;
                // Mask image (kCommandMasked).
                MetalUShort maskLayer;
                MetalUShort maskX;
                MetalUShort maskY;
                MetalUShort maskWidth;
                MetalUShort maskHeight;
                MetalUShort mapRow;
                MetalUChar colour;    // Fill and text colour.
                MetalUChar threshold; // Text hinting threshold; 0 disables blending.
            };

            // Per-axis mapping from a raster pixel to logical space.
            struct RasterSample
            {
                float point;      // Logical coordinate of the raster pixel centre.
                MetalInt logical; // floor(point): the logical pixel used for clipping.
            };

            struct FrameUniforms
            {
                MetalUInt rasterWidth;
                MetalUInt rasterHeight;
                MetalUInt logicalWidth;
                MetalUInt logicalHeight;
                MetalUInt tilesAcross; // Reference rasterizer only.
                MetalUInt tilesDown;
            };

            struct ReferenceSegment
            {
                MetalUInt begin; // Command index range drawn by one reference dispatch.
                MetalUInt end;
            };

            struct ReferenceCopy
            {
                MetalUInt sourceX;
                MetalUInt sourceY;
                MetalUInt destinationX;
                MetalUInt destinationY;
                MetalUInt width;
                MetalUInt height;
                MetalUInt stride;
            };

            struct PresentUniforms
            {
                MetalUInt offsetX; // Content origin in drawable pixels.
                MetalUInt offsetY;
            };

            // CRT presentation: one scanline per logical row, drawn as gaussian electron beams.
            struct CrtUniforms
            {
                MetalUInt offsetX; // Content origin in drawable pixels.
                MetalUInt offsetY;
                MetalUInt rasterWidth;
                MetalUInt rasterHeight;
                MetalUInt logicalWidth;
                MetalUInt logicalHeight;
                float logicalPerRasterX;
                float logicalPerRasterY;
                float rasterPerLogicalX;
                float rasterPerLogicalY;
                float beamPhase;     // Scanline centre offset in logical rows, aligning beams to raster rows.
                float sharpness;   // Horizontal transition steepness; 1 is bilinear.
                float outputGamma;     // Encoding of the linear result for the display.
            };

            // Raster-pass vertex buffer bindings.
            METAL_CONSTANT MetalUInt kBufferCommands = 0;
            METAL_CONSTANT MetalUInt kBufferOrder = 1;
            METAL_CONSTANT MetalUInt kBufferEdgesX = 2;
            METAL_CONSTANT MetalUInt kBufferEdgesY = 3;
            METAL_CONSTANT MetalUInt kBufferUniforms = 4;
            // Fragment buffer bindings.
            METAL_CONSTANT MetalUInt kBufferSamplesX = 0;
            METAL_CONSTANT MetalUInt kBufferSamplesY = 1;
            METAL_CONSTANT MetalUInt kBufferPalette = 2;
            // Reference kernel buffer bindings.
            METAL_CONSTANT MetalUInt kReferenceCommands = 0;
            METAL_CONSTANT MetalUInt kReferenceSamplesX = 1;
            METAL_CONSTANT MetalUInt kReferenceSamplesY = 2;
            METAL_CONSTANT MetalUInt kReferenceUniforms = 3;
            METAL_CONSTANT MetalUInt kReferenceTileRanges = 4;
            METAL_CONSTANT MetalUInt kReferenceTileIndices = 5;
            METAL_CONSTANT MetalUInt kReferenceSegment = 6;
            METAL_CONSTANT MetalUInt kReferenceCanvas = 7;
            // Textures.
            METAL_CONSTANT MetalUInt kTextureAtlas = 0;
            METAL_CONSTANT MetalUInt kTexturePalettes = 1;
            METAL_CONSTANT MetalUInt kTextureBlend = 2;
            METAL_CONSTANT MetalUInt kTextureCanvas = 3;
            METAL_CONSTANT MetalUInt kTextureCrtBeams = 4;

            // CRT beam table: light per (sqrt of the brightest channel, distance in logical rows).
            METAL_CONSTANT MetalUInt kCrtBeamIntensities = 64;
            METAL_CONSTANT MetalUInt kCrtBeamDistances = 128;
        } // namespace Metal
    } // namespace Ui
} // namespace OpenRCT2

#ifndef __METAL_VERSION__
static_assert(sizeof(OpenRCT2::Ui::Metal::DrawCommand) == 56);
static_assert(sizeof(OpenRCT2::Ui::Metal::RasterSample) == 8);
#endif
