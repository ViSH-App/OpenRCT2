/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_METAL

    #include "MetalWeatherDrawer.h"

    #include "MetalDrawingContext.h"

    #include <openrct2/drawing/RenderTarget.h>

using namespace OpenRCT2::Drawing;
using namespace OpenRCT2::Ui::Metal;

namespace
{
    // X8WeatherDrawer::kMaxWeatherPixels: rows beyond this budget are not drawn.
    constexpr uint32_t kMaxWeatherPixels = 0xFFFE;
} // namespace

void WeatherDrawer::Draw(
    RenderTarget& rt, int32_t x, int32_t y, int32_t width, int32_t height, int32_t xStart, int32_t yStart,
    const uint8_t* weatherPattern)
{
    const uint8_t* pattern = weatherPattern;
    const auto patternXSpace = *pattern++;
    const auto patternYSpace = *pattern++;
    const uint8_t patternStartXOffset = xStart % patternXSpace;
    const uint8_t patternStartYOffset = yStart % patternYSpace;
    uint8_t patternYPos = patternStartYOffset % patternYSpace;

    for (int32_t row = 0; row < height; ++row)
    {
        const auto patternX = pattern[patternYPos * 2];
        if (patternX != 0xFF && _pixels < kMaxWeatherPixels - static_cast<uint32_t>(width))
        {
            const auto colour = static_cast<PaletteIndex>(pattern[patternYPos * 2 + 1]);
            const auto first = static_cast<uint8_t>(patternX - patternStartXOffset) % patternXSpace;
            // (x, y) are offsets within rt, as in the software drawer's pixel offsets.
            for (int32_t column = first; column < width; column += patternXSpace)
            {
                const int32_t px = rt.x + x + column;
                const int32_t py = rt.y + y + row;
                _context.FillRect(rt, colour, px, py, px, py);
                ++_pixels;
            }
        }
        patternYPos = (patternYPos + 1) % patternYSpace;
    }
}

#endif
