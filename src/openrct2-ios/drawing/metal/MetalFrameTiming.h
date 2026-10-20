/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#pragma once

#ifdef OPENRCT2_METAL

    #include <algorithm>
    #include <chrono>
    #include <cstdint>
    #include <cstdio>
    #include <mutex>
    #include <string>
    #include <vector>

namespace OpenRCT2::Ui::Metal
{
    // GPU time of every frame (command buffer), summarised as percentiles for the last window
    // and for the whole run, the wall-clock interval between frame completions (pacing and
    // hitches), and frames per wall-clock second. Single scenes vary a
    // lot, so renderer comparisons use these distributions over long runs.
    class FrameTiming
    {
    public:
        // Called from Metal completion handlers.
        void AddGpuFrame(double milliseconds)
        {
            std::scoped_lock lock(_mutex);
            const auto now = std::chrono::steady_clock::now();
            if (_all.empty())
                _start = now;
            else
                _intervals.push_back(std::chrono::duration<float, std::milli>(now - _last).count());
            _last = now;
            _window.push_back(static_cast<float>(milliseconds));
            _all.push_back(static_cast<float>(milliseconds));
        }

        // Returns a log line and starts a new window.
        std::string Summarise()
        {
            std::scoped_lock lock(_mutex);
            const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - _start).count();
            auto line = "window " + Describe(_window) + " | run " + Describe(_all) + " | interval " + Describe(_intervals);
            float hitchTime = 0;
            size_t hitches = 0;
            for (auto interval : _intervals)
            {
                if (interval > 25.0f)
                {
                    ++hitches;
                    hitchTime += interval;
                }
            }
            char hitchText[96];
            std::snprintf(hitchText, sizeof(hitchText), " hitches>25ms=%zu (%.1fs)", hitches, hitchTime / 1000.0f);
            line += hitchText;
            char fps[64];
            std::snprintf(fps, sizeof(fps), " fps=%.2f over %.0fs", seconds > 0 ? _all.size() / seconds : 0.0, seconds);
            _window.clear();
            return line + fps;
        }

    private:
        static std::string Describe(std::vector<float> values)
        {
            if (values.empty())
                return "n=0";
            std::sort(values.begin(), values.end());
            double sum = 0;
            size_t over = 0;
            for (auto value : values)
            {
                sum += value;
                over += value > 16.67f;
            }
            auto percentile = [&](double p) { return values[std::min(values.size() - 1, static_cast<size_t>(p * values.size()))]; };
            char text[192];
            std::snprintf(
                text, sizeof(text), "n=%zu mean=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f over16.7=%.1f%%", values.size(),
                sum / values.size(), percentile(0.50), percentile(0.95), percentile(0.99), values.back(),
                100.0 * over / values.size());
            return text;
        }

        std::mutex _mutex;
        std::vector<float> _window;
        std::vector<float> _all;
        std::vector<float> _intervals; // Wall-clock time between consecutive frame completions.
        std::chrono::steady_clock::time_point _start = std::chrono::steady_clock::now();
        std::chrono::steady_clock::time_point _last;
    };
} // namespace OpenRCT2::Ui::Metal

#endif
