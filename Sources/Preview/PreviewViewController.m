// Quick Look (Space bar) and Finder's preview pane for .braw clips. In the Quick Look window the
// clip plays at once, with sound, looping; in Finder's narrow preview pane it stays a still
// until clicked. Click the picture (or the button) to play or pause, drag the bar to scrub.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <QuickLookUI/QuickLookUI.h>

#import "BRAWClip.h"
#import "ClipPlayer.h"

/// Narrower than this, it's Finder's preview pane rather than the Quick Look window.
static const CGFloat kAutoplayMinimumWidth = 520;
static const CGFloat kBarHeight = 30;
/// Decode sizes (longest side, pixels): smaller while playing, to keep up; sharper when paused.
static const CGFloat kPlaybackMaximumLongSide = 1536;
static const CGFloat kStillMaximumLongSide = 3072;

#pragma mark - Formatting

static NSString *FormatTime(double seconds)
{
    const long total = (long)floor(MAX(seconds, 0));
    if (total >= 3600)
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

static NSString *FormatFrameRate(float frameRate)
{
    if (fabsf(frameRate - roundf(frameRate)) < 0.001f)
        return [NSString stringWithFormat:@"%.0f fps", frameRate];
    return [NSString stringWithFormat:@"%.3f fps", frameRate];
}

static NSString *Caption(BRAWClip *clip)
{
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%u × %u", clip.width, clip.height]];
    if (clip.frameRate > 0)
        [parts addObject:FormatFrameRate(clip.frameRate)];
    if (clip.cameraType.length > 0)
        [parts addObject:clip.cameraType];
    if (clip.lookDescription.length > 0)
        [parts addObject:clip.lookDescription];
    if (clip.audioChannelCount == 0)
        [parts addObject:@"no sound"];
    return [parts componentsJoinedByString:@"  ·  "];
}

static NSImage *Symbol(NSString *name, NSString *description)
{
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold];
    return [image imageWithSymbolConfiguration:configuration] ?: image;
}

static NSTextField *Label(void)
{
    NSTextField *label = [NSTextField labelWithString:@""];
    label.textColor = NSColor.whiteColor;
    label.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

#pragma mark - Picture view

/// Shows frames as layer contents (fitted, black bars), and reports clicks and leaving the window.
@interface PictureView : NSView
@property (nonatomic, readonly) CALayer *pictureLayer;
@property (nonatomic, copy, nullable) void (^clickHandler)(void);
@property (nonatomic, copy, nullable) void (^leftWindowHandler)(void);
@end

@implementation PictureView

- (instancetype)initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect])) {
        // A layer-hosting view: its own layer shows the frames.
        _pictureLayer = [CALayer layer];
        _pictureLayer.backgroundColor = NSColor.blackColor.CGColor;
        _pictureLayer.contentsGravity = kCAGravityResizeAspect;
        _pictureLayer.actions = @{@"contents": [NSNull null]};
        self.layer = _pictureLayer;
        self.wantsLayer = YES;
    }
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (void)mouseDown:(NSEvent *)event
{
    if (self.clickHandler)
        self.clickHandler();
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if (self.window == nil && self.leftWindowHandler)
        self.leftWindowHandler();
}

@end

#pragma mark - View controller

@interface PreviewViewController : NSViewController <QLPreviewingController, ClipPlayerDelegate>
@end

@implementation PreviewViewController {
    PictureView *_picture;
    NSTextField *_caption;
    NSBox *_bar;
    NSButton *_playButton;
    NSSlider *_slider;
    NSTextField *_timeLabel;

    BRAWClip *_clip;
    ClipPlayer *_player;
    BOOL _scrubbing;
}

- (void)dealloc
{
    [_player stop];
}

- (void)loadView
{
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
    root.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    _picture = [[PictureView alloc] initWithFrame:root.bounds];
    _picture.translatesAutoresizingMaskIntoConstraints = NO;
    __weak PreviewViewController *weakSelf = self;
    _picture.clickHandler = ^{
        [weakSelf togglePlaying:nil];
    };
    _picture.leftWindowHandler = ^{
        PreviewViewController *strongSelf = weakSelf;
        if (strongSelf != nil)
            [strongSelf->_player pause]; // Quick Look closed or moved on: no sound left behind
    };

    _caption = Label();
    _caption.drawsBackground = YES;
    _caption.backgroundColor = [NSColor colorWithWhite:0 alpha:0.55];
    _caption.lineBreakMode = NSLineBreakByTruncatingTail;
    [_caption setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSBox *bar = [[NSBox alloc] init];
    bar.boxType = NSBoxCustom;
    bar.borderWidth = 0;
    bar.cornerRadius = 0;
    bar.fillColor = [NSColor colorWithWhite:0 alpha:0.6];
    bar.contentViewMargins = NSZeroSize;
    bar.titlePosition = NSNoTitle;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    _bar = bar;

    _playButton = [NSButton buttonWithImage:Symbol(@"play.fill", @"Play")
                                     target:self
                                     action:@selector(togglePlaying:)];
    _playButton.bordered = NO;
    _playButton.contentTintColor = NSColor.whiteColor;
    _playButton.translatesAutoresizingMaskIntoConstraints = NO;

    _slider = [NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(scrubbed:)];
    _slider.continuous = YES;
    _slider.controlSize = NSControlSizeSmall;
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [_slider setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    _timeLabel = Label();
    [_timeLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *row = [NSStackView stackViewWithViews:@[_playButton, _slider, _timeLabel]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.edgeInsets = NSEdgeInsetsMake(0, 8, 0, 10);
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [_bar.contentView addSubview:row];

    [root addSubview:_picture];
    [root addSubview:_caption];
    [root addSubview:_bar];

    [NSLayoutConstraint activateConstraints:@[
        [_picture.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_picture.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_picture.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_picture.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],

        [_caption.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:8],
        [_caption.topAnchor constraintEqualToAnchor:root.topAnchor constant:8],
        [_caption.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-8],

        [_bar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_bar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_bar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_bar.heightAnchor constraintEqualToConstant:kBarHeight],

        [row.leadingAnchor constraintEqualToAnchor:_bar.contentView.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:_bar.contentView.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:_bar.contentView.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:_bar.contentView.bottomAnchor],
        [_playButton.widthAnchor constraintEqualToConstant:20],
    ]];

    self.view = root;
}

- (void)preparePreviewOfFileAtURL:(NSURL *)url completionHandler:(void (^)(NSError *_Nullable))handler
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BRAWClip *clip = [BRAWClip clipWithURL:url error:&error];
        CGImageRef decoded = clip ? [clip decodeFrame:clip.posterFrameIndex minimumLongSide:1920 error:&error] : NULL;
        id poster = CFBridgingRelease(decoded);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (poster == nil) {
                handler(error);
                return;
            }
            [self showClip:clip poster:(__bridge CGImageRef)poster];
            handler(nil);
        });
    });
}

- (void)showClip:(BRAWClip *)clip poster:(CGImageRef)poster
{
    (void)self.view;
    _clip = clip;
    _picture.pictureLayer.contents = (__bridge id)poster;
    _caption.stringValue = Caption(clip);

    const BOOL playable = clip.frameCount > 1;
    _slider.maxValue = playable ? (double)(clip.frameCount - 1) : 1;
    _slider.doubleValue = clip.posterFrameIndex;
    _slider.enabled = playable;
    _playButton.enabled = playable;
    [self updateTimeLabel:clip.posterFrameIndex];

    _player = [[ClipPlayer alloc] initWithClip:clip startFrame:clip.posterFrameIndex];
    _player.delegate = self;
    [self updateDecodeSizes];

    // Ask for a Quick Look window in the clip's shape.
    const CGFloat aspect = clip.height > 0 ? (CGFloat)clip.width / clip.height : 16.0 / 9.0;
    self.preferredContentSize = aspect >= 16.0 / 9.0 ? NSMakeSize(1280, round(1280 / aspect))
                                                     : NSMakeSize(round(720 * aspect), 720);

    // Decide on autoplay once Quick Look has settled the view's size.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.view.window != nil && self.view.bounds.size.width >= kAutoplayMinimumWidth)
            [self->_player play];
    });
}

- (void)viewDidLayout
{
    [super viewDidLayout];
    [self updateDecodeSizes];
}

- (void)viewWillDisappear
{
    [super viewWillDisappear];
    [_player pause];
}

- (void)updateDecodeSizes
{
    if (_player == nil)
        return;
    const CGFloat backing = self.view.window.backingScaleFactor > 0 ? self.view.window.backingScaleFactor : 2;
    const NSSize size = self.view.bounds.size;
    const CGFloat pixels = MAX(MAX(size.width, size.height) * backing, 640);
    _player.playbackLongSide = MIN(pixels, kPlaybackMaximumLongSide);
    _player.stillLongSide = MIN(pixels, kStillMaximumLongSide);
}

- (void)updateTimeLabel:(uint64_t)frame
{
    const double fps = _clip.frameRate > 0 ? _clip.frameRate : 24;
    _timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@", FormatTime(frame / fps), FormatTime(_clip.frameCount / fps)];
}

- (IBAction)togglePlaying:(nullable id)sender
{
    [_player togglePlaying];
}

- (IBAction)scrubbed:(NSSlider *)sender
{
    const NSEventType type = NSApp.currentEvent.type;
    _scrubbing = type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseDragged;
    const uint64_t frame = (uint64_t)llround(MAX(sender.doubleValue, 0));
    [_player seekToFrame:frame];
    [self updateTimeLabel:frame];
}

#pragma mark ClipPlayerDelegate

- (void)player:(ClipPlayer *)player showImage:(CGImageRef)image frame:(uint64_t)frame
{
    if (player != _player)
        return;
    _picture.pictureLayer.contents = (__bridge id)image;
    if (!_scrubbing)
        _slider.doubleValue = frame;
    [self updateTimeLabel:frame];
}

- (void)playerDidChangeState:(ClipPlayer *)player
{
    if (player != _player)
        return;
    _playButton.image = player.playing ? Symbol(@"pause.fill", @"Pause") : Symbol(@"play.fill", @"Play");
}

@end
