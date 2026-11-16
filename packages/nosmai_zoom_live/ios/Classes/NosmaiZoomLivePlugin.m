#import "NosmaiZoomLivePlugin.h"

#import <AVFoundation/AVFoundation.h>
#import <mach/mach.h>

#import "NosmaiZoomSession.h"
#import "NosmaiZoomVideoSource.h"

static NSString *const kChannel = @"nosmai_zoom_live";

#pragma mark - Remote video platform view

/// Shows the broadcaster through Zoom's own renderer. Detaches from the session when Flutter
/// releases the view.
@interface NosmaiZoomRemoteVideoView : NSObject <FlutterPlatformView>
@end

@implementation NosmaiZoomRemoteVideoView {
  UIView *_view;
  BOOL _attached;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super init])) {
    _view = [[UIView alloc] initWithFrame:frame];
    _view.backgroundColor = UIColor.blackColor;
    _view.clipsToBounds = YES;
    // Zoom's renderer needs Zoom initialized; a viewer may show this view before joining.
    NSError *error = nil;
    if ([[NosmaiZoomSession shared] ensureInitialized:&error]) {
      [[NosmaiZoomSession shared] attachRemoteView:_view];
      _attached = YES;
    } else {
      NSLog(@"[NosmaiZoomLive] Zoom initialize failed; showing an empty view: %@", error.localizedDescription);
    }
  }
  return self;
}

- (UIView *)view {
  return _view;
}

- (void)dealloc {
  if (!_attached) return;
  UIView *view = _view;
  void (^detach)(void) = ^{ [[NosmaiZoomSession shared] detachRemoteView:view]; };
  if ([NSThread isMainThread]) {
    detach();
  } else {
    dispatch_async(dispatch_get_main_queue(), detach);
  }
}

@end

@interface NosmaiZoomRemoteVideoFactory : NSObject <FlutterPlatformViewFactory>
@end

@implementation NosmaiZoomRemoteVideoFactory

- (NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame
                                    viewIdentifier:(int64_t)viewId
                                         arguments:(id)args {
  return [[NosmaiZoomRemoteVideoView alloc] initWithFrame:frame];
}

- (NSObject<FlutterMessageCodec> *)createArgsCodec {
  return [FlutterStandardMessageCodec sharedInstance];
}

@end

#pragma mark - Plugin

@implementation NosmaiZoomLivePlugin {
  FlutterEventSink _sink;
  BOOL _screenOn;
  void (^_emitter)(NSDictionary<NSString *, id> *);
  // Process CPU sampling.
  CFAbsoluteTime _lastCpuAt;
  double _lastCpuSeconds;
}

// Process-wide, like Zoom and Nosmai themselves.
static NosmaiZoomVideoSource *sSource;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  NosmaiZoomLivePlugin *instance = [[NosmaiZoomLivePlugin alloc] init];
  FlutterMethodChannel *methods = [FlutterMethodChannel methodChannelWithName:kChannel
                                                              binaryMessenger:[registrar messenger]];
  [registrar addMethodCallDelegate:instance channel:methods];
  FlutterEventChannel *events =
      [FlutterEventChannel eventChannelWithName:[kChannel stringByAppendingString:@"/events"]
                                binaryMessenger:[registrar messenger]];
  [events setStreamHandler:instance];
  [registrar registerViewFactory:[[NosmaiZoomRemoteVideoFactory alloc] init]
                          withId:[kChannel stringByAppendingString:@"/remote_video"]];
  [registrar publish:instance];

  __weak NosmaiZoomLivePlugin *weakInstance = instance;
  instance->_emitter = ^(NSDictionary<NSString *, id> *event) {
    void (^deliver)(void) = ^{ [weakInstance onSessionEvent:event]; };
    if ([NSThread isMainThread]) {
      deliver();
    } else {
      dispatch_async(dispatch_get_main_queue(), deliver);
    }
  };
  [NosmaiZoomSession shared].emit = instance->_emitter;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  // Hot restart or engine teardown: never leave a session or the frame stream running.
  NosmaiZoomSession *session = [NosmaiZoomSession shared];
  void (^emitter)(NSDictionary *) = _emitter;
  dispatch_async(dispatch_get_main_queue(), ^{
    // A new engine (hot restart) may already own the session; leave it alone then.
    if (session.emit != emitter) return;
    session.emit = ^(NSDictionary *event) {};
    [session leaveEndingSession:NO];
  });
  [sSource shutdown];
  [self setScreenOn:NO];
}

#pragma mark - Events

- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
  _sink = events;
  return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
  _sink = nil;
  return nil;
}

- (void)onSessionEvent:(NSDictionary<NSString *, id> *)event {
  NSString *type = event[@"type"];
  if ([type isEqualToString:@"joined"]) {
    if ([NosmaiZoomSession shared].request.keepScreenOn) [self setScreenOn:YES];
  } else if ([type isEqualToString:@"left"]) {
    [self setScreenOn:NO];
    NosmaiZoomVideoSource *source = sSource;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [source shutdown]; });
  }
  if (_sink) _sink(event);
}

#pragma mark - Methods

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  NosmaiZoomSession *session = [NosmaiZoomSession shared];
  NSString *method = call.method;
  @try {
    if ([method isEqualToString:@"prepare"]) {
      // iOS needs no shared GPU context: Nosmai hands over CVPixelBuffers. Zoom's initialize is
      // slow, so do it now rather than when the user taps Start; a failure resurfaces at join.
      result(@{@"sharedContext" : @NO, @"nosmaiAlreadyInitialized" : @NO});
      dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        if (![session ensureInitialized:&error]) {
          NSLog(@"[NosmaiZoomLive] Early Zoom initialize failed; will retry at join: %@", error.localizedDescription);
        }
      });
    } else if ([method isEqualToString:@"requestPermissions"]) {
      [self requestPermissionsWithCamera:![args[@"camera"] isEqual:@NO] result:result];
    } else if ([method isEqualToString:@"join"]) {
      [self join:args result:result];
    } else if ([method isEqualToString:@"leave"]) {
      [session leaveEndingSession:[args[@"endSession"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"setMicMuted"]) {
      [session setMicMuted:[args[@"muted"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"setVideoMuted"]) {
      [session setVideoMuted:[args[@"muted"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"setSpeakerMuted"]) {
      [session setSpeakerMuted:[args[@"muted"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"setForeground"]) {
      [session setForeground:[args[@"foreground"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"setMaxFps"]) {
      NSNumber *fps = [args[@"fps"] isKindOfClass:[NSNumber class]] ? args[@"fps"] : @30;
      [sSource setMaxFps:fps.integerValue];
      result(nil);
    } else if ([method isEqualToString:@"stats"]) {
      BOOL host = session.request.host;
      result(@{
        @"zoom" : [session stats],
        @"source" : (host && sSource) ? [sSource stats] : [NSNull null],
        @"process" : [self processSample],
      });
    } else if ([method isEqualToString:@"version"]) {
      result(@{@"zoom" : [session sdkVersion], @"sharedContext" : @NO});
    } else {
      result(FlutterMethodNotImplemented);
    }
  } @catch (NSException *exception) {
    NSLog(@"[NosmaiZoomLive] %@ failed: %@", method, exception);
    result([FlutterError errorWithCode:@"native_error" message:exception.reason details:nil]);
  }
}

- (void)join:(NSDictionary *)args result:(FlutterResult)result {
  NSString *missing = nil;
  for (NSString *key in @[ @"sessionName", @"token", @"userName" ]) {
    NSString *value = [args[key] isKindOfClass:[NSString class]] ? args[key] : @"";
    if ([value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length == 0) {
      missing = key;
      break;
    }
  }
  if (missing) {
    result([FlutterError errorWithCode:@"invalid_config"
                               message:[NSString stringWithFormat:@"Missing %@.", missing]
                               details:nil]);
    return;
  }

  NosmaiZoomJoinRequest *request = [[NosmaiZoomJoinRequest alloc] init];
  request.host = [args[@"host"] boolValue];
  request.sessionName = args[@"sessionName"];
  request.token = args[@"token"];
  request.userName = args[@"userName"];
  request.password = [args[@"password"] isKindOfClass:[NSString class]] ? args[@"password"] : @"";
  request.micMuted = [args[@"micMuted"] boolValue];
  request.videoMuted = [args[@"videoMuted"] boolValue];
  request.speakerMuted = [args[@"speakerMuted"] boolValue];
  NSString *hostName = [args[@"hostUserName"] isKindOfClass:[NSString class]] ? args[@"hostUserName"] : nil;
  request.hostUserName = hostName.length > 0 ? hostName : nil;
  request.keepScreenOn = ![args[@"keepScreenOn"] isEqual:@NO];
  NSInteger fps = [args[@"fps"] isKindOfClass:[NSNumber class]] ? [args[@"fps"] integerValue] : 24;
  request.fps = MAX(1, MIN(30, fps));
  request.prioritizeFrameRate = ![args[@"prioritizeFrameRate"] isEqual:@NO];

  NosmaiZoomVideoSource *source = nil;
  if (request.host) {
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
      result([FlutterError errorWithCode:@"permission_denied"
                                 message:@"Camera access is required to broadcast."
                                 details:nil]);
      return;
    }
    if (sSource == nil) sSource = [[NosmaiZoomVideoSource alloc] init];
    source = sSource;
    NSInteger longSide = [args[@"maxLongSide"] isKindOfClass:[NSNumber class]] ? [args[@"maxLongSide"] integerValue] : 960;
    [source configureWithFps:fps
                 maxLongSide:longSide
         adaptToThermalState:![args[@"adaptToThermalState"] isEqual:@NO]];
    [source resetCounters];
    __weak NosmaiZoomLivePlugin *weakSelf = self;
    source.onSendingChanged = ^(BOOL on) {
      [weakSelf onSessionEvent:@{@"type" : @"sending", @"on" : @(on)}];
    };
  }

  NSError *error = nil;
  if (![[NosmaiZoomSession shared] join:request source:source error:&error]) {
    result([FlutterError errorWithCode:error.userInfo[@"code"] ?: @"start_failed"
                               message:error.localizedDescription
                               details:nil]);
    return;
  }
  result(@{@"sharedContext" : @NO});
}

- (void)setScreenOn:(BOOL)on {
  if (_screenOn == on) return;
  _screenOn = on;
  dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication sharedApplication].idleTimerDisabled = on; });
}

#pragma mark - Permissions

- (void)requestPermissionsWithCamera:(BOOL)camera result:(FlutterResult)result {
  void (^askMicrophone)(BOOL) = ^(BOOL cameraGranted) {
    // Zoom's VoIP audio needs the microphone, even when muted.
    [self requestAccessFor:AVMediaTypeAudio
                completion:^(BOOL microphone) {
                  result(@{@"camera" : @(cameraGranted), @"microphone" : @(microphone)});
                }];
  };
  if (!camera) {
    askMicrophone([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] ==
                  AVAuthorizationStatusAuthorized);
    return;
  }
  [self requestAccessFor:AVMediaTypeVideo completion:askMicrophone];
}

- (void)requestAccessFor:(AVMediaType)type completion:(void (^)(BOOL))completion {
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
  if (status != AVAuthorizationStatusNotDetermined) {
    completion(status == AVAuthorizationStatusAuthorized);
    return;
  }
  [AVCaptureDevice requestAccessForMediaType:type
                           completionHandler:^(BOOL granted) {
                             dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); });
                           }];
}

#pragma mark - Process diagnostics

/// App CPU (percent of one core, like `top`) and memory footprint.
- (NSDictionary<NSString *, id> *)processSample {
  double cpuSeconds = 0;
  struct task_thread_times_info threadTimes;
  mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t)&threadTimes, &count) == KERN_SUCCESS) {
    cpuSeconds += threadTimes.user_time.seconds + threadTimes.user_time.microseconds / 1e6;
    cpuSeconds += threadTimes.system_time.seconds + threadTimes.system_time.microseconds / 1e6;
  }
  struct task_basic_info_64 basic;
  count = TASK_BASIC_INFO_64_COUNT;
  if (task_info(mach_task_self(), TASK_BASIC_INFO_64, (task_info_t)&basic, &count) == KERN_SUCCESS) {
    // Threads that already exited.
    cpuSeconds += basic.user_time.seconds + basic.user_time.microseconds / 1e6;
    cpuSeconds += basic.system_time.seconds + basic.system_time.microseconds / 1e6;
  }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  double cpuPercent = 0;
  if (_lastCpuAt > 0 && now > _lastCpuAt) {
    cpuPercent = MAX(0, (cpuSeconds - _lastCpuSeconds) / (now - _lastCpuAt) * 100.0);
  }
  _lastCpuAt = now;
  _lastCpuSeconds = cpuSeconds;

  double memoryMb = 0;
  task_vm_info_data_t vm;
  count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS) {
    memoryMb = vm.phys_footprint / (1024.0 * 1024.0);
  }
  return @{@"cpuPercent" : @(cpuPercent), @"rssMb" : @(memoryMb)};
}

@end
