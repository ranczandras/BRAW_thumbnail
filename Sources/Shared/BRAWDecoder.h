// Decodes single frames of Blackmagic RAW (.braw) clips with the Blackmagic RAW SDK.
// Shared by the Quick Look thumbnail and preview extensions.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const BRAWDecoderErrorDomain;

/// One decoded frame of a clip, plus what we learned about the clip on the way.
@interface BRAWPoster : NSObject
/// Display-ready (Rec.709) 8-bit image. Owned by this object.
@property (nonatomic, readonly) CGImageRef image;
@property (nonatomic, readonly) uint32_t clipWidth;
@property (nonatomic, readonly) uint32_t clipHeight;
@property (nonatomic, readonly) float frameRate;
@property (nonatomic, readonly) uint64_t frameCount;
@property (nonatomic, readonly) uint64_t frameIndex;
@property (nonatomic, readonly, copy, nullable) NSString *cameraType;
@end

@interface BRAWDecoder : NSObject

/// Decodes the frame about one second into the clip, at the smallest decode resolution
/// (full, 1/2, 1/4 or 1/8) whose longest side is still at least `minimumLongSide` pixels.
/// Thread-safe: calls are serialised on one shared decoder.
+ (nullable BRAWPoster *)posterForURL:(NSURL *)url
                      minimumLongSide:(CGFloat)minimumLongSide
                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
