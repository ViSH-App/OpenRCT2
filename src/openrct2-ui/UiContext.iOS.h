#pragma once
#ifdef OPENRCT2_IOS
    #include <SDL_events.h>
    #include <SDL_rect.h>
struct SDL_Window;
struct SDL_Renderer;
namespace OpenRCT2::Ui::IOS
{
    SDL_Rect ContentRect(SDL_Window* window);
    SDL_Rect DrawableRect(SDL_Window* window, SDL_Renderer* renderer);
    bool ProcessEvent(SDL_Event& event, SDL_Window* window);
    bool IsBackgrounded();
    SDL_Point PointerPosition();
} // namespace OpenRCT2::Ui::IOS
#endif
