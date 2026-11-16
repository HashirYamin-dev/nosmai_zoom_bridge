#import "NosmaiZoomVideoSource.h"

#import <Accelerate/Accelerate.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <ZoomVideoSDK/ZoomVideoSDKVideoSender.h>
#import <nosmai_effects_sdk/NosmaiFlutterPlugin.h>

static const CFTimeInterval kResyncAfter = 0.2;
/// Targets at or above this rate send every Nosmai frame (the camera's own rate) unpaced.
static const NSInteger kNoPacingFps = 30;
#define kRingSize 3

/// Tells Zoom how to turn a landscape frame made by rotating a portrait image 90°
/// counter-clockwise back upright. Same convention as the Android plugin
/// (ROTATION_ACTION_90 with a counter-clockwise rotated frame).
static const ZoomVideoSDKVideoRawDataRotation kPortraitRotation = ZoomVideoSDKVideoRawDataRotation90;

/// A reusable, growable byte buffer; touched only on the convert queue.
typedef struct {
  uint8_t *data;
  size_t capacity;
} Scratch;

static uint8_t *ScratchTake(Scratch *scratch, size_t bytes) {
  if (scratch->capacity < bytes) {
    free(scratch->data);
    scratch->data = malloc(bytes);
    scratch->capacity = scratch->data ? bytes : 0;
  }
  return scratch->data;
}

static void ScratchFree(Scratch *scratch) {
  free(scratch->data);
  scratch->data = NULL;
  scratch->capacity = 0;
}

static size_t EvenSize(double value) {
  size_t rounded = (size_t)llround(value);
  rounded &= ~(size_t)1;
  return rounded < 2 ? 2 : rounded;
}

@implementation NosmaiZoomVideoSource {
  NSLock *_lock;
  dispatch_queue_t _convertQueue;
  dispatch_semaphore_t _inFlight;

  // Configuration (under _lock).
  NSInteger _maxFps;
  NSInteger _maxLongSide;
  BOOL _adaptToThermalState;

  // Zoom state (under _lock).
  ZoomVideoSDKVideoSender *_sender;
  BOOL _sending;
  NSString *_suggested;
  NSInteger _suggestedLongSide;

  // Pacing and counters (under _lock).
  CFTimeInterval _nextDeadline;
  uint64_t _framesIn;
  uint64_t _sent;
  uint64_t _dropped;
  uint64_t _paced;
  uint64_t _errors;
  double _convertMsTotal;
  double _convertMsMax;
  size_t _lastWidth;
  size_t _lastHeight;
  NSString *_lastError;

  // Rate bookkeeping for -stats (under _lock).
  CFTimeInterval _lastStatsAt;
  uint64_t _lastStatsIn;
  uint64_t _lastStatsSent;
  double _lastStatsConvertMs;

  // Convert queue only.
  Scratch _bgra;
  Scratch _scaled;
  Scratch _rotated;
  Scratch _ring[kRingSize];
  int _ringNext;
}

- (instancetype)init {
  if ((self = [super init])) {
    _lock = [[NSLock alloc] init];
    _convertQueue = dispatch_queue_create("com.nosmai.zoom_live.convert", DISPATCH_QUEUE_SERIAL);
    _inFlight = dispatch_semaphore_create(1);
    _maxFps = 24;
    _maxLongSide = 960;
    _adaptToThermalState = YES;
    _suggested = @"";
    _lastError = @"";
  }
  return self;
}

- (void)dealloc {
  [NosmaiFlutterPlugin clearLiveStreamFrameCallback];
  ScratchFree(&_bgra);
  ScratchFree(&_scaled);
  ScratchFree(&_rotated);
  for (int i = 0; i < kRingSize; i++) ScratchFree(&_ring[i]);
}

#pragma mark - Configuration

- (void)configureWithFps:(NSInteger)fps maxLongSide:(NSInteger)longSide adaptToThermalState:(BOOL)adapt {
  [_lock lock];
  _maxFps = MAX(1, MIN(60, fps));
  _maxLongSide = MAX(320, MIN(1920, longSide));
  _adaptToThermalState = adapt;
  [_lock unlock];
}

- (void)setMaxFps:(NSInteger)fps {
  [_lock lock];
  _maxFps = MAX(1, MIN(60, fps));
  [_lock unlock];
}

- (void)resetCounters {
  [_lock lock];
  _framesIn = _sent = _dropped = _paced = _errors = 0;
  _convertMsTotal = _convertMsMax = 0;
  _lastWidth = _lastHeight = 0;
  _lastError = @"";
  _nextDeadline = 0;
  _lastStatsAt = 0;
  _lastStatsIn = _lastStatsSent = 0;
  _lastStatsConvertMs = 0;
  [_lock unlock];
}

#pragma mark - ZoomVideoSDKVideoSource (called by Zoom)

- (void)onInitialize:(ZoomVideoSDKVideoSender *)rawDataSender
    supportCapabilityArray:(NSArray *)supportCapabilityArray
         suggestCapability:(ZoomVideoSDKVideoCapability *)suggestCapability {
  [_lock lock];
  _sender = rawDataSender;
  [_lock unlock];
  [self recordCapability:suggestCapability];
  NSLog(@"[NosmaiZoomLive] Zoom video source initialized; suggested %@", _suggested);
}

- (void)onPropertyChange:(NSArray *)supportCapabilityArray
       suggestCapability:(ZoomVideoSDKVideoCapability *)suggestCapability {
  [self recordCapability:suggestCapability];
  NSLog(@"[NosmaiZoomLive] Zoom video capability changed; suggested %@", _suggested);
}

- (void)onStartSend {
  [_lock lock];
  BOOL was = _sending;
  _sending = YES;
  _nextDeadline = 0;
  [_lock unlock];
  if (was) return;
  __weak NosmaiZoomVideoSource *weakSelf = self;
  [NosmaiFlutterPlugin setLiveStreamFrameCallback:^(CVPixelBufferRef pixelBuffer, double timestamp) {
    [weakSelf onFrame:pixelBuffer];
  }];
  [self notifySending:YES];
}

- (void)onStopSend {
  [_lock lock];
  BOOL was = _sending;
  _sending = NO;
  [_lock unlock];
  if (!was) return;
  [NosmaiFlutterPlugin clearLiveStreamFrameCallback];
  [self notifySending:NO];
}

- (void)onUninitialized {
  [self onStopSend];
  [_lock lock];
  _sender = nil;
  [_lock unlock];
}

- (void)shutdown {
  [_lock lock];
  _sending = NO;
  _sender = nil;
  [_lock unlock];
  // Remove the producer first, then drain the consumer.
  [NosmaiFlutterPlugin clearLiveStreamFrameCallback];
  dispatch_sync(_convertQueue, ^{});
}

- (void)notifySending:(BOOL)sending {
  void (^callback)(BOOL) = self.onSendingChanged;
  if (!callback) return;
  dispatch_async(dispatch_get_main_queue(), ^{ callback(sending); });
}

- (void)recordCapability:(ZoomVideoSDKVideoCapability *)capability {
  if (!capability) return;
  [_lock lock];
  _suggested = [NSString stringWithFormat:@"%dx%d@%d", capability.width, capability.height, capability.frame];
  _suggestedLongSide = MAX(capability.width, capability.height);
  [_lock unlock];
}

#pragma mark - Frames

/// Nosmai's processing thread, once per processed frame. Never blocks.
- (void)onFrame:(CVPixelBufferRef)pixelBuffer {
  if (pixelBuffer == NULL) return;
  CFTimeInterval now = CACurrentMediaTime();
  NSInteger fps = [self effectiveFps];
  [_lock lock];
  _framesIn++;
  if (!_sending || _sender == nil) {
    [_lock unlock];
    return;
  }
  // Even spacing at the target rate; a frame may arrive up to a quarter interval early.
  // At kNoPacingFps or more every frame passes: the camera runs at 30, so pacing at the
  // camera's own rate would only drop frames that arrive with a little jitter.
  CFTimeInterval interval = 1.0 / (double)fps;
  if (fps < kNoPacingFps && _nextDeadline > 0 && now + interval / 4 < _nextDeadline) {
    _paced++;
    [_lock unlock];
    return;
  }
  if (dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_NOW) != 0) {
    _dropped++;
    [_lock unlock];
    return;
  }
  _nextDeadline = (_nextDeadline == 0 || now - _nextDeadline > kResyncAfter) ? now + interval
                                                                             : _nextDeadline + interval;
  [_lock unlock];

  CVPixelBufferRetain(pixelBuffer);
  dispatch_async(_convertQueue, ^{
    [self convertAndSend:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);
    dispatch_semaphore_signal(self->_inFlight);
  });
}

/// Convert queue.
- (void)convertAndSend:(CVPixelBufferRef)pixelBuffer {
  [_lock lock];
  ZoomVideoSDKVideoSender *sender = _sending ? _sender : nil;
  NSInteger suggestedLong = _suggestedLongSide;
  NSInteger configuredLong = _maxLongSide;
  [_lock unlock];
  if (sender == nil) return;

  CFTimeInterval started = CACurrentMediaTime();
  size_t outWidth = 0, outHeight = 0;
  BOOL rotated = NO;
  NSString *problem = nil;

  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  uint8_t *i420 = [self i420From:pixelBuffer
                        longSide:(suggestedLong >= 320 ? suggestedLong : configuredLong)
                           width:&outWidth
                          height:&outHeight
                         rotated:&rotated
                         problem:&problem];
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  if (i420 == NULL) {
    [_lock lock];
    _dropped++;
    _errors++;
    _lastError = problem ?: @"Frame conversion failed";
    [_lock unlock];
    return;
  }
  double convertMs = (CACurrentMediaTime() - started) * 1000.0;
  size_t bytes = outWidth * outHeight * 3 / 2;
  [sender sendVideoFrame:(char *)i420
                   width:outWidth
                  height:outHeight
              dataLength:bytes
                rotation:(rotated ? kPortraitRotation : ZoomVideoSDKVideoRawDataRotationNone)];

  [_lock lock];
  _sent++;
  _convertMsTotal += convertMs;
  _convertMsMax = MAX(_convertMsMax, convertMs);
  _lastWidth = outWidth;
  _lastHeight = outHeight;
  [_lock unlock];
}

/// Returns a pooled I420 frame (landscape, even sizes) or NULL with *problem set.
- (uint8_t *)i420From:(CVPixelBufferRef)pixelBuffer
             longSide:(NSInteger)targetLong
                width:(size_t *)outWidth
               height:(size_t *)outHeight
              rotated:(BOOL *)outRotated
              problem:(NSString **)problem {
  size_t srcW = CVPixelBufferGetWidth(pixelBuffer);
  size_t srcH = CVPixelBufferGetHeight(pixelBuffer);
  if (srcW < 2 || srcH < 2) {
    *problem = @"Empty frame";
    return NULL;
  }

  // 1. A BGRA view of the frame.
  vImage_Buffer bgra;
  OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
  switch (type) {
    case kCVPixelFormatType_32BGRA:
      bgra = (vImage_Buffer){CVPixelBufferGetBaseAddress(pixelBuffer), srcH, srcW,
                             CVPixelBufferGetBytesPerRow(pixelBuffer)};
      break;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: {
      BOOL full = type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
      vImage_Buffer yp = {CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), srcH, srcW,
                          CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)};
      vImage_Buffer cbcr = {CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1), srcH / 2, srcW / 2,
                            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)};
      bgra = (vImage_Buffer){ScratchTake(&_bgra, srcW * srcH * 4), srcH, srcW, srcW * 4};
      if (bgra.data == NULL) {
        *problem = @"Out of memory";
        return NULL;
      }
      const uint8_t toBGRA[4] = {3, 2, 1, 0};
      vImage_Error error = vImageConvert_420Yp8_CbCr8ToARGB8888(
          &yp, &cbcr, &bgra, [NosmaiZoomVideoSource yuvToRgb:full], toBGRA, 255, kvImageNoFlags);
      if (error != kvImageNoError) {
        *problem = [NSString stringWithFormat:@"NV12 to BGRA failed (%ld)", (long)error];
        return NULL;
      }
      break;
    }
    default:
      *problem = [NSString stringWithFormat:@"Unsupported pixel format 0x%08X", (unsigned)type];
      return NULL;
  }

  // 2. Scale to Zoom's size. Zoom centre-crops frames that are not the size it asked for.
  BOOL portrait = srcH > srcW;
  size_t srcLong = MAX(srcW, srcH);
  size_t srcShort = MIN(srcW, srcH);
  size_t dstLong = EvenSize((double)(targetLong > 0 ? targetLong : (NSInteger)srcLong));
  size_t dstShort = EvenSize((double)dstLong * (double)srcShort / (double)srcLong);
  size_t scaledW = portrait ? dstShort : dstLong;
  size_t scaledH = portrait ? dstLong : dstShort;
  vImage_Buffer scaled = bgra;
  if (scaledW != srcW || scaledH != srcH) {
    scaled = (vImage_Buffer){ScratchTake(&_scaled, scaledW * scaledH * 4), scaledH, scaledW, scaledW * 4};
    if (scaled.data == NULL) {
      *problem = @"Out of memory";
      return NULL;
    }
    vImage_Error error = vImageScale_ARGB8888(&bgra, &scaled, NULL, kvImageNoFlags);
    if (error != kvImageNoError) {
      *problem = [NSString stringWithFormat:@"Scaling failed (%ld)", (long)error];
      return NULL;
    }
  }

  // 3. Portrait goes out as landscape turned 90° counter-clockwise, plus a rotation flag.
  vImage_Buffer upright = scaled;
  if (portrait) {
    upright = (vImage_Buffer){ScratchTake(&_rotated, scaledW * scaledH * 4), scaledW, scaledH, scaledH * 4};
    if (upright.data == NULL) {
      *problem = @"Out of memory";
      return NULL;
    }
    const uint8_t black[4] = {0, 0, 0, 255};
    vImage_Error error =
        vImageRotate90_ARGB8888(&scaled, &upright, kRotate90DegreesCounterClockwise, black, kvImageNoFlags);
    if (error != kvImageNoError) {
      *problem = [NSString stringWithFormat:@"Rotation failed (%ld)", (long)error];
      return NULL;
    }
  }

  // 4. BGRA -> I420 (BT.601 limited range, Zoom's default external source format).
  size_t w = upright.width;
  size_t h = upright.height;
  size_t ySize = w * h;
  size_t cSize = (w / 2) * (h / 2);
  uint8_t *out = ScratchTake(&_ring[_ringNext], ySize + 2 * cSize);
  _ringNext = (_ringNext + 1) % kRingSize;
  if (out == NULL) {
    *problem = @"Out of memory";
    return NULL;
  }
  vImage_Buffer yPlane = {out, h, w, w};
  vImage_Buffer uPlane = {out + ySize, h / 2, w / 2, w / 2};
  vImage_Buffer vPlane = {out + ySize + cSize, h / 2, w / 2, w / 2};
  const uint8_t fromBGRA[4] = {3, 2, 1, 0};
  vImage_Error error = vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(
      &upright, &yPlane, &uPlane, &vPlane, [NosmaiZoomVideoSource rgbToYuv], fromBGRA, kvImageNoFlags);
  if (error != kvImageNoError) {
    *problem = [NSString stringWithFormat:@"BGRA to I420 failed (%ld)", (long)error];
    return NULL;
  }

  *outWidth = w;
  *outHeight = h;
  *outRotated = portrait;
  return out;
}

+ (const vImage_ARGBToYpCbCr *)rgbToYuv {
  static vImage_ARGBToYpCbCr info;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    vImage_YpCbCrPixelRange range = {16, 128, 235, 240, 235, 16, 240, 16};
    vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &info,
                                                  kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, kvImageNoFlags);
  });
  return &info;
}

+ (const vImage_YpCbCrToARGB *)yuvToRgb:(BOOL)fullRange {
  static vImage_YpCbCrToARGB video;
  static vImage_YpCbCrToARGB full;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    vImage_YpCbCrPixelRange videoRange = {16, 128, 235, 240, 235, 16, 240, 16};
    vImage_YpCbCrPixelRange fullRange = {0, 128, 255, 255, 255, 1, 255, 0};
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &videoRange, &video,
                                                  kvImage420Yp8_CbCr8, kvImageARGB8888, kvImageNoFlags);
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &fullRange, &full,
                                                  kvImage420Yp8_CbCr8, kvImageARGB8888, kvImageNoFlags);
  });
  return fullRange ? &full : &video;
}

#pragma mark - Rate and stats

- (NSInteger)effectiveFps {
  [_lock lock];
  NSInteger fps = _maxFps;
  BOOL adapt = _adaptToThermalState;
  [_lock unlock];
  if (!adapt) return fps;
  switch ([NSProcessInfo processInfo].thermalState) {
    case NSProcessInfoThermalStateCritical:
      return MIN(fps, 10);
    case NSProcessInfoThermalStateSerious:
      return MIN(fps, 15);
    default:
      return fps;
  }
}

+ (NSString *)thermalName {
  switch ([NSProcessInfo processInfo].thermalState) {
    case NSProcessInfoThermalStateNominal:
      return @"nominal";
    case NSProcessInfoThermalStateFair:
      return @"fair";
    case NSProcessInfoThermalStateSerious:
      return @"serious";
    case NSProcessInfoThermalStateCritical:
      return @"critical";
  }
  return @"unknown";
}

- (NSDictionary<NSString *, id> *)stats {
  NSInteger targetFps = [self effectiveFps];
  CFTimeInterval now = CACurrentMediaTime();
  [_lock lock];
  double elapsed = _lastStatsAt > 0 ? now - _lastStatsAt : 0;
  uint64_t sentDelta = _sent - _lastStatsSent;
  double inputFps = elapsed > 0 ? (double)(_framesIn - _lastStatsIn) / elapsed : 0;
  double txFps = elapsed > 0 ? (double)sentDelta / elapsed : 0;
  double convertAvg = sentDelta > 0 ? (_convertMsTotal - _lastStatsConvertMs) / (double)sentDelta : 0;
  NSDictionary *stats = @{
    @"sending" : @(_sending),
    @"senderReady" : @(_sender != nil),
    @"transport" : @"pixelBuffer",
    @"sharedContext" : @NO,
    @"framesIn" : @(_framesIn),
    @"sent" : @(_sent),
    @"dropped" : @(_dropped),
    @"paced" : @(_paced),
    @"errors" : @(_errors),
    @"inputFps" : @(inputFps),
    @"txFps" : @(txFps),
    @"convertMsAvg" : @(convertAvg),
    @"convertMsMax" : @(_convertMsMax),
    @"width" : @(_lastWidth),
    @"height" : @(_lastHeight),
    @"targetFps" : @(targetFps),
    @"thermal" : [NosmaiZoomVideoSource thermalName],
    @"zoomSuggested" : _suggested ?: @"",
    @"lastError" : _lastError ?: @"",
  };
  _lastStatsAt = now;
  _lastStatsIn = _framesIn;
  _lastStatsSent = _sent;
  _lastStatsConvertMs = _convertMsTotal;
  _convertMsMax = 0;
  [_lock unlock];
  return stats;
}

@end
