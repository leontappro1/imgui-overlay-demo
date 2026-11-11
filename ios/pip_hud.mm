// System-level floating HUD on iOS.
//
// There is no "draw over other apps" API for third-party apps. The ONE window
// iOS composites above everything else is picture-in-picture. But there are
// two fundamentally different PiP content sources:
//
//   * initWithSampleBufferDisplayLayer:playbackDelegate:  -> a VIDEO player.
//     iOS adds play/pause, +/-10s, a scrubber and a "LIVE" badge. Looks like
//     a video. (This is what the previous build used.)
//
//   * initWithActiveVideoCallSourceView:contentViewController: (iOS 15+)
//     -> a plain UIView hierarchy inside the PiP window. No player chrome,
//     no LIVE badge, no scrubber, and preferredContentSize lets us influence
//     the window's aspect ratio. This is the one used below.
//
// The activeVideoCallSourceView is a real, visible view in our app. The
// contentViewController's view is what the system shows in the floating
// window. Apple explicitly allows DIFFERENT views in both places as long as
// they represent the same "call"; here both are the same dark HUD strip.
//
// SDK 18.5 header notes we follow here:
//   * KVO key path is "pictureInPicturePossible" (getter isPictureInPicturePossible).
//   * the content VC's view is NOT interactive;
//   * content should be installed once its appearance methods say it is on screen;
//   * content should fill the content VC's view bounds;
//   * set contentSource to nil / release the controller when the "call" ends.

#import "pip_hud.h"

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>

#include <string.h>
#include "ui.h"

namespace
{
    // Influences the aspect ratio AND the size of the system PiP window.
    // A wide, shallow rectangle reads as a HUD bar rather than a video.
    const CGFloat kHudWidth  = 960.0;
    const CGFloat kHudHeight = 240.0;
    const double  kHudFps    = 30.0;

    static char kPipPossibleContext;

    // Dark strip + monospaced text. Used both inline and inside the PiP window.
    // Explicit __strong out-pointer avoids ARC writeback surprises with ivars.
    UIView* MakeHudStrip(CGRect frame, UILabel * __strong *outLabel)
    {
        UIView* strip = [[UIView alloc] initWithFrame:frame];
        strip.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
        strip.layer.cornerRadius = 14.0;
        strip.clipsToBounds = YES;
        strip.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;

        UIView* accent = [[UIView alloc]
            initWithFrame:CGRectMake(0.0, CGRectGetHeight(frame) - 5.0,
                                     CGRectGetWidth(frame), 5.0)];
        accent.backgroundColor = [UIColor colorWithRed:0.20 green:0.80 blue:0.95 alpha:1.0];
        accent.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleTopMargin;
        [strip addSubview:accent];

        UILabel* label = [[UILabel alloc] initWithFrame:CGRectInset(frame, 18.0, 8.0)];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont monospacedSystemFontOfSize:46.0 weight:UIFontWeightBold];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.25;
        label.numberOfLines = 1;
        label.text = @"Hud  |  fps : ?  |  ping : ?";
        [strip addSubview:label];

        if (outLabel) *outLabel = label;
        return strip;
    }
}

// ---------------------------------------------------------------- PiP content VC
// Apple's guidance: put call content into this controller's view hierarchy
// once it has appeared. We do exactly that, instead of guessing view.bounds
// at controller-creation time.

API_AVAILABLE(ios(15.0))
@interface HudVideoCallViewController : AVPictureInPictureVideoCallViewController
@property (nonatomic, strong, nullable) UILabel* hudLabel;
@end

@implementation HudVideoCallViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    self.view.clipsToBounds = YES;
    if (CGRectIsEmpty(self.view.bounds))
        self.view.frame = CGRectMake(0.0, 0.0, kHudWidth, kHudHeight);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.hudLabel) return;

    UILabel* label = nil;
    UIView* strip = MakeHudStrip(self.view.bounds, &label);
    strip.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                             UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:strip];
    self.hudLabel = label;

    overlay::AddLog("HUD: PiP view %.0fx%.0f",
                    self.view.bounds.size.width, self.view.bounds.size.height);
}

@end

// ---------------------------------------------------------------- controller

@interface PipHudController () <AVPictureInPictureControllerDelegate>
@property (nonatomic, weak)   UIView* sourceView;
@property (nonatomic, strong) AVPictureInPictureController* pipController;
@property (nonatomic, strong) AVPictureInPictureControllerContentSource* contentSource;
@property (nonatomic, strong) HudVideoCallViewController* contentVC;
@property (nonatomic, strong) UILabel* inlineLabel;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) AVAudioEngine* audioEngine;
@property (nonatomic, strong) AVAudioPlayerNode* audioNode;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL startRequested;
@property (nonatomic, assign) BOOL observing;
@property (nonatomic, assign) CFTimeInterval lastTick;
@property (nonatomic, assign) float fps;
@end

@implementation PipHudController

+ (instancetype)sharedController
{
    static PipHudController* instance = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ instance = [[PipHudController alloc] init]; });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) _backgroundTask = UIBackgroundTaskInvalid;
    return self;
}

- (void)dealloc
{
    [self stopTimer];
    [self stopObserving];
    [self stopSilentAudio];
}

// ---------------------------------------------------------------- source view
// The video-call PiP API needs a real, visible view in the app. iOS uses its
// layout frame and visibility to decide whether PiP can start automatically.

- (void)attachSourceView:(UIView*)view
{
    if (!view || CGRectIsEmpty(view.bounds)) return;
    self.sourceView = view;

    if (!self.inlineLabel)
    {
        UILabel* label = nil;
        UIView* strip = MakeHudStrip(view.bounds, &label);
        [view addSubview:strip];
        self.inlineLabel = label;
        overlay::AddLog("HUD: source view %.0fx%.0f",
                        view.bounds.size.width, view.bounds.size.height);
    }
    else
    {
        self.inlineLabel.superview.frame = view.bounds;
    }
}

// ---------------------------------------------------------------- control

- (BOOL)isRunning { return self.running; }
- (BOOL)isPictureInPictureActive   { return self.pipController.isPictureInPictureActive; }
- (BOOL)isPictureInPicturePossible { return self.pipController.isPictureInPicturePossible; }

- (void)postState:(BOOL)active
{
    void (^block)(BOOL) = self.stateChanged;
    if (!block) return;
    if ([NSThread isMainThread])
        block(active);
    else
        dispatch_async(dispatch_get_main_queue(), ^{ block(active); });
}

- (BOOL)start:(NSError* _Nullable * _Nullable)error
{
    if (self.running) return YES;

    if (!@available(iOS 15.0, *))
    {
        if (error)
            *error = [NSError errorWithDomain:@"PipHud" code:4 userInfo:@{
                NSLocalizedDescriptionKey: @"Video-call Picture in Picture needs iOS 15 or newer" }];
        overlay::AddLog("HUD: ERROR - iOS 15+ required");
        return NO;
    }

    if (![AVPictureInPictureController isPictureInPictureSupported])
    {
        if (error)
            *error = [NSError errorWithDomain:@"PipHud" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"Picture in Picture is not supported on this device" }];
        return NO;
    }

    UIView* source = self.sourceView;
    if (!source || !source.window || CGRectIsEmpty(source.bounds))
    {
        if (error)
            *error = [NSError errorWithDomain:@"PipHud" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"HUD source view is not on screen" }];
        overlay::AddLog("HUD: ERROR - source view not visible");
        return NO;
    }

    // The audio session must be active BEFORE the controller is created,
    // otherwise isPictureInPicturePossible stays NO and start is a no-op.
    [self startSilentAudio];

    HudVideoCallViewController* contentVC =
        [[HudVideoCallViewController alloc] init];
    contentVC.preferredContentSize = CGSizeMake(kHudWidth, kHudHeight);
    [contentVC loadViewIfNeeded];
    self.contentVC = contentVC;

    AVPictureInPictureControllerContentSource* contentSource =
        [[AVPictureInPictureControllerContentSource alloc]
            initWithActiveVideoCallSourceView:source
                        contentViewController:contentVC];
    self.contentSource = contentSource;

    AVPictureInPictureController* controller =
        [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
    if (!controller)
    {
        if (error)
            *error = [NSError errorWithDomain:@"PipHud" code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"AVPictureInPictureController refused to initialise" }];
        overlay::AddLog("HUD: ERROR - controller init returned nil");
        self.contentSource = nil;
        self.contentVC = nil;
        [self stopSilentAudio];
        return NO;
    }

    self.pipController = controller;
    controller.delegate = self;
    controller.canStartPictureInPictureAutomaticallyFromInline = YES;

    self.running        = YES;
    self.startRequested = NO;
    self.lastTick       = CACurrentMediaTime();
    self.fps            = 0.0f;

    [self startObserving];
    [self startTimer];

    overlay::AddLog("HUD: video-call PiP (no player controls)");
    overlay::AddLog("HUD: possible=%d audio=%d",
                    controller.isPictureInPicturePossible, self.audioEngine.isRunning);

    [self requestStartPictureInPicture];
    [self scheduleStartRetries];
    return YES;
}

- (void)stop
{
    [self stopTimer];
    [self stopObserving];
    [self stopSilentAudio];
    [self.pipController stopPictureInPicture];
    self.pipController  = nil;
    self.contentSource  = nil;
    self.contentVC      = nil;
    self.running        = NO;
    self.startRequested = NO;
    [self postState:NO];
    overlay::AddLog("HUD: stopped by app");
}

// startPictureInPicture is a silent no-op when isPictureInPicturePossible is
// NO. Retry when the flag flips, on a few timers, and on the way to background.

- (void)requestStartPictureInPicture
{
    if (!self.running || !self.pipController) return;
    if (self.pipController.isPictureInPictureActive) return;

    if (!self.pipController.isPictureInPicturePossible)
    {
        overlay::AddLog("HUD: not possible yet (audio=%d)", self.audioEngine.isRunning);
        return;
    }

    if (!self.startRequested)
    {
        self.startRequested = YES;
        overlay::AddLog("HUD: requested");
    }
    [self.pipController startPictureInPicture];
}

- (void)scheduleStartRetries
{
    const double delays[] = { 0.2, 0.6, 1.5, 3.0 };
    __weak __typeof(self) weakSelf = self;
    for (double delay : delays)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * (double)NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf requestStartPictureInPicture];
        });
    }

    // Do not leave the button stuck on "Starting..." forever if the system
    // silently refuses PiP. stateChanged(NO) puts the UI back to idle.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * (double)NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) return;
        if (strongSelf.pipController.isPictureInPictureActive) return;
        overlay::AddLog("HUD: start timeout - PiP never became active");
        [strongSelf stop];
    });
}

- (void)startObserving
{
    if (self.observing) return;
    self.observing = YES;

    [self.pipController addObserver:self
                         forKeyPath:@"pictureInPicturePossible"
                            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                            context:&kPipPossibleContext];

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(appWillResignActive:)
                name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(appDidEnterBackground:)
                name:UIApplicationDidEnterBackgroundNotification object:nil];
}

- (void)stopObserving
{
    if (!self.observing) return;
    if (self.pipController)
        [self.pipController removeObserver:self
                                forKeyPath:@"pictureInPicturePossible"
                                   context:&kPipPossibleContext];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.observing = NO;
}

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id>*)change
                       context:(void*)context
{
    if (context == &kPipPossibleContext)
    {
        id value = change[NSKeyValueChangeNewKey];
        BOOL possible = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
        overlay::AddLog("HUD: possible=%d", possible);
        if (possible) [self requestStartPictureInPicture];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)appWillResignActive:(NSNotification*)note
{
    if (!self.running) return;
    overlay::AddLog("HUD: leaving foreground");
    [self requestStartPictureInPicture];
}

- (void)appDidEnterBackground:(NSNotification*)note
{
    if (!self.running) return;
    overlay::AddLog("HUD: bg audio=%d timer=%d", self.audioEngine.isRunning, self.timer != nil);
    [self requestStartPictureInPicture];
}

// ---------------------------------------------------------------- keep alive
// Background audio keeps the process (and the label-update timer) alive while
// the PiP HUD floats above another app.

- (void)startSilentAudio
{
    if (self.audioEngine) return;

    NSError* error = nil;
    AVAudioSession* session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeMoviePlayback
                      options:AVAudioSessionCategoryOptionMixWithOthers
                        error:&error])
        overlay::AddLog("audio category failed: %s", [[error localizedDescription] UTF8String]);

    error = nil;
    if (![session setActive:YES error:&error])
        overlay::AddLog("audio activate failed: %s", [[error localizedDescription] UTF8String]);

    AVAudioEngine* engine = [[AVAudioEngine alloc] init];
    AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:2];
    AVAudioPlayerNode* node = [[AVAudioPlayerNode alloc] init];

    [engine attachNode:node];
    [engine connect:node to:engine.mainMixerNode format:format];
    [engine prepare];

    error = nil;
    if (![engine startAndReturnError:&error])
    {
        overlay::AddLog("silent audio failed: %s", [[error localizedDescription] UTF8String]);
        return;
    }

    const UInt32 frames = (UInt32)format.sampleRate;
    AVAudioPCMBuffer* buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                            frameCapacity:frames];
    buffer.frameLength = frames;
    for (AVAudioChannelCount ch = 0; ch < format.channelCount; ++ch)
        memset(buffer.floatChannelData[ch], 0, sizeof(float) * frames);

    [node scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [node play];

    self.audioEngine = engine;
    self.audioNode   = node;

    if (self.backgroundTask == UIBackgroundTaskInvalid)
    {
        __weak __typeof(self) weakSelf = self;
        self.backgroundTask = [[UIApplication sharedApplication]
            beginBackgroundTaskWithName:@"hud-frames" expirationHandler:^{
                __strong __typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [[UIApplication sharedApplication] endBackgroundTask:strongSelf.backgroundTask];
                strongSelf.backgroundTask = UIBackgroundTaskInvalid;
            }];
    }
}

- (void)stopSilentAudio
{
    if (self.backgroundTask != UIBackgroundTaskInvalid)
    {
        [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
    [self.audioNode stop];
    [self.audioEngine stop];
    self.audioNode   = nil;
    self.audioEngine = nil;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:NULL];
}

// ---------------------------------------------------------------- HUD text

- (void)startTimer
{
    if (self.timer) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    uint64_t interval = (uint64_t)(1.0 / kHudFps * (double)NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, interval / 4);

    __weak __typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{ [weakSelf updateHud]; });

    self.timer = timer;
    dispatch_resume(timer);
}

- (void)stopTimer
{
    if (!self.timer) return;
    dispatch_source_cancel(self.timer);
    self.timer = nil;
}

- (void)updateHud
{
    if (!self.running) return;

    CFTimeInterval now = CACurrentMediaTime();
    float dt = (float)(now - self.lastTick);
    self.lastTick = now;
    if (dt > 0.0001f && dt < 1.0f)
        self.fps = self.fps * 0.9f + (1.0f / dt) * 0.1f;

    NSString* text = [NSString stringWithFormat:@"Hud  |  fps : %.1f  |  ping : ?", self.fps];
    self.contentVC.hudLabel.text = text;   // nil until the PiP view appears - fine
    self.inlineLabel.text = text;
}

// ---------------------------------------------------------------- delegates

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController*)controller
{
    overlay::AddLog("HUD: starting");
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController*)controller
{
    self.running = YES;
    [self startTimer];
    [self postState:YES];
    overlay::AddLog("HUD: ACTIVE - floats above every app");
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController*)controller
{
    overlay::AddLog("HUD: stopping");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController*)controller
{
    [self stopTimer];
    [self stopObserving];
    [self stopSilentAudio];
    self.pipController  = nil;
    self.contentSource  = nil;
    self.contentVC      = nil;
    self.running        = NO;
    self.startRequested = NO;
    [self postState:NO];
    overlay::AddLog("HUD: stopped by system");
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler
{
    completionHandler(YES);
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
       failedToStartPictureInPictureWithError:(NSError*)error
{
    [self stopTimer];
    [self stopObserving];
    [self stopSilentAudio];
    self.pipController  = nil;
    self.contentSource  = nil;
    self.contentVC      = nil;
    self.running        = NO;
    self.startRequested = NO;
    [self postState:NO];
    overlay::AddLog("HUD FAILED (%ld): %s",
                    (long)error.code, [[error localizedDescription] UTF8String]);
}

@end
