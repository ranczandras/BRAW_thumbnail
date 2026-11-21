// Finder's icons for .braw clips: a frame about one second in, fitted to the size Finder asks for.

#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

#import "BRAWClip.h"

@interface ThumbnailProvider : QLThumbnailProvider
@end

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
    reply.extensionBadge = @"BRAW";
    handler(reply, nil);
}

@end
