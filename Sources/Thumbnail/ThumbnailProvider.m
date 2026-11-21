// Finder's icons for .braw clips: a frame about one second in, fitted to the size Finder asks for.

#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <objc/message.h>

#import "BRAWClip.h"

@interface ThumbnailProvider : QLThumbnailProvider
@end

/// Without this, Finder draws the thumbnail as a document: a page with a folded corner and the
/// picture shrunk inside. QLThumbnailReply has an undocumented `iconFlavor` (the flavors of the
/// old Quick Look generators); 3 is the movie flavor that Finder uses for video files. Skipped
/// if a future macOS drops it.
static void UseMovieStyle(QLThumbnailReply *reply)
{
    const NSInteger movieFlavor = 3;
    SEL setter = NSSelectorFromString(@"setIconFlavor:");
    if ([reply respondsToSelector:setter])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(reply, setter, movieFlavor);
}

@implementation ThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request
                     completionHandler:(void (^)(QLThumbnailReply *_Nullable, NSError *_Nullable))handler
{
    const CGSize box = request.maximumSize;
    const CGFloat wanted = MAX(box.width, box.height) * MAX(request.scale, 1.0);

    NSError *error = nil;
    BRAWClip *clip = [BRAWClip clipWithURL:request.fileURL error:&error];
    CGImageRef decoded = clip ? [clip decodeFrame:clip.posterFrameIndex minimumLongSide:wanted error:&error] : NULL;
    if (decoded == NULL) {
        handler(nil, error);
        return;
    }
    id image = CFBridgingRelease(decoded); // keeps the image alive inside the drawing block

    // Fit the frame into the requested box, keeping its aspect ratio.
    const CGFloat ratio = (CGFloat)CGImageGetWidth(decoded) / MAX(CGImageGetHeight(decoded), 1);
    CGSize size = ratio >= box.width / MAX(box.height, 1) ? CGSizeMake(box.width, box.width / ratio)
                                                           : CGSizeMake(box.height * ratio, box.height);
    size = CGSizeMake(MAX(round(size.width), 1), MAX(round(size.height), 1));

    QLThumbnailReply *reply = [QLThumbnailReply replyWithContextSize:size
                                                        drawingBlock:^BOOL(CGContextRef context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), (__bridge CGImageRef)image);
        return YES;
    }];
    UseMovieStyle(reply);
    handler(reply, nil);
}

@end
