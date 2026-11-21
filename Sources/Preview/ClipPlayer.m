#import "ClipPlayer.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <os/log.h>

#import "BRAWClip.h"

static os_log_t PlayerLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("BRAWPreview", "player");
    });
    return log;
}

#pragma mark - Sound

/// Streams the clip's own sound through AVAudioEngine in short chunks, looping, and reports how
/// far it has played: that position is the clock the picture follows.
@interface AudioFeeder : NSObject
- (nullable instancetype)initWithClip:(BRAWClip *)clip loopSeconds:(double)loopSeconds;
/// Starts (or restarts) playing at `seconds` into the clip.
- (void)playFrom:(double)seconds;
- (void)stop;
/// Seconds into the clip that are being heard now.
- (double)position;
- (void)shutDown;
@end

static inline float SampleValue(const uint8_t *s, uint32_t bytes)
{
    switch (bytes) {
    case 2:
        return (int16_t)(uint16_t)(s[0] | (s[1] << 8)) / 32768.0f;
    case 3: {
        int32_t v = (int32_t)((uint32_t)s[0] | ((uint32_t)s[1] << 8) | ((uint32_t)s[2] << 16));
        if (v & 0x800000)
            v -= 0x1000000;
        return v / 8388608.0f;
    }
    case 4:
        return (int32_t)((uint32_t)s[0] | ((uint32_t)s[1] << 8) | ((uint32_t)s[2] << 16) | ((uint32_t)s[3] << 24)) / 2147483648.0f;
    default:
        return 0;
    }
}

@implementation AudioFeeder {
    BRAWClip *_clip;
    AVAudioEngine *_engine;
    AVAudioPlayerNode *_node;
    AVAudioFormat *_format;
    dispatch_queue_t _queue;
    uint32_t _inChannels;
    uint32_t _outChannels;
    uint32_t _bytesPerSample;
    double _rate;
    uint64_t _loopSamples;
    uint32_t _chunkFrames;

    // Only used on _queue.
    uint64_t _nextSample;
    NSUInteger _generation;

    // Read by -position from the playback thread.
    os_unfair_lock _lock;
    uint64_t _segmentStart;
    BOOL _running;
    CFTimeInterval _playHostTime;
}

- (nullable instancetype)initWithClip:(BRAWClip *)clip loopSeconds:(double)loopSeconds
{
    if (clip.audioChannelCount == 0 || clip.audioSampleRate == 0 || clip.audioSampleCount == 0)
        return nil;
    if (!(self = [super init]))
        return nil;

    _clip = clip;
    _inChannels = clip.audioChannelCount;
    _outChannels = MIN(_inChannels, 2u); // cameras record the main pair on channels 1–2
    _bytesPerSample = clip.audioBitDepth / 8;
    _rate = clip.audioSampleRate;
    _loopSamples = clip.audioSampleCount;
    if (loopSeconds > 0)
        _loopSamples = MIN(_loopSamples, (uint64_t)llround(loopSeconds * _rate));
    if (_loopSamples == 0)
        return nil;
    _chunkFrames = (uint32_t)MAX(1024.0, _rate / 4); // a quarter of a second
    _lock = OS_UNFAIR_LOCK_INIT;
    _queue = dispatch_queue_create("BRAWPreview.audio", DISPATCH_QUEUE_SERIAL);

    @try {
        _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:_rate channels:_outChannels];
        _engine = [[AVAudioEngine alloc] init];
        _node = [[AVAudioPlayerNode alloc] init];
        [_engine attachNode:_node];
        [_engine connect:_node to:_engine.mainMixerNode format:_format];
        [_engine prepare];
        NSError *error = nil;
        if (_format == nil || ![_engine startAndReturnError:&error]) {
            os_log_error(PlayerLog(), "No sound: %{public}@", error.localizedDescription);
            return nil;
        }
        [_engine pause];
    } @catch (NSException *exception) {
        os_log_error(PlayerLog(), "No sound: %{public}@", exception.reason);
        return nil;
    }
    return self;
}

- (nullable AVAudioPCMBuffer *)readBufferAt:(uint64_t)start frames:(uint32_t)frames
{
    if (frames == 0)
        return nil;
    const uint32_t frameBytes = _inChannels * _bytesPerSample;
    NSMutableData *raw = [NSMutableData dataWithLength:(NSUInteger)frames * frameBytes];
    const uint32_t got = [_clip readAudioAtSampleFrame:start
                                                buffer:raw.mutableBytes
                                            bufferSize:(uint32_t)raw.length
                                             maxFrames:frames];
    if (got == 0)
        return nil;

    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format frameCapacity:got];
    if (buffer == nil)
        return nil;
    buffer.frameLength = got;
    float *const *out = buffer.floatChannelData;
    const uint8_t *in = raw.bytes;
    for (uint32_t i = 0; i < got; i++) {
        const uint8_t *frame = in + (size_t)i * frameBytes;
        for (uint32_t c = 0; c < _outChannels; c++)
            out[c][i] = SampleValue(frame + c * _bytesPerSample, _bytesPerSample);
    }
    return buffer;
}

/// On _queue. Keeps the node fed: each finished chunk schedules the next one.
- (void)scheduleChunk:(NSUInteger)generation
{
    if (generation != _generation)
        return;

    AVAudioPCMBuffer *buffer = nil;
    for (int attempt = 0; attempt < 2 && buffer == nil; attempt++) {
        const uint64_t start = _nextSample;
        const uint32_t count = (uint32_t)MIN((uint64_t)_chunkFrames, _loopSamples - start);
        buffer = [self readBufferAt:start frames:count];
        const uint32_t got = buffer != nil ? buffer.frameLength : 0;
        _nextSample = (got == 0 || start + got >= _loopSamples) ? 0 : start + got; // loop
        if (got == 0 && start == 0)
            return; // nothing readable at all
    }
    if (buffer == nil)
        return;

    __weak AudioFeeder *weakSelf = self;
    [_node scheduleBuffer:buffer completionHandler:^{
        AudioFeeder *strongSelf = weakSelf;
        if (strongSelf != nil) {
            dispatch_async(strongSelf->_queue, ^{
                [strongSelf scheduleChunk:generation];
            });
        }
    }];
}

- (void)playFrom:(double)seconds
{
    dispatch_async(_queue, ^{
        self->_generation++;
        [self->_node stop];
        if (!self->_engine.isRunning)
            [self->_engine startAndReturnError:nil];

        const uint64_t start = (uint64_t)llround(MAX(seconds, 0) * self->_rate) % self->_loopSamples;
        self->_nextSample = start;
        os_unfair_lock_lock(&self->_lock);
        self->_segmentStart = start;
        self->_running = YES;
        self->_playHostTime = CACurrentMediaTime();
        os_unfair_lock_unlock(&self->_lock);

        const NSUInteger generation = self->_generation;
        for (int i = 0; i < 4; i++)
            [self scheduleChunk:generation];
        [self->_node play];
    });
}

- (void)stop
{
    os_unfair_lock_lock(&_lock);
    _running = NO;
    os_unfair_lock_unlock(&_lock);
    dispatch_async(_queue, ^{
        self->_generation++;
        [self->_node stop];
        [self->_engine pause];
    });
}

- (void)shutDown
{
    os_unfair_lock_lock(&_lock);
    _running = NO;
    os_unfair_lock_unlock(&_lock);
    dispatch_sync(_queue, ^{
        self->_generation++;
        [self->_node stop];
        [self->_engine stop];
    });
}

- (double)position
{
    os_unfair_lock_lock(&_lock);
    const uint64_t start = _segmentStart;
    const BOOL running = _running;
    const CFTimeInterval playHostTime = _playHostTime;
    os_unfair_lock_unlock(&_lock);

    double played = 0;
    if (running) {
        AVAudioTime *nodeTime = _node.lastRenderTime;
        AVAudioTime *playerTime = nodeTime != nil ? [_node playerTimeForNodeTime:nodeTime] : nil;
        const CFTimeInterval sinceStart = CACurrentMediaTime() - playHostTime;
        if (playerTime != nil && playerTime.sampleTimeValid && playerTime.sampleTime > 0)
            played = playerTime.sampleTime;
        else if (sinceStart > 2.0)
            played = sinceStart * _rate; // the sound never started: follow the system clock instead
        // Otherwise the sound output is still starting up: hold at the start rather than run
        // ahead on the system clock and jump back once the sound is heard.
    }
    return fmod(start + played, (double)_loopSamples) / _rate;
}

@end

#pragma mark - Picture

typedef NS_ENUM(NSInteger, DecodeKind) {
    DecodeKindPlay,
    DecodeKindSeek,
    DecodeKindSharp,
};

@implementation ClipPlayer {
    NSCondition *_condition;
    AudioFeeder *_audio;
    double _fps;
    double _duration;

    // Guarded by _condition.
    BOOL _isPlaying;
    BOOL _stopped;
    BOOL _needsSharp;
    int64_t _seekTarget;        // -1: none
    uint64_t _sharpFrame;
    uint64_t _lastShownFrame;   // UINT64_MAX: none yet
    double _pausedSeconds;
    double _startSeconds;
    CFTimeInterval _startHostTime;
    double _lastClock;          // -1: the clock may go anywhere next (after play or seek)

    // Playback thread only.
    double _averageDecode;
    int _slowFrames;
    CGFloat _speedCap;
}

- (instancetype)initWithClip:(BRAWClip *)clip startFrame:(uint64_t)frame
{
    if (!(self = [super init]))
        return nil;
    _clip = clip;
    _fps = clip.frameRate > 0 ? clip.frameRate : 24;
    _duration = MAX(clip.frameCount, 1) / _fps;
    _condition = [[NSCondition alloc] init];
    _seekTarget = -1;
    _lastClock = -1;
    _lastShownFrame = frame;
    _pausedSeconds = frame / _fps;
    _playbackLongSide = 1280;
    _stillLongSide = 1920;
    _averageDecode = 1 / _fps;
    _speedCap = CGFLOAT_MAX;
    _audio = [[AudioFeeder alloc] initWithClip:clip loopSeconds:_duration];

    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
    thread.name = @"BRAW playback";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start]; // the thread keeps the player alive until -stop
    return self;
}

- (BOOL)isPlaying
{
    [_condition lock];
    const BOOL playing = _isPlaying;
    [_condition unlock];
    return playing;
}

- (BOOL)hasSound
{
    return _audio != nil;
}

/// Seconds into the clip. Call with _condition locked.
- (double)clockLocked
{
    if (!_isPlaying)
        return _pausedSeconds;
    double now = _audio != nil ? [_audio position]
                               : fmod(_startSeconds + (CACurrentMediaTime() - _startHostTime), _duration);
    // Never step backwards by a little (that shows as the picture jumping back); a big step
    // back is the loop starting over.
    if (_lastClock >= 0 && now < _lastClock && _lastClock - now < _duration / 2)
        now = _lastClock;
    _lastClock = now;
    return now;
}

- (void)notifyState
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate playerDidChangeState:self];
    });
}

- (void)play
{
    [_condition lock];
    if (!_isPlaying && !_stopped && _clip.frameCount > 1) {
        _isPlaying = YES;
        _seekTarget = -1;
        _needsSharp = NO;
        _startSeconds = _pausedSeconds;
        _startHostTime = CACurrentMediaTime();
        _lastClock = -1;
        [_audio playFrom:_pausedSeconds];
    }
    [_condition broadcast];
    [_condition unlock];
    [self notifyState];
}

- (void)pause
{
    [_condition lock];
    if (_isPlaying) {
        const uint64_t frame = _lastShownFrame != UINT64_MAX ? _lastShownFrame : (uint64_t)([self clockLocked] * _fps);
        _isPlaying = NO;
        [_audio stop];
        _pausedSeconds = frame / _fps;
        _sharpFrame = frame;
        _needsSharp = YES;
    }
    [_condition broadcast];
    [_condition unlock];
    [self notifyState];
}

- (void)togglePlaying
{
    if (self.playing)
        [self pause];
    else
        [self play];
}

- (void)seekToFrame:(uint64_t)frame
{
    if (_clip.frameCount == 0)
        return;
    frame = MIN(frame, _clip.frameCount - 1);
    [_condition lock];
    _pausedSeconds = frame / _fps;
    if (_isPlaying) {
        _startSeconds = _pausedSeconds;
        _startHostTime = CACurrentMediaTime();
        _lastClock = -1;
        [_audio playFrom:_pausedSeconds];
    } else {
        _seekTarget = (int64_t)frame;
        _needsSharp = NO;
    }
    [_condition broadcast];
    [_condition unlock];
}

- (void)stop
{
    [_condition lock];
    _stopped = YES;
    _isPlaying = NO;
    [_condition broadcast];
    [_condition unlock];
}

/// Waits (at most a little) until `frame` is due, waking early on pause, seek or stop.
- (void)waitForFrame:(uint64_t)frame
{
    [_condition lock];
    const double wait = MIN(MAX(frame / _fps - [self clockLocked], 0.002), 0.1);
    [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:wait]];
    [_condition unlock];
}

- (void)noteDecodeTime:(CFTimeInterval)seconds
{
    _averageDecode = _averageDecode * 0.8 + seconds * 0.2;
    if (_averageDecode > 1.3 / _fps) {
        // Can't keep up: decode smaller (the SDK then decodes at 1/2, 1/4 or 1/8 resolution).
        if (++_slowFrames >= 12 && MIN(self.playbackLongSide, _speedCap) > 480) {
            _speedCap = MAX(480, MIN(self.playbackLongSide, _speedCap) / 2);
            _slowFrames = 0;
            os_log_info(PlayerLog(), "Decoding too slowly (%.0f ms per frame), now at %.0f px", _averageDecode * 1000, _speedCap);
        }
    } else {
        _slowFrames = 0;
    }
}

- (void)run
{
    const uint64_t frameCount = MAX(_clip.frameCount, 1);
    while (YES) {
        @autoreleasepool {
            [_condition lock];
            while (!_stopped && !_isPlaying && _seekTarget < 0 && !_needsSharp)
                [_condition wait];
            if (_stopped) {
                [_condition unlock];
                break;
            }

            DecodeKind kind;
            uint64_t frame;
            CGFloat longSide;
            if (_isPlaying) {
                kind = DecodeKindPlay;
                // Aim at the frame that will be due once it's decoded.
                const double target = fmod([self clockLocked] + _averageDecode, _duration);
                frame = MIN((uint64_t)floor(target * _fps), frameCount - 1);
                longSide = MIN(self.playbackLongSide, _speedCap);
            } else if (_seekTarget >= 0) {
                kind = DecodeKindSeek;
                frame = (uint64_t)_seekTarget;
                _seekTarget = -1;
                _sharpFrame = frame;
                _needsSharp = YES; // once scrubbing settles
                longSide = MIN(self.playbackLongSide, _speedCap);
            } else {
                kind = DecodeKindSharp;
                frame = _sharpFrame;
                _needsSharp = NO;
                longSide = self.stillLongSide;
            }
            const uint64_t lastShown = _lastShownFrame;
            [_condition unlock];

            if (kind == DecodeKindPlay && frame == lastShown) {
                [self waitForFrame:frame + 1];
                continue;
            }

            const CFTimeInterval began = CACurrentMediaTime();
            NSError *error = nil;
            CGImageRef image = [_clip decodeFrame:frame minimumLongSide:longSide error:&error];
            if (image == NULL) {
                if (kind == DecodeKindPlay)
                    [NSThread sleepForTimeInterval:0.05]; // don't spin on a broken frame
                continue;
            }

            if (kind == DecodeKindPlay) {
                [self noteDecodeTime:CACurrentMediaTime() - began];
                [_condition lock];
                const double early = frame / _fps - [self clockLocked];
                if (_isPlaying && early > 0 && early < 0.25)
                    [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:early]];
                const BOOL stillPlaying = _isPlaying;
                [_condition unlock];
                if (!stillPlaying) { // paused meanwhile: the sharp still takes over
                    CGImageRelease(image);
                    continue;
                }
            }

            [_condition lock];
            _lastShownFrame = frame;
            [_condition unlock];

            id object = CFBridgingRelease(image);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate player:self showImage:(__bridge CGImageRef)object frame:frame];
            });
        }
    }
    [_audio shutDown];
}

@end
