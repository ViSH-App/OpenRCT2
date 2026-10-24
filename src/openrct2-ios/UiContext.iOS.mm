/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_IOS
    #include <openrct2-ui/UiContext.h>

    #include "UiContext.iOS.h"
    #include <openrct2-ui/windows/Windows.h>

    #import <AVFAudio/AVFAudio.h>
    #include <SDL.h>
    #include <SDL_metal.h>
    #include <SDL_syswm.h>
    #import <UIKit/UIKit.h>
    #import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
    #include <openrct2/Context.h>
    #include <openrct2/Game.h>
    #include <openrct2/OpenRCT2.h>
    #include <openrct2/PlatformEnvironment.h>
    #include <openrct2/audio/Audio.h>
    #include <openrct2/config/Config.h>
    #include <openrct2/platform/Platform.h>
    #include <openrct2/scenes/SceneManager.h>
    #include <openrct2/ui/UiContext.h>
    #include <algorithm>
    #include <cmath>
    #include <cstdlib>
    #include <unistd.h>

using namespace OpenRCT2;
namespace
{
    constexpr int kToolbarHeight = 44;
    bool IsPlayingPark()
    {
        auto context = GetContext();
        auto scenes = context ? context->GetSceneManager() : nullptr;
        return scenes && scenes->getActiveScene() == scenes->getGameScene();
    }
    bool backgrounded = false;
    bool audioInterrupted = false;
    uint8_t savedPause = 0;
    SDL_Window* gameWindow = nullptr;
    std::string pendingPark;
    bool pendingMenu = false;
    void RequestMenu()
    {
        pendingMenu = true;
        SDL_Event event{};
        event.type = SDL_USEREVENT;
        SDL_PushEvent(&event);
    }
    SDL_Point pointer{};
    bool pencilSqueezeHeld = false;
    UIWindow* bootstrapWindow;

    UIViewController* Controller()
    {
        if (gameWindow)
        {
            SDL_SysWMinfo info;
            SDL_VERSION(&info.version);
            if (SDL_GetWindowWMInfo(gameWindow, &info))
                return info.info.uikit.window.rootViewController;
        }
        return bootstrapWindow.rootViewController;
    }
    NSString* Documents()
    {
        return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    }
    void WaitUntil(bool (^done)())
    {
        // SDL_main and all engine calls remain on the main thread. Only pump UIKit while a modal is open.
        while (!done())
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    void Alert(NSString* title, NSString* message)
    {
        __block bool done = false;
        auto alert = [UIAlertController alertControllerWithTitle:title
                                                         message:message
                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction*) {
                                                  done = true;
                                                }]];
        [Controller() presentViewController:alert animated:YES completion:nil];
        WaitUntil(^bool {
          return done && !alert.presentingViewController;
        });
    }
} // namespace

@interface RCTDocumentDelegate : NSObject <UIDocumentPickerDelegate>
@property(nonatomic) bool done;
@property(nonatomic, strong) NSURL* selected;
@end
@implementation RCTDocumentDelegate
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls
{
    self.selected = urls.firstObject;
    self.done = true;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller
{
    self.done = true;
}
@end

namespace
{
    NSURL* Pick(bool folder)
    {
        auto delegate = [RCTDocumentDelegate new];
        auto picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ folder ? UTTypeFolder : UTTypeData ]
                                                                                  asCopy:NO];
        picker.delegate = delegate;
        picker.allowsMultipleSelection = NO;
        if (!folder)
            picker.directoryURL = [NSURL fileURLWithPath:[Documents() stringByAppendingPathComponent:@"OpenRCT2/save"]];
        picker.modalInPresentation = YES;
        [Controller() presentViewController:picker animated:YES completion:nil];
        WaitUntil(^bool {
          return delegate.done && !picker.presentingViewController;
        });
        return delegate.selected;
    }
    std::string ImportPark()
    {
        NSURL* source = Pick(false);
        if (!source)
            return {};
        NSSet* types = [NSSet setWithArray:@[ @"park", @"sv6", @"sc6", @"sv4", @"sc4" ]];
        if (![types containsObject:source.pathExtension.lowercaseString])
        {
            Alert(@"Unsupported file", @"Select a .park, .sv6, .sc6, .sv4 or .sc4 file.");
            return {};
        }
        bool access = [source startAccessingSecurityScopedResource];
        NSString* folder = [Documents() stringByAppendingPathComponent:@"OpenRCT2/save/Imported"];
        auto fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* destination = [folder stringByAppendingPathComponent:source.lastPathComponent];
        if ([fm fileExistsAtPath:destination])
            destination = [folder
                stringByAppendingPathComponent:[NSString
                                                   stringWithFormat:@"%@-%@.%@",
                                                                    source.lastPathComponent.stringByDeletingPathExtension,
                                                                    NSUUID.UUID.UUIDString, source.pathExtension]];
        __block NSError* failure = nil;
        auto coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:source
                                        options:0
                                          error:&failure
                                     byAccessor:^(NSURL* readable) {
                                       [fm copyItemAtURL:readable toURL:[NSURL fileURLWithPath:destination] error:&failure];
                                     }];
        if (access)
            [source stopAccessingSecurityScopedResource];
        if (failure)
        {
            Alert(@"Import failed", failure.localizedDescription);
            return {};
        }
        return destination.UTF8String;
    }
    void ExportPark()
    {
        // Select an already-saved park using the system browser rooted at our Documents directory.
        NSURL* selected = Pick(false);
        if (!selected)
            return;
        if (![selected.pathExtension.lowercaseString isEqualToString:@"park"])
        {
            Alert(
                @"Select a saved park",
                @"Save in the game first, then choose a .park file in OpenRCT2/save. The Files app can also copy any save "
                @"directly.");
            return;
        }
        bool access = [selected startAccessingSecurityScopedResource];
        auto delegate = [RCTDocumentDelegate new];
        auto picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ selected ] asCopy:YES];
        picker.delegate = delegate;
        picker.modalInPresentation = YES;
        [Controller() presentViewController:picker animated:YES completion:nil];
        WaitUntil(^bool {
          return delegate.done && !picker.presentingViewController;
        });
        if (access)
            [selected stopAccessingSecurityScopedResource];
    }
    int Menu(const std::vector<std::string>& choices, NSString* title, NSString* message)
    {
        __block int result = -1;
        __block bool done = false;
        auto alert = [UIAlertController alertControllerWithTitle:title
                                                         message:message
                                                  preferredStyle:UIAlertControllerStyleAlert];
        for (size_t i = 0; i < choices.size(); ++i)
            [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:choices[i].c_str()]
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction*) {
                                                      result = i;
                                                      done = true;
                                                    }]];
        [Controller() presentViewController:alert animated:YES completion:nil];
        WaitUntil(^bool {
          return done && !alert.presentingViewController;
        });
        return result;
    }
    int Lifecycle(void*, SDL_Event* event)
    {
        if (event->type == SDL_APP_WILLENTERBACKGROUND && !backgrounded)
        {
            backgrounded = true;
            savedPause = gGamePaused;
            gGamePaused = 1;
            Audio::Pause();
            Config::Save();
            if (IsPlayingPark())
            {
                try
                {
                    GameAutosave();
                }
                catch (const std::exception& error)
                {
                    fprintf(stderr, "Background autosave failed: %s\n", error.what());
                }
            }
            NSLog(@"OpenRCT2: background paused; autosave requested for a playing park");
        }
        else if (event->type == SDL_APP_DIDENTERFOREGROUND && backgrounded)
        {
            backgrounded = false;
            gGamePaused = savedPause;
            if (!audioInterrupted)
                Audio::Resume();
            NSLog(@"OpenRCT2: foreground resumed");
        }
        return 1;
    }
} // namespace

@interface RCTTouchControls : NSObject <UIPencilInteractionDelegate>
@end
@implementation RCTTouchControls
- (void)files
{
    RequestMenu();
}
// Apple Pencil Pro: the pencil pans the map while squeezed, unless squeeze is turned off in Settings.
- (void)pencilInteraction:(UIPencilInteraction*)interaction didReceiveSqueeze:(UIPencilInteractionSqueeze*)squeeze
    API_AVAILABLE(ios(17.5))
{
    pencilSqueezeHeld = (squeeze.phase == UIPencilInteractionPhaseBegan || squeeze.phase == UIPencilInteractionPhaseChanged)
        && UIPencilInteraction.preferredSqueezeAction != UIPencilPreferredActionIgnore;
}
@end

namespace OpenRCT2::Ui::IOS
{
    SDL_Point OutputPixelSize(SDL_Window* window)
    {
        SDL_Point result{};
        SDL_Metal_GetDrawableSize(window, &result.x, &result.y);
        return result;
    }
    SDL_Rect ContentRect(SDL_Window* window)
    {
        int w = 0, h = 0;
        SDL_GetWindowSize(window, &w, &h);
        UIEdgeInsets inset = Controller().view.safeAreaInsets;
        int top = static_cast<int>(inset.top) + kToolbarHeight;
        return { static_cast<int>(inset.left), top, w - static_cast<int>(inset.left + inset.right),
                 h - top - static_cast<int>(inset.bottom) };
    }
    float PixelsPerPoint(SDL_Window* window)
    {
        int w = 0, h = 0;
        SDL_GetWindowSize(window, &w, &h);
        const auto pixels = OutputPixelSize(window);
        return w > 0 && pixels.x > 0 ? static_cast<float>(pixels.x) / w : 1.0f;
    }
    int32_t PixelScale(SDL_Window* window, float windowScale)
    {
        // Every logical pixel is a whole number of physical pixels: interface scales are
        // multiples of one point's pixel size (0.5 on a 2x display), at least 1.
        const float pixelsPerPoint = PixelsPerPoint(window);
        return std::max<int32_t>(std::lround(windowScale * pixelsPerPoint), std::max<int32_t>(std::lround(pixelsPerPoint), 1));
    }
    float QuantizeWindowScale(SDL_Window* window, float windowScale)
    {
        return PixelScale(window, windowScale) / PixelsPerPoint(window);
    }
    SDL_Rect PresentationRect(SDL_Window* window, int32_t logicalWidth, int32_t logicalHeight)
    {
        // The content origin in physical pixels and the logical canvas scaled by the pixel scale.
        // Physical pixels left over below one logical pixel stay black at the right and bottom.
        const auto content = ContentRect(window);
        const float pixelsPerPoint = PixelsPerPoint(window);
        const int32_t scale = PixelScale(window, Config::Get().general.windowScale);
        return { static_cast<int>(std::lround(content.x * pixelsPerPoint)), static_cast<int>(std::lround(content.y * pixelsPerPoint)),
                 logicalWidth * scale, logicalHeight * scale };
    }
    bool IsBackgrounded()
    {
        return backgrounded;
    }
    SDL_Point PointerPosition()
    {
        return pointer;
    }
    bool IsPencilSqueezeHeld()
    {
        return pencilSqueezeHeld;
    }
    bool ProcessEvent(SDL_Event& event, SDL_Window* window)
    {
        if (pendingMenu)
        {
            pendingMenu = false;
            int selection = Menu(
                { "Import park", "Export saved park", "Touch controls", "Cancel" }, @"Files & controls",
                @"Saves are available in Files → On My iPad → OpenRCT2 iPad → OpenRCT2 → save.");
            if (selection == 0)
            {
                const bool proceed = !IsPlayingPark()
                    || Menu(
                           { "Cancel", "Import park" }, @"Replace current park?",
                           @"Save your current park first if you want to keep any unsaved changes.")
                        == 1;
                if (proceed)
                    pendingPark = ImportPark();
            }
            if (selection == 1)
                ExportPark();
            if (selection == 2)
                Alert(
                    @"Touch controls",
                    @"Tap menus and buttons once.\nMove one finger to preview placement; double-tap to build.\n"
                    @"Hold briefly, then drag to paint paths, land, water, or clear scenery.\n"
                    @"Two-finger drag: pan. Pinch: zoom. Twist: rotate supported construction.\n"
                    @"Two-finger tap on a removable path: remove. Hold two fingers, then drag: erase paths.\n"
                    @"Apple Pencil Pro: squeeze and drag to pan.\n"
                    @"Long press outside paint tools: right click.\nOptions → Display: change interface scale");
        }
        if (!pendingPark.empty())
        {
            auto path = std::move(pendingPark);
            pendingPark.clear();
            NSString* extension = [NSString stringWithUTF8String:path.c_str()].pathExtension.lowercaseString;
            GetContext()->LoadParkFromFile(
                path, false, [extension isEqualToString:@"sc6"] || [extension isEqualToString:@"sc4"]);
        }
        // Finger events are handled by UiContext's OpenRCT2Touch gesture state machine.
        // Do not let SDL's optional synthetic mouse events overwrite its virtual cursor.
        if ((event.type == SDL_MOUSEMOTION && event.motion.which == SDL_TOUCH_MOUSEID)
            || ((event.type == SDL_MOUSEBUTTONDOWN || event.type == SDL_MOUSEBUTTONUP)
                && event.button.which == SDL_TOUCH_MOUSEID))
            return true;
        auto r = ContentRect(window);
        if (event.type == SDL_MOUSEMOTION)
        {
            event.motion.x -= r.x;
            event.motion.y -= r.y;
            pointer = { event.motion.x, event.motion.y };
        }
        if (event.type == SDL_MOUSEBUTTONDOWN || event.type == SDL_MOUSEBUTTONUP)
        {
            event.button.x -= r.x;
            event.button.y -= r.y;
            pointer = { event.button.x, event.button.y };
            if (event.type == SDL_MOUSEBUTTONDOWN && (pointer.x < 0 || pointer.y < 0 || pointer.x >= r.w || pointer.y >= r.h))
                return true;
        }
        return false;
    }
} // namespace OpenRCT2::Ui::IOS

namespace OpenRCT2::Ui
{
    class IOSContext final : public IPlatformUiContext
    {
        RCTTouchControls* _controls;
        id _audioObserver;

    public:
        ~IOSContext() override
        {
            SDL_DelEventWatch(Lifecycle, nullptr);
            if (_audioObserver)
                [NSNotificationCenter.defaultCenter removeObserver:_audioObserver];
            gameWindow = nullptr;
        }
        void SetWindowIcon(SDL_Window* window) override
        {
            SDL_DelEventWatch(Lifecycle, nullptr);
            if (_audioObserver) [NSNotificationCenter.defaultCenter removeObserver:_audioObserver];
            gameWindow = window;
            auto view = Controller().view;
            _controls = [RCTTouchControls new];
            UIView* bar = [UIView new];
            bar.backgroundColor = UIColor.darkGrayColor;
            bar.translatesAutoresizingMaskIntoConstraints = NO;
            [view addSubview:bar];
            [NSLayoutConstraint activateConstraints:@[
                [bar.leadingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.leadingAnchor],
                [bar.trailingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.trailingAnchor],
                [bar.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor],
                [bar.heightAnchor constraintEqualToConstant:kToolbarHeight]
            ]];
            UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.frame = CGRectMake(12, 0, 160, kToolbarHeight);
            [button setTitle:@"Files & controls" forState:UIControlStateNormal];
            [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            [button addTarget:_controls action:@selector(files) forControlEvents:UIControlEventTouchUpInside];
            [bar addSubview:button];
            if (@available(iOS 17.5, *))
            {
                auto pencil = [[UIPencilInteraction alloc] initWithDelegate:_controls];
                [view addInteraction:pencil];
            }
            SDL_AddEventWatch(Lifecycle, nullptr);
            _audioObserver = [NSNotificationCenter.defaultCenter
                addObserverForName:AVAudioSessionInterruptionNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification* notification) {
                          audioInterrupted = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]
                              == AVAudioSessionInterruptionTypeBegan;
                          if (audioInterrupted)
                              Audio::Pause();
                          else if (!backgrounded)
                              Audio::Resume();
                        }];
        }
        bool IsSteamOverlayAttached() override
        {
            return false;
        }
        bool HasMenuSupport() override
        {
            return false;
        }
        bool HasFilePicker() const override
        {
            return true;
        }
        void ShowMessageBox(SDL_Window*, const std::string& message) override
        {
            Alert(@"OpenRCT2", [NSString stringWithUTF8String:message.c_str()]);
        }
        int32_t ShowMenuDialog(
            const std::vector<std::string>& options, const std::string& title, const std::string& text) override
        {
            return Menu(options, [NSString stringWithUTF8String:title.c_str()], [NSString stringWithUTF8String:text.c_str()]);
        }
        std::string ShowDirectoryDialog(SDL_Window*, const std::string&) override
        {
            // Game data is imported and replaced in the launcher, before the game starts.
            Alert(@"OpenRCT2", @"Original game data is managed in the launcher. Quit the game and reopen the app to import or replace it.");
            return {};
        }
        std::string ShowFileDialog(SDL_Window*, const FileDialogDesc& desc) override
        {
            if (desc.Type == FileDialogType::open)
                return ImportPark();
            __block bool done = false;
            __block NSString* filename = nil;
            auto alert = [UIAlertController
                alertControllerWithTitle:@"Save to this iPad"
                                 message:@"The file will appear in Files → OpenRCT2 iPad → OpenRCT2 → save."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
              field.text = [NSString stringWithUTF8String:desc.DefaultFilename.c_str()].lastPathComponent;
              field.placeholder = @"My park.park";
            }];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                      style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction*) {
                                                      done = true;
                                                    }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction*) {
                                                      filename = alert.textFields.firstObject.text.lastPathComponent;
                                                      done = true;
                                                    }]];
            [Controller() presentViewController:alert animated:YES completion:nil];
            WaitUntil(^bool {
              return done && !alert.presentingViewController;
            });
            if (filename.length == 0 || [filename isEqualToString:@"."] || [filename isEqualToString:@".."])
                return {};
            if (filename.pathExtension.length == 0)
                filename = [filename stringByAppendingPathExtension:@"park"];
            NSString* directory = [Documents() stringByAppendingPathComponent:@"OpenRCT2/save"];
            [NSFileManager.defaultManager createDirectoryAtPath:directory
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:nil];
            return [directory stringByAppendingPathComponent:filename].UTF8String;
        }
        void OpenFolder(const std::string&) override
        {
            RequestMenu();
        }
        void OpenURL(const std::string& url) override
        {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]]
                                             options:@{}
                                   completionHandler:nil];
        }
    };
    std::unique_ptr<IPlatformUiContext> CreatePlatformUiContext()
    {
        return std::make_unique<IOSContext>();
    }
} // namespace OpenRCT2::Ui

int IosGameMain(int argc, const char** argv);
extern "C" int SDL_main(int argc, char** argv)
{
    @autoreleasepool
    {
        SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
        SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");
        NSString* logPath = [Documents() stringByAppendingPathComponent:@"OpenRCT2-ios.log"];
        freopen(logPath.UTF8String, "a", stdout);
        freopen(logPath.UTF8String, "a", stderr);
        setvbuf(stdout, nullptr, _IOLBF, 0);
        setvbuf(stderr, nullptr, _IOLBF, 0);
        fprintf(stderr, "\nOpenRCT2 iPad startup: %s\n", NSDate.date.description.UTF8String);
        bootstrapWindow = [[UIWindow alloc] initWithWindowScene:OpenRCT2::Ui::IOS::GetWindowScene()];
        bootstrapWindow.rootViewController = [UIViewController new];
        bootstrapWindow.rootViewController.view.backgroundColor = UIColor.blackColor;
        [bootstrapWindow makeKeyAndVisible];
        bootstrapWindow.hidden = YES;
        bootstrapWindow = nil;
        // Use a writable working directory; game data is located explicitly in the bundle.
        chdir(Documents().UTF8String);
        // UIKit/Xcode may append Cocoa launch arguments, which are not game file paths. A park
        // to open at startup can be named explicitly instead (testing and measurement): an
        // absolute path, a path relative to Documents, or a name in OpenRCT2/save.
        if (const char* park = std::getenv("OPENRCT2_IOS_OPEN_PARK"); park != nullptr && *park != '\0')
        {
            NSString* requested = @(park);
            NSFileManager* files = NSFileManager.defaultManager;
            NSString* saves = [Documents() stringByAppendingPathComponent:@"OpenRCT2/save"];
            NSString* resolved = nil;
            for (NSString* candidate in @[
                     requested, [Documents() stringByAppendingPathComponent:requested],
                     [saves stringByAppendingPathComponent:requested],
                     [saves stringByAppendingPathComponent:[requested stringByAppendingPathExtension:@"park"]]
                 ])
            {
                if (candidate.isAbsolutePath && [files fileExistsAtPath:candidate])
                {
                    resolved = candidate;
                    break;
                }
            }
            if (resolved != nil)
            {
                fprintf(stderr, "Opening park at startup: %s\n", resolved.UTF8String);
                const char* arguments[] = { argv[0], resolved.UTF8String, nullptr };
                return IosGameMain(2, arguments);
            }
            fprintf(stderr, "OPENRCT2_IOS_OPEN_PARK not found: %s\n", park);
        }
        return IosGameMain(1, const_cast<const char**>(argv));
    }
}
#endif
