// Floating iOS overlay (Picture in Picture) - implementation.
//
// Pipeline per frame:
//   ImGui -> Metal render pass -> CVPixelBuffer -> CMSampleBuffer
//        -> AVSampleBufferDisplayLayer -> AVPictureInPictureController
//
// The picture-in-picture window is drawn by iOS above every other app,
// which is the only sanctioned way to get an overlay on a stock iPhone.

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
    // Square canvas: the PiP window keeps the aspect ratio of the video it
    // shows, and a square panel lets the ImGui menu fill it nicely.
    const int    kPipWidth   = 900;
    const int    kPipHeight  = 900;
    const double kPipFps     = 30.0;

    static bool  s_pipOpaque = true;
    static bool  s_pipPaused = false;

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
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) AVAudioEngine* audioEngine;
@property (nonatomic, strong) AVAudioPlayerNode* audioNode;
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

- (void)dealloc
{
    [self stopTimer];
    [self stopSilentAudio];
    if (_textureCache)  CFRelease(_textureCache);
    if (_pixelPool)    CFRelease(_pixelPool);
    if (_timebase)     CFRelease(_timebase);
}

// ---------------------------------------------------------------- setup

- (void)configureWithDevice:(id<MTLDevice>)device queue:(id<MTLCommandQueue>)queue
{
    self.device = device;
    self.queue = queue;

    if (!self.textureCache)
    {
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_textureCache);
    }
    [self ensurePixelPool];
    [self ensureGuiContext];
}

- (void)ensurePixelPool
{
    if (self.pixelPool) return;

    NSDictionary* attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey            : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey                      : @(kPipWidth),
        (id)kCVPixelBufferHeightKey                     : @(kPipHeight),
        (id)kCVPixelBufferIOSurfacePropertiesKey        : @{},
        (id)kCVPixelBufferMetalCompatibilityKey         : @YES,
        (id)kCVPixelBufferCGImageCompatibilityKey       : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
    };
    NSDictionary* poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey : @(3),
    };

    CVPixelBufferPoolCreate(kCFAllocatorDefault,
                            (__bridge CFDictionaryRef)poolAttrs,
                            (__bridge CFDictionaryRef)attrs,
                            NULL,
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
    io.DisplaySize               = ImVec2((float)kPipWidth, (float)kPipHeight);
    io.DisplayFramebufferScale   = ImVec2(1.0f, 1.0f);
    ImGui::StyleColorsDark();
    ImGuiStyle& style = ImGui::GetStyle();
    style.FontSizeBase = 24.0f;          // the PiP window is small on screen
    style.ScaleAllSizes(1.2f);

    ImGui_ImplMetal_Init(self.device);

    self.guiContext = ImGui::GetCurrentContext();
    self.guiReady   = YES;

    ImGui::SetCurrentContext(previous);
}

// ---------------------------------------------------------------- control

- (BOOL)isRunning { return self.running; }

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

    [self ensureGuiContext];

    if (!self.displayLayer)
    {
        self.displayLayer = [AVSampleBufferDisplayLayer layer];
        self.displayLayer.videoGravity   = AVLayerVideoGravityResizeAspect;
        self.displayLayer.backgroundColor = [UIColor blackColor].CGColor;
    }

    // The sample buffer display layer needs a timebase to pace the frames.
    if (!self.timebase)
    {
        CMTimebaseCreateWithMasterClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &_timebase);
        CMTimebaseSetTime(self.timebase, kCMTimeZero);
        CMTimebaseSetRate(self.timebase, 1.0, 0);
        self.displayLayer.controlTimebase = self.timebase;
    }

    AVPictureInPictureControllerContentSource* source =
        [[AVPictureInPictureControllerContentSource alloc]
            initWithSampleBufferDisplayLayer:self.displayLayer
                             playbackDelegate:self];

    self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:source];
    self.pipController.delegate = self;

    self.firstPTS      = kCMTimeInvalid;
    self.lastPTS       = kCMTimeInvalid;
    self.lastFrameTime = CACurrentMediaTime();
    self.running       = YES;

    // Keep the app alive while it is in the background with PiP on screen.
    [self startSilentAudio];

    // PiP refuses to start if no frame was ever queued, so push one first.
    [self renderFrame];
    [self startTimer];

    [self.pipController startPictureInPicture];

    overlay::AddLog("PiP: requested");
    return YES;
}

- (void)stop
{
    [self stopTimer];
    [self stopSilentAudio];
    [self.pipController stopPictureInPicture];
    self.pipController = nil;
    self.running = NO;
    overlay::AddLog("PiP: stopped");
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
    [session setCategory:AVAudioSessionCategoryPlayback
                     mode:AVAudioSessionModeMoviePlayback
                  options:AVAudioSessionCategoryOptionMixWithOthers
                    error:&error];
    [session setActive:YES error:&error];

    AVAudioEngine* engine = [[AVAudioEngine alloc] init];
    AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:1];
    AVAudioPlayerNode* node = [[AVAudioPlayerNode alloc] init];

    [engine attachNode:node];
    [engine connect:node to:engine.mainMixerNode format:format];
    [engine prepare];

    if (![engine startAndReturnError:&error])
    {
        overlay::AddLog("silent audio failed: %s", [[error localizedDescription] UTF8String]);
        return;
    }

    AVAudioPCMBuffer* buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                            frameCapacity:44100];
    buffer.frameLength = 44100;
    memset(buffer.floatChannelData[0], 0, sizeof(float) * 44100);
    [node scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [node play];

    self.audioEngine = engine;
    self.audioNode   = node;
}

- (void)stopSilentAudio
{
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
    if (CVMetalTextureCacheCreateTexture(kCFAllocatorDefault, self.textureCache, pixelBuffer, NULL,
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
        timing.duration                = CMTimeMake(1, (int32_t)kPipFps);
        timing.presentationTimeStamp   = pts;
        timing.decodeTimeStamp         = kCMTimeInvalid;

        CMSampleBufferRef sampleBuffer = NULL;
        if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true,
                                                formatDescription, &timing,
                                                &sampleBuffer) == noErr)
        {
            if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed)
                [self.displayLayer flush];

            [self.displayLayer enqueueSampleBuffer:sampleBuffer];
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
    overlay::AddLog("PiP: running - it now floats above every app");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController*)controller
{
    [self stopTimer];
    self.running = NO;
    overlay::AddLog("PiP: stopped");
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
       failedToStartPictureInPictureWithError:(NSError*)error
{
    [self stopTimer];
    self.running = NO;
    overlay::AddLog("PiP failed: %s", [[error localizedDescription] UTF8String]);
}

// AVPictureInPictureSampleBufferPlaybackDelegate

- (void)pictureInPictureController:(AVPictureInPictureController*)controller setPlaying:(BOOL)playing
{
    if (playing) [self startTimer];
}

- (CMTimeRange)pictureInPictureController:(AVPictureInPictureController*)controller
                     timeRangeForPlayback:(CMTimeRange)timeRange
{
    if (CMTIME_IS_INVALID(self.firstPTS)) return CMTimeRangeMake(kCMTimeZero, kCMTimeZero);

    CMTime duration = CMTimeSubtract(self.lastPTS, self.firstPTS);
    if (CMTIME_IS_INVALID(duration) || CMTimeCompare(duration, kCMTimeZero) < 0)
        duration = kCMTimeZero;

    return CMTimeRangeMake(self.firstPTS, duration);
}

@end
