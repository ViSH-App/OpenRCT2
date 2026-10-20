/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_METAL
    #include "../../../UiContext.iOS.h"
    #include "../DrawingEngineFactory.hpp"

    #import <Metal/Metal.h>
    #import <QuartzCore/CAMetalLayer.h>
    #include <SDL.h>
    #include <SDL_metal.h>
    #include <algorithm>
    #include <array>
    #include <cmath>
    #include <cstdlib>
    #include <cstring>
    #include <openrct2/Context.h>
    #include <openrct2/config/Config.h>
    #include <openrct2/drawing/BlendColourMap.h>
    #include <openrct2/drawing/Drawing.Sprite.h>
    #include <openrct2/drawing/Drawing.String.h>
    #include <openrct2/drawing/Drawing.h>
    #include <openrct2/drawing/LightFX.h>
    #include <openrct2/drawing/RenderTarget.h>
    #include <openrct2/drawing/TTF.h>
    #include <openrct2/drawing/X8DrawingEngine.h>
    #include <openrct2/interface/Screenshot.h>
    #include <openrct2/interface/Window.h>
    #include <openrct2/platform/Platform.h>
    #include <openrct2/ui/UiContext.h>
    #include <stdexcept>
    #include <unordered_map>
    #include <vector>

using namespace OpenRCT2;
using namespace OpenRCT2::Drawing;
using namespace OpenRCT2::Ui;

namespace
{
    constexpr uint32_t kTileSize = 16;
    enum CommandFlag : uint32_t
    {
        fill = 1,
        filter = 2,
        mask = 4,
        transparent = 8,
        remapSource = 16,
        remapDestination = 32,
        crossHatch = 64,
        ttf = 128,
        nativeSprite = 256,
    };
    // Scalar layout shared with MetalShaders.metal (no SIMD padding).
    struct MetalCommand
    {
        int32_t left{}, top{}, right{}, bottom{};
        int32_t destX{}, destY{}, sourceX{}, sourceY{};
        uint32_t textureOffset{}, textureWidth{}, textureHeight{}, maskOffset{}, maskWidth{};
        int32_t zoom{};
        uint32_t flags{}, mapOffset{}, mapLength{}, colour{};
        float textScaleX{ 1 }, textScaleY{ 1 };
        float spriteX{}, spriteY{};
    };
    static_assert(sizeof(MetalCommand) == 88);
    struct FrameSize
    {
        uint32_t width, height, tilesAcross, tileSize;
        uint32_t logicalWidth, logicalHeight;
    };
    struct TileRange
    {
        uint32_t begin, end;
    };
    struct Sprite
    {
        uint32_t offset{}, width{}, height{};
    };

    void Check(bool condition, NSString* message)
    {
        if (!condition)
            throw std::runtime_error(message.UTF8String ?: "Metal operation failed");
    }

    class MetalDrawingEngine final : public IDrawingEngine, public IDrawingContext, public IWeatherDrawer
    {
        SDL_Window* _window{};
        SDL_MetalView _view{};
        id<MTLDevice> _device;
        id<MTLCommandQueue> _queue;
        id<MTLComputePipelineState> _rasterizer;
        id<MTLComputePipelineState> _referenceRasterizer;
        id<MTLBuffer> _referencePixels;
        id<MTLTexture> _referenceCanvas;
        id<MTLRenderPipelineState> _presenter;
        CAMetalLayer* _layer;
        id<MTLTexture> _canvas;
        id<MTLBuffer> _pixels;
        id<MTLBuffer> _spriteBuffer;
        id<MTLCommandBuffer> _lastCommand;
        dispatch_semaphore_t _inflight = dispatch_semaphore_create(3);
        std::vector<PaletteIndex> _bits;
        RenderTarget _rt{};
        std::array<uint32_t, 256> _palette{};
        std::vector<MetalCommand> _commands;
        std::vector<std::vector<uint32_t>> _bins;
        std::vector<uint8_t> _maps;
        std::unordered_map<std::string, uint32_t> _mapOffsets;
        std::vector<uint16_t> _spritePixels;
        std::unordered_map<ImageIndex, Sprite> _sprites;
        std::unordered_map<std::string, Sprite> _textSprites;
        size_t _uploadedPixels{};
        uint32_t _tilesAcross{};
        uint32_t _rasterWidth{}, _rasterHeight{};
        bool _ownsTTF{};
        std::unordered_map<std::string, TTF_Font*> _retinaFonts;
        std::unordered_map<std::string, Sprite> _retinaText;
        uint64_t _frame{};
        bool _validate = std::getenv("OPENRCT2_METAL_VALIDATE") != nullptr;
        bool _compareGPU = std::getenv("OPENRCT2_METAL_COMPARE_GPU") != nullptr;
        X8DrawingContext _reference{ nullptr };

        id<MTLBuffer> Buffer(const void* bytes, size_t size)
        {
            if (size == 0)
                return [_device newBufferWithLength:4 options:MTLResourceStorageModeShared];
            auto buffer = [_device newBufferWithBytes:bytes length:size options:MTLResourceStorageModeShared];
            Check(buffer != nil, @"Metal buffer allocation failed");
            return buffer;
        }
        ScreenCoordsXY Origin(const RenderTarget& rt) const
        {
            const auto offset = rt.bits - _rt.bits;
            return { static_cast<int32_t>(offset % _rt.width), static_cast<int32_t>(offset / _rt.width) };
        }
        void Add(const RenderTarget& rt, MetalCommand command)
        {
            auto origin = Origin(rt);
            command.left = std::max({ command.left, origin.x, 0 });
            command.top = std::max({ command.top, origin.y, 0 });
            command.right = std::min({ command.right, origin.x + rt.width, _rt.width });
            command.bottom = std::min({ command.bottom, origin.y + rt.height, _rt.height });
            if (command.left >= command.right || command.top >= command.bottom)
                return;
            const auto index = static_cast<uint32_t>(_commands.size());
            _commands.push_back(command);
            for (uint32_t y = command.top / kTileSize; y <= static_cast<uint32_t>(command.bottom - 1) / kTileSize; ++y)
                for (uint32_t x = command.left / kTileSize; x <= static_cast<uint32_t>(command.right - 1) / kTileSize; ++x)
                    _bins[y * _tilesAcross + x].push_back(index);
        }
        void AddMap(MetalCommand& command, const PaletteMap& map)
        {
            auto bytes = map.GetData();
            std::string key(reinterpret_cast<const char*>(bytes.data()), bytes.size());
            auto found = _mapOffsets.find(key);
            if (found == _mapOffsets.end())
            {
                auto offset = static_cast<uint32_t>(_maps.size());
                const auto* data = reinterpret_cast<const uint8_t*>(bytes.data());
                _maps.insert(_maps.end(), data, data + bytes.size());
                found = _mapOffsets.emplace(std::move(key), offset).first;
            }
            command.mapOffset = found->second;
            command.mapLength = static_cast<uint32_t>(bytes.size());
        }
        Sprite CacheImage(ImageIndex image)
        {
            auto found = _sprites.find(image);
            if (found != _sprites.end())
                return found->second;
            const auto* g1 = GfxGetG1Element(image);
            if (!g1 || g1->width <= 0 || g1->height <= 0 || g1->flags.has(G1Flag::isPalette))
                return {};
            Sprite sprite{ static_cast<uint32_t>(_spritePixels.size()), static_cast<uint32_t>(g1->width),
                           static_cast<uint32_t>(g1->height) };
            _spritePixels.resize(_spritePixels.size() + sprite.width * sprite.height);
            auto* output = _spritePixels.data() + sprite.offset;
            // Decode source assets only. No screen pixels are composed on the CPU.
            // The extra coverage bit preserves RLE holes independently of palette index zero.
            if (g1->flags.has(G1Flag::hasRLECompression))
            {
                for (uint32_t y = 0; y < sprite.height; ++y)
                {
                    const auto* run = g1->offset + (g1->offset[y * 2] | (g1->offset[y * 2 + 1] << 8));
                    bool last = false;
                    do
                    {
                        auto length = *run++;
                        auto start = *run++;
                        last = (length & 0x80) != 0;
                        length &= 0x7f;
                        for (uint32_t x = 0; x < length && x + start < sprite.width; ++x)
                            output[y * sprite.width + x + start] = 256 | run[x];
                        run += length;
                    } while (!last);
                }
            }
            else if (!g1->flags.has(G1Flag::one))
            {
                for (size_t i = 0; i < sprite.width * sprite.height; ++i)
                    output[i] = 256 | g1->offset[i];
            }
            _sprites.emplace(image, sprite);
            return sprite;
        }
        void RecordSprite(RenderTarget& rt, const DrawSpriteArgs& args)
        {
            auto sprite = CacheImage(args.Image.GetIndex());
            if (!sprite.width)
                return;
            MetalCommand c{};
            const auto offset = args.DestinationBits - _rt.bits;
            c.destX = c.left = static_cast<int32_t>(offset % _rt.width);
            c.destY = c.top = static_cast<int32_t>(offset / _rt.width);
            c.zoom = static_cast<int8_t>(rt.zoom_level);
            const int step = c.zoom >= 0 ? 1 << c.zoom : 1;
            c.right = c.left + (args.Width + step - 1) / step;
            c.bottom = c.top + (args.Height + step - 1) / step;
            c.sourceX = args.SrcX;
            c.sourceY = args.SrcY;
            c.textureOffset = sprite.offset;
            c.textureWidth = sprite.width;
            c.textureHeight = sprite.height;
            const bool rle = args.SourceImage.flags.has(G1Flag::hasRLECompression);
            if (args.Image.HasPrimary())
                c.flags |= remapSource;
            if (args.Image.IsBlended())
                c.flags |= remapDestination;
            if (args.Image.HasPrimary() || args.Image.IsBlended()
                || (rle ? c.zoom != 0 : args.SourceImage.flags.has(G1Flag::hasTransparency)))
                c.flags |= transparent;
            if (c.flags & (remapSource | remapDestination))
                AddMap(c, args.PalMap);
            Add(rt, c);
        }
        void RecordNativeSprite(RenderTarget& rt, ImageId image, const ScreenCoordsXY& coords, const PaletteMap& map)
        {
            const auto* g1 = GfxGetG1Element(image);
            if (!g1 || (rt.zoom_level > ZoomLevel{ 0 } && g1->flags.has(G1Flag::noZoomDraw)))
                return;
            auto sprite = CacheImage(image.GetIndex());
            if (!sprite.width)
                return;
            auto origin = Origin(rt);
            MetalCommand c{};
            c.zoom = static_cast<int8_t>(rt.zoom_level);
            const float step = std::ldexp(1.0f, c.zoom);
            c.textScaleX = step;
            c.spriteX = (coords.x + g1->xOffset) / step - rt.x + origin.x;
            c.spriteY = (coords.y + g1->yOffset) / step - rt.y + origin.y;
            c.left = std::floor(c.spriteX);
            c.top = std::floor(c.spriteY);
            c.right = std::ceil(c.spriteX + sprite.width / step);
            c.bottom = std::ceil(c.spriteY + sprite.height / step);
            c.textureOffset = sprite.offset;
            c.textureWidth = sprite.width;
            c.textureHeight = sprite.height;
            c.flags = nativeSprite;
            if (image.HasPrimary())
                c.flags |= remapSource;
            if (image.IsBlended())
                c.flags |= remapDestination;
            if (image.HasPrimary() || image.IsBlended()
                || (g1->flags.has(G1Flag::hasRLECompression) ? c.zoom != 0 : g1->flags.has(G1Flag::hasTransparency)))
                c.flags |= transparent;
            if (c.flags & (remapSource | remapDestination))
                AddMap(c, map);
            Add(rt, c);
        }
        void SpriteWithPalette(RenderTarget& rt, ImageId imageId, const ScreenCoordsXY& coords, const PaletteMap& paletteMap);
        void TTFCommand(
            RenderTarget& rt, Sprite sprite, int x, int y, PaletteIndex colour, uint8_t threshold, int logicalWidth = 0,
            int logicalHeight = 0)
        {
            auto origin = Origin(rt);
            MetalCommand c{};
            c.destX = c.left = x - rt.x + origin.x;
            c.destY = c.top = y - rt.y + origin.y;
            c.right = c.left + (logicalWidth ? logicalWidth : sprite.width);
            c.bottom = c.top + (logicalHeight ? logicalHeight : sprite.height);
            c.textScaleX = static_cast<float>(sprite.width) / (c.right - c.left);
            c.textScaleY = static_cast<float>(sprite.height) / (c.bottom - c.top);
            c.textureOffset = sprite.offset;
            c.textureWidth = sprite.width;
            c.textureHeight = sprite.height;
            c.flags = ttf;
            c.colour = EnumValue(colour) | (static_cast<uint32_t>(threshold) << 8);
    #ifndef DISABLE_TTF
            if (threshold)
            {
                auto* blend = GetBlendColourMap();
                AddMap(c, PaletteMap((*blend)[EnumValue(colour)]));
            }
    #endif
            Add(rt, c);
        }
        void UploadSprites()
        {
            const auto size = _spritePixels.size() * sizeof(uint16_t);
            if (!_spriteBuffer || _spriteBuffer.length < size)
            {
                _spriteBuffer = [_device newBufferWithLength:std::max<size_t>(size * 2, 4096)
                                                     options:MTLResourceStorageModeShared];
                Check(_spriteBuffer != nil, @"Metal sprite cache allocation failed");
                _uploadedPixels = 0;
            }
            if (_uploadedPixels < _spritePixels.size())
                std::memcpy(
                    static_cast<uint16_t*>(_spriteBuffer.contents) + _uploadedPixels, _spritePixels.data() + _uploadedPixels,
                    (_spritePixels.size() - _uploadedPixels) * sizeof(uint16_t));
            _uploadedPixels = _spritePixels.size();
        }

    public:
        explicit MetalDrawingEngine(IUiContext& ui)
            : _window(static_cast<SDL_Window*>(ui.GetWindow()))
        {
            _rt.DrawingEngine = this;
            LightFx::SetAvailable(false);
        }
        ~MetalDrawingEngine() override
        {
            [_lastCommand waitUntilCompleted];
            for (auto& [key, font] : _retinaFonts)
                TTF_CloseFont(font);
            if (_ownsTTF)
                TTF_Quit();
            if (_view)
                SDL_Metal_DestroyView(_view);
        }
        void Initialise() override
        {
            _device = MTLCreateSystemDefaultDevice();
            Check(_device != nil, @"Metal is not available on this device");
            _queue = [_device newCommandQueue];
            NSError* error = nil;
            NSURL* url = [NSBundle.mainBundle URLForResource:@"OpenRCT2" withExtension:@"metallib"];
            Check(url != nil, @"OpenRCT2.metallib is missing from the application");
            auto library = [_device newLibraryWithURL:url error:&error];
            Check(library != nil, error.localizedDescription);
            _rasterizer = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"drawIndexed"]
                                                                 error:&error];
            Check(_rasterizer != nil, error.localizedDescription);
            if (_compareGPU)
            {
                _referenceRasterizer = [_device
                    newComputePipelineStateWithFunction:[library newFunctionWithName:@"drawIndexedReference"]
                                                  error:&error];
                Check(_referenceRasterizer != nil, error.localizedDescription);
            }
            auto descriptor = [MTLRenderPipelineDescriptor new];
            descriptor.vertexFunction = [library newFunctionWithName:@"fullscreenVertex"];
            descriptor.fragmentFunction = [library newFunctionWithName:@"presentIndexed"];
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            _presenter = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
            Check(_presenter != nil, error.localizedDescription);
            _view = SDL_Metal_CreateView(_window);
            Check(_view != nullptr, @"Unable to create the SDL Metal view");
            _layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(_view);
            _layer.device = _device;
            _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            _layer.framebufferOnly = YES;
            fprintf(
                stderr, "Native Metal indexed drawing engine: %s; software comparison=%s\n", _device.name.UTF8String,
                _validate ? "on" : "off");
        }
        void Resize(uint32_t width, uint32_t height) override
        {
            if (!width || !height)
                return;
            [_lastCommand waitUntilCompleted];
            _bits.assign(static_cast<size_t>(width) * height, PaletteIndex::transparent);
            _rt.bits = _bits.data();
            _rt.width = width;
            _rt.height = height;
            _rt.pitch = 0;
            _tilesAcross = (width + kTileSize - 1) / kTileSize;
            _bins.clear();
            _bins.resize(_tilesAcross * ((height + kTileSize - 1) / kTileSize));
            UpdateRasterSize();
        }
        void UpdateRasterSize()
        {
            int windowWidth = 0, windowHeight = 0, drawableWidth = 0, drawableHeight = 0;
            SDL_GetWindowSize(_window, &windowWidth, &windowHeight);
            SDL_Metal_GetDrawableSize(_window, &drawableWidth, &drawableHeight);
            const auto content = IOS::ContentRect(_window);
            const uint32_t width = _validate
                ? _rt.width
                : std::max(1L, std::lround(static_cast<double>(content.w) * drawableWidth / std::max(windowWidth, 1)));
            const uint32_t height = _validate
                ? _rt.height
                : std::max(1L, std::lround(static_cast<double>(content.h) * drawableHeight / std::max(windowHeight, 1)));
            if (_canvas && width == _rasterWidth && height == _rasterHeight)
                return;
            [_lastCommand waitUntilCompleted];
            _rasterWidth = width;
            _rasterHeight = height;
            _pixels = [_device newBufferWithLength:static_cast<size_t>(width) * height options:MTLResourceStorageModeShared];
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:width
                                                                                height:height
                                                                             mipmapped:NO];
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            _canvas = [_device newTextureWithDescriptor:descriptor];
            Check(_canvas != nil && _pixels != nil, @"Metal Retina canvas allocation failed");
            if (_compareGPU)
            {
                _referenceCanvas = [_device newTextureWithDescriptor:descriptor];
                _referencePixels = [_device newBufferWithLength:static_cast<size_t>(width) * height
                                                        options:MTLResourceStorageModeShared];
                Check(_referenceCanvas != nil && _referencePixels != nil, @"Metal comparison allocation failed");
            }
            fprintf(
                stderr, "Metal raster=%ux%u logical=%dx%d drawable=%dx%d comparison=%s\n", width, height, _rt.width, _rt.height,
                drawableWidth, drawableHeight, _validate ? "on" : "off");
        }
        void SetPalette(const GamePalette& colours) override
        {
            for (size_t i = 0; i < 256; ++i)
                _palette[i] = colours[i].red | (colours[i].green << 8) | (colours[i].blue << 16) | 0xff000000;
        }
        void SetVSync(bool) override
        { /* CAMetalLayer presents on display refresh on iPadOS. */
        }
        void Invalidate(int32_t, int32_t, int32_t, int32_t) override
        {
        }
        void CopyRect(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t) override
        {
            // This backend redraws the whole frame; viewport copies would only duplicate work.
        }
        DrawingEngineFlags GetFlags() override
        {
            return {};
        }
        IDrawingContext* GetDrawingContext() override
        {
            return this;
        }
        RenderTarget* getRT() override
        {
            return &_rt;
        }
        void InvalidateImage(uint32_t image) override
        {
            _sprites.erase(image);
        }
        void BeginDraw() override
        {
            UpdateRasterSize();
            _commands.clear();
            _maps.clear();
            _mapOffsets.clear();
            for (auto& bin : _bins)
                bin.clear();
            // Bound cache growth from dynamic sprites/TTF surfaces. Submitted commands retain
            // their old Metal buffers while a new cache is allocated for subsequent frames.
            if (_spritePixels.size() > 64 * 1024 * 1024)
            {
                _sprites.clear();
                _textSprites.clear();
                _retinaText.clear();
                _spritePixels.clear();
                _spriteBuffer = nil;
                _uploadedPixels = 0;
            }
            if (_validate)
            {
                std::fill(_bits.begin(), _bits.end(), PaletteIndex::transparent);
                _reference.BeginDraw();
            }
        }
        void PaintWindows() override
        {
            WindowUpdateAllViewports();
            WindowDrawAll(_rt, 0, 0, _rt.width, _rt.height);
        }
        void PaintWeather() override
        {
            DrawWeather(_rt, this);
        }
        void EndDraw() override;
        std::string Screenshot() override
        {
            [_lastCommand waitUntilCompleted];
            auto screenshotRT = _rt;
            screenshotRT.width = _rasterWidth;
            screenshotRT.height = _rasterHeight;
            screenshotRT.bits = static_cast<PaletteIndex*>(_pixels.contents);
            return ScreenshotDumpPNG(screenshotRT);
        }
        void Clear(RenderTarget& rt, PaletteIndex colour) override
        {
            FillRect(rt, colour, rt.x, rt.y, rt.x + rt.width - 1, rt.y + rt.height - 1, false);
        }
        void FillRect(
            RenderTarget& rt, PaletteIndex colour, int32_t left, int32_t top, int32_t right, int32_t bottom,
            bool hatch = false) override
        {
            if (_validate)
                _reference.FillRect(rt, colour, left, top, right, bottom, hatch);
            auto origin = Origin(rt);
            MetalCommand c{};
            c.destX = c.left = left - rt.x + origin.x;
            c.destY = c.top = top - rt.y + origin.y;
            c.right = right - rt.x + origin.x + 1;
            c.bottom = bottom - rt.y + origin.y + 1;
            c.colour = EnumValue(colour);
            c.flags = fill | (hatch ? crossHatch : 0);
            Add(rt, c);
        }
        void FilterRect(
            RenderTarget& rt, FilterPaletteID palette, int32_t left, int32_t top, int32_t right, int32_t bottom) override
        {
            if (_validate)
                _reference.FilterRect(rt, palette, left, top, right, bottom);
            auto map = GetPaletteMapForColour(palette);
            if (!map)
                return;
            auto origin = Origin(rt);
            MetalCommand c{};
            c.left = left - rt.x + origin.x;
            c.top = top - rt.y + origin.y;
            c.right = right - rt.x + origin.x + 1;
            c.bottom = bottom - rt.y + origin.y + 1;
            c.flags = filter;
            AddMap(c, *map);
            Add(rt, c);
        }
        void DrawLine(RenderTarget& rt, PaletteIndex colour, const ScreenLine& line) override;
        void DrawSprite(RenderTarget& rt, ImageId image, int32_t x, int32_t y) override
        {
            if (_validate)
                _reference.DrawSprite(rt, image, x, y);
            auto map = PaletteMap::GetDefault();
            std::array<PaletteIndex, 256> colours;
            if (image.HasSecondary())
            {
                for (size_t i = 0; i < colours.size(); ++i)
                    colours[i] = static_cast<PaletteIndex>(i);
                colours[1] = static_cast<PaletteIndex>(243);
                colours[2] = static_cast<PaletteIndex>(244);
                colours[3] = static_cast<PaletteIndex>(245);
                map = PaletteMap(colours);
                auto copy = [&](Colour source, PaletteIndex destination) {
                    auto remap = GetPaletteMapForColour(static_cast<FilterPaletteID>(source));
                    if (remap)
                        map.Copy(destination, *remap, PaletteIndex::primaryRemap0, 12);
                };
                copy(image.GetPrimary(), PaletteIndex::primaryRemap0);
                copy(image.GetSecondary(), PaletteIndex::secondaryRemap0);
                if (image.HasTertiary())
                    copy(image.GetTertiary(), PaletteIndex::tertiaryRemap0);
            }
            else if (image.HasPrimary() || image.IsBlended())
            {
                auto palette = GetPaletteMapForColour(
                    static_cast<FilterPaletteID>(image.GetRemap() & (image.IsBlended() ? 255 : 127)));
                if (palette)
                    map = *palette;
            }
            SpriteWithPalette(rt, image, { x, y }, map);
        }
        void DrawGlyph(RenderTarget& rt, ImageId image, int32_t x, int32_t y, const PaletteMap& map) override
        {
            if (_validate)
                _reference.DrawGlyph(rt, image, x, y, map);
            SpriteWithPalette(rt, image, { x, y }, map);
        }
        void DrawSpriteSolid(RenderTarget& rt, ImageId image, int32_t x, int32_t y, PaletteIndex colour) override
        {
            if (_validate)
                _reference.DrawSpriteSolid(rt, image, x, y, colour);
            std::array<PaletteIndex, 256> colours;
            colours.fill(colour);
            colours[0] = PaletteIndex::transparent;
            SpriteWithPalette(rt, ImageId(image.GetIndex(), Colour::black), { x, y }, PaletteMap(colours));
        }
        void DrawSpriteRawMasked(RenderTarget& rt, int32_t x, int32_t y, ImageId maskImage, ImageId colourImage) override
        {
            const auto* m = GfxGetG1Element(maskImage);
            const auto* c = GfxGetG1Element(colourImage);
            if (!m || !c)
                return;
            if (m->flags.has(G1Flag::hasRLECompression) || c->flags.has(G1Flag::hasRLECompression))
            {
                DrawSprite(rt, colourImage, x, y);
                return;
            }
            if (_validate)
                _reference.DrawSpriteRawMasked(rt, x, y, maskImage, colourImage);
            auto maskSprite = CacheImage(maskImage.GetIndex());
            auto colourSprite = CacheImage(colourImage.GetIndex());
            auto origin = Origin(rt);
            MetalCommand cmd{};
            cmd.zoom = static_cast<int8_t>(rt.zoom_level);
            cmd.destX = cmd.left = rt.zoom_level.ApplyInversedTo(x + m->xOffset) - rt.x + origin.x;
            cmd.destY = cmd.top = rt.zoom_level.ApplyInversedTo(y + m->yOffset) - rt.y + origin.y;
            cmd.right = cmd.left + rt.zoom_level.ApplyInversedTo(std::min(m->width, c->width));
            cmd.bottom = cmd.top + rt.zoom_level.ApplyInversedTo(std::min(m->height, c->height));
            cmd.textureOffset = colourSprite.offset;
            cmd.textureWidth = colourSprite.width;
            cmd.textureHeight = colourSprite.height;
            cmd.maskOffset = maskSprite.offset;
            cmd.maskWidth = maskSprite.width;
            cmd.flags = mask | transparent;
            cmd.colour = maskSprite.height;
            if (!_validate)
            {
                const float step = std::ldexp(1.0f, cmd.zoom);
                cmd.flags |= nativeSprite;
                cmd.textScaleX = step;
                cmd.spriteX = (x + m->xOffset) / step - rt.x + origin.x;
                cmd.spriteY = (y + m->yOffset) / step - rt.y + origin.y;
                cmd.left = std::floor(cmd.spriteX);
                cmd.top = std::floor(cmd.spriteY);
                cmd.right = std::ceil(cmd.spriteX + std::min(m->width, c->width) / step);
                cmd.bottom = std::ceil(cmd.spriteY + std::min(m->height, c->height) / step);
            }
            Add(rt, cmd);
        }
        bool TryDrawTTFText(
            RenderTarget& rt, const TextDrawInfo& info, const TTFFontDescriptor& fontDesc, std::string_view text,
            const TTFSurface& logical, int32_t x, int32_t y) override
        {
            if (_validate || logical.w <= 0 || logical.h <= 0)
                return false;
            if (!_ownsTTF)
            {
                if (TTF_Init() != 0)
                    return false;
                _ownsTTF = true;
            }
            const auto density = std::max(
                static_cast<double>(_rasterWidth) / _rt.width, static_cast<double>(_rasterHeight) / _rt.height);
            const auto pointSize = static_cast<int>(std::ceil(fontDesc.ptSize * density));
            const auto fontKey = std::string(fontDesc.filename) + ":" + fontDesc.font_name + ":" + std::to_string(pointSize);
            const auto textKey = fontKey + ":" + std::string(text);
            auto entry = _retinaText.find(textKey);
            if (entry == _retinaText.end())
            {
                auto font = _retinaFonts.find(fontKey);
                if (font == _retinaFonts.end())
                {
                    // Bound face/glyph caches when UI scales or languages change.
                    if (_retinaFonts.size() >= 6)
                    {
                        for (auto& [key, cached] : _retinaFonts)
                            TTF_CloseFont(cached);
                        _retinaFonts.clear();
                    }
                    const auto path = Platform::GetFontPath(fontDesc);
                    auto face = TTF_OpenFont(path.c_str(), pointSize);
                    if (!face)
                        return false;
                    font = _retinaFonts.emplace(fontKey, face).first;
                    fprintf(
                        stderr, "Metal Retina font: %s logical=%d raster=%d pt density=%.3f\n", fontDesc.font_name,
                        fontDesc.ptSize, pointSize, density);
                }
                auto surface = TTF_RenderUTF8(font->second, std::string(text).c_str(), true);
                if (!surface)
                    return false;
                Sprite sprite{ static_cast<uint32_t>(_spritePixels.size()), static_cast<uint32_t>(surface->w),
                               static_cast<uint32_t>(surface->h) };
                const auto* coverage = static_cast<const uint8_t*>(surface->pixels);
                for (size_t i = 0; i < sprite.width * sprite.height; ++i)
                    _spritePixels.push_back(256 | coverage[i]);
                TTFFreeSurface(surface);
                entry = _retinaText.emplace(textKey, sprite).first;
            }
            const auto sprite = entry->second;
            if (info.colourFlags.has(ColourFlag::withOutline))
                for (auto delta : std::array<ScreenCoordsXY, 4>{ { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } })
                    TTFCommand(rt, sprite, x + delta.x, y + delta.y, info.palette.shadowOutline, 64, logical.w, logical.h);
            if (info.colourFlags.has(ColourFlag::inset))
                TTFCommand(rt, sprite, x + 1, y + 1, info.palette.shadowOutline, 64, logical.w, logical.h);
            TTFCommand(rt, sprite, x, y, info.palette.fill, 64, logical.w, logical.h);
            return true;
        }
        void DrawTTFBitmap(
            RenderTarget& rt, const TextDrawInfo& info, TTFSurface* surface, int32_t x, int32_t y, uint8_t threshold) override
        {
    #ifndef DISABLE_TTF
            if (_validate)
                _reference.DrawTTFBitmap(rt, info, surface, x, y, threshold);
            const auto* pixels = static_cast<const uint8_t*>(surface->pixels);
            // TTF surfaces are recycled by the core. Key by content, not their address,
            // and keep immutable atlas entries so in-flight frames remain valid.
            std::string key(reinterpret_cast<const char*>(&surface->w), sizeof(surface->w));
            key.append(reinterpret_cast<const char*>(&surface->h), sizeof(surface->h));
            key.append(reinterpret_cast<const char*>(pixels), static_cast<size_t>(surface->w) * surface->h);
            auto found = _textSprites.find(key);
            if (found == _textSprites.end())
            {
                Sprite sprite{ static_cast<uint32_t>(_spritePixels.size()), static_cast<uint32_t>(surface->w),
                               static_cast<uint32_t>(surface->h) };
                for (size_t i = 0; i < sprite.width * sprite.height; ++i)
                    _spritePixels.push_back(256 | pixels[i]);
                found = _textSprites.emplace(std::move(key), sprite).first;
            }
            const auto sprite = found->second;
            if (info.colourFlags.has(ColourFlag::withOutline))
                for (auto delta : std::array<ScreenCoordsXY, 4>{ { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } })
                    TTFCommand(rt, sprite, x + delta.x, y + delta.y, info.palette.shadowOutline, 0);
            if (info.colourFlags.has(ColourFlag::inset))
                TTFCommand(rt, sprite, x + 1, y + 1, info.palette.shadowOutline, 0);
            TTFCommand(rt, sprite, x, y, info.palette.fill, threshold);
    #endif
        }
        void Draw(
            RenderTarget& rt, int32_t x, int32_t y, int32_t width, int32_t height, int32_t startX, int32_t startY,
            const uint8_t* pattern) override
        {
            const uint8_t xSpace = *pattern++, ySpace = *pattern++;
            const uint8_t xOffset = startX % xSpace, yOffset = startY % ySpace;
            for (int32_t row = 0; row < height; ++row)
            {
                const auto patternY = (yOffset + row) % ySpace;
                if (pattern[patternY * 2] == 255)
                    continue;
                const auto colour = static_cast<PaletteIndex>(pattern[patternY * 2 + 1]);
                const auto first = static_cast<uint8_t>(pattern[patternY * 2] - xOffset) % xSpace;
                for (int32_t col = first; col < width; col += xSpace)
                    FillRect(rt, colour, x + col, y + row, x + col, y + row);
            }
        }
    };

    // Preserve the software renderer's clipping and zoom-sprite sampling exactly.
    void MetalDrawingEngine::SpriteWithPalette(
        RenderTarget& rt, const ImageId imageId, const ScreenCoordsXY& coords, const PaletteMap& paletteMap)
    {
        if (!_validate)
        {
            RecordNativeSprite(rt, imageId, coords, paletteMap);
            return;
        }
        const auto zoomLevel = rt.zoom_level;
        int32_t x = coords.x;
        int32_t y = coords.y;

        const auto* g1 = GfxGetG1Element(imageId);
        if (g1 == nullptr)
        {
            return;
        }

        if (_validate && zoomLevel > ZoomLevel{ 0 } && g1->flags.has(G1Flag::hasZoomSprite))
        {
            RenderTarget zoomedRT = rt;
            zoomedRT.bits = rt.bits;
            zoomedRT.x = rt.x;
            zoomedRT.y = rt.y;
            zoomedRT.height = rt.height;
            zoomedRT.width = rt.width;
            zoomedRT.pitch = rt.pitch;
            zoomedRT.zoom_level = zoomLevel - 1;

            const auto spriteCoords = ScreenCoordsXY{ coords.x / 2, coords.y / 2 };
            SpriteWithPalette(zoomedRT, imageId.WithIndex(imageId.GetIndex() - g1->zoomedOffset), spriteCoords, paletteMap);
            return;
        }

        if (zoomLevel > ZoomLevel{ 0 } && g1->flags.has(G1Flag::noZoomDraw))
        {
            return;
        }

        // mber: There should not be two separate code paths for minifying and magnifying sprites.
        //       I haven't been able to refactor the code in a way that handles both cases properly with one code path.
        //       For the moment, I've added this block here just for magnification with the old code continuing below.
        if (zoomLevel < ZoomLevel{ 0 })
        {
            ScreenCoordsXY spriteTopLeft = { zoomLevel.ApplyInversedTo(coords.x + g1->xOffset),
                                             zoomLevel.ApplyInversedTo(coords.y + g1->yOffset) };

            ScreenCoordsXY spriteBottomLeft{ zoomLevel.ApplyInversedTo(coords.x + g1->xOffset + g1->width),
                                             zoomLevel.ApplyInversedTo(coords.y + g1->yOffset + g1->height) };

            const int32_t width = std::min(spriteBottomLeft.x, rt.x + rt.width) - std::max(spriteTopLeft.x, rt.x);
            const int32_t height = std::min(spriteBottomLeft.y, rt.y + rt.height) - std::max(spriteTopLeft.y, rt.y);

            if (width <= 0 || height <= 0)
                return;

            const int32_t offsetX = rt.x - spriteTopLeft.x;
            const int32_t offsetY = rt.y - spriteTopLeft.y;
            const int32_t srcX = std::max(0, offsetX);
            const int32_t srcY = std::max(0, offsetY);
            PaletteIndex* dst = rt.bits + std::max(0, -offsetX) + std::max(0, -offsetY) * rt.LineStride();

            DrawSpriteArgs args(imageId, paletteMap, *g1, srcX, srcY, width, height, dst);
            RecordSprite(rt, args);
            return;
        }

        const int32_t zoom_mask = zoomLevel > ZoomLevel{ 0 } ? zoomLevel.ApplyTo(0xFFFFFFFF) : 0xFFFFFFFF;

        if (zoomLevel > ZoomLevel{ 0 } && g1->flags.has(G1Flag::hasRLECompression))
        {
            x -= ~zoom_mask;
            y -= ~zoom_mask;
        }

        // This will be the height of the drawn image
        int32_t height = g1->height;

        // This is the start y coordinate on the destination
        int32_t dest_start_y = y + g1->yOffset;

        // For whatever reason the RLE version does not use
        // the zoom mask on the y coordinate but does on x.
        if (g1->flags.has(G1Flag::hasRLECompression))
        {
            dest_start_y -= rt.WorldY();
        }
        else
        {
            dest_start_y = (dest_start_y & zoom_mask) - rt.WorldY();
        }
        // This is the start y coordinate on the source
        int32_t source_start_y = 0;

        if (dest_start_y < 0)
        {
            // If the destination y is negative reduce the height of the
            // image as we will cut off the bottom
            height += dest_start_y;
            // If the image is no longer visible nothing to draw
            if (height <= 0)
            {
                return;
            }
            // The source image will start a further up the image
            source_start_y -= dest_start_y;
            // The destination start is now reset to 0
            dest_start_y = 0;
        }
        else
        {
            if (g1->flags.has(G1Flag::hasRLECompression) && zoomLevel > ZoomLevel{ 0 })
            {
                source_start_y -= dest_start_y & ~zoom_mask;
                height += dest_start_y & ~zoom_mask;
            }
        }

        int32_t dest_end_y = dest_start_y + height;

        if (dest_end_y > rt.WorldHeight())
        {
            // If the destination y is outside of the drawing
            // image reduce the height of the image
            height -= dest_end_y - rt.WorldHeight();
        }
        // If the image no longer has anything to draw
        if (height <= 0)
            return;

        dest_start_y = zoomLevel.ApplyInversedTo(dest_start_y);

        // This will be the width of the drawn image
        int32_t width = g1->width;

        // This is the source start x coordinate
        int32_t source_start_x = 0;
        // This is the destination start x coordinate
        int32_t dest_start_x = ((x + g1->xOffset + ~zoom_mask) & zoom_mask) - rt.WorldX();

        if (dest_start_x < 0)
        {
            // If the destination is negative reduce the width
            // image will cut off the side
            width += dest_start_x;
            // If there is no image to draw
            if (width <= 0)
            {
                return;
            }
            // The source start will also need to cut off the side
            source_start_x -= dest_start_x;
            // Reset the destination to 0
            dest_start_x = 0;
        }
        else
        {
            if (g1->flags.has(G1Flag::hasRLECompression) && zoomLevel > ZoomLevel{ 0 })
            {
                source_start_x -= dest_start_x & ~zoom_mask;
            }
        }

        int32_t dest_end_x = dest_start_x + width;

        if (dest_end_x > rt.WorldWidth())
        {
            // If the destination x is outside of the drawing area
            // reduce the image width.
            width -= dest_end_x - rt.WorldWidth();
            // If there is no image to draw.
            if (width <= 0)
                return;
        }

        dest_start_x = zoomLevel.ApplyInversedTo(dest_start_x);

        PaletteIndex* dest_pointer = rt.bits;
        // Move the pointer to the start point of the destination
        dest_pointer += (zoomLevel.ApplyInversedTo(rt.WorldWidth()) + rt.pitch) * dest_start_y + dest_start_x;

        DrawSpriteArgs args(imageId, paletteMap, *g1, source_start_x, source_start_y, width, height, dest_pointer);
        RecordSprite(rt, args);
    }

    void MetalDrawingEngine::DrawLine(RenderTarget& rt, PaletteIndex colour, const ScreenLine& line)
    {
        if (_validate)
            _reference.DrawLine(rt, colour, line);
        auto span = [&](const ScreenCoordsXY& point, int32_t length) {
            auto origin = Origin(rt);
            MetalCommand c{};
            c.destX = c.left = point.x - rt.x + origin.x;
            c.destY = c.top = point.y - rt.y + origin.y;
            c.right = c.left + std::max(length, 1);
            c.bottom = c.top + 1;
            c.flags = fill;
            c.colour = EnumValue(colour);
            Add(rt, c);
        };
        const ZoomLevel zoom = rt.zoom_level;
        int32_t x1 = zoom.ApplyInversedTo(line.getX1());
        int32_t x2 = zoom.ApplyInversedTo(line.getX2());
        int32_t y1 = zoom.ApplyInversedTo(line.getY1());
        int32_t y2 = zoom.ApplyInversedTo(line.getY2());
        // Check to make sure the line is within the drawing area
        if ((x1 < rt.x) && (x2 < rt.x))
        {
            return;
        }

        if ((y1 < rt.y) && (y2 < rt.y))
        {
            return;
        }

        if ((x1 > (rt.x + rt.width)) && (x2 > (rt.x + rt.width)))
        {
            return;
        }

        if ((y1 > (rt.y + rt.height)) && (y2 > (rt.y + rt.height)))
        {
            return;
        }

        // Bresenham's algorithm

        // If vertical plot points upwards
        int32_t steep = std::abs(y2 - y1) > std::abs(x2 - x1);
        if (steep)
        {
            int32_t temp_y2 = y2;
            int32_t temp_x2 = x2;
            y2 = x1;
            x2 = y1;
            y1 = temp_x2;
            x1 = temp_y2;
        }

        // If line is right to left swap direction
        if (x1 > x2)
        {
            int32_t temp_y2 = y2;
            int32_t temp_x2 = x2;
            y2 = y1;
            x2 = x1;
            y1 = temp_y2;
            x1 = temp_x2;
        }

        int32_t delta_x = x2 - x1;
        int32_t delta_y = std::abs(y2 - y1);
        int32_t error = delta_x / 2;
        int32_t y_step;
        int32_t y = y1;

        // Direction of step
        if (y1 < y2)
            y_step = 1;
        else
            y_step = -1;

        for (int32_t x = x1, x_start = x1, length = 1; x < x2; ++x, ++length)
        {
            // Vertical lines are drawn 1 pixel at a time
            if (steep)
                span({ y, x }, 1);

            error -= delta_y;
            if (error < 0)
            {
                // Non vertical lines are drawn with as many pixels in a horizontal line as possible
                if (!steep)
                    span({ x_start, y }, length);

                // Reset non vertical line vars
                x_start = x + 1;
                length = 0; // NB: will be incremented in next iteration
                y += y_step;
                error += delta_x;
            }

            // Catch the case of the last line
            if (x + 1 == x2 && !steep)
            {
                span({ x_start, y }, length);
            }
        }
    }
    void MetalDrawingEngine::EndDraw()
    {
        if (!_canvas)
        {
            return;
        }
        @autoreleasepool
        {
            dispatch_semaphore_wait(_inflight, DISPATCH_TIME_FOREVER);
            auto completionSemaphore = _inflight;
            std::vector<TileRange> ranges;
            std::vector<uint32_t> indices;
            ranges.reserve(_bins.size());
            for (const auto& bin : _bins)
            {
                const auto begin = static_cast<uint32_t>(indices.size());
                indices.insert(indices.end(), bin.begin(), bin.end());
                ranges.push_back({ begin, static_cast<uint32_t>(indices.size()) });
            }
            UploadSprites();
            auto commands = Buffer(_commands.data(), _commands.size() * sizeof(MetalCommand));
            auto tileRanges = Buffer(ranges.data(), ranges.size() * sizeof(TileRange));
            auto tileIndices = Buffer(indices.data(), indices.size() * sizeof(uint32_t));
            auto maps = Buffer(_maps.data(), _maps.size());
            auto batch = [_queue commandBuffer];
            batch.label = @"OpenRCT2 native Metal frame";
            auto compute = [batch computeCommandEncoder];
            compute.label = @"Indexed sprites, palette filters, text and weather";
            [compute setComputePipelineState:_rasterizer];
            [compute setBuffer:commands offset:0 atIndex:0];
            [compute setBuffer:tileRanges offset:0 atIndex:1];
            [compute setBuffer:tileIndices offset:0 atIndex:2];
            [compute setBuffer:_spriteBuffer offset:0 atIndex:3];
            [compute setBuffer:maps offset:0 atIndex:4];
            [compute setBuffer:_pixels offset:0 atIndex:5];
            [compute setBytes:_palette.data() length:sizeof(_palette) atIndex:6];
            FrameSize size{ _rasterWidth,
                            _rasterHeight,
                            _tilesAcross,
                            kTileSize,
                            static_cast<uint32_t>(_rt.width),
                            static_cast<uint32_t>(_rt.height) };
            [compute setBytes:&size length:sizeof(size) atIndex:7];
            [compute setTexture:_canvas atIndex:0];
            [compute dispatchThreads:MTLSizeMake(size.width, size.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            if (_compareGPU)
            {
                [compute setComputePipelineState:_referenceRasterizer];
                [compute setBuffer:_referencePixels offset:0 atIndex:5];
                [compute setTexture:_referenceCanvas atIndex:0];
                [compute dispatchThreads:MTLSizeMake(size.width, size.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            }
            [compute endEncoding];
            auto drawable = [_layer nextDrawable];
            if (drawable)
            {
                auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = drawable.texture;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                auto encoder = [batch renderCommandEncoderWithDescriptor:pass];
                encoder.label = @"Palette-coloured canvas presentation";
                [encoder setRenderPipelineState:_presenter];
                auto content = IOS::ContentRect(_window);
                int w, h;
                SDL_GetWindowSize(_window, &w, &h);
                const double sx = static_cast<double>(drawable.texture.width) / std::max(w, 1);
                const double sy = static_cast<double>(drawable.texture.height) / std::max(h, 1);
                [encoder setViewport:MTLViewport{ content.x * sx, content.y * sy, content.w * sx, content.h * sy, 0, 1 }];
                [encoder setFragmentTexture:_canvas atIndex:0];
                // Native canvas already matches the content viewport pixel-for-pixel.
                uint32_t quality = 0;
                [encoder setFragmentBytes:&quality length:sizeof(quality) atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [encoder endEncoding];
                [batch presentDrawable:drawable];
            }
            const auto submittedFrame = _frame + 1;
            [batch addCompletedHandler:^(id<MTLCommandBuffer> completed) {
              if (completed.status == MTLCommandBufferStatusError)
                  fprintf(stderr, "Metal GPU command failed: %s\n", completed.error.localizedDescription.UTF8String);
              if (submittedFrame % 600 == 0)
                  fprintf(
                      stderr, "Metal GPU frame=%llu duration=%.2fms\n", static_cast<unsigned long long>(submittedFrame),
                      (completed.GPUEndTime - completed.GPUStartTime) * 1000);
              dispatch_semaphore_signal(completionSemaphore);
            }];
            [batch commit];
            _lastCommand = batch;
            ++_frame;
            if (_compareGPU)
            {
                [batch waitUntilCompleted];
                const auto* actual = static_cast<const uint8_t*>(_pixels.contents);
                const auto* reference = static_cast<const uint8_t*>(_referencePixels.contents);
                size_t mismatch = 0;
                for (size_t i = 0; i < static_cast<size_t>(_rasterWidth) * _rasterHeight; ++i)
                    mismatch += actual[i] != reference[i];
                if (mismatch || _frame % 60 == 0)
                    fprintf(
                        stderr, "Metal native comparison frame=%llu pixels=%u mismatches=%zu\n",
                        static_cast<unsigned long long>(_frame), _rasterWidth * _rasterHeight, mismatch);
            }
            if (_validate)
            {
                _reference.EndDraw();
                [batch waitUntilCompleted];
                const auto* actual = static_cast<const PaletteIndex*>(_pixels.contents);
                size_t mismatch = 0, first = 0;
                for (size_t i = 0; i < _bits.size(); ++i)
                    if (_bits[i] != actual[i])
                    {
                        if (!mismatch)
                            first = i;
                        ++mismatch;
                    }
                if (mismatch || _frame % 60 == 0)
                    fprintf(
                        stderr,
                        "Metal compare frame=%llu commands=%zu mismatches=%zu first=(%zu,%zu) software=%u gpu=%u GPU=%.2fms\n",
                        static_cast<unsigned long long>(_frame), _commands.size(), mismatch, first % _rt.width,
                        first / _rt.width, EnumValue(_bits[first]), EnumValue(actual[first]),
                        (batch.GPUEndTime - batch.GPUStartTime) * 1000);
            }
            else if (_frame % 600 == 0)
                fprintf(
                    stderr, "Metal frame=%llu commands=%zu indexed_pixels=%zu cache=%.1fMiB\n",
                    static_cast<unsigned long long>(_frame), _commands.size(),
                    static_cast<size_t>(_rasterWidth) * _rasterHeight, _spritePixels.size() * 2.0 / (1024 * 1024));
        }
    }
} // namespace

std::unique_ptr<IDrawingEngine> OpenRCT2::Ui::CreateMetalDrawingEngine(IUiContext& uiContext)
{
    return std::make_unique<MetalDrawingEngine>(uiContext);
}
#endif
