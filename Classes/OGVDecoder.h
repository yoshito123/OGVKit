//
//  OGVDecoder.h
//  OGVKit
//
//  Created by Brion on 11/2/13.
//  Copyright (c) 2013-2015 Brion Vibber. All rights reserved.
//

@class OGVDecoder;
@class SeekCancelQueue;


// 表示モード
typedef NS_ENUM (NSUInteger, eProcessState) {
    eProcessState_Error = 0,
    eProcessState_Success,
    eProcessState_EndPacket,
};


@protocol OGVDecoder <NSObject>
+ (instancetype)alloc;
+ (BOOL)canPlayType:(OGVMediaType *)type;
@end

@interface OGVDecoder : NSObject <OGVDecoder>

@property BOOL dataReady;

/**
 * Contains YES if the target media and its underlying data stream
 * allow seeking; NO if not.
 */
@property (readonly) BOOL seekable;

/**
 * Length of the loaded media segment in seconds, if known;
 * contains INFINITY if duration cannot be determined.
 */
@property (readonly) float duration;

@property BOOL hasVideo;
@property OGVVideoFormat *videoFormat;

@property BOOL hasAudio;
@property OGVAudioFormat *audioFormat;

@property (readonly) BOOL audioReady;
@property (readonly) float audioTimestamp;

@property (readonly) BOOL frameReady;
@property (readonly) float frameTimestamp;

@property OGVInputStream *inputStream;

- (eProcessState)process;
- (BOOL)dequeueFrame;
- (BOOL)videoQueueIsEmpty;
- (BOOL)dequeueAudio;
- (BOOL)audioQueueIsEmpty;
- (BOOL)decodeFrameWithBlock:(BOOL)isMakeBuffer :(void (^)(OGVVideoBuffer *))block;
- (BOOL)decodeAudioWithBlock:(BOOL)isMakeBuffer :(void (^)(OGVAudioBuffer *audioBuffer))block;
- (BOOL)seek:(float)seconds
 cancelQueue:(SeekCancelQueue*)cancelQueue;
- (void)flush;
- (float)findNextKeyframe;

+ (BOOL)canPlayType:(OGVMediaType *)mediaType;

@end
