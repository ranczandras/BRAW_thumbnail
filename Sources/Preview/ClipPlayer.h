// Plays a BRAWClip: decodes frames on a worker thread just in time for the clock, which is the
// clip's own sound when it has any (so picture and sound stay in sync), else the system clock.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class BRAWClip;
@class ClipPlayer;

NS_ASSUME_NONNULL_BEGIN

@protocol ClipPlayerDelegate <NSObject>
/// On the main thread.
- (void)player:(ClipPlayer *)player showImage:(CGImageRef)image frame:(uint64_t)frame;
/// On the main thread.
- (void)playerDidChangeState:(ClipPlayer *)player;
@end

@interface ClipPlayer : NSObject

- (instancetype)initWithClip:(BRAWClip *)clip startFrame:(uint64_t)frame NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<ClipPlayerDelegate> delegate;
@property (nonatomic, readonly) BRAWClip *clip;
@property (nonatomic, readonly, getter=isPlaying) BOOL playing;
@property (nonatomic, readonly) BOOL hasSound;

/// Decode size (longest side, pixels) while playing. Lowered automatically when the Mac can't
/// keep up.
@property (atomic) CGFloat playbackLongSide;
/// Decode size of the sharp still shown when paused.
@property (atomic) CGFloat stillLongSide;

- (void)play;
- (void)pause;
- (void)togglePlaying;
/// Jumps to a frame; keeps playing if playing.
- (void)seekToFrame:(uint64_t)frame;
/// Ends playback for good (stops the worker thread and the sound).
- (void)stop;

@end

NS_ASSUME_NONNULL_END
