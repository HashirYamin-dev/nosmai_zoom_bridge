#import <Foundation/Foundation.h>
#import <ZoomVideoSDK/ZoomVideoSDK.h>

NS_ASSUME_NONNULL_BEGIN

/// Zoom external video source fed by Nosmai's processed camera frames. Nosmai owns the
/// camera; Zoom never opens it.
///
/// Nosmai hands over a CVPixelBuffer per processed frame (BGRA or NV12). Each admitted frame is
/// scaled to Zoom's suggested size, turned to landscape if it is portrait (Zoom centre-crops
/// portrait frames, so they go out rotated plus a rotation flag, as on Android), converted to
/// I420 (BT.601 limited range) with Accelerate and handed to Zoom. At most one frame is in
/// flight; a busy converter drops the newest frame instead of queueing.
///
/// Frames are only taken from Nosmai between Zoom's onStartSend and onStopSend.
@interface NosmaiZoomVideoSource : NSObject <ZoomVideoSDKVideoSource>

/// Called on the main queue whenever Zoom starts or stops asking for frames.
@property(nonatomic, copy, nullable) void (^onSendingChanged)(BOOL sending);

- (void)configureWithFps:(NSInteger)fps
             maxLongSide:(NSInteger)longSide
     adaptToThermalState:(BOOL)adapt;
- (void)setMaxFps:(NSInteger)fps;
- (void)resetCounters;

/// Detaches from Nosmai and drains the in-flight frame. Safe to call repeatedly.
- (void)shutdown;

/// Pipeline counters for the Dart stats overlay; call about once per second.
- (NSDictionary<NSString *, id> *)stats;

@end

NS_ASSUME_NONNULL_END
