/*****************************************************************************
 * Copyright (c) 2026 OpenRCT2 developers
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/
#ifdef OPENRCT2_IOS
    #define SDL_MAIN_HANDLED
    #include "UiContext.iOS.h"
    #import "OpenRCT2Launcher-Swift.h"

    #include <SDL.h>
    #include <SDL_syswm.h>
    #import <UIKit/UIKit.h>
    #include <stdexcept>

namespace
{
    UIWindowScene* gameScene;
    bool gameStarted = false;
    UIWindow* launcherWindow;
    void IdleTimerChanged(void*, const char*, const char*, const char* value)
    {
        UIApplication.sharedApplication.idleTimerDisabled = value && *value != '0';
    }
} // namespace

namespace OpenRCT2::Ui::IOS
{
    UIWindowScene* GetWindowScene()
    {
        return gameScene;
    }

    void AttachWindowToScene(SDL_Window* window)
    {
        SDL_SysWMinfo info{};
        SDL_VERSION(&info.version);
        if (!gameScene || !SDL_GetWindowWMInfo(window, &info))
            throw std::runtime_error("Unable to attach the SDL window to its iPad scene");
        // SDL2 creates a UIWindow using its legacy initializer. Adopt it into our
        // scene before creating the renderer and presenting the first frame.
        UIWindow* nativeWindow = info.info.uikit.window;
        nativeWindow.windowScene = gameScene;
        nativeWindow.frame = gameScene.coordinateSpace.bounds;
        [nativeWindow makeKeyAndVisible];
        [nativeWindow layoutIfNeeded];
    }
} // namespace OpenRCT2::Ui::IOS

@interface RCT2SceneDelegate : NSObject <UIWindowSceneDelegate>
@end

@interface RCT2ApplicationDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation RCT2ApplicationDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options
{
    SDL_SetMainReady();
    SDL_AddHintCallback(SDL_HINT_IDLE_TIMER_DISABLED, IdleTimerChanged, nullptr);
    return YES;
}
- (UISceneConfiguration*)application:(UIApplication*)application
    configurationForConnectingSceneSession:(UISceneSession*)session
                                   options:(UISceneConnectionOptions*)options
{
    auto configuration = [[UISceneConfiguration alloc] initWithName:@"OpenRCT2" sessionRole:session.role];
    configuration.delegateClass = RCT2SceneDelegate.class;
    return configuration;
}
- (void)applicationDidReceiveMemoryWarning:(UIApplication*)application
{
    SDL_OnApplicationDidReceiveMemoryWarning();
}
- (void)applicationWillTerminate:(UIApplication*)application
{
    SDL_OnApplicationWillTerminate();
}
@end

@implementation RCT2SceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options
{
    if ([scene isKindOfClass:UIWindowScene.class] && [session.role isEqualToString:UIWindowSceneSessionRoleApplication])
        gameScene = static_cast<UIWindowScene*>(scene);
}
- (void)showLauncher
{
    if (launcherWindow || gameStarted || !gameScene)
        return;
    launcherWindow = [ORCTLauncher makeWindowWithScene:gameScene
                                               onStart:^{
                                                 [self startGame];
                                               }];
    [launcherWindow makeKeyAndVisible];
}
- (void)startGame
{
    if (gameStarted || !gameScene)
        return;
    gameStarted = true;
    launcherWindow.hidden = YES;
    launcherWindow = nil;
    char name[] = "OpenRCT2-iPad";
    char* arguments[] = { name, nullptr };
    // Keep OpenRCT2 on the main thread. SDL's existing UIKit event pump services
    // scene events while the game's normal loop is running.
    int status = SDL_main(1, arguments);
    // Quitting from the game has torn down the engine and its window; leave the
    // app instead of showing an empty screen.
    exit(status);
}
- (void)sceneDidBecomeActive:(UIScene*)scene
{
    if (scene != gameScene)
        return;
    SDL_OnApplicationDidBecomeActive();
    // The launcher decides when the game starts; it needs imported RCT2 data first.
    if (!gameStarted)
        [self showLauncher];
}
- (void)sceneWillResignActive:(UIScene*)scene
{
    if (scene == gameScene)
        SDL_OnApplicationWillResignActive();
}
- (void)sceneWillEnterForeground:(UIScene*)scene
{
    if (scene == gameScene)
        SDL_OnApplicationWillEnterForeground();
}
- (void)sceneDidEnterBackground:(UIScene*)scene
{
    if (scene == gameScene)
        SDL_OnApplicationDidEnterBackground();
}
@end

int main(int argc, char** argv)
{
    @autoreleasepool
    {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(RCT2ApplicationDelegate.class));
    }
}
#endif
