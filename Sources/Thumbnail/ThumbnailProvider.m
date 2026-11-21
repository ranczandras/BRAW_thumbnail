// Finder's icons for .braw clips: a frame about one second in, fitted to the size Finder asks for.

#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

#import "BRAWDecoder.h"

@interface ThumbnailProvider : QLThumbnailProvider
@end

@implementation ThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request
                     completionHandler:(void (^)(QLThumbnailReply *_Nullable, NSError *_Nullable))handler
{
    const CGSize box = request.maximumSize;
    const CGFloat wanted = MAX(box.width, box.height) * MAX(request.scale, 1.0);

    NSError *error = nil;
    BRAWPoster *poster = [BRAWDecoder posterForURL:request.fileURL minimumLongSide:wanted error:&error];
    if (poster == nil) {
        handler(nil, error);
        return;
    }

    // Fit the frame into the requested box, keeping its aspect ratio.
    const CGFloat imageWidth = CGImageGetWidth(poster.image);
    const CGFloat imageHeight = MAX(CGImageGetHeight(poster.image), 1);
    const CGFloat ratio = imageWidth / imageHeight;
    CGSize size = ratio >= box.width / MAX(box.height, 1) ? CGSizeMake(box.width, box.width / ratio)
                                                           : CGSizeMake(box.height * ratio, box.height);
    size = CGSizeMake(MAX(round(size.width), 1), MAX(round(size.height), 1));

    QLThumbnailReply *reply = [QLThumbnailReply replyWithContextSize:size
                                                        drawingBlock:^BOOL(CGContextRef context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), poster.image);
        return YES;
    }];
    reply.extensionBadge = @"BRAW";
    handler(reply, nil);
}

@end
