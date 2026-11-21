// Quick Look (Space bar) and Finder's preview pane for .braw clips: a sharp still about one
// second in, titled with the clip's resolution, frame rate, length and camera.

#import <QuickLookUI/QuickLookUI.h>

#import "BRAWDecoder.h"

/// Decode at least this wide (or tall); larger stills are scaled down to `kMaximumLongSide`.
static const CGFloat kMinimumLongSide = 1920;
static const CGFloat kMaximumLongSide = 2560;

@interface PreviewProvider : QLPreviewProvider <QLPreviewingController>
@end

static NSString *FormatFrameRate(float frameRate)
{
    if (frameRate <= 0)
        return nil;
    if (fabsf(frameRate - roundf(frameRate)) < 0.001f)
        return [NSString stringWithFormat:@"%.0f fps", frameRate];
    return [NSString stringWithFormat:@"%.3f fps", frameRate];
}

static NSString *FormatDuration(uint64_t frameCount, float frameRate)
{
    if (frameRate <= 0 || frameCount == 0)
        return nil;
    const uint64_t seconds = (uint64_t)llround((double)frameCount / frameRate);
    if (seconds >= 3600)
        return [NSString stringWithFormat:@"%llu:%02llu:%02llu", seconds / 3600, (seconds / 60) % 60, seconds % 60];
    return [NSString stringWithFormat:@"%llu:%02llu", seconds / 60, seconds % 60];
}

static NSString *Title(NSURL *url, BRAWPoster *poster)
{
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%u × %u", poster.clipWidth, poster.clipHeight]];
    NSString *frameRate = FormatFrameRate(poster.frameRate);
    if (frameRate != nil)
        [parts addObject:frameRate];
    NSString *duration = FormatDuration(poster.frameCount, poster.frameRate);
    if (duration != nil)
        [parts addObject:duration];
    if (poster.cameraType.length > 0)
        [parts addObject:poster.cameraType];
    return [NSString stringWithFormat:@"%@ — %@", url.lastPathComponent, [parts componentsJoinedByString:@" · "]];
}

@implementation PreviewProvider

- (void)providePreviewForFileRequest:(QLFilePreviewRequest *)request
                   completionHandler:(void (^)(QLPreviewReply *_Nullable, NSError *_Nullable))handler
{
    NSError *error = nil;
    BRAWPoster *poster = [BRAWDecoder posterForURL:request.fileURL minimumLongSide:kMinimumLongSide error:&error];
    if (poster == nil) {
        handler(nil, error);
        return;
    }

    const CGFloat width = CGImageGetWidth(poster.image);
    const CGFloat height = CGImageGetHeight(poster.image);
    const CGFloat shrink = MIN(1.0, kMaximumLongSide / MAX(MAX(width, height), 1));
    const CGSize size = CGSizeMake(MAX(round(width * shrink), 1), MAX(round(height * shrink), 1));

    QLPreviewReply *reply =
        [[QLPreviewReply alloc] initWithContextSize:size
                                           isBitmap:YES
                                       drawingBlock:^BOOL(CGContextRef context, QLPreviewReply *r, NSError **drawError) {
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), poster.image);
        return YES;
    }];
    reply.title = Title(request.fileURL, poster);
    handler(reply, nil);
}

@end
