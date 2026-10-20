#pragma once
#ifdef OPENRCT2_IOS
    #include <SDL_events.h>
    #include <SDL_rect.h>
    #include <cstdint>
struct SDL_Window;
struct SDL_Renderer;
    #ifdef __OBJC__
@class UIWindowScene;
    #endif
namespace OpenRCT2::Ui::IOS
{
    #ifdef __OBJC__
    UIWindowScene* GetWindowScene();
    #endif
    void AttachWindowToScene(SDL_Window* window);
    SDL_Rect ContentRect(SDL_Window* window);
    SDL_Point OutputPixelSize(SDL_Window* window);
    float PixelsPerPoint(SDL_Window* window);
    // Physical pixels per logical pixel for an interface scale, and that scale made exact.
    int32_t PixelScale(SDL_Window* window, float windowScale);
    float QuantizeWindowScale(SDL_Window* window, float windowScale);
    // Where the logical canvas is shown, in drawable pixels: integer-scaled from the content origin.
    SDL_Rect PresentationRect(SDL_Window* window, int32_t logicalWidth, int32_t logicalHeight);
    bool ProcessEvent(SDL_Event& event, SDL_Window* window);
    bool IsBackgrounded();
    SDL_Point PointerPosition();
} // namespace OpenRCT2::Ui::IOS
#endif
