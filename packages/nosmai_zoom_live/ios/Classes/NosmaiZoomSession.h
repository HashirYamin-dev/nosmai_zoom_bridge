#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class NosmaiZoomVideoSource;

NS_ASSUME_NONNULL_BEGIN

/// What Dart asked for when joining.
@interface NosmaiZoomJoinRequest : NSObject
@property(nonatomic) BOOL host;
@property(nonatomic, copy) NSString *sessionName;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *userName;
@property(nonatomic, copy) NSString *password;
@property(nonatomic) BOOL micMuted;
@property(nonatomic) BOOL videoMuted;
@property(nonatomic) BOOL speakerMuted;
@property(nonatomic, copy, nullable) NSString *hostUserName;
@property(nonatomic) BOOL keepScreenOn;
@property(nonatomic) NSInteger fps;
@property(nonatomic) BOOL prioritizeFrameRate;
@end

/// The process-wide Zoom Video SDK session: one broadcaster (publishes a
/// NosmaiZoomVideoSource) or one viewer (renders the broadcaster into UIViews).
///
/// Main thread only: Zoom expects its calls and delivers its callbacks there.
/// Outcomes reach Dart through `emit`: `joined`, `left {reason}`, `reconnecting`,
/// `error {code, message, fatal}`, `warning {message}` and `remoteVideo {userName, on}`.
@interface NosmaiZoomSession : NSObject

+ (instancetype)shared;

@property(nonatomic, copy) void (^emit)(NSDictionary<NSString *, id> *event);
@property(nonatomic, readonly, nullable) NosmaiZoomJoinRequest *request;

- (NSString *)sdkVersion;

/// Zoom's initialize is slow; run it before the user presses Start. Returns NO with *error set.
- (BOOL)ensureInitialized:(NSError **)error;

/// Joins asynchronously; success arrives as the `joined` event.
- (BOOL)join:(NosmaiZoomJoinRequest *)request
      source:(nullable NosmaiZoomVideoSource *)source
       error:(NSError **)error;

/// Leaves (and, for a broadcaster with endSession, ends) the session. `left` follows.
- (void)leaveEndingSession:(BOOL)endSession;

- (void)setMicMuted:(BOOL)muted;
- (void)setVideoMuted:(BOOL)muted;
- (void)setSpeakerMuted:(BOOL)muted;
- (void)setForeground:(BOOL)foreground;

- (void)attachRemoteView:(UIView *)view;
- (void)detachRemoteView:(UIView *)view;

- (NSDictionary<NSString *, id> *)stats;

@end

/// Error domain of NSErrors from this plugin; the Flutter error code is in userInfo[@"code"].
extern NSString *const NosmaiZoomLiveErrorDomain;
NSError *NosmaiZoomLiveError(NSString *code, NSString *message);

NS_ASSUME_NONNULL_END
