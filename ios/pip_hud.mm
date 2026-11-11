// Floating iOS overlay (Picture in Picture) - implementation.
//
// Pipeline per frame:
//   ImGui -> Metal render pass -> CVPixelBuffer -> CMSampleBuffer
//        -> AVSampleBufferDisplayLayer -> AVPictureInPictureController
//
// The picture-in-picture window is drawn by iOS above every other app,
// which is the only sanctioned way to get an overlay on a stock iPhone.
//
// Requirements that are easy to miss (all handled below):
//   1. The AVSampleBufferDisplayLayer MUST be a sublayer of a view that is
//      actually on screen, with a non-zero frame. A detached layer makes
//      startPictureInPicture a silent no-op.
//   2. The AVAudioSession (.playback) must be active BEFORE the PiP
//      controller is created, otherwise pictureInPicturePossible stays NO.
//   3. At least one frame must have been enqueued before the controller is
//      created - the content source has to be "ready for display".
//   4. The live time range must be [-inf, +inf], otherwise PiP shows an
//      endless loading spinner instead of the frames.

#import "pip_hud.h"

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "ui.h"

namespace
{
    // Square canvas: the PiP window keeps the aspect ratio of the content it
    // shows, and a square panel lets the ImGui menu fill it nicely.
    const int    kPipWidth  = 900;
    const int    kPipHeight = 900;
    const double kPipFps    = 30.0;

    static bool s_pipOpaque = true;
    static bool s_pipPaused = false;
    static char kPipPossibleContext;

    static void PipOnToggle(void*) {}

    overlay::PlatformHooks MakePipHooks()
    {
        overlay::PlatformHooks h = {};
        h.platform_line = "iOS / PiP floating window / Metal";
        h.hotkeys_line  = "the PiP window is display only - control it in the app";
        h.backend_name  = "AVSampleBufferDisplayLayer + imgui_impl_metal";
        h.compiler_name = "Apple Clang (Xcode)";
        h.window_note   = "This is a real picture-in-picture window: iOS draws "
                          "it above every other application. The frames are "
                          "rendered by Dear ImGui into a CVPixelBuffer and "
                          "pushed through the sample buffer display layer.";
        h.toggles[0] = { "opaque background", &s_pipOpaque };
        h.toggles[1] = { "paused", &s_pipPaused };
        h.toggle_count = 2;
        h.on_toggle = PipOnToggle;
        return h;
    }
}

@interface PipHudController () <AVPictureInPictureControllerDelegate,
                                AVPictureInPictureSampleBufferPlaybackDelegate>
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) AVSampleBufferDisplayLayer* displayLayer;
@property (nonatomic, strong) AVPictureInPictureController* pipController;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign) CVPixelBufferPoolRef pixelPool;
@property (nonatomic, assign) CMTimebaseRef timebase;
@property (nonatomic, assign) ImGuiContext* guiContext;
@property (nonatomic, assign) BOOL guiReady;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL startRequested;
@property (nonatomic, assign) BOOL observing;
@property (nonatomic, assign) BOOL firstFrameLogged;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) AVAudioEngine* audioEngine;
@property (nonatomic, strong) AVAudioPlayerNode* audioNode;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, assign) CMTime firstPTS;
@property (nonatomic, assign) CMTime lastPTS;
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
    if (_textureCache) CFRelease(_textureCache);
    if (_pixelPool)    CFRelease(_pixelPool);
    if (_timebase)     CFRelease(_timebase);
}

// ---------------------------------------------------------------- setup

- (void)configureWithDevice:(id<MTLDevice>)device queue:(id<MTLCommandQueue>)queue
{
    self.device = device;
    self.queue  = queue;

    if (!self.textureCache)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_textureCache);

    [self ensureDisplayLayer];
    [self ensureTimebase];
    [self ensurePixelPool];
    [self ensureGuiContext];
}

- (void)ensureDisplayLayer
{
    if (self.displayLayer) return;

    AVSampleBufferDisplayLayer* layer = [AVSampleBufferDisplayLayer layer];
    layer.videoGravity    = AVLayerVideoGravityResizeAspect;
    layer.backgroundColor = [UIColor blackColor].CGColor;
    layer.opaque          = YES;
    self.displayLayer = layer;
}

- (void)ensureTimebase
{
    if (self.timebase) return;
    [self ensureDisplayLayer];
    CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &_timebase);
    CMTimebaseSetTime(self.timebase, kCMTimeZero);
    CMTimebaseSetRate(self.timebase, 1.0);
    self.displayLayer.controlTimebase = self.timebase;
}

- (void)ensurePixelPool
{
    if (self.pixelPool) return;

    NSDictionary* attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey              : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey                        : @(kPipWidth),
        (id)kCVPixelBufferHeightKey                       : @(kPipHeight),
        (id)kCVPixelBufferIOSurfacePropertiesKey          : @{},
        (id)kCVPixelBufferMetalCompatibilityKey           : @YES,
        (id)kCVPixelBufferCGImageCompatibilityKey         : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
    };
    NSDictionary* poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey : @(3),
    };

    // CVPixelBufferPoolCreate(allocator, poolAttributes, pixelBufferAttributes, poolOut)
    CVPixelBufferPoolCreate(kCFAllocatorDefault,
                            (__bridge CFDictionaryRef)poolAttrs,
                            (__bridge CFDictionaryRef)attrs,
                            &_pixelPool);
}

// The PiP window has its own ImGui context, so the menu inside it never
// fights with the full screen menu of the app.
- (void)ensureGuiContext
{
    if (self.guiReady) return;

    ImGuiContext* previous = ImGui::GetCurrentContext();

    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename              = nullptr;
    io.DisplaySize              = ImVec2((float)kPipWidth, (float)kPipHeight);
    io.DisplayFramebufferScale  = ImVec2(1.0f, 1.0f);
    ImGui::StyleColorsDark();
    ImGuiStyle& style = ImGui::GetStyle();
    style.FontSizeBase = 24.0f;          // the PiP window is small on screen
    style.ScaleAllSizes(1.2f);

    ImGui_ImplMetal_Init(self.device);

    self.guiContext = ImGui::GetCurrentContext();
    self.guiReady   = YES;

    ImGui::SetCurrentContext(previous);
}

// ---------------------------------------------------------------- host view
// iOS only starts PiP for a layer that lives in the on-screen view hierarchy.
// The little square in main.mm doubles as a local preview of the HUD frames.

- (void)attachToView:(UIView*)hostView
{
    if (!hostView) return;
    [self ensureDisplayLayer];
    [self ensureTimebase];

    BOOL wasAttached = (self.displayLayer.superlayer != nil);
    if (self.displayLayer.superlayer != hostView.layer)
    {
        [self.displayLayer removeFromSuperlayer];
        [hostView.layer addSublayer:self.displayLayer];
    }
    self.displayLayer.frame = hostView.bounds;

    if (!wasAttached)
        overlay::AddLog("PiP: source view %.0fx%.0f attached",
                        hostView.bounds.size.width, hostView.bounds.size.height);
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

    if (![AVPictureInPictureController isPictureInPictureSupported])
    {
        if (error)
            *error = [NSError errorWithDomain:@"PipHud" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"Picture in Picture is not supported on this device" }];
        return NO;
    }

    if (!self.device || !self.queue)
    {
        if (error)
            *error = [NSError errorWithDomain:@"PipHud" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"Metal device was not configured" }];
        return NO;
    }

    // Failure #1 in the field: a detached display layer. Fail loudly instead
    // of pretending PiP started.
    if (!self.displayLayer || !self.displayLayer.superlayer ||
        CGRectIsEmpty(self.displayLayer.frame))
    {
        if (error)
            *error = [NSError errorWithDomain:@"PipHud" code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"PiP display layer is not attached to a visible view" }];
        overlay::AddLog("PiP: ERROR - display layer not on screen");
        return NO;
    }

    [self ensureGuiContext];
    [self ensureTimebase];

    // Failure #2: the audio session has to be active BEFORE the controller is
    // created, or isPictureInPicturePossible stays NO and start is a no-op.
    [self startSilentAudio];

    self.firstPTS         = kCMTimeInvalid;
    self.lastPTS          = kCMTimeInvalid;
    self.lastFrameTime    = CACurrentMediaTime();
    self.startRequested   = NO;
    self.firstFrameLogged = NO;
    self.running          = YES;

    // Failure #3: the content source must already have a frame. The renderer
    // waits for the GPU before enqueueing, so this is a real picture.
    [self renderFrame];

    AVPictureInPictureControllerContentSource* source =
        [[AVPictureInPictureControllerContentSource alloc]
            initWithSampleBufferDisplayLayer:self.displayLayer
                             playbackDelegate:self];

    AVPictureInPictureController* controller =
        [[AVPictureInPictureController alloc] initWithContentSource:source];
    if (!controller)
    {
        if (error)
            *error = [NSError errorWithDomain:@"PipHud" code:4 userInfo:@{
                NSLocalizedDescriptionKey: @"AVPictureInPictureController refused to initialise" }];
        overlay::AddLog("PiP: ERROR - controller init returned nil");
        self.running = NO;
        [self stopSilentAudio];
        return NO;
    }

    self.pipController = controller;
    controller.delegate = self;
    controller.canStartPictureInPictureAutomaticallyFromInline = YES;
    controller.requiresLinearPlayback = NO;

    [self startObserving];
    [self startTimer];

    overlay::AddLog("PiP: possible=%d active=%d layer=%ld audio=%d",
                    controller.isPictureInPicturePossible,
                    controller.isPictureInPictureActive,
                    (long)self.displayLayer.status,
                    self.audioEngine.isRunning);

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
    self.pipController = nil;
    self.running       = NO;
    self.startRequested = NO;
    [self postState:NO];
    overlay::AddLog("PiP: stopped by app");
}

// startPictureInPicture is a silent no-op when isPictureInPicturePossible is
// NO. Retry when the flag flips, on a few timers, and on the way to background.

- (void)requestStartPictureInPicture
{
    if (!self.running || !self.pipController) return;
    if (self.pipController.isPictureInPictureActive) return;

    if (!self.pipController.isPictureInPicturePossible)
    {
        overlay::AddLog("PiP: not possible yet (layer=%ld audio=%d)",
                        (long)self.displayLayer.status, self.audioEngine.isRunning);
        return;
    }

    if (!self.startRequested)
    {
        self.startRequested = YES;
        overlay::AddLog("PiP: requested");
    }
    [self.pipController startPictureInPicture];
}

- (void)scheduleStartRetries
{
    const double delays[] = { 0.2, 0.6, 1.5, 3.0 };
    for (double delay : delays)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * (double)NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self requestStartPictureInPicture];
        });
    }
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
    [nc addObserver:self selector:@selector(appDidBecomeActive:)
                name:UIApplicationDidBecomeActiveNotification object:nil];
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
        BOOL possible = [change[NSKeyValueChangeNewKey] boolValue];
        overlay::AddLog("PiP: possible=%d", possible);
        if (possible) [self requestStartPictureInPicture];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)appWillResignActive:(NSNotification*)note
{
    if (!self.running) return;
    overlay::AddLog("PiP: leaving foreground - kicking start");
    [self requestStartPictureInPicture];
}

- (void)appDidEnterBackground:(NSNotification*)note
{
    if (!self.running) return;
    overlay::AddLog("PiP: bg audio=%d timer=%d layer=%ld",
                    self.audioEngine.isRunning, self.timer != nil,
                    (long)self.displayLayer.status);
    [self requestStartPictureInPicture];
}

- (void)appDidBecomeActive:(NSNotification*)note
{
    if (!self.running) return;
    // AVSampleBufferDisplayLayer often comes back from background in the
    // "failed" state. Flush and push a fresh frame so the window recovers.
    if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed)
        [self.displayLayer flush];
    [self renderFrame];
}

// ---------------------------------------------------------------- keep alive
// iOS suspends apps that have nothing to do in the background. A silent audio
// session plus the "audio" background mode keeps the frame timer running while
// the PiP window floats above another app.

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

    // Stereo float matches the mixer's format, so connect:to:format: cannot
    // throw an incompatible-format exception.
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

    const UInt32 frames = (UInt32)format.sampleRate;   // one second of silence
    AVAudioPCMBuffer* buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                            frameCapacity:frames];
    buffer.frameLength = frames;
    for (AVAudioChannelCount ch = 0; ch < format.channelCount; ++ch)
        memset(buffer.floatChannelData[ch], 0, sizeof(float) * frames);

    [node scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [node play];

    self.audioEngine = engine;
    self.audioNode   = node;
    overlay::AddLog("audio keepalive: on (%s)", [session.category UTF8String]);

    // Extra insurance for the first seconds after the app leaves foreground.
    if (self.backgroundTask == UIBackgroundTaskInvalid)
    {
        __weak __typeof(self) weakSelf = self;
        self.backgroundTask = [[UIApplication sharedApplication]
            beginBackgroundTaskWithName:@"pip-frames" expirationHandler:^{
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

// ---------------------------------------------------------------- render loop

- (void)startTimer
{
    if (self.timer) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    uint64_t interval = (uint64_t)(1.0 / kPipFps * (double)NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, interval / 4);

    __weak __typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{ [weakSelf renderFrame]; });

    self.timer = timer;
    dispatch_resume(timer);
}

- (void)stopTimer
{
    if (!self.timer) return;
    dispatch_source_cancel(self.timer);
    self.timer = nil;
}

- (CVPixelBufferRef)nextPixelBuffer
{
    if (!self.pixelPool) return NULL;

    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pixelPool, &buffer) != kCVReturnSuccess)
        return NULL;
    return buffer;
}

- (void)renderFrame
{
    if (!self.running) return;

    CVPixelBufferRef pixelBuffer = [self nextPixelBuffer];
    if (!pixelBuffer) return;

    size_t width  = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);

    CVMetalTextureRef metalTexture = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, self.textureCache, pixelBuffer, NULL,
                                                  MTLPixelFormatBGRA8Unorm, width, height, 0,
                                                  &metalTexture) != kCVReturnSuccess)
    {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }
    id<MTLTexture> texture = CVMetalTextureGetTexture(metalTexture);

    id<MTLCommandBuffer> commandBuffer = [self.queue commandBuffer];

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture      = texture;
    rpd.colorAttachments[0].loadAction   = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction  = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor   = s_pipOpaque
        ? MTLClearColorMake(0.04f, 0.05f, 0.07f, 1.0f)
        : MTLClearColorMake(0.0f, 0.0f, 0.0f, 0.0f);

    CFTimeInterval now = CACurrentMediaTime();
    float dt = (float)(now - self.lastFrameTime);
    self.lastFrameTime = now;
    if (dt < 0.0f)  dt = 0.0f;
    if (dt > 0.25f) dt = 0.25f;

    ImGuiContext* previous = ImGui::GetCurrentContext();
    ImGui::SetCurrentContext(self.guiContext);

    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize             = ImVec2((float)width, (float)height);
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();

    overlay::DrawUI(MakePipHooks(), s_pipPaused ? 0.0f : dt);

    ImGui::Render();
    ImDrawData* drawData = ImGui::GetDrawData();

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [encoder pushDebugGroup:@"Dear ImGui PiP frame"];
    ImGui_ImplMetal_RenderDrawData(drawData, commandBuffer, encoder);
    [encoder popDebugGroup];
    [encoder endEncoding];

    ImGui::SetCurrentContext(previous);

    [commandBuffer commit];
    // The CVPixelBuffer is shared with the GPU. Without this wait the display
    // layer can read it before Metal finished drawing (blank/garbage frame).
    [commandBuffer waitUntilCompleted];

    // --- push the rendered frame into the display layer ---
    CMTime pts = self.timebase ? CMTimebaseGetTime(self.timebase)
                                : CMClockGetTime(CMClockGetHostTimeClock());
    if (CMTIME_IS_INVALID(self.firstPTS)) self.firstPTS = pts;
    self.lastPTS = pts;

    CMVideoFormatDescriptionRef formatDescription = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                     &formatDescription) == noErr)
    {
        CMSampleTimingInfo timing;
        timing.duration              = kCMTimeInvalid;   // live stream
        timing.presentationTimeStamp = pts;
        timing.decodeTimeStamp       = kCMTimeInvalid;

        CMSampleBufferRef sampleBuffer = NULL;
        // CMSampleBufferCreateForImageBuffer(allocator, imageBuffer, dataReady,
        //                                      makeDataReadyCallback, makeDataReadyRefcon,
        //                                      formatDescription, sampleTiming, sampleBufferOut)
        if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true,
                                                NULL, NULL,
                                                formatDescription, &timing,
                                                &sampleBuffer) == noErr)
        {
            if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed)
            {
                [self.displayLayer flush];
                overlay::AddLog("PiP: display layer flushed after failure");
            }

            [self.displayLayer enqueueSampleBuffer:sampleBuffer];
            if (!self.firstFrameLogged)
            {
                self.firstFrameLogged = YES;
                overlay::AddLog("PiP: first frame queued (%zux%zu)", width, height);
            }
            CFRelease(sampleBuffer);
        }
        CFRelease(formatDescription);
    }

    CFRelease(metalTexture);
    CVPixelBufferRelease(pixelBuffer);
}

// ---------------------------------------------------------------- delegates

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController*)controller
{
    overlay::AddLog("PiP: starting");
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController*)controller
{
    self.running = YES;
    [self startTimer];
    [self postState:YES];
    overlay::AddLog("PiP: ACTIVE - floats above every app");
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController*)controller
{
    overlay::AddLog("PiP: stopping");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController*)controller
{
    [self stopTimer];
    [self stopObserving];
    [self stopSilentAudio];
    self.running        = NO;
    self.startRequested = NO;
    [self postState:NO];
    overlay::AddLog("PiP: stopped by system");
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
    self.running        = NO;
    self.startRequested = NO;
    [self postState:NO];
    overlay::AddLog("PiP FAILED (%ld): %s",
                    (long)error.code, [[error localizedDescription] UTF8String]);
}

// AVPictureInPictureSampleBufferPlaybackDelegate
// (AVKit/AVPictureInPictureController_AVSampleBufferDisplayLayerSupport.h)

- (void)pictureInPictureController:(AVPictureInPictureController*)pictureInPictureController setPlaying:(BOOL)playing
{
    s_pipPaused = !playing;
    if (playing) [self startTimer];
    overlay::AddLog("PiP: setPlaying %d", playing);
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController*)pictureInPictureController
{
    // Live content. Returning [0, +inf) makes the system cover the window
    // with a permanent loading spinner; live content is [-inf, +inf].
    return CMTimeRangeMake(kCMTimeNegativeInfinity, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController*)pictureInPictureController
{
    return s_pipPaused;
}

- (void)pictureInPictureController:(AVPictureInPictureController*)pictureInPictureController
          didTransitionToRenderSize:(CMVideoDimensions)newRenderSize
{
    overlay::AddLog("PiP render size: %d x %d", newRenderSize.width, newRenderSize.height);
}

- (void)pictureInPictureController:(AVPictureInPictureController*)pictureInPictureController
                   skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler
{
    // There is nothing to skip in a live overlay, but the handler MUST be called
    // or the system keeps the playback UI stuck in a "seeking" state.
    completionHandler();
}

@end
