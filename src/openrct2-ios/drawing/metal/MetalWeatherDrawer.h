/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#pragma once

#ifdef OPENRCT2_METAL

    #include <cstdint>
    #include <openrct2/drawing/IDrawingEngine.h>

namespace OpenRCT2::Ui::Metal
{
    class DrawingContext;

    // Rain and snow: X8WeatherDrawer's pattern walk and per-frame pixel budget, recorded as
    // single-pixel fills. The engine redraws the whole screen while weather is visible (as the
    // OpenGL engine does), so the drops need no restore pass.
    class WeatherDrawer final : public Drawing::IWeatherDrawer
    {
    public:
        explicit WeatherDrawer(DrawingContext& context)
            : _context(context)
        {
        }

        void BeginFrame()
        {
            _pixels = 0;
        }

        void Draw(
            Drawing::RenderTarget& rt, int32_t x, int32_t y, int32_t width, int32_t height, int32_t xStart, int32_t yStart,
            const uint8_t* weatherPattern) override;

    private:
        DrawingContext& _context;
        uint32_t _pixels{};
    };
} // namespace OpenRCT2::Ui::Metal

#endif
