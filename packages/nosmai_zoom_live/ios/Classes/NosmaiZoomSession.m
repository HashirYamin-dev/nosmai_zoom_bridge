#import "NosmaiZoomSession.h"

#import <ZoomVideoSDK/ZoomVideoSDK.h>

#import "NosmaiZoomVideoSource.h"

NSString *const NosmaiZoomLiveErrorDomain = @"nosmai_zoom_live";

NSError *NosmaiZoomLiveError(NSString *code, NSString *message) {
  return [NSError errorWithDomain:NosmaiZoomLiveErrorDomain
                             code:0
                         userInfo:@{@"code" : code, NSLocalizedDescriptionKey : message}];
}

@implementation NosmaiZoomJoinRequest
@end

@interface NosmaiZoomSession () <ZoomVideoSDKDelegate>
@end

@implementation NosmaiZoomSession {
  BOOL _initialized;
  NosmaiZoomJoinRequest *_request;
  NosmaiZoomVideoSource *_source;  // Zoom holds its video source weakly.
  BOOL _joined;
  CFAbsoluteTime _joinedAt;
  BOOL _foreground;
  BOOL _micMuted;
  BOOL _videoMuted;
  BOOL _speakerMuted;
  BOOL _localVideoOn;
  NSMutableArray<UIView *> *_remoteViews;
  NSMapTable<UIView *, ZoomVideoSDKUser *> *_subscribed;
  NSString *_reportedName;
  NSNumber *_reportedOn;
}

+ (instancetype)shared {
  static NosmaiZoomSession *session;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ session = [[NosmaiZoomSession alloc] init]; });
  return session;
}

- (instancetype)init {
  if ((self = [super init])) {
    _emit = ^(NSDictionary *event) {};
    _foreground = YES;
    _remoteViews = [NSMutableArray array];
    _subscribed = [NSMapTable strongToStrongObjectsMapTable];
  }
  return self;
}

- (NosmaiZoomJoinRequest *)request {
  return _request;
}

- (ZoomVideoSDK *)sdk {
  return [ZoomVideoSDK sharedInstance];
}

- (BOOL)inSession {
  return _initialized && [[self sdk] isInSession];
}

- (NSString *)sdkVersion {
  return [[self sdk] getSDKVersion] ?: @"";
}

- (BOOL)ensureInitialized:(NSError **)error {
  if (_initialized) return YES;
  ZoomVideoSDKInitParams *params = [[ZoomVideoSDKInitParams alloc] init];
  params.domain = @"zoom.us";
  params.enableLog = NO;
  params.videoRawdataMemoryMode = ZoomVideoSDKRawDataMemoryModeHeap;
  params.audioRawdataMemoryMode = ZoomVideoSDKRawDataMemoryModeHeap;
  params.shareRawdataMemoryMode = ZoomVideoSDKRawDataMemoryModeHeap;
  ZoomVideoSDKError code = [[self sdk] initialize:params];
  if (code != Errors_Success) {
    if (error) {
      *error = NosmaiZoomLiveError(
          @"start_failed", [NSString stringWithFormat:@"Zoom Video SDK initialize failed: %@ (%lu)",
                                                      [NosmaiZoomSession errorName:code], (unsigned long)code]);
    }
    return NO;
  }
  [[self sdk] addDelegate:self];
  _initialized = YES;
  return YES;
}

- (BOOL)join:(NosmaiZoomJoinRequest *)join source:(NosmaiZoomVideoSource *)source error:(NSError **)error {
  if (![self ensureInitialized:error]) return NO;
  if (_request != nil || [[self sdk] isInSession]) {
    if (error) {
      *error = NosmaiZoomLiveError(@"already_active",
                                   @"Another Zoom session is active in this app. Stop it before starting a new one.");
    }
    return NO;
  }
  _request = join;
  _source = join.host ? source : nil;
  _joined = NO;
  _joinedAt = 0;
  _foreground = YES;
  _micMuted = join.micMuted;
  _videoMuted = join.videoMuted;
  _speakerMuted = join.speakerMuted;
  _localVideoOn = join.host && !join.videoMuted;
  _reportedName = nil;
  _reportedOn = nil;

  ZoomVideoSDKSessionContext *context = [[ZoomVideoSDKSessionContext alloc] init];
  context.sessionName = join.sessionName;
  context.token = join.token;
  context.userName = join.userName;
  context.sessionPassword = join.password;
  ZoomVideoSDKVideoOptions *video = [[ZoomVideoSDKVideoOptions alloc] init];
  video.localVideoOn = _localVideoOn;
  context.videoOption = video;
  ZoomVideoSDKAudioOptions *audio = [[ZoomVideoSDKAudioOptions alloc] init];
  audio.connect = join.host || !join.speakerMuted;
  audio.mute = !join.host || join.micMuted;
  audio.autoAdjustSpeakerVolume = YES;
  context.audioOption = audio;
  if (join.host) context.externalVideoSourceDelegate = source;

  if ([[self sdk] joinSession:context] == nil) {
    [self reset];
    if (error) {
      *error = NosmaiZoomLiveError(@"start_failed", @"Zoom rejected the join request. Check the session name "
                                                    @"and that the token was issued for it.");
    }
    return NO;
  }
  return YES;
}

- (void)leaveEndingSession:(BOOL)endSession {
  NosmaiZoomJoinRequest *current = _request;
  if (current == nil) return;
  [self unsubscribeAll];
  ZoomVideoSDKError code =
      _initialized ? [[self sdk] leaveSession:(endSession && current.host)] : Errors_Wrong_Usage;
  if (code != Errors_Success && ![self inSession]) {
    // Nothing to leave (the join never got through), so Zoom will not call back.
    NSLog(@"[NosmaiZoomLive] leaveSession: %@; not in a session", [NosmaiZoomSession errorName:code]);
    [self reset];
    self.emit(@{@"type" : @"left", @"reason" : @"BySelf"});
  }
}

#pragma mark - Media

- (void)setMicMuted:(BOOL)muted {
  _micMuted = muted;
  [self applyMedia];
}

- (void)setVideoMuted:(BOOL)muted {
  _videoMuted = muted;
  [self applyMedia];
}

- (void)setSpeakerMuted:(BOOL)muted {
  _speakerMuted = muted;
  [self applyMedia];
}

- (void)setForeground:(BOOL)foreground {
  if (_foreground == foreground) return;
  _foreground = foreground;
  [self applyMedia];
}

- (void)applyMedia {
  NosmaiZoomJoinRequest *current = _request;
  if (current == nil || !_joined || ![self inSession]) return;
  ZoomVideoSDKUser *me = [[[self sdk] getSession] getMySelf];
  if (me == nil) return;
  ZoomVideoSDKAudioHelper *audio = [[self sdk] getAudioHelper];
  if (current.host) {
    BOOL wantVideo = !_videoMuted && _foreground;
    if (wantVideo != _localVideoOn) {
      ZoomVideoSDKVideoHelper *video = [[self sdk] getVideoHelper];
      ZoomVideoSDKError code = wantVideo ? [video startVideo] : [video stopVideo];
      if (code == Errors_Success) {
        _localVideoOn = wantVideo;
      } else {
        [self warn:[NSString stringWithFormat:@"%@ video failed: %@", wantVideo ? @"Starting" : @"Stopping",
                                              [NosmaiZoomSession errorName:code]]];
      }
    }
    BOOL wantMuted = _micMuted || !_foreground;
    ZoomVideoSDKAudioStatus *status = [me audioStatus];
    BOOL isMuted = status ? status.isMuted : YES;
    if (wantMuted != isMuted) {
      if (![self audioConnected:me]) [audio startAudio];
      ZoomVideoSDKError code = wantMuted ? [audio muteAudio:me] : [audio unmuteAudio:me];
      if (code != Errors_Success) {
        [self warn:[NSString stringWithFormat:@"%@ the microphone failed: %@", wantMuted ? @"Muting" : @"Unmuting",
                                              [NosmaiZoomSession errorName:code]]];
      }
    }
  } else {
    BOOL wantAudio = !_speakerMuted && _foreground;
    BOOL connected = [self audioConnected:me];
    if (wantAudio && !connected) {
      ZoomVideoSDKError code = [audio startAudio];
      if (code == Errors_Success) {
        [audio muteAudio:me];  // Viewers listen; they never send audio.
      } else {
        [self warn:[NSString stringWithFormat:@"Starting audio failed: %@", [NosmaiZoomSession errorName:code]]];
      }
    } else if (!wantAudio && connected) {
      [audio stopAudio];
    }
    [self refreshSubscriptions];
  }
}

/// Zoom's default (Balance) trades frame rate for sharpness. Pinning min = max = the
/// configured rate makes Zoom lower resolution instead.
- (void)applyVideoPreference:(NosmaiZoomJoinRequest *)join {
  ZoomVideoSDKVideoPreferenceSetting *setting = [[ZoomVideoSDKVideoPreferenceSetting alloc] init];
  if (join.prioritizeFrameRate) {
    setting.mode = ZoomVideoSDKVideoPreferenceMode_Custom;
    setting.minimumFrameRate = (NSUInteger)join.fps;
    setting.maximumFrameRate = (NSUInteger)join.fps;
  } else {
    setting.mode = ZoomVideoSDKVideoPreferenceMode_Balance;
  }
  ZoomVideoSDKError code = [[[self sdk] getVideoHelper] setVideoQualityPreference:setting];
  NSLog(@"[NosmaiZoomLive] Video preference %lu %ld fps: %@", (unsigned long)setting.mode, (long)join.fps,
        [NosmaiZoomSession errorName:code]);
  if (code != Errors_Success) {
    [self warn:[NSString stringWithFormat:@"Zoom did not accept the frame-rate preference: %@",
                                          [NosmaiZoomSession errorName:code]]];
  }
}

- (BOOL)audioConnected:(ZoomVideoSDKUser *)me {
  ZoomVideoSDKAudioStatus *status = [me audioStatus];
  return status != nil && status.audioType != ZoomVideoSDKAudioType_None;
}

#pragma mark - Remote video (viewer)

- (void)attachRemoteView:(UIView *)view {
  if (![_remoteViews containsObject:view]) [_remoteViews addObject:view];
  [self refreshSubscriptions];
}

- (void)detachRemoteView:(UIView *)view {
  [_remoteViews removeObject:view];
  ZoomVideoSDKUser *user = [_subscribed objectForKey:view];
  if (user != nil) {
    [[user getVideoCanvas] unSubscribeWithView:view];
    [_subscribed removeObjectForKey:view];
  }
  [self reportRemote];
}

/// Shows the broadcaster in every attached view, and reports what is shown.
- (void)refreshSubscriptions {
  NosmaiZoomJoinRequest *current = _request;
  if (current == nil || current.host || !_joined || ![self inSession]) return;
  ZoomVideoSDKUser *target = _foreground ? [self publisher:current.hostUserName] : nil;
  for (UIView *view in [_remoteViews copy]) {
    ZoomVideoSDKUser *existing = [_subscribed objectForKey:view];
    if (existing != nil && target != nil && [existing getUserID] == [target getUserID]) continue;
    if (existing != nil) [[existing getVideoCanvas] unSubscribeWithView:view];
    [_subscribed removeObjectForKey:view];
    if (target == nil) continue;
    ZoomVideoSDKVideoCanvas *canvas = [target getVideoCanvas];
    ZoomVideoSDKError code = canvas ? [canvas subscribeWithView:view
                                                     aspectMode:ZoomVideoSDKVideoAspect_LetterBox
                                                  andResolution:ZoomVideoSDKVideoResolution_720]
                                    : Errors_Wrong_Usage;
    if (code == Errors_Success) {
      [_subscribed setObject:target forKey:view];
    } else {
      [self warn:[NSString stringWithFormat:@"Showing the broadcaster's video failed: %@",
                                            [NosmaiZoomSession errorName:code]]];
    }
  }
  [self reportRemote];
}

- (void)reportRemote {
  NosmaiZoomJoinRequest *current = _request;
  if (current == nil || current.host) return;
  ZoomVideoSDKUser *shown = [[_subscribed objectEnumerator] nextObject];
  ZoomVideoSDKUser *target = shown;
  if (target == nil && _joined && [self inSession] && _foreground) target = [self publisher:current.hostUserName];
  BOOL on = shown != nil && [[shown getVideoCanvas] videoStatus].on;
  NSString *name = [target getUserName];
  if (_reportedOn != nil && _reportedOn.boolValue == on &&
      ((name == nil && _reportedName == nil) || [name isEqualToString:_reportedName])) {
    return;
  }
  _reportedName = name;
  _reportedOn = @(on);
  self.emit(@{@"type" : @"remoteVideo", @"userName" : name ?: [NSNull null], @"on" : @(on)});
}

- (void)unsubscribeAll {
  for (UIView *view in _subscribed) {
    [[[_subscribed objectForKey:view] getVideoCanvas] unSubscribeWithView:view];
  }
  [_subscribed removeAllObjects];
}

/// The user to watch: `wanted` by name if given, else the sending host, else any sender.
- (ZoomVideoSDKUser *)publisher:(NSString *)wanted {
  ZoomVideoSDKSession *session = [[self sdk] getSession];
  if (session == nil) return nil;
  NSInteger myId = [[session getMySelf] getUserID];
  NSMutableArray<ZoomVideoSDKUser *> *remote = [NSMutableArray array];
  for (ZoomVideoSDKUser *user in [session getRemoteUsers] ?: @[]) {
    if ([user getUserID] == myId) continue;
    if (wanted.length > 0 && ![[user getUserName] isEqualToString:wanted]) continue;
    [remote addObject:user];
  }
  ZoomVideoSDKUser *anyWithVideo = nil;
  for (ZoomVideoSDKUser *user in remote) {
    if (![[user getVideoCanvas] videoStatus].on) continue;
    if ([user isHost]) return user;
    if (anyWithVideo == nil) anyWithVideo = user;
  }
  if (anyWithVideo != nil) return anyWithVideo;
  for (ZoomVideoSDKUser *user in remote) {
    if ([user isHost]) return user;
  }
  return remote.firstObject;
}

#pragma mark - Stats

- (NSDictionary<NSString *, id> *)stats {
  NosmaiZoomJoinRequest *current = _request;
  ZoomVideoSDKSession *session = (current != nil && _joined && [self inSession]) ? [[self sdk] getSession] : nil;
  NSMutableDictionary *stats = [NSMutableDictionary dictionary];
  stats[@"inSession"] = @(session != nil);
  if (session == nil) return stats;
  stats[@"participants"] = @([session getRemoteUsers].count);
  stats[@"secondsLive"] = @(_joinedAt > 0 ? (NSInteger)(CFAbsoluteTimeGetCurrent() - _joinedAt) : 0);
  ZoomVideoSDKUser *me = [session getMySelf];
  if (me != nil) {
    ZoomVideoSDKAudioStatus *audio = [me audioStatus];
    stats[@"micMuted"] = @(audio ? audio.isMuted : YES);
    stats[@"network"] = [NosmaiZoomSession networkName:[me getOverallNetworkLevel]];
  }
  ZoomVideoSDKSessionASVStatisticInfo *video = [session getSessionVideoStatisticInfo];
  if (video != nil) {
    if (current.host) {
      stats[@"fps"] = @(video.sendFps);
      stats[@"width"] = @(video.sendFrameWidth);
      stats[@"height"] = @(video.sendFrameHeight);
      stats[@"latencyMs"] = @(video.sendLatency);
      stats[@"lossPercent"] = @((double)video.sendPacketLossAvg);
    } else {
      stats[@"fps"] = @(video.recvFps);
      stats[@"width"] = @(video.recvFrameWidth);
      stats[@"height"] = @(video.recvFrameHeight);
      stats[@"latencyMs"] = @(video.recvLatency);
      stats[@"lossPercent"] = @((double)video.recvPacketLossAvg);
    }
  }
  if (!current.host) {
    // Per-user figures describe exactly the stream on screen; prefer them.
    ZoomVideoSDKVideoStatisticInfo *info = [[[_subscribed objectEnumerator] nextObject] getVideoStatisticInfo];
    if (info != nil) {
      if (info.fps > 0) stats[@"fps"] = @(info.fps);
      if (info.width > 0) stats[@"width"] = @(info.width);
      if (info.height > 0) stats[@"height"] = @(info.height);
      stats[@"bitrateKbps"] = @(info.bps / 1000);
      stats[@"rttMs"] = @(info.rtt);
      stats[@"network"] = [NosmaiZoomSession networkName:info.networkLevel];
    }
  }
  return stats;
}

+ (NSString *)networkName:(ZoomVideoSDKNetworkStatus)status {
  switch (status) {
    case ZoomVideoSDKNetworkStatus_Good:
      return @"Good";
    case ZoomVideoSDKNetworkStatus_Normal:
      return @"Normal";
    case ZoomVideoSDKNetworkStatus_Bad:
      return @"Bad";
    default:
      return @"None";
  }
}

#pragma mark - ZoomVideoSDKDelegate

- (void)onSessionJoin {
  if (_request == nil) return;
  BOOL firstJoin = !_joined;
  _joined = YES;
  if (firstJoin) {
    _joinedAt = CFAbsoluteTimeGetCurrent();
    if (_request.host) [self applyVideoPreference:_request];
  }
  self.emit(@{@"type" : @"joined"});
  [self applyMedia];
  [self refreshSubscriptions];
}

- (void)onSessionLeave:(ZoomVideoSDKSessionLeaveReason)reason {
  BOOL wasActive = _request != nil;
  [self unsubscribeAll];
  [self reset];
  if (wasActive) self.emit(@{@"type" : @"left", @"reason" : [NosmaiZoomSession leaveReasonName:reason]});
}

- (void)onError:(ZoomVideoSDKError)errorType detail:(NSInteger)details {
  if (_request == nil) return;
  if (errorType == Errors_Session_Reconnecting) {
    self.emit(@{@"type" : @"reconnecting"});
    return;
  }
  NSLog(@"[NosmaiZoomLive] Zoom error %@ (%lu), detail %ld", [NosmaiZoomSession errorName:errorType],
        (unsigned long)errorType, (long)details);
  self.emit(@{
    @"type" : @"error",
    @"code" : @(errorType),
    @"message" : [NosmaiZoomSession describeError:errorType],
    @"fatal" : @(!_joined || [NosmaiZoomSession isFatal:errorType]),
  });
}

- (void)onUserJoin:(ZoomVideoSDKUserHelper *)helper users:(NSArray<ZoomVideoSDKUser *> *)userArray {
  [self refreshSubscriptions];
}

- (void)onUserLeave:(ZoomVideoSDKUserHelper *)helper users:(NSArray<ZoomVideoSDKUser *> *)userArray {
  [self refreshSubscriptions];
}

- (void)onUserVideoStatusChanged:(ZoomVideoSDKVideoHelper *)helper user:(NSArray<ZoomVideoSDKUser *> *)userArray {
  [self refreshSubscriptions];
}

- (void)onUserHostChanged:(ZoomVideoSDKUserHelper *)helper users:(ZoomVideoSDKUser *)user {
  [self refreshSubscriptions];
}

- (void)onSessionNeedPassword:(ZoomVideoSDKError (^)(NSString *, BOOL))completion {
  if (completion) completion(nil, YES);
  if (_request == nil) return;
  self.emit(@{@"type" : @"error", @"code" : @2010, @"message" : @"This Zoom session needs a password.", @"fatal" : @YES});
}

- (void)onSessionPasswordWrong:(ZoomVideoSDKError (^)(NSString *, BOOL))completion {
  if (completion) completion(nil, YES);
  if (_request == nil) return;
  self.emit(@{@"type" : @"error", @"code" : @2011, @"message" : @"The Zoom session password is wrong.", @"fatal" : @YES});
}

- (void)onVideoCanvasSubscribeFail:(ZoomVideoSDKSubscribeFailReason)failReason
                              user:(ZoomVideoSDKUser *)user
                              view:(UIView *)view {
  if (_request == nil) return;
  [self warn:[NSString stringWithFormat:@"Showing the broadcaster's video failed: %ld", (long)failReason]];
}

#pragma mark - Helpers

- (void)warn:(NSString *)message {
  NSLog(@"[NosmaiZoomLive] %@", message);
  self.emit(@{@"type" : @"warning", @"message" : message});
}

- (void)reset {
  _request = nil;
  _source = nil;
  _joined = NO;
  _joinedAt = 0;
  _localVideoOn = NO;
  _reportedName = nil;
  _reportedOn = nil;
  [_subscribed removeAllObjects];
}

+ (NSString *)leaveReasonName:(ZoomVideoSDKSessionLeaveReason)reason {
  switch (reason) {
    case ZoomVideoSDKSessionLeaveReason_BySelf:
      return @"BySelf";
    case ZoomVideoSDKSessionLeaveReason_KickByHost:
      return @"KickByHost";
    case ZoomVideoSDKSessionLeaveReason_EndByHost:
      return @"EndByHost";
    case ZoomVideoSDKSessionLeaveReason_NetworkError:
      return @"NetworkError";
    default:
      return @"Unknown";
  }
}

+ (BOOL)isFatal:(ZoomVideoSDKError)code {
  switch (code) {
    case Errors_Session_Disconnecting:
    case Errors_Session_Join_Failed:
    case Errors_Session_No_Rights:
    case Errors_Session_Need_Password:
    case Errors_Session_Password_Wrong:
    case Errors_Session_Client_Incompatible:
    case Errors_Session_Account_FreeMinutesExceeded:
    case Errors_Session_Account_FreeCreditExceeded:
      return YES;
    default:
      return NO;
  }
}

+ (NSString *)describeError:(ZoomVideoSDKError)code {
  switch (code) {
    case Errors_Session_Disconnecting:
      return @"Disconnected from Zoom.";
    case Errors_JoinSession_Invalid_SessionToken:
      return @"Zoom rejected the token. Check that it is signed with this app's SDK key and has not expired.";
    case Errors_JoinSession_Token_MismatchedSessionName:
      return @"The token was issued for a different session name.";
    default:
      return [NSString stringWithFormat:@"Zoom error %@ (%lu).", [self errorName:code], (unsigned long)code];
  }
}

+ (NSString *)errorName:(ZoomVideoSDKError)code {
  switch (code) {
    case Errors_Success: return @"Success";
    case Errors_Wrong_Usage: return @"Wrong_Usage";
    case Errors_Internal_Error: return @"Internal_Error";
    case Errors_Uninitialize: return @"Uninitialize";
    case Errors_Invalid_Parameter: return @"Invalid_Parameter";
    case Errors_Auth_Error: return @"Auth_Error";
    case Errors_Auth_Wrong_Key_or_Secret: return @"Auth_Wrong_Key_or_Secret";
    case Errors_JoinSession_NoSessionName: return @"JoinSession_NoSessionName";
    case Errors_JoinSession_NoSessionToken: return @"JoinSession_NoSessionToken";
    case Errors_JoinSession_Invalid_SessionToken: return @"JoinSession_Invalid_SessionToken";
    case Errors_JoinSession_Token_MismatchedSessionName: return @"JoinSession_Token_MismatchedSessionName";
    case Errors_JoinSession_Token_RoleType_EmptyOrWrong: return @"JoinSession_Token_RoleType_EmptyOrWrong";
    case Errors_Session_Join_Failed: return @"Session_Join_Failed";
    case Errors_Session_No_Rights: return @"Session_No_Rights";
    case Errors_Session_Already_In_Progress: return @"Session_Already_In_Progress";
    case Errors_Session_Reconnecting: return @"Session_Reconnecting";
    case Errors_Session_Disconnecting: return @"Session_Disconnecting";
    case Errors_Session_Need_Password: return @"Session_Need_Password";
    case Errors_Session_Password_Wrong: return @"Session_Password_Wrong";
    case Errors_Session_Client_Incompatible: return @"Session_Client_Incompatible";
    case Errors_Session_Audio_Error: return @"Session_Audio_Error";
    case Errors_Session_Audio_No_Microphone: return @"Session_Audio_No_Microphone";
    case Errors_Session_Video_Error: return @"Session_Video_Error";
    default: return [NSString stringWithFormat:@"Error %lu", (unsigned long)code];
  }
}

@end
