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
    #include <cstdlib>
    #include <unistd.h>

using namespace OpenRCT2;
namespace
{
    constexpr Uint32 kTouchPointer = 0xFFFFFFFE;
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
    NSString* RCT2Directory()
    {
        return [Documents() stringByAppendingPathComponent:@"RCT2"];
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
    void ButtonEvent(Uint32 type, Uint8 button, CGPoint point)
    {
        SDL_Event event{};
        event.type = type;
        event.button.windowID = SDL_GetWindowID(gameWindow);
        event.button.which = kTouchPointer;
        event.button.button = button;
        event.button.state = type == SDL_MOUSEBUTTONDOWN ? SDL_PRESSED : SDL_RELEASED;
        event.button.x = point.x;
        event.button.y = point.y;
        SDL_PushEvent(&event);
    }
    void MotionEvent(CGPoint point)
    {
        SDL_Event event{};
        event.type = SDL_MOUSEMOTION;
        event.motion.windowID = SDL_GetWindowID(gameWindow);
        event.motion.which = kTouchPointer;
        event.motion.x = point.x;
        event.motion.y = point.y;
        SDL_PushEvent(&event);
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
    NSString* ChildIgnoringCase(NSString* directory, NSString* name)
    {
        for (NSString* child in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil])
            if ([child caseInsensitiveCompare:name] == NSOrderedSame)
                return [directory stringByAppendingPathComponent:child];
        return nil;
    }
    bool ValidData(NSString* root)
    {
        NSString* data = ChildIgnoringCase(root, @"Data");
        NSString* g1 = data ? ChildIgnoringCase(data, @"g1.dat") : nil;
        if (!g1)
            return false;
        NSNumber* size = [NSFileManager.defaultManager attributesOfItemAtPath:g1 error:nil][NSFileSize];
        return size && [size unsignedLongLongValue] > 1000000;
    }
    bool ImportRCT2()
    {
        NSURL* url = Pick(true);
        if (!url)
            return false;
        bool access = [url startAccessingSecurityScopedResource];
        if (!ValidData(url.path))
        {
            if (access)
                [url stopAccessingSecurityScopedResource];
            Alert(
                @"Missing RCT2 data",
                @"Choose the installed or unpacked RCT2 folder containing Data/g1.dat, ObjData and Scenarios. An installer "
                @".exe or a patch alone is not sufficient.");
            return false;
        }
        // Copy on a worker while UIKit keeps showing progress. Commit only a complete copy.
        auto progress = [UIAlertController
            alertControllerWithTitle:@"Importing RCT2"
                             message:@"Copying your game data into this app. Please keep the app open."
                      preferredStyle:UIAlertControllerStyleAlert];
        [Controller() presentViewController:progress animated:YES completion:nil];
        __block bool done = false;
        __block NSError* failure = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          auto fm = NSFileManager.defaultManager;
          NSString* staging = [Documents()
              stringByAppendingPathComponent:[@"RCT2-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
          [fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:&failure];
          auto coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
          if (!failure)
              [coordinator
                  coordinateReadingItemAtURL:url
                                     options:0
                                       error:&failure
                                  byAccessor:^(NSURL* source) {
                                    for (NSString* name in @[ @"Data", @"ObjData", @"Scenarios", @"Tracks", @"Saved Games" ])
                                    {
                                        NSString* child = ChildIgnoringCase(source.path, name);
                                        if (child
                                            && ![fm copyItemAtPath:child
                                                            toPath:[staging stringByAppendingPathComponent:name]
                                                             error:&failure])
                                            break;
                                    }
                                  }];
          if (!failure)
          {
              if ([fm fileExistsAtPath:RCT2Directory()])
                  [fm replaceItemAtURL:[NSURL fileURLWithPath:RCT2Directory()]
                         withItemAtURL:[NSURL fileURLWithPath:staging]
                        backupItemName:nil
                               options:0
                      resultingItemURL:nil
                                 error:&failure];
              else
                  [fm moveItemAtPath:staging toPath:RCT2Directory() error:&failure];
          }
          if (failure)
              [fm removeItemAtPath:staging error:nil];
          dispatch_async(dispatch_get_main_queue(), ^{
            done = true;
          });
        });
        WaitUntil(^bool {
          return done;
        });
        if (access)
            [url stopAccessingSecurityScopedResource];
        [progress dismissViewControllerAnimated:NO completion:nil];
        WaitUntil(^bool {
          return !progress.presentingViewController;
        });
        if (failure)
            Alert(@"Import failed", failure.localizedDescription);
        return !failure && ValidData(RCT2Directory());
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

@interface RCTTouchControls : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIView* bar;
@end
@implementation RCTTouchControls
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture shouldReceiveTouch:(UITouch*)touch
{
    return ![touch.view isDescendantOfView:self.bar];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)first
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)second
{
    // Allow two-finger panning and zooming together, but never combine them with a construction drag.
    auto isNavigation = [](UIGestureRecognizer* gesture) {
        return [gesture isKindOfClass:UIPinchGestureRecognizer.class]
            || ([gesture isKindOfClass:UIPanGestureRecognizer.class]
                && static_cast<UIPanGestureRecognizer*>(gesture).minimumNumberOfTouches == 2);
    };
    return isNavigation(first) && isNavigation(second);
}
- (void)files
{
    RequestMenu();
}
- (void)tap:(UITapGestureRecognizer*)gesture
{
    CGPoint p = [gesture locationInView:gesture.view];
    MotionEvent(p);
    ButtonEvent(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, p);
    ButtonEvent(SDL_MOUSEBUTTONUP, SDL_BUTTON_LEFT, p);
}
- (void)drag:(UIPanGestureRecognizer*)gesture
{
    CGPoint p = [gesture locationInView:gesture.view];
    Uint8 button = gesture.minimumNumberOfTouches == 2 ? SDL_BUTTON_RIGHT : SDL_BUTTON_LEFT;
    if (gesture.state == UIGestureRecognizerStateBegan)
    {
        CGPoint delta = [gesture translationInView:gesture.view];
        ButtonEvent(SDL_MOUSEBUTTONDOWN, button, CGPointMake(p.x - delta.x, p.y - delta.y));
    }
    MotionEvent(p);
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled)
        ButtonEvent(SDL_MOUSEBUTTONUP, button, p);
}
- (void)hold:(UILongPressGestureRecognizer*)gesture
{
    CGPoint p = [gesture locationInView:gesture.view];
    MotionEvent(p);
    if (gesture.state == UIGestureRecognizerStateBegan)
        ButtonEvent(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_RIGHT, p);
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled)
        ButtonEvent(SDL_MOUSEBUTTONUP, SDL_BUTTON_RIGHT, p);
}
- (void)pinch:(UIPinchGestureRecognizer*)gesture
{
    if (gesture.scale > 1.18 || gesture.scale < 0.85)
    {
        SDL_Event event{};
        event.type = SDL_MOUSEWHEEL;
        event.wheel.y = gesture.scale > 1 ? 1 : -1;
        SDL_PushEvent(&event);
        gesture.scale = 1;
    }
}
@end

namespace OpenRCT2::Ui::IOS
{
    SDL_Point OutputPixelSize(SDL_Window* window)
    {
        SDL_Point result{};
        if (auto renderer = SDL_GetRenderer(window))
            SDL_GetRendererOutputSize(renderer, &result.x, &result.y);
        else
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
    SDL_Rect DrawableRect(SDL_Window* window, SDL_Renderer* renderer)
    {
        auto r = ContentRect(window);
        int w, h, rw, rh;
        SDL_GetWindowSize(window, &w, &h);
        SDL_GetRendererOutputSize(renderer, &rw, &rh);
        return { r.x * rw / w, r.y * rh / h, r.w * rw / w, r.h * rh / h };
    }
    bool IsBackgrounded()
    {
        return backgrounded;
    }
    SDL_Point PointerPosition()
    {
        return pointer;
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
                    @"Tap: left click\nOne-finger drag: use the selected tool\nTwo-finger drag: move the view\nPinch: zoom the "
                    @"view\nHold then release: right click / cancel tool\nHold and drag: move the view\nOptions → Display: "
                    @"change interface scale");
        }
        if (!pendingPark.empty())
        {
            auto path = std::move(pendingPark);
            pendingPark.clear();
            NSString* extension = [NSString stringWithUTF8String:path.c_str()].pathExtension.lowercaseString;
            GetContext()->LoadParkFromFile(
                path, false, [extension isEqualToString:@"sc6"] || [extension isEqualToString:@"sc4"]);
        }
        if (event.type == SDL_FINGERDOWN || event.type == SDL_FINGERUP || event.type == SDL_FINGERMOTION
            || event.type == SDL_MULTIGESTURE)
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
            SDL_RendererInfo rendererInfo{};
            SDL_GetRendererInfo(SDL_GetRenderer(window), &rendererInfo);
            fprintf(stderr, "iPad drawing engine: %s\n", rendererInfo.name ? rendererInfo.name : "native Metal");
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
            _controls.bar = bar;
            UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.frame = CGRectMake(12, 0, 160, kToolbarHeight);
            [button setTitle:@"Files & controls" forState:UIControlStateNormal];
            [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            [button addTarget:_controls action:@selector(files) forControlEvents:UIControlEventTouchUpInside];
            [bar addSubview:button];
            auto tap = [[UITapGestureRecognizer alloc] initWithTarget:_controls action:@selector(tap:)];
            auto drag = [[UIPanGestureRecognizer alloc] initWithTarget:_controls action:@selector(drag:)];
            drag.maximumNumberOfTouches = 1;
            auto pan = [[UIPanGestureRecognizer alloc] initWithTarget:_controls action:@selector(drag:)];
            pan.minimumNumberOfTouches = pan.maximumNumberOfTouches = 2;
            auto hold = [[UILongPressGestureRecognizer alloc] initWithTarget:_controls action:@selector(hold:)];
            auto pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:_controls action:@selector(pinch:)];
            [tap requireGestureRecognizerToFail:hold];
            for (UIGestureRecognizer* recognizer in @[ tap, drag, pan, hold, pinch ])
            {
                recognizer.delegate = _controls;
                [view addGestureRecognizer:recognizer];
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
            return ImportRCT2() ? RCT2Directory().UTF8String : "";
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
        while (!ValidData(RCT2Directory()))
        {
            Menu(
                { "Import RCT2 folder" }, @"Welcome to OpenRCT2",
                @"Select your own installed or unpacked RCT2 folder using Files. It must contain Data/g1.dat. The game will "
                @"copy Data, ObjData, Scenarios, Tracks and Saved Games into this app. Your originals stay unchanged.");
            ImportRCT2();
        }
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
