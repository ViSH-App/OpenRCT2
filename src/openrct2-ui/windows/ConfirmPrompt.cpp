/*****************************************************************************
 * Copyright (c) 2014-2026 OpenRCT2 developers
 *
 * For a complete list of all authors, please refer to contributors.md
 * Interested in contributing? Visit https://github.com/OpenRCT2/OpenRCT2
 *
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/

#include <openrct2-ui/interface/Widget.h>
#include <openrct2-ui/interface/Window.h>
#include <openrct2-ui/windows/Windows.h>
#include <openrct2/config/Config.h>
#include <openrct2/drawing/Text.h>
#include <openrct2/ui/WindowManager.h>

namespace OpenRCT2::Ui::Windows
{
    static constexpr ScreenSize kWindowSize = { 250, 100 };

    enum WindowConfirmPromptWidgetIdx : WidgetIndex
    {
        WIDX_BACKGROUND,
        WIDX_TITLE,
        WIDX_CLOSE,
        WIDX_YES,
        WIDX_CANCEL
    };

    // clang-format off
    static constexpr auto _confirmPromptWidgets = makeWidgets(
        makeWindowShim(STR_CONFIRM_TITLE, kWindowSize),
        makeWidget({                    10, kWindowSize.height - 20}, {85, 14}, WidgetType::button, WindowColour::primary, STR_YES               ),
        makeWidget({kWindowSize.width - 95, kWindowSize.height - 20}, {85, 14}, WidgetType::button, WindowColour::primary, STR_SAVE_PROMPT_CANCEL)
    );
    // clang-format on

    // A Yes/Cancel question for an action that should not happen on a single click (or tap).
    class ConfirmPromptWindow final : public Window
    {
        StringId _message{};
        Formatter _arguments;
        std::function<void()> _onConfirm;

    public:
        void setPrompt(StringId message, const Formatter& arguments, std::function<void()> onConfirm)
        {
            _message = message;
            _arguments = arguments;
            _onConfirm = std::move(onConfirm);
            invalidate();
        }

        void onOpen() override
        {
            setWidgets(_confirmPromptWidgets);
            // Not a themed window class: an opaque version of the other confirmation prompts' colour.
            colours[0] = ColourWithFlags{ Drawing::Colour::bordeauxRed };
            WindowInitScrollWidgets(*this);
        }

        void onMouseUp(WidgetIndex widgetIndex) override
        {
            switch (widgetIndex)
            {
                case WIDX_YES:
                {
                    // The action may open or close windows, including this one.
                    auto onConfirm = std::move(_onConfirm);
                    close();
                    if (onConfirm)
                        onConfirm();
                    break;
                }
                case WIDX_CLOSE:
                case WIDX_CANCEL:
                    close();
                    break;
            }
        }

        void onDraw(Drawing::RenderTarget& rt) override
        {
            drawWidgets(rt);
            ScreenCoordsXY textCoords(windowPos + ScreenCoordsXY{ width / 2, (height / 2) - 9 });
            auto ft = _arguments;
            drawTextWrapped(rt, textCoords, width - 8, _message, ft, { TextAlignment::centre });
        }
    };

    WindowBase* ConfirmPromptOpen(StringId message, const Formatter& arguments, std::function<void()> onConfirm)
    {
        auto* windowMgr = GetWindowManager();
        auto* window = windowMgr->FocusOrCreate<ConfirmPromptWindow>(
            WindowClass::confirmPrompt, kWindowSize, { WindowFlag::centreScreen });
        window->setPrompt(message, arguments, std::move(onConfirm));
        return window;
    }

    WindowBase* ConfirmPromptOpen(StringId message, std::function<void()> onConfirm)
    {
        return ConfirmPromptOpen(message, Formatter(), std::move(onConfirm));
    }

    void RunConfirmed(StringId message, const Formatter& arguments, std::function<void()> action)
    {
        if (Config::Get().interface.enlargedUi)
            ConfirmPromptOpen(message, arguments, std::move(action));
        else
            action();
    }

    void RunConfirmed(StringId message, std::function<void()> action)
    {
        RunConfirmed(message, Formatter(), std::move(action));
    }
} // namespace OpenRCT2::Ui::Windows
