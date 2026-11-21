#import "BRAWClip.h"

// Blackmagic RAW SDK 6 added ReadAudioComplete() to IBlackmagicRawCallback. Declaring the type
// here lets the callback below implement it whatever SDK version we are compiled against: with
// SDK 6 it overrides the new pure virtual method, with older SDKs it is an unused extra method.
class IBlackmagicRawAudioBuffer;
#include "BlackmagicRawAPI.h"

#import <os/log.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

NSErrorDomain const BRAWErrorDomain = @"BRAWErrorDomain";

static os_log_t BRAWLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("BRAWPreview", "decoder");
    });
    return log;
}

static NSError *BRAWMakeError(NSInteger code, NSString *message, HRESULT result)
{
    os_log_error(BRAWLog(), "%{public}@ (HRESULT 0x%08x)", message, (unsigned)result);
    return [NSError errorWithDomain:BRAWErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

namespace {

/// One frame decode, handed through the SDK's asynchronous jobs as user data. Two owners: the
/// thread waiting for it and the SDK callback; whichever lets go last deletes it, so a decode
/// that outlives a timeout can't write into freed memory.
struct FrameRequest {
    std::atomic<int> references{2};
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    BlackmagicRawResolutionScale scale = blackmagicRawResolutionScaleFull;
    IBlackmagicRawClipProcessingAttributes *clipAttributes = nullptr; // one reference held
    HRESULT result = E_FAIL;
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> pixels; // RGBA, 8 bits per channel, rows of width * 4 bytes

    ~FrameRequest()
    {
        if (clipAttributes != nullptr)
            clipAttributes->Release();
    }

    void Release()
    {
        if (references.fetch_sub(1) == 1)
            delete this;
    }

    /// Called once by the SDK side, with the callback's reference.
    void Finish(HRESULT finalResult)
    {
        result = finalResult;
        dispatch_semaphore_signal(done);
        Release();
    }
};

FrameRequest *RequestOf(IBlackmagicRawJob *job)
{
    void *userData = nullptr;
    if (job != nullptr && SUCCEEDED(job->GetUserData(&userData)))
        return static_cast<FrameRequest *>(userData);
    return nullptr;
}

/// Tries `wanted` first, then each larger decode size, as not every clip offers every scale.
void SetResolutionScale(IBlackmagicRawFrame *frame, BlackmagicRawResolutionScale wanted)
{
    const BlackmagicRawResolutionScale scales[] = {
        blackmagicRawResolutionScaleEighth,
        blackmagicRawResolutionScaleQuarter,
        blackmagicRawResolutionScaleHalf,
        blackmagicRawResolutionScaleFull,
    };
    bool reached = false;
    for (BlackmagicRawResolutionScale scale : scales) {
        reached = reached || scale == wanted;
        if (reached && SUCCEEDED(frame->SetResolutionScale(scale)))
            return;
    }
}

// Deliberately no `override` keywords: the set of pure virtual methods differs between SDK
// versions, and methods the compiled-against header does not declare are simply extra.
class Callback : public IBlackmagicRawCallback {
public:
    virtual ~Callback() = default;

    virtual void ReadComplete(IBlackmagicRawJob *readJob, HRESULT result, IBlackmagicRawFrame *frame)
    {
        FrameRequest *request = RequestOf(readJob);
        if (request != nullptr) {
            IBlackmagicRawJob *decodeJob = nullptr;
            if (SUCCEEDED(result)) {
                SetResolutionScale(frame, request->scale);
                result = frame->SetResourceFormat(blackmagicRawResourceFormatRGBAU8);
            }
            if (SUCCEEDED(result))
                result = frame->CreateJobDecodeAndProcessFrame(request->clipAttributes, nullptr, &decodeJob);
            if (SUCCEEDED(result))
                result = decodeJob->SetUserData(request);
            if (SUCCEEDED(result))
                result = decodeJob->Submit();
            if (FAILED(result)) {
                // ProcessComplete() will not run for this frame.
                if (decodeJob != nullptr)
                    decodeJob->Release();
                request->Finish(result);
            }
        }
        readJob->Release();
    }

    virtual void ProcessComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawProcessedImage *image)
    {
        FrameRequest *request = RequestOf(job);
        if (request != nullptr) {
            uint32_t width = 0;
            uint32_t height = 0;
            uint32_t sizeBytes = 0;
            void *resource = nullptr;
            BlackmagicRawResourceType type = 0;

            if (SUCCEEDED(result))
                result = image->GetWidth(&width);
            if (SUCCEEDED(result))
                result = image->GetHeight(&height);
            if (SUCCEEDED(result))
                result = image->GetResourceType(&type);
            if (SUCCEEDED(result) && type != blackmagicRawResourceTypeBufferCPU)
                result = E_UNEXPECTED;
            if (SUCCEEDED(result))
                result = image->GetResourceSizeBytes(&sizeBytes);
            if (SUCCEEDED(result))
                result = image->GetResource(&resource);

            const size_t needed = (size_t)width * height * 4;
            if (SUCCEEDED(result) && (needed == 0 || resource == nullptr || sizeBytes < needed))
                result = E_FAIL;
            if (SUCCEEDED(result)) {
                const uint8_t *bytes = static_cast<const uint8_t *>(resource);
                request->pixels.assign(bytes, bytes + needed);
                request->width = width;
                request->height = height;
            }
            request->Finish(result);
        }
        job->Release();
    }

    virtual void ReadAudioComplete(IBlackmagicRawJob *, HRESULT, IBlackmagicRawAudioBuffer *) {}
    virtual void DecodeComplete(IBlackmagicRawJob *, HRESULT) {}
    virtual void TrimProgress(IBlackmagicRawJob *, float) {}
    virtual void TrimComplete(IBlackmagicRawJob *, HRESULT) {}
    virtual void SidecarMetadataParseWarning(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) {}
    virtual void SidecarMetadataParseError(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) {}
    virtual void PreparePipelineComplete(void *, HRESULT) {}

    virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, LPVOID *object)
    {
        if (object == nullptr)
            return E_POINTER;
        const CFUUIDBytes unknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (std::memcmp(&iid, &IID_IBlackmagicRawCallback, sizeof(CFUUIDBytes)) == 0 ||
            std::memcmp(&iid, &unknown, sizeof(CFUUIDBytes)) == 0) {
            *object = this;
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }

    // The callback is a static object that outlives the codec: no reference counting needed.
    virtual ULONG STDMETHODCALLTYPE AddRef(void) { return 1; }
    virtual ULONG STDMETHODCALLTYPE Release(void) { return 1; }
};

std::mutex gCodecMutex;
IBlackmagicRawFactory *gFactory = nullptr;
IBlackmagicRaw *gCodec = nullptr;
Callback gCallback;

/// Loads the SDK (once). Must be called with gCodecMutex held.
HRESULT StartCodec()
{
    if (gCodec != nullptr)
        return S_OK;

    if (gFactory == nullptr) {
        // install.sh puts a copy of BlackmagicRawAPI.framework into each extension's own
        // Contents/Frameworks: a Quick Look extension's sandbox can't load it from elsewhere,
        // and the copy is the exact version this code was compiled against.
        NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
        if (frameworks != nil)
            gFactory = CreateBlackmagicRawFactoryInstanceFromPath((__bridge CFStringRef)frameworks);
        if (gFactory == nullptr)
            return E_FAIL;
    }

    HRESULT result = gFactory->CreateCodec(&gCodec);
    if (SUCCEEDED(result))
        result = gCodec->SetCallback(&gCallback);
    if (FAILED(result) && gCodec != nullptr) {
        gCodec->Release();
        gCodec = nullptr;
    }
    return result;
}

/// Bounds how many frames decode at once (Finder asks for many thumbnails in parallel).
dispatch_semaphore_t DecodeSlots()
{
    static dispatch_semaphore_t slots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        slots = dispatch_semaphore_create(3);
    });
    return slots;
}

NSString *StringAttribute(IBlackmagicRawClipProcessingAttributes *attributes, BlackmagicRawClipProcessingAttribute attribute)
{
    Variant value;
    VariantInit(&value);
    NSString *text = nil;
    if (SUCCEEDED(attributes->GetClipAttribute(attribute, &value)) &&
        value.vt == blackmagicRawVariantTypeString && value.bstrVal != nullptr)
        text = [(__bridge NSString *)value.bstrVal copy];
    VariantClear(&value);
    return text.length > 0 ? text : nil;
}

NSArray<NSString *> *OfferedValues(IBlackmagicRawClipProcessingAttributes *attributes,
                                   BlackmagicRawClipProcessingAttribute attribute)
{
    uint32_t count = 0;
    bool readOnly = false;
    if (FAILED(attributes->GetClipAttributeList(attribute, nullptr, &count, &readOnly)) || count == 0 || readOnly)
        return @[];

    std::vector<Variant> values(count);
    for (Variant &value : values)
        VariantInit(&value);

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (SUCCEEDED(attributes->GetClipAttributeList(attribute, values.data(), &count, &readOnly))) {
        for (uint32_t i = 0; i < count && i < values.size(); i++) {
            if (values[i].vt == blackmagicRawVariantTypeString && values[i].bstrVal != nullptr)
                [names addObject:[(__bridge NSString *)values[i].bstrVal copy]];
        }
    }
    for (Variant &value : values)
        VariantClear(&value);
    return names;
}

/// Sets the attribute to the first of `preferred` that the clip offers. Returns the value set.
NSString *SetFirstOffered(IBlackmagicRawClipProcessingAttributes *attributes,
                          BlackmagicRawClipProcessingAttribute attribute,
                          NSArray<NSString *> *preferred)
{
    NSArray<NSString *> *offered = OfferedValues(attributes, attribute);
    for (NSString *wanted in preferred) {
        for (NSString *name in offered) {
            if ([name caseInsensitiveCompare:wanted] != NSOrderedSame)
                continue;
            Variant value;
            VariantInit(&value);
            value.vt = blackmagicRawVariantTypeString;
            value.bstrVal = (__bridge CFStringRef)name;
            // No VariantClear(): the string still belongs to `name`.
            if (SUCCEEDED(attributes->SetClipAttribute(attribute, &value)))
                return name;
        }
    }
    return nil;
}

BOOL Contains(NSString *text, NSString *part)
{
    return text != nil && [text rangeOfString:part options:NSCaseInsensitiveSearch].location != NSNotFound;
}

NSString *ShortGammaName(NSString *gamma)
{
    return [gamma stringByReplacingOccurrencesOfString:@"Blackmagic Design " withString:@""];
}

/// Picks how frames are developed, changing `attributes` accordingly. Returns a description.
NSString *ChooseLook(IBlackmagicRawClipProcessingAttributes *attributes)
{
    NSString *lutMode = StringAttribute(attributes, blackmagicRawClipProcessingAttributePost3DLUTMode);
    NSString *embeddedLUT = StringAttribute(attributes, blackmagicRawClipProcessingAttributeEmbeddedPost3DLUTTitle)
                                ?: StringAttribute(attributes, blackmagicRawClipProcessingAttributeEmbeddedPost3DLUTName);

    // 1. A LUT already applied to the clip: keep the clip exactly as it is.
    if (Contains(lutMode, @"embed") || Contains(lutMode, @"sidecar")) {
        NSString *name = Contains(lutMode, @"embed") ? embeddedLUT : nil;
        return [NSString stringWithFormat:@"LUT: %@", name ?: lutMode];
    }

    // 2. A LUT the camera embedded in the clip but that isn't switched on: use it.
    if (embeddedLUT != nil && SetFirstOffered(attributes, blackmagicRawClipProcessingAttributePost3DLUTMode, @[@"Embedded"]) != nil)
        return [NSString stringWithFormat:@"LUT: %@", embeddedLUT];

    // 3. Log footage looks flat and grey: develop it the way the camera's monitor shows it.
    NSString *gamma = StringAttribute(attributes, blackmagicRawClipProcessingAttributeGamma);
    if (Contains(gamma, @"Film")) {
        NSString *video = SetFirstOffered(attributes, blackmagicRawClipProcessingAttributeGamma,
                                          @[@"Blackmagic Design Extended Video", @"Blackmagic Design Video", @"Rec.709"]);
        if (video != nil) {
            // The gamut list can depend on the gamma, so it is read after the gamma is set.
            SetFirstOffered(attributes, blackmagicRawClipProcessingAttributeGamut, @[@"Rec.709"]);
            return [NSString stringWithFormat:@"%@ → %@", ShortGammaName(gamma), ShortGammaName(video)];
        }
    }

    // 4. Anything else (Video, Extended Video, custom curves…) is shown as shot.
    return gamma != nil ? ShortGammaName(gamma) : @"";
}

NSString *CameraType(IBlackmagicRawClip *clip)
{
    Variant value;
    VariantInit(&value);
    NSString *camera = nil;
    if (SUCCEEDED(clip->GetMetadata(CFSTR("camera_type"), &value)) &&
        value.vt == blackmagicRawVariantTypeString && value.bstrVal != nullptr)
        camera = [(__bridge NSString *)value.bstrVal copy];
    VariantClear(&value);
    return camera;
}

BlackmagicRawResolutionScale ScaleFor(uint32_t clipLongSide, CGFloat wanted)
{
    if (wanted > 0 && clipLongSide > 0) {
        if (clipLongSide / 8.0 >= wanted)
            return blackmagicRawResolutionScaleEighth;
        if (clipLongSide / 4.0 >= wanted)
            return blackmagicRawResolutionScaleQuarter;
        if (clipLongSide / 2.0 >= wanted)
            return blackmagicRawResolutionScaleHalf;
    }
    return blackmagicRawResolutionScaleFull;
}

CGImageRef CreateImage(const FrameRequest &request)
{
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, request.pixels.data(), (CFIndex)request.pixels.size());
    CGDataProviderRef provider = data != nullptr ? CGDataProviderCreateWithCFData(data) : nullptr;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    CGImageRef image = nullptr;
    if (provider != nullptr && space != nullptr)
        image = CGImageCreate(request.width, request.height, 8, 32, (size_t)request.width * 4, space,
                              (CGBitmapInfo)kCGImageAlphaNoneSkipLast, provider, nullptr, true,
                              kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    if (data != nullptr)
        CFRelease(data);
    return image;
}

} // namespace

@implementation BRAWClip {
    IBlackmagicRawClip *_clip;
    IBlackmagicRawClipProcessingAttributes *_attributes;
    IBlackmagicRawClipAudio *_audio;
    std::mutex _audioMutex;
}

+ (nullable instancetype)clipWithURL:(NSURL *)url error:(NSError **)error
{
    IBlackmagicRawClip *clip = nullptr;
    HRESULT result;
    {
        std::lock_guard<std::mutex> lock(gCodecMutex);
        result = StartCodec();
        if (FAILED(result)) {
            if (error)
                *error = BRAWMakeError(1, @"The Blackmagic RAW decoder could not be loaded. Run install.sh again.", result);
            return nil;
        }
        result = gCodec->OpenClip((__bridge CFStringRef)url.path, &clip);
    }
    if (FAILED(result) || clip == nullptr) {
        if (error)
            *error = BRAWMakeError(2, [NSString stringWithFormat:@"Could not open %@.", url.lastPathComponent], result);
        return nil;
    }
    return [[self alloc] initWithClip:clip url:url];
}

- (instancetype)initWithClip:(IBlackmagicRawClip *)clip url:(NSURL *)url
{
    if (!(self = [super init])) {
        clip->Release();
        return nil;
    }
    _clip = clip;
    _url = [url copy];

    float frameRate = 0;
    clip->GetWidth(&_width);
    clip->GetHeight(&_height);
    clip->GetFrameRate(&frameRate);
    clip->GetFrameCount(&_frameCount);
    _frameRate = (std::isfinite(frameRate) && frameRate > 0 && frameRate < 10000) ? frameRate : 0;
    _cameraType = CameraType(clip);
    _posterFrameIndex = _frameCount > 0 ? std::min<uint64_t>((uint64_t)std::llround(_frameRate), _frameCount - 1) : 0;

    _lookDescription = @"";
    if (SUCCEEDED(clip->CloneClipProcessingAttributes(&_attributes)) && _attributes != nullptr)
        _lookDescription = ChooseLook(_attributes);

    if (SUCCEEDED(clip->QueryInterface(IID_IBlackmagicRawClipAudio, (LPVOID *)&_audio)) && _audio != nullptr) {
        BlackmagicRawAudioFormat format = 0;
        uint32_t channels = 0, rate = 0, bits = 0;
        uint64_t samples = 0;
        _audio->GetAudioFormat(&format);
        _audio->GetAudioChannelCount(&channels);
        _audio->GetAudioSampleRate(&rate);
        _audio->GetAudioBitDepth(&bits);
        _audio->GetAudioSampleCount(&samples);
        if (format == blackmagicRawAudioFormatPCMLittleEndian && channels > 0 && rate > 0 && samples > 0 &&
            (bits == 16 || bits == 24 || bits == 32)) {
            _audioChannelCount = channels;
            _audioSampleRate = rate;
            _audioBitDepth = bits;
            _audioSampleCount = samples;
        }
    } else {
        _audio = nullptr;
    }

    os_log_info(BRAWLog(), "Opened %{public}@: %ux%u, %.3f fps, %llu frames, look \"%{public}@\", audio %u ch",
                _url.lastPathComponent, _width, _height, _frameRate, _frameCount, _lookDescription, _audioChannelCount);
    return self;
}

- (void)dealloc
{
    if (_audio != nullptr)
        _audio->Release();
    if (_attributes != nullptr)
        _attributes->Release();
    if (_clip != nullptr)
        _clip->Release();
}

- (nullable CGImageRef)decodeFrame:(uint64_t)frameIndex minimumLongSide:(CGFloat)minimumLongSide error:(NSError **)error
{
    if (_frameCount == 0) {
        if (error)
            *error = BRAWMakeError(3, [NSString stringWithFormat:@"%@ has no frames.", _url.lastPathComponent], E_FAIL);
        return nil;
    }
    frameIndex = std::min(frameIndex, _frameCount - 1);

    dispatch_semaphore_wait(DecodeSlots(), DISPATCH_TIME_FOREVER);

    FrameRequest *request = new FrameRequest();
    request->scale = ScaleFor(std::max(_width, _height), minimumLongSide);
    if (_attributes != nullptr) {
        _attributes->AddRef();
        request->clipAttributes = _attributes;
    }

    IBlackmagicRawJob *readJob = nullptr;
    HRESULT result = _clip->CreateJobReadFrame(frameIndex, &readJob);
    if (SUCCEEDED(result))
        result = readJob->SetUserData(request);
    if (SUCCEEDED(result))
        result = readJob->Submit();

    BOOL timedOut = NO;
    if (FAILED(result)) {
        // The read never started, so neither the callback nor ReadComplete() will run.
        if (readJob != nullptr)
            readJob->Release();
        request->Release();
    } else if (dispatch_semaphore_wait(request->done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0) {
        result = request->result;
    } else {
        timedOut = YES;
        result = E_FAIL;
    }

    dispatch_semaphore_signal(DecodeSlots());

    CGImageRef image = nullptr;
    if (SUCCEEDED(result))
        image = CreateImage(*request);
    request->Release();

    if (image == nullptr && error) {
        NSString *what = timedOut ? @"Timed out decoding" : @"Could not decode";
        *error = BRAWMakeError(4, [NSString stringWithFormat:@"%@ frame %llu of %@.", what, frameIndex, _url.lastPathComponent], result);
    }
    return image;
}

- (uint32_t)readAudioAtSampleFrame:(uint64_t)sampleFrame buffer:(void *)buffer bufferSize:(uint32_t)bufferSize maxFrames:(uint32_t)maxFrames
{
    if (_audio == nullptr || _audioChannelCount == 0 || sampleFrame >= _audioSampleCount)
        return 0;
    const uint32_t frameBytes = _audioChannelCount * (_audioBitDepth / 8);
    maxFrames = std::min(maxFrames, bufferSize / frameBytes);
    if (maxFrames == 0)
        return 0;

    uint32_t samplesRead = 0;
    uint32_t bytesRead = 0;
    std::lock_guard<std::mutex> lock(_audioMutex);
    if (FAILED(_audio->GetAudioSamples((int64_t)sampleFrame, buffer, bufferSize, maxFrames, &samplesRead, &bytesRead)))
        return 0;
    if (bytesRead > 0)
        samplesRead = std::min(samplesRead, bytesRead / frameBytes);
    return std::min(samplesRead, maxFrames);
}

@end
