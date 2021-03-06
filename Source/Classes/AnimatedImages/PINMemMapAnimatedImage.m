//
//  PINMemMapAnimatedImage.m
//  Pods
//
//  Created by Garrett Moon on 3/18/16.
//
//

#import "PINMemMapAnimatedImage.h"

#import "PINRemoteLock.h"
#import "PINGIFAnimatedImageManager.h"

#import "NSData+ImageDetectors.h"

static const size_t kPINAnimatedImageBitsPerComponent = 8;

@class PINSharedAnimatedImage;

@interface PINMemMapAnimatedImage ()
{
  PINRemoteLock *_completionLock;
  PINRemoteLock *_dataLock;
  
  NSData *_currentData;
  NSData *_nextData;
}

@property (atomic, strong, readwrite) PINSharedAnimatedImage *sharedAnimatedImage;
@property (atomic, assign, readwrite) BOOL infoCompleted;

@end

@implementation PINMemMapAnimatedImage

- (instancetype)init
{
  return [self initWithAnimatedImageData:nil];
}

- (instancetype)initWithAnimatedImageData:(NSData *)animatedImageData
{
  if (self = [super init]) {
    _completionLock = [[PINRemoteLock alloc] initWithName:@"PINMemMapAnimatedImage completion lock"];
    _dataLock = [[PINRemoteLock alloc] initWithName:@"PINMemMapAnimatedImage data lock"];
    
    NSAssert(animatedImageData != nil, @"animatedImageData must not be nil.");
    
    [[PINGIFAnimatedImageManager sharedManager] animatedPathForImageData:animatedImageData infoCompletion:^(PINImage *coverImage, PINSharedAnimatedImage *shared) {
      self.sharedAnimatedImage = shared;
      self.infoCompleted = YES;
      
      [self->_completionLock lockWithBlock:^{
        if (self->_infoCompletion) {
          self->_infoCompletion(coverImage);
          self->_infoCompletion = nil;
        }
      }];
    } completion:^(BOOL completed, NSString *path, NSError *error) {
      BOOL success = NO;
        
      if (completed && error == nil) {
        success = YES;
      }
      
      [self->_completionLock lockWithBlock:^{
        if (self->_fileReady) {
          self->_fileReady();
        }
      }];
      
      if (success) {
        [self->_completionLock lockWithBlock:^{
          if (self->_animatedImageReady) {
            self->_animatedImageReady();
            self->_fileReady = nil;
            self->_animatedImageReady = nil;
          }
        }];
      }
    }];
  }
  return self;
}

- (void)setInfoCompletion:(PINAnimatedImageInfoReady)infoCompletion
{
  [_completionLock lockWithBlock:^{
    self->_infoCompletion = infoCompletion;
  }];
}

- (void)setAnimatedImageReady:(dispatch_block_t)animatedImageReady
{
  [_completionLock lockWithBlock:^{
    self->_animatedImageReady = animatedImageReady;
  }];
}

- (void)setFileReady:(dispatch_block_t)fileReady
{
  [_completionLock lockWithBlock:^{
    self->_fileReady = fileReady;
  }];
}

- (PINImage *)coverImageWithMemoryMap:(NSData *)memoryMap width:(UInt32)width height:(UInt32)height bitsPerPixel:(UInt32)bitsPerPixel bitmapInfo:(CGBitmapInfo)bitmapInfo
{
  CGImageRef imageRef = [[self class] imageAtIndex:0 inMemoryMap:memoryMap width:width height:height bitsPerPixel:bitsPerPixel bitmapInfo:bitmapInfo];
#if PIN_TARGET_IOS
  return [UIImage imageWithCGImage:imageRef];
#elif PIN_TARGET_MAC
  return [[NSImage alloc] initWithCGImage:imageRef size:CGSizeMake(width, height)];
#endif
}

void releaseData(void *data, const void *imageData, size_t size);

void releaseData(void *data, const void *imageData, size_t size)
{
  CFRelease(data);
}

- (CGImageRef)imageAtIndex:(NSUInteger)index inSharedImageFiles:(NSArray <PINSharedAnimatedImageFile *>*)imageFiles width:(UInt32)width height:(UInt32)height bitsPerPixel:(UInt32)bitsPerPixel bitmapInfo:(CGBitmapInfo)bitmapInfo
{
  if (self.status == PINAnimatedImageStatusError) {
    return nil;
  }
  
  for (NSUInteger fileIdx = 0; fileIdx < imageFiles.count; fileIdx++) {
    PINSharedAnimatedImageFile *imageFile = imageFiles[fileIdx];
    if (index < imageFile.frameCount) {
      __block NSData *memoryMappedData = nil;
      [_dataLock lockWithBlock:^{
        memoryMappedData = imageFile.memoryMappedData;
        self->_currentData = memoryMappedData;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          [self->_dataLock lockWithBlock:^{
            self->_nextData = (fileIdx + 1 < imageFiles.count) ? imageFiles[fileIdx + 1].memoryMappedData : imageFiles[0].memoryMappedData;
          }];
        });
      }];
      return [[self class] imageAtIndex:index inMemoryMap:memoryMappedData width:width height:height bitsPerPixel:bitsPerPixel bitmapInfo:bitmapInfo];
    } else {
      index -= imageFile.frameCount;
    }
  }
  //image file not done yet :(
  return nil;
}

- (CFTimeInterval)durationAtIndex:(NSUInteger)index
{
  return self.durations[index];
}

+ (CGImageRef)imageAtIndex:(NSUInteger)index inMemoryMap:(NSData *)memoryMap width:(UInt32)width height:(UInt32)height bitsPerPixel:(UInt32)bitsPerPixel bitmapInfo:(CGBitmapInfo)bitmapInfo
{
  if (memoryMap == nil) {
    return nil;
  }
  
  Float32 outDuration;
  
  const size_t imageLength = width * height * bitsPerPixel / 8;
  
  //frame duration + previous images
  NSUInteger offset = sizeof(UInt32) + (index * (imageLength + sizeof(outDuration)));
  
  [memoryMap getBytes:&outDuration range:NSMakeRange(offset, sizeof(outDuration))];
  
  BytePtr imageData = (BytePtr)[memoryMap bytes];
  imageData += offset + sizeof(outDuration);
  
  NSAssert(offset + sizeof(outDuration) + imageLength <= memoryMap.length, @"Requesting frame beyond data bounds");
  
  //retain the memory map, it will be released when releaseData is called
  CFRetain((CFDataRef)memoryMap);
  CGDataProviderRef dataProvider = CGDataProviderCreateWithData((void *)memoryMap, imageData, imageLength, releaseData);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGImageRef imageRef = CGImageCreate(width,
                                      height,
                                      kPINAnimatedImageBitsPerComponent,
                                      bitsPerPixel,
                                      bitsPerPixel / 8 * width,
                                      colorSpace,
                                      bitmapInfo,
                                      dataProvider,
                                      NULL,
                                      NO,
                                      kCGRenderingIntentDefault);
  if (imageRef) {
    CFAutorelease(imageRef);
  }
  
  CGColorSpaceRelease(colorSpace);
  CGDataProviderRelease(dataProvider);
  
  return imageRef;
}

// Although the following methods are unused, they could be in the future for restoring decoded images off disk (they're cleared currently).
+ (UInt32)widthFromMemoryMap:(NSData *)memoryMap
{
  UInt32 width;
  [memoryMap getBytes:&width range:NSMakeRange(2, sizeof(width))];
  return width;
}

+ (UInt32)heightFromMemoryMap:(NSData *)memoryMap
{
  UInt32 height;
  [memoryMap getBytes:&height range:NSMakeRange(6, sizeof(height))];
  return height;
}

+ (UInt32)bitsPerPixelFromMemoryMap:(NSData *)memoryMap
{
  UInt32 bitsPerPixel;
  [memoryMap getBytes:&bitsPerPixel range:NSMakeRange(10, sizeof(bitsPerPixel))];
  return bitsPerPixel;
}

+ (UInt32)loopCountFromMemoryMap:(NSData *)memoryMap
{
  UInt32 loopCount;
  [memoryMap getBytes:&loopCount range:NSMakeRange(14, sizeof(loopCount))];
  return loopCount;
}

+ (UInt32)frameCountFromMemoryMap:(NSData *)memoryMap
{
  UInt32 frameCount;
  [memoryMap getBytes:&frameCount range:NSMakeRange(18, sizeof(frameCount))];
  return frameCount;
}

//durations should be a buffer of size Float32 * frameCount
+ (Float32 *)createDurations:(Float32 *)durations fromMemoryMap:(NSData *)memoryMap frameCount:(UInt32)frameCount frameSize:(NSUInteger)frameSize totalDuration:(nonnull CFTimeInterval *)totalDuration
{
  *totalDuration = 0;
  [memoryMap getBytes:&durations range:NSMakeRange(22, sizeof(Float32) * frameCount)];

  for (NSUInteger idx = 0; idx < frameCount; idx++) {
    *totalDuration += durations[idx];
  }

  return durations;
}

- (Float32 *)durations
{
  NSAssert([self infoReady], @"info must be ready");
  return self.sharedAnimatedImage.durations;
}

- (CFTimeInterval)totalDuration
{
  NSAssert([self infoReady], @"info must be ready");
  return self.sharedAnimatedImage.totalDuration;
}

- (size_t)loopCount
{
  NSAssert([self infoReady], @"info must be ready");
  return self.sharedAnimatedImage.loopCount;
}

- (size_t)frameCount
{
  NSAssert([self infoReady], @"info must be ready");
  return self.sharedAnimatedImage.frameCount;
}

- (uint32_t)width
{
  NSAssert([self infoReady], @"info must be ready");
  return self.sharedAnimatedImage.width;
}

- (uint32_t)height
{
  NSAssert([self infoReady], @"info must be ready");
  return self.sharedAnimatedImage.height;
}

- (uint32_t)bytesPerFrame
{
    NSAssert([self infoReady], @"info must be ready");
    return self.sharedAnimatedImage.width * self.sharedAnimatedImage.height * 3;
}

- (NSError *)error
{
  return self.sharedAnimatedImage.error;
}

- (PINAnimatedImageStatus)status
{
  if (self.sharedAnimatedImage == nil) {
    return PINAnimatedImageStatusUnprocessed;
  }
  return self.sharedAnimatedImage.status;
}

- (nullable CGImageRef)imageAtIndex:(NSUInteger)index cacheProvider:(nullable id<PINCachedAnimatedFrameProvider>)cacheProvider
{
  return [self imageAtIndex:index
         inSharedImageFiles:self.sharedAnimatedImage.maps
                      width:(UInt32)self.sharedAnimatedImage.width
                     height:(UInt32)self.sharedAnimatedImage.height
               bitsPerPixel:(UInt32)self.sharedAnimatedImage.bitsPerPixel
                 bitmapInfo:self.sharedAnimatedImage.bitmapInfo];
}

- (PINImage *)coverImage
{
  NSAssert(self.coverImageReady, @"cover image must be ready.");
  return self.sharedAnimatedImage.coverImage;
}

- (BOOL)infoReady
{
  return self.infoCompleted;
}

- (BOOL)coverImageReady
{
  return self.status == PINAnimatedImageStatusInfoProcessed || self.status == PINAnimatedImageStatusFirstFileProcessed || self.status == PINAnimatedImageStatusProcessed;
}

- (BOOL)playbackReady
{
  return self.status == PINAnimatedImageStatusProcessed || self.status == PINAnimatedImageStatusFirstFileProcessed;
}

- (void)clearAnimatedImageCache
{
  [_dataLock lockWithBlock:^{
    self->_currentData = nil;
    self->_nextData = nil;
  }];
}

@end

@implementation PINSharedAnimatedImage

- (instancetype)init
{
  if (self = [super init]) {
    _coverImageLock = [[PINRemoteLock alloc] initWithName:@"PINSharedAnimatedImage cover image lock"];
    _completions = @[];
    _infoCompletions = @[];
    _maps = @[];
  }
  return self;
}

- (void)setInfoProcessedWithCoverImage:(PINImage *)coverImage UUID:(NSUUID *)UUID durations:(Float32 *)durations totalDuration:(CFTimeInterval)totalDuration loopCount:(size_t)loopCount frameCount:(size_t)frameCount width:(uint32_t)width height:(uint32_t)height bitsPerPixel:(size_t)bitsPerPixel bitmapInfo:(CGBitmapInfo)bitmapInfo
{
  NSAssert(_status == PINAnimatedImageStatusUnprocessed, @"Status should be unprocessed.");
  [_coverImageLock lockWithBlock:^{
    self->_coverImage = coverImage;
  }];
  _UUID = UUID;
  _durations = (Float32 *)malloc(sizeof(Float32) * frameCount);
  memcpy(_durations, durations, sizeof(Float32) * frameCount);
  _totalDuration = totalDuration;
  _loopCount = loopCount;
  _frameCount = frameCount;
  _width = width;
  _height = height;
  _bitsPerPixel = bitsPerPixel;
  _bitmapInfo = bitmapInfo;
  _status = PINAnimatedImageStatusInfoProcessed;
}

- (void)dealloc
{
  NSAssert(self.completions.count == 0 && self.infoCompletions.count == 0, @"Shouldn't be dealloc'd if we have a completion or an infoCompletion");

  //Clean up shared files.

  //Get references to maps and UUID so the below block doesn't reference self.
  NSArray *maps = self.maps;
  self.maps = nil;
  NSUUID *UUID = self.UUID;

  if (maps.count > 0) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      //ignore errors
      [[NSFileManager defaultManager] removeItemAtPath:[PINGIFAnimatedImageManager filePathWithTemporaryDirectory:[PINGIFAnimatedImageManager temporaryDirectory] UUID:UUID count:0] error:nil];
      for (PINSharedAnimatedImageFile *file in maps) {
        [[NSFileManager defaultManager] removeItemAtPath:file.path error:nil];
      }
    });
  }
  free(_durations);
}

- (PINImage *)coverImage
{
  __block PINImage *coverImage = nil;
  [_coverImageLock lockWithBlock:^{
    if (self->_coverImage == nil) {
      CGImageRef imageRef = [PINMemMapAnimatedImage imageAtIndex:0 inMemoryMap:self.maps[0].memoryMappedData width:(UInt32)self.width height:(UInt32)self.height bitsPerPixel:(UInt32)self.bitsPerPixel bitmapInfo:self.bitmapInfo];
#if PIN_TARGET_IOS
      coverImage = [UIImage imageWithCGImage:imageRef];
#elif PIN_TARGET_MAC
      coverImage = [[NSImage alloc] initWithCGImage:imageRef size:CGSizeMake(self.width, self.height)];
#endif
      self->_coverImage = coverImage;
    } else {
      coverImage = self->_coverImage;
    }
  }];
  
  return coverImage;
}

@end

@implementation PINSharedAnimatedImageFile

@synthesize memoryMappedData = _memoryMappedData;
@synthesize frameCount = _frameCount;

- (instancetype)init
{
  NSAssert(NO, @"Call initWithPath:");
  return [self initWithPath:nil];
}

- (instancetype)initWithPath:(NSString *)path
{
  if (self = [super init]) {
    _lock = [[PINRemoteLock alloc] initWithName:@"PINSharedAnimatedImageFile lock"];
    _path = path;
  }
  return self;
}

- (UInt32)frameCount
{
  __block UInt32 frameCount;
  [_lock lockWithBlock:^{
    if (self->_frameCount == 0) {
      NSData *memoryMappedData = self->_memoryMappedData;
      if (memoryMappedData == nil) {
        memoryMappedData = [self loadMemoryMappedData];
      }
      [memoryMappedData getBytes:&self->_frameCount range:NSMakeRange(0, sizeof(self->_frameCount))];
    }
    frameCount = self->_frameCount;
  }];
  
  return frameCount;
}

- (NSData *)memoryMappedData
{
  __block NSData *memoryMappedData;
  [_lock lockWithBlock:^{
    memoryMappedData = self->_memoryMappedData;
    if (memoryMappedData == nil) {
      memoryMappedData = [self loadMemoryMappedData];
    }
  }];
  return memoryMappedData;
}

//must be called within lock
- (NSData *)loadMemoryMappedData
{
  NSError *error = nil;
  //local variable shenanigans due to weak ivar _memoryMappedData
  NSData *memoryMappedData = [NSData dataWithContentsOfFile:self.path options:NSDataReadingMappedAlways error:&error];
  if (error) {
#if PINMemMapAnimatedImageDebug
    NSLog(@"Could not memory map data: %@", error);
#endif
  } else {
    _memoryMappedData = memoryMappedData;
  }
  return memoryMappedData;
}

@end
