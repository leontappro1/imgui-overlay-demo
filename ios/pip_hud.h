// System-level floating HUD on iOS (iOS 15+).
//
// iOS has no API that lets a third-party app draw on top of another app.
// The one thing the system DOES draw above everything else is a
// picture-in-picture window. We use the video-call flavour of PiP
// (AVPictureInPictureVideoCallViewController), which hosts a plain UIView
// instead of a video player - so there are no player controls, no scrubber
// and no "LIVE" badge.
//
// The HUD is ours - no screen capture, no other app is touched.

#pragma once

#import <Foundation/Foundation.h>

@class UIView;

NS_ASSUME_NONNULL_BEGIN

@interface PipHudController : NSObject

+ (instancetype)sharedController;

/// The video-call PiP API requires a real, visible view in the app. Call this
/// from viewDidAppear / viewDidLayoutSubviews; the HUD strip is added to it.
- (void)attachSourceView:(UIView*)view;

- (BOOL)isRunning;
- (BOOL)isPictureInPictureActive;
- (BOOL)isPictureInPicturePossible;

/// Called on the main queue when PiP actually starts, stops or fails. The
/// button in main.mm must follow this, NOT the return value of start:.
@property (nonatomic, copy, nullable) void (^stateChanged)(BOOL active);

/// Starts the floating HUD. Returns NO on an immediate setup failure; a
/// successful start is asynchronous and reported through stateChanged.
- (BOOL)start:(NSError* _Nullable * _Nullable)error;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
