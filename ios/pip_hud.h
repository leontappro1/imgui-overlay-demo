// Floating iOS overlay (Picture in Picture).
//
// iOS has no API that lets a third-party app draw on top of another app.
// The one thing the system DOES draw above everything else is a
// picture-in-picture window. So we render our ImGui UI into an offscreen
// CVPixelBuffer, push it through an AVSampleBufferDisplayLayer and let the
// system float that layer above every other application.
//
// The frames are ours - no screen capture, no other app is touched.

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class UIView;

NS_ASSUME_NONNULL_BEGIN

@interface PipHudController : NSObject

+ (instancetype)sharedController;

- (void)configureWithDevice:(id<MTLDevice>)device
                     queue:(id<MTLCommandQueue>)queue;

/// iOS refuses to start PiP unless the sample buffer display layer is part of
/// a visible view hierarchy with a non-zero frame. Call this from
/// viewDidAppear (and again from viewDidLayoutSubviews after a rotation).
- (void)attachToView:(UIView*)hostView;

- (BOOL)isRunning;
- (BOOL)isPictureInPictureActive;
- (BOOL)isPictureInPicturePossible;

/// Called on the main queue when PiP actually starts, stops or fails. The
/// button in main.mm must follow this, NOT the return value of start:.
@property (nonatomic, copy, nullable) void (^stateChanged)(BOOL active);

/// Starts the picture-in-picture window. Returns NO and fills @p error on an
/// immediate setup failure; a successful start is asynchronous and reported
/// through stateChanged / the delegate callbacks.
- (BOOL)start:(NSError* _Nullable * _Nullable)error;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
