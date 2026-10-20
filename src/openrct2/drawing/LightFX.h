/*****************************************************************************
 * Copyright (c) 2014-2026 OpenRCT2 developers
 *
 * For a complete list of all authors, please refer to contributors.md
 * Interested in contributing? Visit https://github.com/OpenRCT2/OpenRCT2
 *
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/

#pragma once

#include "../interface/ScreenCoords.hpp"
#include "../world/Location.hpp"
#include "PaletteType.h"

#include <cstdint>
#include <vector>

namespace OpenRCT2
{
    struct EntityBase;
    struct Vehicle;
    struct Viewport;
} // namespace OpenRCT2

namespace OpenRCT2::Drawing
{
    struct RenderTarget;
    enum class PaletteIndex : uint8_t;
} // namespace OpenRCT2::Drawing

namespace OpenRCT2::Drawing::LightFx
{
    enum class LightType : uint8_t
    {
        none = 0,

        lantern0 = 4,
        lantern1 = 5,
        lantern2 = 6,
        lantern3 = 7,

        spot0 = 8,
        spot1 = 9,
        spot2 = 10,
        spot3 = 11,
    };

    // What a light belongs to; drawing engines that light the world on their own colour by it.
    enum class LightColour : uint8_t
    {
        pathLamp,
        rideEntrance,
        parkEntrance,
        shop,
        vehicle,
    };

    // A light collected while painting, for drawing engines that light the world on their own.
    struct LightSource
    {
        CoordsXYZ position;
        ScreenCoordsXY viewCoords; // Zoom-0 screen position at the rotation it was painted with.
        LightType type;
        LightColour colour;
    };

    // Natural light for the current time of day and weather, as ApplyPaletteFilter derives it.
    // Colours are in 0-255 palette units, as there.
    struct AmbientLight
    {
        float night;             // gDayNightCycle^1.5; < 0 when there is no darkening.
        bool lightning;          // A lightning flash: no darkening.
        float naturalLight[3];   // Multiplier for colours not lit by lamps.
        float reduceNatural;
        float reduceLit;         // Multiplier for colours lit by lamps.
        float environmentFog;
        float fog[3];
        float lightFog;
    };

    void SetAvailable(bool available);
    bool IsAvailable();
    bool ForVehiclesIsAvailable();

    void Init();

    void UpdateBuffers(RenderTarget&);
    const GamePalette& GetPalette();

    void Add3DLight(const EntityBase& entity, uint8_t id, const CoordsXYZ& loc, LightType lightType);

    void Add3DLightMagicFromDrawingTile(
        const CoordsXY& mapPosition, int16_t offsetX, int16_t offsetY, int16_t offsetZ, LightType lightType,
        LightColour colour = LightColour::pathLamp);

    void AddLightsMagicVehicle(const Vehicle* vehicle);
    void AddLightsMagicVehicle_ObservationTower(const Vehicle* vehicle);
    void AddLightsMagicVehicle_MineTrainCoaster(const Vehicle* vehicle);
    void AddLightsMagicVehicle_ChairLift(const Vehicle* vehicle);
    void AddLightsMagicVehicle_BoatHire(const Vehicle* vehicle);
    void AddLightsMagicVehicle_Monorail(const Vehicle* vehicle);
    void AddLightsMagicVehicle_MiniatureRailway(const Vehicle* vehicle);

    void AddKioskLights(const CoordsXY& mapPosition, int32_t height, uint8_t zOffset);
    void AddShopLights(const CoordsXY& mapPosition, uint8_t direction, int32_t height, uint8_t zOffset);

    void ApplyPaletteFilter(uint8_t i, uint8_t* r, uint8_t* g, uint8_t* b);

    // A drawing engine that lights the world itself: the game palette keeps its daylight
    // colours, the engine takes the painted lights each frame and applies ComputeAmbientLight.
    void SetEngineLighting(bool engineLighting);
    bool IsEngineLighting();
    void TakeLights(std::vector<LightSource>& lights);
    AmbientLight ComputeAmbientLight(float lightPollution);
    void RenderToTexture(
        const Viewport& vp, void* dstPixels, uint32_t dstPitch, Drawing::PaletteIndex* bits, uint32_t width, uint32_t height,
        const uint32_t* palette, const uint32_t* lightPalette);

} // namespace OpenRCT2::Drawing::LightFx
