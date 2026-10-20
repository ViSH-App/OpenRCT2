// Copyright (c) 2026 OpenRCT2 developers. GPL-3.0.
#include <metal_stdlib>
using namespace metal;

// Kept scalar/aligned to 4 bytes to match MetalCommand in MetalDrawingEngine.mm.
struct MetalCommand {
    int left, top, right, bottom;
    int destX, destY, sourceX, sourceY;
    uint textureOffset, textureWidth, textureHeight, maskOffset, maskWidth;
    int zoom;
    uint flags, mapOffset, mapLength, colour;
    float textScaleX, textScaleY;
    float spriteX, spriteY;
};
struct FrameSize { uint width, height, tilesAcross, tileSize, logicalWidth, logicalHeight; };

// Each thread owns one destination pixel. Commands in each tile remain in painter order,
// so palette filtering/glass/water do not need lossy RGB blending or unordered atomics.
// Returns 0..255 for a covered source sample, or 256 for a transparent hole.
inline uint sourceSample(MetalCommand c, float2 point, constant FrameSize& size, device const ushort* sprites) {
    float2 local = point-float2(c.destX,c.destY);
    if (size.width == size.logicalWidth && size.height == size.logicalHeight)
        local = floor(point)-float2(c.destX,c.destY);
    float2 source = c.zoom >= 0 ? float2(c.sourceX,c.sourceY)+local*float(1<<c.zoom)
                               : (float2(c.sourceX,c.sourceY)+local)/float(1<<(-c.zoom));
    if (c.flags & 256u) source = (point-float2(c.spriteX,c.spriteY))*c.textScaleX;
    if (c.flags & 128u) source = local*float2(c.textScaleX,c.textScaleY);
    int sx = int(floor(source.x)), sy = int(floor(source.y));
    if (sx < 0 || sy < 0 || sx >= int(c.textureWidth) || sy >= int(c.textureHeight)) return 256;
    uint sample = sprites[c.textureOffset+uint(sy)*c.textureWidth+uint(sx)];
    if (!(sample & 256u)) return 256;
    sample &= 255u;
    if (c.flags & 4u) {
        if (sx >= int(c.maskWidth) || sy >= int(c.colour)) return 256;
        sample &= sprites[c.maskOffset+uint(sy)*c.maskWidth+uint(sx)] & 255u;
    }
    if ((c.flags & 8u) && sample == 0) return 256;
    return sample;
}

kernel void drawIndexed(
    device const MetalCommand* commands [[buffer(0)]],
    device const uint2* ranges [[buffer(1)]],
    device const uint* indices [[buffer(2)]],
    device const ushort* sprites [[buffer(3)]],
    device const uchar* maps [[buffer(4)]],
    device uchar* pixels [[buffer(5)]],
    constant uint* palette [[buffer(6)]],
    constant FrameSize& size [[buffer(7)]],
    texture2d<float, access::write> output [[texture(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= size.width || position.y >= size.height) return;
    // Rasterize at drawable density; commands, clipping and input remain logical.
    float2 point = (float2(position)+0.5)*float2(size.logicalWidth,size.logicalHeight)/float2(size.width,size.height);
    const int x = int(point.x), y = int(point.y);
    uint2 range = ranges[(uint(y) / size.tileSize) * size.tilesAcross + uint(x) / size.tileSize];
    uint colour = 0;
    uint first = range.x;
    // Find the last fully opaque contribution. Everything before it is hidden.
    // Destination palette filters and partially covered text must still be
    // replayed in painter order after that contribution.
    for (uint j = range.y; j > range.x; --j) {
        MetalCommand c = commands[indices[j-1]];
        if (x < c.left || y < c.top || x >= c.right || y >= c.bottom) continue;
        if (c.flags & 1u) {
            if ((c.flags & 64u) && ((x-c.destX+y-c.destY)&1) != 0) continue;
            colour = c.colour;
            first = j;
            break;
        }
        if (c.flags & (2u|32u)) continue;
        uint sample = sourceSample(c, point, size, sprites);
        if (sample == 256) continue;
        if (c.flags & 128u) {
            if (sample == 0 || ((c.colour >> 8) != 0 && sample <= 180)) continue;
            sample = c.colour & 255u;
        } else if (c.flags & 16u) {
            if (sample >= c.mapLength) continue;
            sample = maps[c.mapOffset+sample];
            if ((c.flags & 8u) && sample == 0) continue;
        }
        colour = sample;
        first = j;
        break;
    }
    for (uint i = first; i < range.y; ++i) {
        MetalCommand c = commands[indices[i]];
        if (x < c.left || y < c.top || x >= c.right || y >= c.bottom) continue;
        if (c.flags & 1u) {
            if (!(c.flags & 64u) || ((x-c.destX+y-c.destY)&1) == 0) colour = c.colour;
            continue;
        }
        if (c.flags & 2u) {
            if (colour < c.mapLength) colour = maps[c.mapOffset+colour];
            continue;
        }
        uint sample = sourceSample(c, point, size, sprites);
        if (sample == 256) continue;
        if (c.flags & 128u) {
            uint threshold = c.colour >> 8;
            if (sample != 0) {
                if (threshold == 0 || sample > 180) colour = c.colour & 255u;
                else if (sample > threshold) colour = maps[c.mapOffset+colour];
            }
            continue;
        }
        uint index = sample;
        if (c.flags & 32u) index = (c.flags & 16u) ? (sample-1)*256+colour : colour;
        if (c.flags & (16u|32u)) {
            if (index >= c.mapLength) continue;
            sample = maps[c.mapOffset+index];
            if ((c.flags & 8u) && sample == 0) continue;
        }
        colour = sample;
    }
    pixels[position.y*size.width+position.x] = uchar(colour);
    uint rgba = palette[colour];
    output.write(float4(float(rgba&255),float((rgba>>8)&255),float((rgba>>16)&255),255.0)/255.0,position);
}

// Unoptimised build-6 rasterizer, retained only for opt-in native-pixel verification.
kernel void drawIndexedReference(
    device const MetalCommand* commands [[buffer(0)]],
    device const uint2* ranges [[buffer(1)]],
    device const uint* indices [[buffer(2)]],
    device const ushort* sprites [[buffer(3)]],
    device const uchar* maps [[buffer(4)]],
    device uchar* pixels [[buffer(5)]],
    constant uint* palette [[buffer(6)]],
    constant FrameSize& size [[buffer(7)]],
    texture2d<float, access::write> output [[texture(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= size.width || position.y >= size.height) return;
    // Rasterize at drawable density; commands, clipping and input remain logical.
    float2 point = (float2(position)+0.5)*float2(size.logicalWidth,size.logicalHeight)/float2(size.width,size.height);
    const int x = int(point.x), y = int(point.y);
    uint2 range = ranges[(uint(y) / size.tileSize) * size.tilesAcross + uint(x) / size.tileSize];
    uint colour = 0;
    for (uint i = range.x; i < range.y; ++i) {
        MetalCommand c = commands[indices[i]];
        if (x < c.left || y < c.top || x >= c.right || y >= c.bottom) continue;
        if (c.flags & 1u) {
            if (!(c.flags & 64u) || ((x-c.destX+y-c.destY)&1) == 0) colour = c.colour;
            continue;
        }
        if (c.flags & 2u) {
            if (colour < c.mapLength) colour = maps[c.mapOffset+colour];
            continue;
        }
        float2 local = point-float2(c.destX,c.destY);
        // At density 1 use the original software sample positions for comparison.
        if (size.width == size.logicalWidth && size.height == size.logicalHeight)
            local = floor(point)-float2(c.destX,c.destY);
        float2 source = c.zoom >= 0 ? float2(c.sourceX,c.sourceY)+local*float(1<<c.zoom)
                                   : (float2(c.sourceX,c.sourceY)+local)/float(1<<(-c.zoom));
        if (c.flags & 256u) source = (point-float2(c.spriteX,c.spriteY))*c.textScaleX;
        if (c.flags & 128u) source = local*float2(c.textScaleX,c.textScaleY);
        int sx = int(floor(source.x)), sy = int(floor(source.y));
        if (sx < 0 || sy < 0 || sx >= int(c.textureWidth) || sy >= int(c.textureHeight)) continue;
        uint sample = sprites[c.textureOffset+uint(sy)*c.textureWidth+uint(sx)];
        if (!(sample & 256u)) continue;
        sample &= 255u;
        if (c.flags & 4u) {
            if (sx >= int(c.maskWidth) || sy >= int(c.colour)) continue;
            sample &= sprites[c.maskOffset+uint(sy)*c.maskWidth+uint(sx)] & 255u;
        }
        if ((c.flags & 8u) && sample == 0) continue;
        if (c.flags & 128u) {
            uint threshold = c.colour >> 8;
            if (sample != 0) {
                if (threshold == 0 || sample > 180) colour = c.colour & 255u;
                else if (sample > threshold) colour = maps[c.mapOffset+colour];
            }
            continue;
        }
        uint index = sample;
        if (c.flags & 32u) index = (c.flags & 16u) ? (sample-1)*256+colour : colour;
        if (c.flags & (16u|32u)) {
            if (index >= c.mapLength) continue;
            sample = maps[c.mapOffset+index];
            if ((c.flags & 8u) && sample == 0) continue;
        }
        colour = sample;
    }
    pixels[position.y*size.width+position.x] = uchar(colour);
    uint rgba = palette[colour];
    output.write(float4(float(rgba&255),float((rgba>>8)&255),float((rgba>>16)&255),255.0)/255.0,position);
}

struct VertexOutput { float4 position [[position]]; float2 uv; };
vertex VertexOutput fullscreenVertex(uint index [[vertex_id]]) {
    const float2 positions[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    VertexOutput out;
    out.position = float4(positions[index],0,1);
    out.uv = float2((positions[index].x+1)*0.5,(1-positions[index].y)*0.5);
    return out;
}
fragment float4 presentIndexed(VertexOutput in [[stage_in]], texture2d<float> canvas [[texture(0)]],
                              constant uint& quality [[buffer(0)]]) {
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    if (quality == 0) return canvas.sample(nearestSampler,in.uv);
    if (quality == 1) return canvas.sample(linearSampler,in.uv);
    float2 size = float2(canvas.get_width(),canvas.get_height());
    float2 pixel = in.uv*size;
    float2 footprint = max(fwidth(pixel),float2(0.0001));
    // Keep each source pixel's interior at its texel centre. Only blend where an
    // output pixel straddles a source-pixel boundary. Mapping the interior across
    // [0, 1] instead makes even enlarged pixel interiors blend with neighbours.
    float2 fraction = fract(pixel);
    float2 snapped = clamp(fraction/footprint,0.0,0.5)
                   + clamp((fraction-1.0)/footprint+0.5,0.0,0.5);
    float2 uv = (floor(pixel)+snapped)/size;
    return canvas.sample(linearSampler,uv);
}
