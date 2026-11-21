#import "BRAWDecoder.h"

// Blackmagic RAW SDK 6 added ReadAudioComplete() to IBlackmagicRawCallback. Declaring the type
// here lets the callback below implement it whatever SDK version we are compiled against: with
// SDK 6 it overrides the new pure virtual method, with older SDKs it is an unused extra method.
class IBlackmagicRawAudioBuffer;
#include "BlackmagicRawAPI.h"

#import <os/log.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

NSErrorDomain const BRAWDecoderErrorDomain = @"BRAWDecoderErrorDomain";

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
    return [NSError errorWithDomain:BRAWDecoderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface BRAWPoster ()
- (instancetype)initWithImage:(CGImageRef)image
                    clipWidth:(uint32_t)clipWidth
                   clipHeight:(uint32_t)clipHeight
                    frameRate:(float)frameRate
                   frameCount:(uint64_t)frameCount
                   frameIndex:(uint64_t)frameIndex
                   cameraType:(nullable NSString *)cameraType;
@end

@implementation BRAWPoster

- (instancetype)initWithImage:(CGImageRef)image
                    clipWidth:(uint32_t)clipWidth
                   clipHeight:(uint32_t)clipHeight
                    frameRate:(float)frameRate
                   frameCount:(uint64_t)frameCount
                   frameIndex:(uint64_t)frameIndex
                   cameraType:(nullable NSString *)cameraType
{
    if ((self = [super init])) {
        _image = CGImageRetain(image);
        _clipWidth = clipWidth;
        _clipHeight = clipHeight;
        _frameRate = frameRate;
        _frameCount = frameCount;
        _frameIndex = frameIndex;
        _cameraType = [cameraType copy];
    }
    return self;
}

- (void)dealloc
{
    CGImageRelease(_image);
}

@end

namespace {

/// State of one frame decode, passed through the SDK's asynchronous jobs as user data.
struct FrameRequest {
    BlackmagicRawResolutionScale scale = blackmagicRawResolutionScaleFull;
    IBlackmagicRawClipProcessingAttributes *clipAttributes = nullptr;
    HRESULT result = E_FAIL;
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> pixels; // RGBA, 8 bits per channel, rows of width * 4 bytes
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
        IBlackmagicRawJob *decodeJob = nullptr;

        if (request == nullptr)
            result = E_UNEXPECTED;
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
            // ProcessComplete() will not be called for this frame.
            if (decodeJob != nullptr)
                decodeJob->Release();
            if (request != nullptr)
                request->result = result;
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
            request->result = result;
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

std::mutex gMutex;
IBlackmagicRawFactory *gFactory = nullptr;
IBlackmagicRaw *gCodec = nullptr;
Callback gCallback;

/// Loads the SDK (once). Must be called with gMutex held.
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

/// Sets the attribute to the first of `preferred` that the clip offers; otherwise leaves it.
void SetFirstOffered(IBlackmagicRawClipProcessingAttributes *attributes,
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
                return;
        }
    }
}

/// Log footage ("Blackmagic Design Film") looks flat and grey as a thumbnail. Develop it the way
/// the camera's monitor shows it instead: (Extended) Video gamma in Rec.709.
void ApplyDisplayLook(IBlackmagicRawClipProcessingAttributes *attributes)
{
    SetFirstOffered(attributes, blackmagicRawClipProcessingAttributeGamma,
                    @[@"Blackmagic Design Extended Video", @"Blackmagic Design Video", @"Rec.709"]);
    // The gamut list can depend on the gamma, so it is read after the gamma is set.
    SetFirstOffered(attributes, blackmagicRawClipProcessingAttributeGamut, @[@"Rec.709"]);
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

@implementation BRAWDecoder

+ (nullable BRAWPoster *)posterForURL:(NSURL *)url minimumLongSide:(CGFloat)minimumLongSide error:(NSError **)error
{
    std::lock_guard<std::mutex> lock(gMutex);

    HRESULT result = StartCodec();
    if (FAILED(result)) {
        if (error)
            *error = BRAWMakeError(1, @"The Blackmagic RAW decoder could not be loaded. Run install.sh again.", result);
        return nil;
    }

    IBlackmagicRawClip *clip = nullptr;
    result = gCodec->OpenClip((__bridge CFStringRef)url.path, &clip);
    if (FAILED(result) || clip == nullptr) {
        if (error)
            *error = BRAWMakeError(2, [NSString stringWithFormat:@"Could not open %@.", url.lastPathComponent], result);
        return nil;
    }

    uint32_t width = 0;
    uint32_t height = 0;
    float frameRate = 0;
    uint64_t frameCount = 0;
    clip->GetWidth(&width);
    clip->GetHeight(&height);
    clip->GetFrameRate(&frameRate);
    clip->GetFrameCount(&frameCount);
    if (!std::isfinite(frameRate) || frameRate < 0 || frameRate > 10000)
        frameRate = 0;
    NSString *camera = CameraType(clip);

    if (frameCount == 0) {
        clip->Release();
        if (error)
            *error = BRAWMakeError(3, [NSString stringWithFormat:@"%@ has no frames.", url.lastPathComponent], E_FAIL);
        return nil;
    }

    // About one second in: the very first frames are often still settling (exposure, focus).
    const uint64_t frameIndex = std::min<uint64_t>((uint64_t)std::llround(frameRate), frameCount - 1);

    FrameRequest request;
    request.scale = ScaleFor(std::max(width, height), minimumLongSide);

    IBlackmagicRawClipProcessingAttributes *attributes = nullptr;
    if (SUCCEEDED(clip->CloneClipProcessingAttributes(&attributes)) && attributes != nullptr) {
        ApplyDisplayLook(attributes);
        request.clipAttributes = attributes;
    }

    IBlackmagicRawJob *readJob = nullptr;
    result = clip->CreateJobReadFrame(frameIndex, &readJob);
    if (SUCCEEDED(result))
        result = readJob->SetUserData(&request);
    if (SUCCEEDED(result))
        result = readJob->Submit();
    if (FAILED(result)) {
        // The read never started, so ReadComplete() will not release the job.
        if (readJob != nullptr)
            readJob->Release();
    } else {
        // Blocks until the read and the decode it starts have both finished.
        gCodec->FlushJobs();
        result = request.result;
    }

    if (attributes != nullptr)
        attributes->Release();
    clip->Release();

    if (FAILED(result)) {
        if (error)
            *error = BRAWMakeError(4, [NSString stringWithFormat:@"Could not decode %@.", url.lastPathComponent], result);
        return nil;
    }

    CGImageRef image = CreateImage(request);
    if (image == nullptr) {
        if (error)
            *error = BRAWMakeError(5, @"Could not create the image.", E_FAIL);
        return nil;
    }

    BRAWPoster *poster = [[BRAWPoster alloc] initWithImage:image
                                                 clipWidth:width
                                                clipHeight:height
                                                 frameRate:frameRate
                                                frameCount:frameCount
                                                frameIndex:frameIndex
                                                cameraType:camera];
    CGImageRelease(image);
    os_log_info(BRAWLog(), "Decoded frame %llu of %{public}@ at %ux%u", frameIndex, url.lastPathComponent,
                (unsigned)request.width, (unsigned)request.height);
    return poster;
}

@end
