// Dear ImGui overlay sandbox - iOS + Metal
// Adapted from Dear ImGui's official examples/example_apple_metal (MIT).
// The menu is NOT here: it is ../shared/ui.cpp, identical to the Win32 build.
// Only the platform glue (UIKit + MTKView + touch mapping) is iOS-specific.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "ui.h"

#import "pip_hud.h"

// ---------------------------------------------------------------- platform state
static bool s_opaqueBackground = false;   // MTKView.opaque
static bool s_paused = false;             // freeze counters, keep presenting
static MTKView* __weak s_mtkView = nil;

static void ApplyViewSettings()
{
    MTKView* view = s_mtkView;
    if (!view) return;
    view.opaque = s_opaqueBackground;
    view.backgroundColor = s_opaqueBackground
        ? [UIColor colorWithRed:0.055 green:0.065 blue:0.085 alpha:1.0]
        : [UIColor clearColor];
}

static void OnToggle(void*)
{
    ApplyViewSettings();
    overlay::AddLog("opaque=%d paused=%d", s_opaqueBackground, s_paused);
}

static overlay::PlatformHooks MakeHooks()
{
    overlay::PlatformHooks h = {};
    h.platform_line = "iOS / UIKit / Metal";
    h.hotkeys_line  = "touch = mouse  |  swipe to drag sliders";
    h.backend_name  = "UIKit + Metal (imgui_impl_metal)";
    h.compiler_name = "Apple Clang (Xcode)";
    h.window_note   = "The MTKView sits on top of a normal UIView and is "
                      "non-opaque, so the app content stays visible behind "
                      "the ImGui layer. That is what an overlay is on iOS.";
    h.toggles[0] = { "opaque background", &s_opaqueBackground };
    h.toggles[1] = { "paused", &s_paused };
    h.toggle_count = 2;
    h.on_toggle = OnToggle;
    return h;
}

static overlay::PlatformHooks g_hooks;

// ---------------------------------------------------------------- view controller
@interface AppViewController : UIViewController <MTKViewDelegate>
@property (nonatomic, strong) MTKView* mtkView;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@end

@implementation AppViewController
{
    CFTimeInterval _lastTime;
}

- (instancetype)initWithNibName:(NSString*)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (!self) return nil;

    _device = MTLCreateSystemDefaultDevice();
    if (!self.device)
    {
        NSLog(@"Metal is not supported on this device");
        abort();
    }
    _commandQueue = [self.device newCommandQueue];
    _lastTime = CACurrentMediaTime();

    // --- Dear ImGui context (platform independent part) ---
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;                 // don't write imgui.ini into the sandbox
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ImGui::StyleColorsDark();
    ImGuiStyle& style = ImGui::GetStyle();
    style.FontSizeBase = 17.0f;               // bigger glyphs for touch input
    style.ScaleAllSizes(1.15f);

    ImGui_ImplMetal_Init(self.device);
    return self;
}

- (void)loadView
{
    UIView* root = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    root.backgroundColor = [UIColor colorWithRed:0.055 green:0.065 blue:0.085 alpha:1.0];
    root.userInteractionEnabled = YES;

    // Some "application content" behind the overlay, so the transparency is visible.
    UILabel* label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = @"your app content here\nImGui renders on top";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:root.centerYAnchor]
    ]];

    self.mtkView = [[MTKView alloc] initWithFrame:root.bounds device:self.device];
    self.mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.mtkView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    self.mtkView.opaque = NO;
    self.mtkView.backgroundColor = [UIColor clearColor];
    self.mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.mtkView.userInteractionEnabled = NO;   // touches are handled by the VC below
    [root addSubview:self.mtkView];

    // Button that floats the HUD above every other app (picture in picture).
    UIButton* pipButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [pipButton setTitle:@"> HUD above the screen (PiP)" forState:UIControlStateNormal];
    pipButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    pipButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    pipButton.layer.cornerRadius = 10.0;
    pipButton.translatesAutoresizingMaskIntoConstraints = NO;
    [pipButton addTarget:self action:@selector(togglePictureInPicture:) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:pipButton];
    [NSLayoutConstraint activateConstraints:@[
        [pipButton.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12],
        [pipButton.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [pipButton.heightAnchor constraintEqualToConstant:44],
    ]];

    self.view = root;
    s_mtkView = self.mtkView;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.mtkView.delegate = self;
    g_hooks = MakeHooks();
    ApplyViewSettings();
    overlay::AddLog("overlay initialised (iOS / Metal)");
    overlay::AddLog("device: %s", [[self.device name] UTF8String]);

    [[PipHudController sharedController] configureWithDevice:self.device queue:self.commandQueue];
    overlay::AddLog("PiP overlay: %s",
                    [AVPictureInPictureController isPictureInPictureSupported] ? "supported" : "NOT supported");
}

// ---------------------------------------------------------------- floating HUD
- (void)togglePictureInPicture:(UIButton*)sender
{
    PipHudController* pip = [PipHudController sharedController];

    if (pip.isRunning)
    {
        [pip stop];
        [sender setTitle:@"> HUD above the screen (PiP)" forState:UIControlStateNormal];
        return;
    }

    NSError* error = nil;
    if ([pip start:&error])
    {
        [sender setTitle:@"Stop HUD (PiP)" forState:UIControlStateNormal];
    }
    else
    {
        overlay::AddLog("PiP start failed: %s", [[error localizedDescription] UTF8String]);
    }
}

// ---------------------------------------------------------------- frame
- (void)drawInMTKView:(MTKView*)view
{
    @autoreleasepool
    {
        CFTimeInterval now = CACurrentMediaTime();
        float dt = (float)(now - _lastTime);
        _lastTime = now;
        if (dt < 0.0f) dt = 0.0f;
        if (dt > 0.25f) dt = 0.25f;

        ImGuiIO& io = ImGui::GetIO();
        io.DisplaySize.x = view.bounds.size.width;
        io.DisplaySize.y = view.bounds.size.height;
        CGFloat scale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
        io.DisplayFramebufferScale = ImVec2(scale, scale);

        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        if (rpd == nil) { [commandBuffer commit]; return; }

        ImGui_ImplMetal_NewFrame(rpd);
        ImGui::NewFrame();

        overlay::DrawUI(g_hooks, s_paused ? 0.0f : dt);

        ImGui::Render();
        ImDrawData* drawData = ImGui::GetDrawData();

        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
        [encoder pushDebugGroup:@"Dear ImGui rendering"];
        ImGui_ImplMetal_RenderDrawData(drawData, commandBuffer, encoder);
        [encoder popDebugGroup];
        [encoder endEncoding];

        [commandBuffer presentDrawable:view.currentDrawable];
        [commandBuffer commit];
    }
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size
{
    (void)view; (void)size;
}

// ---------------------------------------------------------------- touch input
// Single-touch mapping, same approach as ImGui's official iOS example:
// any touch acts as a pressed left mouse button.
- (void)updateIOWithTouchEvent:(UIEvent*)event
{
    UITouch* anyTouch = event.allTouches.anyObject;
    if (!anyTouch) return;
    CGPoint p = [anyTouch locationInView:self.view];
    ImGuiIO& io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent(p.x, p.y);

    BOOL active = NO;
    for (UITouch* t in event.allTouches)
        if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) { active = YES; break; }
    io.AddMouseButtonEvent(0, active);
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event     { [self updateIOWithTouchEvent:event]; }
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event     { [self updateIOWithTouchEvent:event]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self updateIOWithTouchEvent:event]; }
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event     { [self updateIOWithTouchEvent:event]; }

- (void)dealloc
{
    ImGui_ImplMetal_Shutdown();
    ImGui::DestroyContext();
}

@end

// ---------------------------------------------------------------- app delegate
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id>*)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[AppViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char* argv[])
{
    @autoreleasepool
    {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
