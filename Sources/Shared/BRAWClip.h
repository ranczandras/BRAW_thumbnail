// An open Blackmagic RAW (.braw) clip, decoded with the Blackmagic RAW SDK.
// Shared by the Quick Look thumbnail and preview extensions.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const BRAWErrorDomain;

@interface BRAWClip : NSObject

+ (nullable instancetype)clipWithURL:(NSURL *)url error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
/// Frames per second; 0 when the clip doesn't say.
@property (nonatomic, readonly) float frameRate;
@property (nonatomic, readonly) uint64_t frameCount;
@property (nonatomic, readonly, copy, nullable) NSString *cameraType;

/// How frames are developed for display, e.g. "LUT: Rec709 Video" or "Film → Extended Video".
/// A LUT the camera put in the clip is used as is; otherwise log ("Film") footage is shown as
/// Extended Video in Rec.709, and everything else as it was shot.
@property (nonatomic, readonly, copy) NSString *lookDescription;

/// About one second in: the very first frames are often still settling (exposure, focus).
@property (nonatomic, readonly) uint64_t posterFrameIndex;

/// Decodes a frame as an 8-bit Rec.709 image, at the smallest decode size (full, 1/2, 1/4 or
/// 1/8) whose longest side is still at least `minimumLongSide` pixels. Blocks until done.
/// Safe to call from any thread.
- (nullable CGImageRef)decodeFrame:(uint64_t)frameIndex
                   minimumLongSide:(CGFloat)minimumLongSide
                             error:(NSError **)error CF_RETURNS_RETAINED;

// Sound recorded into the clip itself. All 0 when there is none.
@property (nonatomic, readonly) uint32_t audioChannelCount;
@property (nonatomic, readonly) uint32_t audioSampleRate;
/// Bits per sample of the interleaved little-endian integer PCM that readAudio… returns.
@property (nonatomic, readonly) uint32_t audioBitDepth;
@property (nonatomic, readonly) uint64_t audioSampleCount;

/// Reads up to `maxFrames` sample frames starting at `sampleFrame`. Returns the number read.
- (uint32_t)readAudioAtSampleFrame:(uint64_t)sampleFrame
                            buffer:(void *)buffer
                        bufferSize:(uint32_t)bufferSize
                         maxFrames:(uint32_t)maxFrames;

@end

NS_ASSUME_NONNULL_END
