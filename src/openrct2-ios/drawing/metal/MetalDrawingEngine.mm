/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_METAL

    #include "MetalDebugOptions.h"
    #include "MetalDrawingContext.h"
    #include "MetalShaderTypes.h"
    #include "MetalTextureCache.h"
    #include "MetalWeatherDrawer.h"

    #include <openrct2-ios/UiContext.iOS.h>
    #include <openrct2-ui/drawing/engines/DrawingEngineFactory.hpp>

    #import <Metal/Metal.h>
    #import <QuartzCore/CAMetalLayer.h>
    #include <SDL.h>
    #include <SDL_metal.h>
    #include <algorithm>
    #include <array>
    #include <atomic>
    #include <bit>
    #include <chrono>
    #include <cmath>
    #include <cstring>
    #include <memory>
    #include <openrct2/Diagnostic.h>
    #include <openrct2/config/Config.h>
    #include <openrct2/core/EnumUtils.hpp>
    #include <openrct2/drawing/Drawing.h>
    #include <openrct2/drawing/IDrawingEngine.h>
    #include <openrct2/drawing/InvalidationGrid.h>
    #include <openrct2/drawing/LightFX.h>
    #include <openrct2/drawing/RenderTarget.h>
    #include <openrct2/drawing/WeatherDrawer.h>
    #include <openrct2/interface/Screenshot.h>
    #include <openrct2/interface/Window.h>
    #include <openrct2/ui/UiContext.h>
    #include <openrct2/world/Weather.h>
    #include <stdexcept>
    #include <vector>

using namespace OpenRCT2;
using namespace OpenRCT2::Drawing;
using namespace OpenRCT2::Ui;
using namespace OpenRCT2::Ui::Metal;

namespace
{
    constexpr uint32_t kFramesInFlight = TextureCache::kFramesInFlight;
    // Dirty-region granularity in logical pixels. X8DrawingEngine uses 128, but at Retina
    // density a block is several hundred raster pixels and small animations then redraw most
    // of the screen. On the iPad mini title screen 16 halved the redrawn area and GPU time
    // compared with 128, without increasing CPU time (see VALIDATION.md).
    constexpr uint32_t kDirtyBlockSize = 16;
    // Initial canvas contents, as X8DrawingEngine::Resize and the OpenGL engine.
    constexpr uint8_t kInitialCanvasIndex = 10;
    constexpr uint64_t kStatisticsInterval = 600;

    // Accumulated on Metal's completion threads; owned jointly with in-flight handlers.
    struct GpuStatistics
    {
        std::atomic<uint64_t> microseconds{};
        std::atomic<uint64_t> maxMicroseconds{};
        std::atomic<uint32_t> frames{};
        std::atomic<bool> failed{};
    };

    // Releases the frame-in-flight slot unless ownership passed to a committed command buffer.
    class InflightSlot
    {
    public:
        explicit InflightSlot(dispatch_semaphore_t semaphore)
            : _semaphore(semaphore)
        {
            dispatch_semaphore_wait(_semaphore, DISPATCH_TIME_FOREVER);
        }
        ~InflightSlot()
        {
            if (_semaphore != nullptr)
                dispatch_semaphore_signal(_semaphore);
        }
        void Release()
        {
            _semaphore = nullptr;
        }
        InflightSlot(const InflightSlot&) = delete;
        InflightSlot& operator=(const InflightSlot&) = delete;

    private:
        dispatch_semaphore_t _semaphore;
    };

    struct FrameSlot
    {
        id<MTLBuffer> commands;
        id<MTLBuffer> order;
        id<MTLBuffer> tiles; // Reference rasterizer bins.
    };

    struct SegmentDraw
    {
        uint32_t begin, end;
        uint32_t independentOffset, independentCount;
        uint32_t dependentOffset, dependentCount;
        std::optional<CopyOperation> copy;
    };

    bool EnsureBuffer(id<MTLDevice> device, id<MTLBuffer> __strong& buffer, size_t size, NSString* label)
    {
        if (buffer != nil && buffer.length >= size)
            return true;
        buffer = [device newBufferWithLength:std::bit_ceil(std::max<size_t>(size, 4096))
                                     options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
        buffer.label = label;
        return buffer != nil;
    }

    void Require(bool condition, const char* message)
    {
        if (!condition)
            throw std::runtime_error(message);
    }

    double Milliseconds(std::chrono::steady_clock::duration duration)
    {
        return std::chrono::duration<double, std::milli>(duration).count();
    }

    class MetalDrawingEngine final : public IDrawingEngine
    {
        SDL_Window* _window{};
        SDL_MetalView _view{};
        CAMetalLayer* _layer;
        id<MTLDevice> _device;
        id<MTLCommandQueue> _queue;
        id<MTLRenderPipelineState> _independentPipeline;
        id<MTLRenderPipelineState> _dependentPipeline;
        id<MTLRenderPipelineState> _presentPipeline;
        id<MTLDepthStencilState> _depthWrite;
        id<MTLDepthStencilState> _depthTest;
        id<MTLDepthStencilState> _depthAlways;
        id<MTLComputePipelineState> _referencePipeline;
        id<MTLComputePipelineState> _referenceCopyPipeline;
        const DebugOptions& _debug = DebugOptions::Get();

        std::unique_ptr<TextureCache> _textureCache;
        std::unique_ptr<DrawingContext> _context;
        std::unique_ptr<WeatherDrawer> _weatherDrawer;

        RenderTarget _rt{};
        std::vector<PaletteIndex> _bits;
        InvalidationGrid _invalidationGrid;
        std::array<uint32_t, 256> _palette{};

        // Raster (physical pixel) canvas and its mapping to logical pixels.
        uint32_t _rasterWidth{}, _rasterHeight{};
        uint32_t _drawableOffsetX{}, _drawableOffsetY{};
        uint32_t _integerDensity{}; // k when raster = k × logical exactly, else 0.
        id<MTLTexture> _canvas;
        id<MTLTexture> _depth;
        id<MTLTexture> _copyScratch;
        id<MTLBuffer> _rasterMap;
        size_t _samplesYOffset{}, _edgesXOffset{}, _edgesYOffset{};
        bool _canvasNeedsClear{};
        bool _forceFullRedraw{ true };
        bool _ignoreCopyRect{};
        bool _parallelThisFrame{};

        dispatch_semaphore_t _inflight = dispatch_semaphore_create(kFramesInFlight);
        std::array<FrameSlot, kFramesInFlight> _slots;
        id<MTLCommandBuffer> _lastCommand;
        uint64_t _frame{};
        std::vector<uint32_t> _order;
        std::vector<SegmentDraw> _segmentDraws;

        // Statistics for the periodic log.
        std::shared_ptr<GpuStatistics> _gpuStatistics = std::make_shared<GpuStatistics>();
        std::chrono::steady_clock::time_point _beginDrawTime;
        double _cpuMilliseconds{}, _encodeMilliseconds{}, _drawableWaitMilliseconds{};
        uint64_t _commandsRecorded{}, _framesDrawn{}, _fullRedraws{};
        // Logical pixels redrawn by dirty blocks, by CopyRect fallbacks and by full redraws, and
        // raster pixels covered by each pass's quads (fragment work before depth rejection).
        uint64_t _dirtyArea{}, _copyRedrawArea{}, _copyRedraws{}, _fullArea{};
        uint64_t _independentPixels{}, _dependentPixels{};

        // OPENRCT2_METAL_COMPARE_GPU resources.
        id<MTLBuffer> _referenceCanvas;
        id<MTLBuffer> _referenceScratch;
        id<MTLBuffer> _readback;
        std::vector<uint32_t> _tileCounts;
        uint64_t _comparedFrames{}, _mismatchedFrames{};

    public:
        explicit MetalDrawingEngine(IUiContext& uiContext)
            : _window(static_cast<SDL_Window*>(uiContext.GetWindow()))
        {
            _rt.DrawingEngine = this;
            LightFx::SetAvailable(false);
        }

        ~MetalDrawingEngine() override
        {
            // Wait for every in-flight frame (including completion handlers), then restore the
            // semaphore's count so it can be released.
            for (uint32_t i = 0; i < kFramesInFlight; ++i)
                dispatch_semaphore_wait(_inflight, DISPATCH_TIME_FOREVER);
            for (uint32_t i = 0; i < kFramesInFlight; ++i)
                dispatch_semaphore_signal(_inflight);
            _weatherDrawer.reset();
            _context.reset();
            _textureCache.reset();
            if (_view)
                SDL_Metal_DestroyView(_view);
        }

        void Initialise() override
        {
            _device = MTLCreateSystemDefaultDevice();
            Require(_device != nil, "Metal is not available on this device");
            _queue = [_device newCommandQueue];
            Require(_queue != nil, "Unable to create a Metal command queue");
            NSError* error = nil;
            NSURL* url = [NSBundle.mainBundle URLForResource:@"OpenRCT2" withExtension:@"metallib"];
            Require(url != nil, "OpenRCT2.metallib is missing from the application");
            id<MTLLibrary> library = [_device newLibraryWithURL:url error:&error];
            Require(library != nil, "Unable to load OpenRCT2.metallib");

            auto raster = [MTLRenderPipelineDescriptor new];
            raster.vertexFunction = [library newFunctionWithName:@"rasterVertex"];
            raster.colorAttachments[0].pixelFormat = MTLPixelFormatR8Uint;
            raster.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            raster.fragmentFunction = [library newFunctionWithName:@"rasterIndependent"];
            raster.label = @"Destination-independent commands";
            _independentPipeline = [_device newRenderPipelineStateWithDescriptor:raster error:&error];
            raster.fragmentFunction = [library newFunctionWithName:@"rasterDependent"];
            raster.label = @"Destination-dependent commands";
            _dependentPipeline = [_device newRenderPipelineStateWithDescriptor:raster error:&error];
            Require(_independentPipeline != nil && _dependentPipeline != nil, "Unable to create the Metal raster pipelines");

            auto present = [MTLRenderPipelineDescriptor new];
            present.vertexFunction = [library newFunctionWithName:@"presentVertex"];
            present.fragmentFunction = [library newFunctionWithName:@"presentFragment"];
            present.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            present.label = @"Palette presentation";
            _presentPipeline = [_device newRenderPipelineStateWithDescriptor:present error:&error];
            Require(_presentPipeline != nil, "Unable to create the Metal presentation pipeline");

            auto depth = [MTLDepthStencilDescriptor new];
            depth.depthCompareFunction = MTLCompareFunctionLess;
            depth.depthWriteEnabled = YES;
            _depthWrite = [_device newDepthStencilStateWithDescriptor:depth];
            depth.depthWriteEnabled = NO;
            _depthTest = [_device newDepthStencilStateWithDescriptor:depth];
            depth.depthCompareFunction = MTLCompareFunctionAlways;
            _depthAlways = [_device newDepthStencilStateWithDescriptor:depth];

            if (_debug.compareWithReference)
            {
                _referencePipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"referenceRasterize"]
                                                                            error:&error];
                _referenceCopyPipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"referenceCopy"]
                                                                                error:&error];
                Require(_referencePipeline != nil && _referenceCopyPipeline != nil, "Unable to create the Metal reference rasterizer");
            }

            _view = SDL_Metal_CreateView(_window);
            Require(_view != nullptr, "Unable to create the SDL Metal view");
            _layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(_view);
            _layer.device = _device;
            _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            _layer.framebufferOnly = YES;

            _textureCache = std::make_unique<TextureCache>(_device);
            _context = std::make_unique<DrawingContext>(*_textureCache);
            _weatherDrawer = std::make_unique<WeatherDrawer>(*_context);
            LOG_INFO(
                "Metal drawing engine: %s; raster=%s; GPU comparison=%s; dirty regions=%s; block=%u", _device.name.UTF8String,
                _debug.rasterMode == RasterMode::twoPass ? "two-pass" : "single-pass",
                _debug.compareWithReference ? "on" : "off", _debug.fullRedraw ? "off" : "on",
                _debug.dirtyBlockSize != 0 ? _debug.dirtyBlockSize : kDirtyBlockSize);
        }

        void Resize(uint32_t width, uint32_t height) override
        {
            if (width == 0 || height == 0)
                return;
            [_lastCommand waitUntilCompleted];
            _bits.assign(static_cast<size_t>(width) * height, PaletteIndex::transparent);
            _rt.bits = _bits.data();
            _rt.x = 0;
            _rt.y = 0;
            _rt.width = width;
            _rt.height = height;
            _rt.pitch = 0;
            const uint32_t block = _debug.dirtyBlockSize != 0 ? std::clamp<uint32_t>(_debug.dirtyBlockSize, 16, 256) : kDirtyBlockSize;
            _invalidationGrid.reset(width, height, block, block);
            // Rebuild the canvas and the logical mapping for the new layout.
            _rasterWidth = 0;
            _canvas = nil;
            UpdateRasterSize();
            _forceFullRedraw = true;
        }

        void SetPalette(const GamePalette& colours) override
        {
            for (size_t i = 0; i < _palette.size(); ++i)
                _palette[i] = colours[i].red | (colours[i].green << 8) | (colours[i].blue << 16) | 0xFF000000u;
        }

        void SetVSync(bool) override
        {
            // CAMetalLayer presents on display refresh.
        }

        void Invalidate(int32_t left, int32_t top, int32_t right, int32_t bottom) override
        {
            _invalidationGrid.invalidate(left, top, right, bottom);
        }

        void BeginDraw() override
        {
            _beginDrawTime = std::chrono::steady_clock::now();
            UpdateRasterSize();
            if (_gpuStatistics->failed.exchange(false))
            {
                // A frame never reached the canvas; its dirty regions are lost.
                _forceFullRedraw = true;
            }
            ++_frame;
            _parallelThisFrame = !_debug.serialDrawing && Config::Get().general.multiThreading;
            _textureCache->BeginFrame(_frame);
            _weatherDrawer->BeginFrame();
            _context->BeginFrame(_parallelThisFrame);
        }

        void PaintWindows() override
        {
            if (_forceFullRedraw || _debug.fullRedraw || gPaintForceRedraw || Weather::hasWeatherEffect())
            {
                // Rain and snow are drawn over the canvas, so frames with weather are redrawn in
                // full (as in the OpenGL engine). Viewport copies would be overdrawn anyway.
                _invalidationGrid.traverseDirtyCells([](int32_t, int32_t, int32_t, int32_t) {});
                _ignoreCopyRect = true;
                WindowUpdateAllViewports();
                _ignoreCopyRect = false;
                WindowDrawAll(_rt, 0, 0, _rt.width, _rt.height);
                _forceFullRedraw = false;
                ++_fullRedraws;
                _fullArea += static_cast<uint64_t>(_rt.width) * _rt.height;
            }
            else
            {
                // Redraw dirty regions before updating the viewports, otherwise viewport moves
                // would copy stale pixels.
                DrawAllDirtyBlocks();
                WindowUpdateAllViewports();
                DrawAllDirtyBlocks();
            }
        }

        void PaintWeather() override
        {
            DrawWeather(_rt, _weatherDrawer.get());
        }

        void CopyRect(int32_t x, int32_t y, int32_t width, int32_t height, int32_t dx, int32_t dy) override
        {
            if ((dx == 0 && dy == 0) || _ignoreCopyRect)
                return;
            // Clip as X8DrawingEngine::CopyRect.
            const int32_t lmargin = std::min(x - dx, 0);
            const int32_t rmargin = std::min(_rt.width - (x - dx + width), 0);
            const int32_t tmargin = std::min(y - dy, 0);
            const int32_t bmargin = std::min(_rt.height - (y - dy + height), 0);
            x -= lmargin;
            y -= tmargin;
            width += lmargin + rmargin;
            height += tmargin + bmargin;
            if (width <= 0 || height <= 0)
                return;
            if (_integerDensity != 0)
            {
                // Each logical pixel is exactly k × k raster pixels: move them.
                const auto k = static_cast<int32_t>(_integerDensity);
                _context->AddCopy({ x * k, y * k, width * k, height * k, dx * k, dy * k });
            }
            else
            {
                // A logical shift is not a whole number of raster pixels; redraw the moved area.
                WindowDrawAll(_rt, x, y, x + width, y + height);
                ++_copyRedraws;
                _copyRedrawArea += static_cast<uint64_t>(width) * height;
            }
        }

        std::string Screenshot() override
        {
            if (_canvas == nil || !ReadCanvas())
                return {};
            auto screenshot = _rt;
            screenshot.x = 0;
            screenshot.y = 0;
            screenshot.width = _rasterWidth;
            screenshot.height = _rasterHeight;
            screenshot.pitch = 0;
            screenshot.bits = static_cast<PaletteIndex*>(_readback.contents);
            return ScreenshotDumpPNG(screenshot);
        }

        IDrawingContext* GetDrawingContext() override
        {
            return _context.get();
        }

        RenderTarget* getRT() override
        {
            return &_rt;
        }

        DrawingEngineFlags GetFlags() override
        {
            DrawingEngineFlags flags;
            if (!_debug.fullRedraw)
                flags.set(DrawingEngineFlag::dirtyOptimisations);
            if (_parallelThisFrame && _context != nullptr && _context->IsActive())
                flags.set(DrawingEngineFlag::parallelDrawing);
            return flags;
        }

        void InvalidateImage(uint32_t image) override
        {
            if (_textureCache != nullptr)
                _textureCache->InvalidateImage(image);
        }

        void EndDraw() override;

    private:
        void DrawAllDirtyBlocks()
        {
            _invalidationGrid.traverseDirtyCells([this](int32_t left, int32_t top, int32_t right, int32_t bottom) {
                _dirtyArea += static_cast<uint64_t>(right - left) * (bottom - top);
                WindowDrawAll(_rt, left, top, right, bottom);
            });
        }

        void UpdateRasterSize();
        void BuildRasterMap();
        void BuildOrder(const RecordedFrame& frame);
        bool BuildReferenceTiles(const RecordedFrame& frame, FrameSlot& slot, uint32_t& tilesAcross, uint32_t& tilesDown);
        void EncodeSegment(
            id<MTLCommandBuffer> commandBuffer, const FrameSlot& slot, const SegmentDraw& segment, const FrameUniforms& uniforms);
        void EncodeCopy(id<MTLCommandBuffer> commandBuffer, const CopyOperation& copy);
        void EncodeReference(
            id<MTLCommandBuffer> commandBuffer, const FrameSlot& slot, const SegmentDraw& segment, const FrameUniforms& uniforms);
        void EncodePresent(id<MTLCommandBuffer> commandBuffer);
        void CompareWithReference();
        bool ReadCanvas();
        void LogStatistics(size_t commands);
    };

    void MetalDrawingEngine::UpdateRasterSize()
    {
        if (_device == nil || _context == nullptr)
            return;
        int windowWidth = 0, windowHeight = 0, drawableWidth = 0, drawableHeight = 0;
        SDL_GetWindowSize(_window, &windowWidth, &windowHeight);
        SDL_Metal_GetDrawableSize(_window, &drawableWidth, &drawableHeight);
        if (windowWidth <= 0 || windowHeight <= 0 || drawableWidth <= 0 || drawableHeight <= 0 || _rt.width <= 0)
            return;
        const auto content = IOS::ContentRect(_window);
        const double scaleX = static_cast<double>(drawableWidth) / windowWidth;
        const double scaleY = static_cast<double>(drawableHeight) / windowHeight;
        const auto offsetX = static_cast<uint32_t>(std::clamp<long>(std::lround(content.x * scaleX), 0, drawableWidth - 1));
        const auto offsetY = static_cast<uint32_t>(std::clamp<long>(std::lround(content.y * scaleY), 0, drawableHeight - 1));
        const auto width = static_cast<uint32_t>(std::clamp<long>(std::lround(content.w * scaleX), 1, drawableWidth - offsetX));
        const auto height = static_cast<uint32_t>(std::clamp<long>(std::lround(content.h * scaleY), 1, drawableHeight - offsetY));
        _drawableOffsetX = offsetX;
        _drawableOffsetY = offsetY;
        if (_canvas != nil && width == _rasterWidth && height == _rasterHeight)
            return;

        [_lastCommand waitUntilCompleted];
        _rasterWidth = width;
        _rasterHeight = height;
        auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                                                             width:width
                                                                            height:height
                                                                         mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        _canvas = [_device newTextureWithDescriptor:descriptor];
        _canvas.label = @"OpenRCT2 indexed canvas";
        auto depthDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                  width:width
                                                                                 height:height
                                                                              mipmapped:NO];
        depthDescriptor.storageMode = MTLStorageModeMemoryless;
        depthDescriptor.usage = MTLTextureUsageRenderTarget;
        _depth = [_device newTextureWithDescriptor:depthDescriptor];
        _copyScratch = nil;
        _canvasNeedsClear = true;
        _forceFullRedraw = true;
        BuildRasterMap();

        const uint32_t k = width / _rt.width;
        _integerDensity = (k >= 1 && width == k * _rt.width && height == k * static_cast<uint32_t>(_rt.height)) ? k : 0;
        _context->SetTarget(_rt, width, height);

        _referenceCanvas = nil;
        _referenceScratch = nil;
        if (_debug.compareWithReference)
        {
            const size_t pixels = static_cast<size_t>(width) * height;
            _referenceCanvas = [_device newBufferWithLength:pixels options:MTLResourceStorageModeShared];
            _referenceScratch = [_device newBufferWithLength:pixels options:MTLResourceStorageModeShared];
            if (_referenceCanvas != nil)
                std::memset(_referenceCanvas.contents, kInitialCanvasIndex, pixels);
        }
        if (_canvas == nil || _depth == nil || _rasterMap == nil)
            LOG_ERROR("Metal canvas allocation failed (%ux%u)", width, height);
        LOG_INFO(
            "Metal raster=%ux%u logical=%dx%d drawable=%dx%d offset=%u,%u density=%.4f%s", width, height, _rt.width,
            _rt.height, drawableWidth, drawableHeight, offsetX, offsetY, static_cast<double>(width) / _rt.width,
            _integerDensity != 0 ? " (integer: viewport copies enabled)" : "");
    }

    // Per-axis tables shared by both rasterizers: each raster pixel's logical sample point and
    // logical pixel, and for each logical edge the first raster pixel at or beyond it.
    void MetalDrawingEngine::BuildRasterMap()
    {
        const uint32_t logicalWidth = _rt.width;
        const uint32_t logicalHeight = _rt.height;
        _samplesYOffset = _rasterWidth * sizeof(RasterSample);
        _edgesXOffset = _samplesYOffset + _rasterHeight * sizeof(RasterSample);
        _edgesYOffset = (_edgesXOffset + (logicalWidth + 1) * sizeof(uint16_t) + 3) & ~size_t{ 3 };
        const size_t size = _edgesYOffset + (logicalHeight + 1) * sizeof(uint16_t);
        _rasterMap = [_device newBufferWithLength:size options:MTLResourceStorageModeShared];
        if (_rasterMap == nil)
            return;
        _rasterMap.label = @"OpenRCT2 raster-to-logical map";
        auto* bytes = static_cast<uint8_t*>(_rasterMap.contents);
        auto build = [](RasterSample* samples, uint16_t* edges, uint32_t raster, uint32_t logical) {
            for (uint32_t pixel = 0; pixel < raster; ++pixel)
            {
                const auto point = static_cast<float>((pixel + 0.5) * logical / raster);
                samples[pixel] = { point, std::min<int32_t>(static_cast<int32_t>(std::floor(point)), logical - 1) };
            }
            uint32_t pixel = 0;
            for (uint32_t edge = 0; edge <= logical; ++edge)
            {
                while (pixel < raster && samples[pixel].logical < static_cast<int32_t>(edge))
                    ++pixel;
                edges[edge] = static_cast<uint16_t>(pixel);
            }
        };
        build(reinterpret_cast<RasterSample*>(bytes), reinterpret_cast<uint16_t*>(bytes + _edgesXOffset), _rasterWidth,
              logicalWidth);
        build(reinterpret_cast<RasterSample*>(bytes + _samplesYOffset), reinterpret_cast<uint16_t*>(bytes + _edgesYOffset),
              _rasterHeight, logicalHeight);
    }

    // Per segment: destination-independent commands latest-first, then dependent commands in
    // submission order. In single-pass mode every command is submitted in order.
    void MetalDrawingEngine::BuildOrder(const RecordedFrame& frame)
    {
        _order.clear();
        _order.reserve(frame.commands.size());
        const auto* map = static_cast<const uint8_t*>(_rasterMap.contents);
        const auto* edgesX = reinterpret_cast<const uint16_t*>(map + _edgesXOffset);
        const auto* edgesY = reinterpret_cast<const uint16_t*>(map + _edgesYOffset);
        for (const auto& c : frame.commands)
        {
            const uint64_t area = static_cast<uint64_t>(edgesX[c.right] - edgesX[c.left]) * (edgesY[c.bottom] - edgesY[c.top]);
            ((c.flags & kCommandReadsDestination) != 0 ? _dependentPixels : _independentPixels) += area;
        }
        _segmentDraws.clear();
        uint32_t begin = 0;
        for (const auto& segment : frame.segments)
        {
            SegmentDraw draw{ begin, segment.end };
            draw.copy = segment.copy;
            draw.independentOffset = static_cast<uint32_t>(_order.size());
            if (_debug.rasterMode == RasterMode::twoPass)
            {
                for (uint32_t i = segment.end; i > begin; --i)
                    if ((frame.commands[i - 1].flags & kCommandReadsDestination) == 0)
                        _order.push_back(i - 1);
                draw.independentCount = static_cast<uint32_t>(_order.size()) - draw.independentOffset;
                draw.dependentOffset = static_cast<uint32_t>(_order.size());
                for (uint32_t i = begin; i < segment.end; ++i)
                    if ((frame.commands[i].flags & kCommandReadsDestination) != 0)
                        _order.push_back(i);
            }
            else
            {
                draw.dependentOffset = draw.independentOffset;
                for (uint32_t i = begin; i < segment.end; ++i)
                    _order.push_back(i);
            }
            draw.dependentCount = static_cast<uint32_t>(_order.size()) - draw.dependentOffset;
            _segmentDraws.push_back(draw);
            begin = segment.end;
        }
    }

    void MetalDrawingEngine::EncodeSegment(
        id<MTLCommandBuffer> commandBuffer, const FrameSlot& slot, const SegmentDraw& segment, const FrameUniforms& uniforms)
    {
        if (segment.independentCount == 0 && segment.dependentCount == 0 && !_canvasNeedsClear)
            return;
        auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = _canvas;
        pass.colorAttachments[0].loadAction = _canvasNeedsClear ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(kInitialCanvasIndex, 0, 0, 0);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.depthAttachment.texture = _depth;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.clearDepth = 1.0;
        pass.depthAttachment.storeAction = MTLStoreActionDontCare;
        _canvasNeedsClear = false;

        auto encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        encoder.label = @"OpenRCT2 indexed commands";
        [encoder setVertexBuffer:slot.commands offset:0 atIndex:kBufferCommands];
        [encoder setVertexBuffer:_rasterMap offset:_edgesXOffset atIndex:kBufferEdgesX];
        [encoder setVertexBuffer:_rasterMap offset:_edgesYOffset atIndex:kBufferEdgesY];
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:kBufferUniforms];
        [encoder setFragmentBuffer:_rasterMap offset:0 atIndex:kBufferSamplesX];
        [encoder setFragmentBuffer:_rasterMap offset:_samplesYOffset atIndex:kBufferSamplesY];
        [encoder setFragmentTexture:_textureCache->GetAtlas() atIndex:kTextureAtlas];
        [encoder setFragmentTexture:_textureCache->GetPalettes() atIndex:kTexturePalettes];
        [encoder setFragmentTexture:_textureCache->GetBlend() atIndex:kTextureBlend];
        const bool twoPass = _debug.rasterMode == RasterMode::twoPass;
        if (segment.independentCount != 0)
        {
            [encoder setRenderPipelineState:_independentPipeline];
            [encoder setDepthStencilState:_depthWrite];
            [encoder setVertexBuffer:slot.order offset:segment.independentOffset * sizeof(uint32_t) atIndex:kBufferOrder];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:segment.independentCount];
        }
        if (segment.dependentCount != 0)
        {
            [encoder setRenderPipelineState:_dependentPipeline];
            [encoder setDepthStencilState:twoPass ? _depthTest : _depthAlways];
            [encoder setVertexBuffer:slot.order offset:segment.dependentOffset * sizeof(uint32_t) atIndex:kBufferOrder];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:segment.dependentCount];
        }
        [encoder endEncoding];
    }

    void MetalDrawingEngine::EncodeCopy(id<MTLCommandBuffer> commandBuffer, const CopyOperation& copy)
    {
        if (_copyScratch == nil)
        {
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                                                                 width:_rasterWidth
                                                                                height:_rasterHeight
                                                                             mipmapped:NO];
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = MTLTextureUsageShaderRead;
            _copyScratch = [_device newTextureWithDescriptor:descriptor];
            if (_copyScratch == nil)
            {
                _forceFullRedraw = true;
                return;
            }
        }
        // Source and destination overlap, so go through a scratch texture.
        const auto size = MTLSizeMake(copy.width, copy.height, 1);
        auto blit = [commandBuffer blitCommandEncoder];
        blit.label = @"OpenRCT2 viewport move";
        [blit copyFromTexture:_canvas
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(copy.x - copy.dx, copy.y - copy.dy, 0)
                   sourceSize:size
                    toTexture:_copyScratch
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit copyFromTexture:_copyScratch
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:size
                    toTexture:_canvas
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(copy.x, copy.y, 0)];
        [blit endEncoding];
    }

    void MetalDrawingEngine::EncodePresent(id<MTLCommandBuffer> commandBuffer)
    {
        const auto waitStart = std::chrono::steady_clock::now();
        id<CAMetalDrawable> drawable = [_layer nextDrawable];
        _drawableWaitMilliseconds += Milliseconds(std::chrono::steady_clock::now() - waitStart);
        if (drawable == nil)
            return;
        auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        auto encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        encoder.label = @"OpenRCT2 palette presentation";
        const auto width = std::min<uint32_t>(_rasterWidth, drawable.texture.width - std::min<NSUInteger>(_drawableOffsetX, drawable.texture.width));
        const auto height = std::min<uint32_t>(_rasterHeight, drawable.texture.height - std::min<NSUInteger>(_drawableOffsetY, drawable.texture.height));
        if (width != 0 && height != 0)
        {
            [encoder setRenderPipelineState:_presentPipeline];
            [encoder setViewport:MTLViewport{ static_cast<double>(_drawableOffsetX), static_cast<double>(_drawableOffsetY),
                                              static_cast<double>(width), static_cast<double>(height), 0, 1 }];
            const PresentUniforms uniforms{ _drawableOffsetX, _drawableOffsetY };
            [encoder setFragmentTexture:_canvas atIndex:kTextureCanvas];
            [encoder setFragmentBytes:_palette.data() length:sizeof(_palette) atIndex:kBufferPalette];
            [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:kBufferUniforms];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [encoder endEncoding];
        [commandBuffer presentDrawable:drawable];
    }

    bool MetalDrawingEngine::BuildReferenceTiles(
        const RecordedFrame& frame, FrameSlot& slot, uint32_t& tilesAcross, uint32_t& tilesDown)
    {
        tilesAcross = (_rt.width + kReferenceTileSize - 1) / kReferenceTileSize;
        tilesDown = (_rt.height + kReferenceTileSize - 1) / kReferenceTileSize;
        const size_t tiles = static_cast<size_t>(tilesAcross) * tilesDown;
        _tileCounts.assign(tiles + 1, 0);
        auto forEachTile = [&](const DrawCommand& c, auto&& function) {
            for (uint32_t y = c.top / kReferenceTileSize; y <= static_cast<uint32_t>(c.bottom - 1) / kReferenceTileSize; ++y)
                for (uint32_t x = c.left / kReferenceTileSize; x <= static_cast<uint32_t>(c.right - 1) / kReferenceTileSize; ++x)
                    function(y * tilesAcross + x);
        };
        size_t entries = 0;
        for (const auto& command : frame.commands)
            forEachTile(command, [&](size_t tile) {
                ++_tileCounts[tile + 1];
                ++entries;
            });
        for (size_t i = 1; i <= tiles; ++i)
            _tileCounts[i] += _tileCounts[i - 1];
        const size_t rangeBytes = tiles * 2 * sizeof(uint32_t);
        if (!EnsureBuffer(_device, slot.tiles, rangeBytes + std::max<size_t>(entries, 1) * sizeof(uint32_t), @"Reference tiles"))
            return false;
        auto* ranges = static_cast<uint32_t*>(slot.tiles.contents);
        auto* indices = reinterpret_cast<uint32_t*>(static_cast<uint8_t*>(slot.tiles.contents) + rangeBytes);
        for (size_t tile = 0; tile < tiles; ++tile)
        {
            ranges[tile * 2] = _tileCounts[tile];
            ranges[tile * 2 + 1] = _tileCounts[tile];
        }
        for (uint32_t index = 0; index < frame.commands.size(); ++index)
            forEachTile(frame.commands[index], [&](size_t tile) { indices[ranges[tile * 2 + 1]++] = index; });
        return true;
    }

    void MetalDrawingEngine::EncodeReference(
        id<MTLCommandBuffer> commandBuffer, const FrameSlot& slot, const SegmentDraw& segment, const FrameUniforms& uniforms)
    {
        const size_t rangeBytes = static_cast<size_t>(uniforms.tilesAcross) * uniforms.tilesDown * 2 * sizeof(uint32_t);
        auto compute = [commandBuffer computeCommandEncoder];
        compute.label = @"OpenRCT2 reference rasterizer";
        if (segment.end > segment.begin)
        {
            const ReferenceSegment range{ segment.begin, segment.end };
            [compute setComputePipelineState:_referencePipeline];
            [compute setBuffer:slot.commands offset:0 atIndex:kReferenceCommands];
            [compute setBuffer:_rasterMap offset:0 atIndex:kReferenceSamplesX];
            [compute setBuffer:_rasterMap offset:_samplesYOffset atIndex:kReferenceSamplesY];
            [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:kReferenceUniforms];
            [compute setBuffer:slot.tiles offset:0 atIndex:kReferenceTileRanges];
            [compute setBuffer:slot.tiles offset:rangeBytes atIndex:kReferenceTileIndices];
            [compute setBytes:&range length:sizeof(range) atIndex:kReferenceSegment];
            [compute setBuffer:_referenceCanvas offset:0 atIndex:kReferenceCanvas];
            [compute setTexture:_textureCache->GetAtlas() atIndex:kTextureAtlas];
            [compute setTexture:_textureCache->GetPalettes() atIndex:kTexturePalettes];
            [compute setTexture:_textureCache->GetBlend() atIndex:kTextureBlend];
            [compute dispatchThreadgroups:MTLSizeMake((_rasterWidth + 15) / 16, (_rasterHeight + 15) / 16, 1)
                    threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        }
        if (segment.copy)
        {
            const auto& copy = *segment.copy;
            const ReferenceCopy toScratch{ static_cast<uint32_t>(copy.x - copy.dx), static_cast<uint32_t>(copy.y - copy.dy),
                                           static_cast<uint32_t>(copy.x - copy.dx), static_cast<uint32_t>(copy.y - copy.dy),
                                           static_cast<uint32_t>(copy.width),       static_cast<uint32_t>(copy.height),
                                           _rasterWidth };
            const ReferenceCopy fromScratch{ toScratch.sourceX, toScratch.sourceY, static_cast<uint32_t>(copy.x),
                                             static_cast<uint32_t>(copy.y), toScratch.width, toScratch.height, _rasterWidth };
            const auto groups = MTLSizeMake((copy.width + 15) / 16, (copy.height + 15) / 16, 1);
            [compute setComputePipelineState:_referenceCopyPipeline];
            [compute setBuffer:_referenceCanvas offset:0 atIndex:0];
            [compute setBuffer:_referenceScratch offset:0 atIndex:1];
            [compute setBytes:&toScratch length:sizeof(toScratch) atIndex:2];
            [compute dispatchThreadgroups:groups threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [compute setBuffer:_referenceScratch offset:0 atIndex:0];
            [compute setBuffer:_referenceCanvas offset:0 atIndex:1];
            [compute setBytes:&fromScratch length:sizeof(fromScratch) atIndex:2];
            [compute dispatchThreadgroups:groups threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        }
        [compute endEncoding];
    }

    bool MetalDrawingEngine::ReadCanvas()
    {
        [_lastCommand waitUntilCompleted];
        const size_t bytes = static_cast<size_t>(_rasterWidth) * _rasterHeight;
        if (_readback == nil || _readback.length < bytes)
            _readback = [_device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        if (_readback == nil)
            return false;
        auto commandBuffer = [_queue commandBuffer];
        auto blit = [commandBuffer blitCommandEncoder];
        [blit copyFromTexture:_canvas
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(_rasterWidth, _rasterHeight, 1)
                            toBuffer:_readback
                   destinationOffset:0
              destinationBytesPerRow:_rasterWidth
            destinationBytesPerImage:bytes];
        [blit endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        return commandBuffer.status == MTLCommandBufferStatusCompleted;
    }

    void MetalDrawingEngine::CompareWithReference()
    {
        if (_referenceCanvas == nil || !ReadCanvas())
            return;
        const auto* actual = static_cast<const uint8_t*>(_readback.contents);
        const auto* reference = static_cast<const uint8_t*>(_referenceCanvas.contents);
        const size_t pixels = static_cast<size_t>(_rasterWidth) * _rasterHeight;
        size_t mismatches = 0, first = 0;
        for (size_t i = 0; i < pixels; ++i)
        {
            if (actual[i] != reference[i])
            {
                if (mismatches == 0)
                    first = i;
                ++mismatches;
            }
        }
        ++_comparedFrames;
        if (mismatches != 0)
        {
            ++_mismatchedFrames;
            LOG_INFO(
                "Metal native comparison frame=%llu pixels=%zu mismatches=%zu first=(%zu,%zu) raster=%u reference=%u",
                static_cast<unsigned long long>(_frame), pixels, mismatches, first % _rasterWidth, first / _rasterWidth,
                actual[first], reference[first]);
            // Resynchronise so later frames are compared on their own merit.
            std::memcpy(_referenceCanvas.contents, actual, pixels);
        }
        else if (_frame % 60 == 0)
        {
            LOG_INFO(
                "Metal native comparison frame=%llu pixels=%zu mismatches=0 compared=%llu mismatched_frames=%llu",
                static_cast<unsigned long long>(_frame), pixels, static_cast<unsigned long long>(_comparedFrames),
                static_cast<unsigned long long>(_mismatchedFrames));
        }
    }

    void MetalDrawingEngine::EndDraw()
    {
        auto& frame = _context->EndFrame();
        if (_canvas == nil || _rasterMap == nil || IOS::IsBackgrounded())
        {
            // Nothing can be drawn now (no canvas or no GPU access in the background); the
            // regions consumed by this frame are recovered by a full redraw.
            _forceFullRedraw = true;
            return;
        }
        const auto encodeStart = std::chrono::steady_clock::now();
        @autoreleasepool
        {
            InflightSlot inflight(_inflight);
            auto& slot = _slots[_frame % kFramesInFlight];
            const size_t commandCount = frame.commands.size();
            BuildOrder(frame);
            if (!EnsureBuffer(_device, slot.commands, commandCount * sizeof(DrawCommand), @"OpenRCT2 frame commands")
                || !EnsureBuffer(_device, slot.order, _order.size() * sizeof(uint32_t), @"OpenRCT2 frame command order"))
            {
                LOG_ERROR("Unable to allocate Metal frame buffers for %zu commands", commandCount);
                _forceFullRedraw = true;
                return;
            }
            std::memcpy(slot.commands.contents, frame.commands.data(), commandCount * sizeof(DrawCommand));
            std::memcpy(slot.order.contents, _order.data(), _order.size() * sizeof(uint32_t));

            FrameUniforms uniforms{ _rasterWidth, _rasterHeight, static_cast<uint32_t>(_rt.width),
                                    static_cast<uint32_t>(_rt.height), 0, 0 };
            const bool compare = _debug.compareWithReference && _referenceCanvas != nil
                && BuildReferenceTiles(frame, slot, uniforms.tilesAcross, uniforms.tilesDown);

            id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
            commandBuffer.label = @"OpenRCT2 frame";
            if (!_textureCache->Flush(commandBuffer, static_cast<uint32_t>(_frame % kFramesInFlight)))
            {
                _forceFullRedraw = true;
                return;
            }
            for (const auto& segment : _segmentDraws)
            {
                EncodeSegment(commandBuffer, slot, segment, uniforms);
                if (compare)
                    EncodeReference(commandBuffer, slot, segment, uniforms);
                if (segment.copy)
                    EncodeCopy(commandBuffer, *segment.copy);
            }
            EncodePresent(commandBuffer);

            const auto statistics = _gpuStatistics;
            dispatch_semaphore_t semaphore = _inflight;
            [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
              if (completed.status == MTLCommandBufferStatusError)
              {
                  statistics->failed = true;
                  LOG_ERROR("Metal GPU command failed: %s", completed.error.localizedDescription.UTF8String);
              }
              else
              {
                  const auto microseconds = static_cast<uint64_t>((completed.GPUEndTime - completed.GPUStartTime) * 1e6);
                  statistics->microseconds += microseconds;
                  auto previous = statistics->maxMicroseconds.load();
                  while (previous < microseconds && !statistics->maxMicroseconds.compare_exchange_weak(previous, microseconds))
                  {
                  }
                  ++statistics->frames;
              }
              dispatch_semaphore_signal(semaphore);
            }];
            [commandBuffer commit];
            inflight.Release();
            _lastCommand = commandBuffer;
            _commandsRecorded += commandCount;
            ++_framesDrawn;

            if (compare)
                CompareWithReference();
        }
        const auto end = std::chrono::steady_clock::now();
        _encodeMilliseconds += Milliseconds(end - encodeStart);
        _cpuMilliseconds += Milliseconds(end - _beginDrawTime);
        if (_frame % kStatisticsInterval == 0)
            LogStatistics(frame.commands.size());
    }

    void MetalDrawingEngine::LogStatistics(size_t commands)
    {
        const auto frames = _gpuStatistics->frames.exchange(0);
        const auto microseconds = _gpuStatistics->microseconds.exchange(0);
        const auto maxMicroseconds = _gpuStatistics->maxMicroseconds.exchange(0);
        const auto drawn = std::max<uint64_t>(_framesDrawn, 1);
        const auto stats = _textureCache->GetStats();
        LOG_INFO(
            "Metal GPU frame=%llu duration=%.2fms max=%.2fms cpu=%.2fms encode=%.2fms drawable_wait=%.2fms commands=%zu avg_commands=%llu "
            "full_redraws=%llu/%llu atlas=%u layers %.1f MiB images=%zu text=%zu palettes=%zu",
            static_cast<unsigned long long>(_frame), frames != 0 ? microseconds / 1000.0 / frames : 0.0,
            maxMicroseconds / 1000.0, _cpuMilliseconds / drawn,
            _encodeMilliseconds / drawn, _drawableWaitMilliseconds / drawn, commands, static_cast<unsigned long long>(_commandsRecorded / drawn),
            static_cast<unsigned long long>(_fullRedraws), static_cast<unsigned long long>(drawn), stats.atlasLayers,
            stats.usedTexels * 2.0 / (1024 * 1024), stats.images, stats.bitmaps, stats.dynamicPalettes);
        const double rasterPixels = static_cast<double>(_rasterWidth) * _rasterHeight;
        const double logicalPixels = static_cast<double>(_rt.width) * _rt.height;
        LOG_INFO(
            "Metal redraw per frame: dirty=%.2f copy_redraw=%.2f (%.1f calls) full=%.2f screens; quad coverage independent=%.2f "
            "dependent=%.2f screens",
            _dirtyArea / logicalPixels / drawn, _copyRedrawArea / logicalPixels / drawn,
            static_cast<double>(_copyRedraws) / drawn, _fullArea / logicalPixels / drawn,
            _independentPixels / rasterPixels / drawn, _dependentPixels / rasterPixels / drawn);
        _dirtyArea = _copyRedrawArea = _copyRedraws = _fullArea = _independentPixels = _dependentPixels = 0;
        _cpuMilliseconds = 0;
        _encodeMilliseconds = 0;
        _drawableWaitMilliseconds = 0;
        _commandsRecorded = 0;
        _framesDrawn = 0;
        _fullRedraws = 0;
    }
} // namespace

std::unique_ptr<IDrawingEngine> OpenRCT2::Ui::CreateMetalDrawingEngine(IUiContext& uiContext)
{
    return std::make_unique<MetalDrawingEngine>(uiContext);
}

#endif
