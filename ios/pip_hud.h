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

NS_ASSUME_NONNULL_BEGIN

@interface PipHudController : NSObject

+ (instancetype)sharedController;

- (void)configureWithDevice:(id<MTLDevice>)device
                     queue:(id<MTLCommandQueue>)queue;

- (BOOL)isRunning;

/// Starts the picture-in-picture window. Returns NO and fills @p error on failure.
- (BOOL)start:(NSError* _Nullable * _Nullable)error;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
