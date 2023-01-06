//
//  OGVPlayerState.m
//  OGVKit
//
//  Created by Brion on 6/13/15.
//  Copyright (c) 2015 Brion Vibber. All rights reserved.
//
//

#import "OGVKit.h"

#import "OGVFileInputStream.h"
#import "OGVHTTPInputStream.h"

// 表示モード
typedef NS_ENUM (NSUInteger, ePlayState) {
    ePlayState_Stop = 0,// 完全停止
    ePlayState_Pause,// 一時停止
    ePlayState_Play, // 再生中
};

@interface OGVPlayerState ()
@property (readonly) float baseTime;
@end

@implementation SeekQueueItem

-(instancetype)init:(float)time
  completionHandler:(void (^)(BOOL))completionHandler
{
    self = [super init];
    if (self) {
        self.time = time;
        self.completionHandler = completionHandler;
    }
    return self;
}
@end

@implementation SeekCancelQueue

-(instancetype)init
{
    self = [super init];
    if (self) {
        self.queue = [[OGVQueue alloc] init];
        self.queueLock = [[NSObject alloc] init];
    }
    return self;
}

-(void)addQueue:(SeekQueueItem*)value
{
    @synchronized (self.queueLock) {
        [self.queue queue:value];
    }
}


-(SeekQueueItem*)lastPop
{
    SeekQueueItem* result = nil;
    NSMutableArray* actionArray = [[NSMutableArray alloc] init];
    @synchronized (self.queueLock) {
        while(![self.queue empty]){
            result = [self.queue dequeue];
            if([self.queue empty]){
                break;
            }
            else{
                if(result.completionHandler != nil){
                    [actionArray addObject:result];
                }
            }
        }
    }
    
    // ロック内で処理するとデッドロックする
    for(SeekQueueItem* item in actionArray){
        item.completionHandler(NO);
    }
    return result;
}

-(BOOL)isCancel
{
    BOOL result = NO;
    @synchronized (self.queueLock) {
        if(![self.queue empty]){
            result = YES;
        }
    }
    return result;
}

@end

@implementation OGVPlayerState
{
    __weak id<OGVPlayerStateDelegate> delegate;

    OGVInputStream *stream;
    OGVAudioFeeder *audioFeeder;
    OGVDecoder *decoder;

    float frameEndTimestamp;
    float audioPausePosition;

    CFTimeInterval initTime; // [self baseTime] at the beginning of timeline counting
    CFTimeInterval offsetTime; // offset from initTime to 'live' time at the beginning of timeline counting

    ePlayState playState;
    BOOL playAfterLoad;
    BOOL seeking;
    BOOL ended;
    float playRate;
    
    SeekCancelQueue* seekChancelQueue;
    BOOL isSeekStart;
    ePlayState beforePlayState;  // シーク開始時の再生状態
    
    dispatch_queue_t decodeQueue;
    dispatch_queue_t delegateQueue;
}

#pragma mark - Public methods

-(instancetype)initWithURL:(NSURL *)URL
                 startTime:(float)startTime
                  delegate:(id<OGVPlayerStateDelegate>)aDelegate
{
    return [self initWithInputStream:[OGVInputStream inputStreamWithURL:URL]
                           startTime:startTime
                            delegate:aDelegate];
}

-(instancetype)initWithInputStream:(OGVInputStream *)inputStream
                         startTime:(float)startTime
                          delegate:(id<OGVPlayerStateDelegate>)aDelegate
{
    return [self initWithInputStream:inputStream
                           startTime:startTime
                            delegate:aDelegate
                       delegateQueue:dispatch_get_main_queue()];
}

-(instancetype)initWithInputStream:(OGVInputStream *)inputStream
                         startTime:(float)startTime
                          delegate:(id<OGVPlayerStateDelegate>)aDelegate
                     delegateQueue:(dispatch_queue_t)aDelegateQueue
{
    self = [super init];
    if (self) {
        delegate = aDelegate;

        // decode on background thread
        decodeQueue = dispatch_queue_create("OGVKit.Decoder", NULL);

        // draw on UI thread
        delegateQueue = aDelegateQueue;

        stream = inputStream;
        initTime = 0;
        playState = ePlayState_Stop;
        seeking = NO;
        playAfterLoad = NO;
        playRate = 1.0;
        
        offsetTime = startTime;
        frameEndTimestamp = startTime;
        audioPausePosition = startTime;
        
        seekChancelQueue = [[SeekCancelQueue alloc] init];
        isSeekStart = NO;

        // Start loading the URL and processing header data
        dispatch_async(decodeQueue, ^() {
            // @todo set our own state to connecting!
            self->stream.delegate = self;
            [self->stream start];
        });
    }
    return self;
}

-(void)play:(BOOL)isSeekAfter
{
    dispatch_async(decodeQueue, ^() {
        if (isSeekAfter && self->playState == ePlayState_Pause){
            // シーク中にPauseするとpauseが呼び出された後にplayが呼び出されるので
            // pauseになっていたら再生しない
        } else if (self->playState == ePlayState_Play) {
            // Already playing
        } else if (self->ended) {
            // 何もしない
            //self->ended = NO;
            //self->playing = YES;
            //[self seek:0.0f completionHandler:nil];
        } else if (self->decoder.dataReady) {
            [self startPlayback:self->decoder.hasAudio ? self->audioPausePosition : self->frameEndTimestamp];
        } else {
            self->playAfterLoad = YES;
        }
    });
}

-(void)pause
{
    dispatch_async(decodeQueue, ^() {
        
        self->playAfterLoad = NO;
        
        if (self->audioFeeder) {
            [self pauseAudio];
        }

        if (self->playState == ePlayState_Play) {
            self->playState = ePlayState_Pause;
            [self callDelegateSelector:@selector(ogvPlayerStateDidPause:) sync:NO withBlock:^() {
                [self->delegate ogvPlayerStateDidPause:self];
            }];
        } else {
            self->playState = ePlayState_Pause;
        }
    });
}

-(void)stop
{
    dispatch_async(decodeQueue, ^() {
        float newBaseTime = self.baseTime;
        self->offsetTime = self.playbackPosition;
        self->initTime = newBaseTime;
        if (self->audioFeeder) {
            [self stopAudio];
        }

        if (self->playState == ePlayState_Play) {
            self->playState = ePlayState_Stop;
            [self callDelegateSelector:@selector(ogvPlayerStateDidPause:) sync:NO withBlock:^() {
                [self->delegate ogvPlayerStateDidPause:self];
            }];
        } else {
            self->playState = ePlayState_Stop;
        }
    });
}

-(void)cancel
{
    [self stop];

    dispatch_async(decodeQueue, ^() {
        if (self->stream) {
            [self->stream cancel];
        }
        self->stream = nil;
        self->decoder = nil;
    });
}

-(void)seek:(float)time completionHandler:(void (^)(BOOL))completionHandler
{
    ended = NO;
    
    [seekChancelQueue addQueue:[[SeekQueueItem alloc] init:time completionHandler:completionHandler]];
    
//    if (seeking) {
//        // this feels very hacky!
//        [decoder.inputStream cancel];
//        [decoder.inputStream restart];
//    }
    dispatch_async(decodeQueue, ^() {
        SeekQueueItem* item = [self->seekChancelQueue lastPop];
        if(item == nil){
            return;
        }
        
        if (self->decoder && self->decoder.seekable) {
            
            if(!self->isSeekStart){
                self->isSeekStart = YES;
                self->beforePlayState = self->playState;
                if(self->playState == ePlayState_Play || self->playState == ePlayState_Pause){
                    [self stop];
                }
            }
            BOOL ok = [self->decoder seek:item.time
                              cancelQueue:self->seekChancelQueue];
            
            if([self->seekChancelQueue isCancel]){
                item.completionHandler(NO);
                return;
            }

            if (ok) {
                // Adjust the offset for the seek
                self->offsetTime = item.time;
                self->initTime = self.baseTime;

                // Find out the actual time we seeked to!
                // We may have gone to a keyframe nearby.
                [self syncAfterSeek:item.time exact:YES];
                
                if([self->seekChancelQueue isCancel]){
                    item.completionHandler(NO);
                    return;
                }
                
                if (self->decoder.frameReady) {
                    self->frameEndTimestamp = self->decoder.frameTimestamp;
                    self->offsetTime = self->frameEndTimestamp;
                } else {
                    // probably at end?
                    self->frameEndTimestamp = item.time;
                }
                if (self->decoder.audioReady) {
                    self->audioPausePosition = self->decoder.audioTimestamp;
                    self->offsetTime = self->audioPausePosition;
                } else {
                    // probably at end?
                    self->audioPausePosition = item.time;
                }
                
                if(item.completionHandler != nil){
                    item.completionHandler(YES);
                }
                
                if (self->decoder.hasVideo) {
                    // Show where we left off
                    [self->decoder decodeFrameWithBlock:YES :^(OGVVideoBuffer *frameBuffer) {
                        [self drawFrame:frameBuffer];
                        [frameBuffer neuter];
                    }];
                }
                if (self->beforePlayState == ePlayState_Play) {
                    [self play:YES];
                }
            } else {
                if(item.completionHandler != nil){
                    item.completionHandler(NO);
                }
            }
        } else {
            if(item.completionHandler != nil){
                item.completionHandler(NO);
            }
        }
        
        self->isSeekStart = NO;
    });
}


- (void)changePlayRate:(float)rate
{
    playRate = rate;
    if (audioFeeder) {
        [audioFeeder changePlayRate:rate];
    }
}


#pragma mark - getters/setters

-(BOOL)paused
{
    return playState != ePlayState_Play;
}

-(float)playbackPosition
{
//    NSLog(@"debug print playbackPosition1 playState [%@] baseTime [%f] initTime [%f] offsetTime [%f]"
//          ,(playState == ePlayState_Play ? @"play" : (playState == ePlayState_Stop ? @"stop" : @"pause"))
//          ,self.baseTime
//          ,initTime
//          ,offsetTime);
        
    double position = 0.0;
    if (playState != ePlayState_Stop) {
        position = (self.baseTime - initTime) + offsetTime;
    } else {
        position = offsetTime;
    }
    
    return (position > 0.0) ? position : 0.0;
}

- (float)baseTime
{
    if (decoder.hasAudio) {
        if(audioFeeder){
            return audioFeeder.playbackPosition;
        } else {
            return 0.0;
        }
    } else {
        return CACurrentMediaTime();
    }
}

-(float)duration
{
    if (decoder) {
        return decoder.duration;
    } else {
        return INFINITY;
    }
}

-(BOOL)seekable
{
    if (decoder) {
        return decoder.seekable;
    } else {
        return NO;
    }
}

#pragma mark - Private decode thread methods

- (void)callDelegateSelector:(SEL)selector sync:(BOOL)sync withBlock:(void(^)(void))block
{
    if ([delegate respondsToSelector:selector]) {
        if (delegateQueue) {
            if (sync) {
                dispatch_sync(delegateQueue, block);
            } else {
                dispatch_async(delegateQueue, block);
            }
        } else {
            block();
        }
    }
}

- (void)startDecoder
{
    decoder = [[OGVKit singleton] decoderForType:stream.mediaType];
    if (decoder) {
        // Hand the stream off to the decoder and goooooo!
        decoder.inputStream = stream;
        [self processHeaders];
    } else {
        [OGVKit.singleton.logger fatalWithFormat:@"no decoder, this should not happen"];
        // TODO)エラーコールバックする
        //abort();
    }
    // @fixme update our state
}

- (void)startPlayback:(float)offset
{
    assert(decoder.dataReady);
    assert(offset >= 0);
    
    if(playState == ePlayState_Pause){
        // pause解除
        playState = ePlayState_Play;
        
        if (decoder.hasAudio) {
            if(audioFeeder){
                [audioFeeder pauseOff];
            }
        }
    } else {
        playState = ePlayState_Play;
        
        [self initPlaybackState:offset];

        if (decoder.hasAudio) {
            [self startAudio:offset];
        }

        [self callDelegateSelector:@selector(ogvPlayerStateDidPlay:) sync:NO withBlock:^() {
            [self->delegate ogvPlayerStateDidPlay:self];
        }];
    }
    [self pingProcessing:0];
}

- (void)initPlaybackState:(float)offset
{
    assert(decoder.dataReady);
    assert(offset >= 0);
    
    frameEndTimestamp = 0.0f;
    initTime = self.baseTime;
    offsetTime = offset;
}

-(void)startAudio:(float)offset
{
    assert(decoder.hasAudio);
    assert(!audioFeeder);

    audioFeeder = [[OGVAudioFeeder alloc] initWithFormat:decoder.audioFormat
                                                delegate:self];
    [audioFeeder changePlayRate:playRate];

    // Reset to audio clock
    initTime = self.baseTime;
    offsetTime = offset;
}

-(void)pauseAudio
{
    assert(decoder.hasAudio);
    assert(audioFeeder);
    
    [audioFeeder pause];
}

-(void)stopAudio
{
    assert(decoder.hasAudio);
    assert(audioFeeder);

    // Save the actual audio time as last offset
    audioPausePosition = [audioFeeder bufferTailPosition] - initTime + offsetTime;

    [audioFeeder close];
    audioFeeder = nil;

    // Reset to generic media clock
    initTime = self.baseTime;
    offsetTime = audioPausePosition;
}



- (void)processHeaders
{
    eProcessState processState = [decoder process];
    if (processState == eProcessState_Success) {
        if (decoder.dataReady) {
            float seekTime = self->decoder.hasAudio ? self->audioPausePosition : self->frameEndTimestamp;
                        
            void(^afterFunc)(void) = ^() {
                [self callDelegateSelector:@selector(ogvPlayerStateDidLoadMetadata:) sync:NO withBlock:^() {
                    [self->delegate ogvPlayerStateDidLoadMetadata:self];
                }];
                if (self->playAfterLoad) {
                    self->playAfterLoad = NO;
                    [self startPlayback:seekTime];
                }
            };
            
            if(seekTime > 0.0){
                // 初回シーク
                [self seek:seekTime completionHandler:^(BOOL success) {
                    afterFunc();
                }];
            } else {
                afterFunc();
            }
            
        } else {
            dispatch_async(decodeQueue, ^() {
                [self processHeaders];
            });
        }
    } else {
        [OGVKit.singleton.logger errorWithFormat:@"Error processing header state. :("];
    }
}

- (void)processNextFrame
{
    eProcessState more;
    if (playState != ePlayState_Play) {
        return;
    }
    while (true) {
        more = [decoder process];
        if (more != eProcessState_Success) {
            if (decoder.inputStream.state == OGVInputStreamStateFailed) {
                [OGVKit.singleton.logger errorWithFormat:@"Hey! The input stream failed. Handle this more gracefully."];
                [self stop];
                playState = ePlayState_Stop;
                return;
            }
            
            if ((!decoder.hasAudio || decoder.audioReady) && (!decoder.hasVideo || decoder.frameReady)) {
                // More packets already demuxed, just keep running them.
            } else {
                // Wait for audio to run out, then close up shop!
                float timeLeft;
                if (audioFeeder && [audioFeeder isStarted]) {
                    // @fixme if we haven't started and there's time left,
                    // we should trigger actual playback and pad the buffer.
                    timeLeft = [audioFeeder timeAwaitingPlayback];
                } else {
                    timeLeft = 0;
                }
                [OGVKit.singleton.logger debugWithFormat:@"ended? time left %f", timeLeft];
                if (timeLeft > 0) {
                    [self pingProcessing:timeLeft];
                } else {
                    [self stop];
                    ended = YES;
                    [self callDelegateSelector:@selector(ogvPlayerStateDidEnd:) sync:NO withBlock:^() {
                        [self->delegate ogvPlayerStateDidEnd:self];
                    }];
                }
                return;
            }
        }

        float nextDelay = INFINITY;
        float playbackPosition = self.playbackPosition;
        float frameDelay = (frameEndTimestamp - playbackPosition);
        
        // See if the frame timestamp is behind the playhead
        BOOL readyToDecodeFrame = (frameDelay <= 0.0);

        // If we get behind audio, and there's a keyframe we can pick up on, skip to it.
        if (frameEndTimestamp < playbackPosition) {
            float nextKeyframe = [decoder findNextKeyframe];
            if (nextKeyframe > decoder.frameTimestamp && nextKeyframe < playbackPosition) {
                [OGVKit.singleton.logger debugWithFormat:@"behind by %f; skipping to next keyframe %f", frameDelay, nextKeyframe];
                while (decoder.frameReady && decoder.frameTimestamp < nextKeyframe) {
                    [decoder dequeueFrame];
                }
                frameEndTimestamp = decoder.frameTimestamp;
                continue;
            }
        }
        
        
        if (decoder.hasAudio) {
            
            if ([audioFeeder isClosed]) {
                // Switch to raw clock when audio is done.
                [self stopAudio];
            }

            if (decoder.audioReady) {
                // Drive on the audio clock!
                const float audioTimestamp = decoder.audioTimestamp;
                if (!audioFeeder) {
                    [self startAudio:audioTimestamp];
                }

                const int bufferSize = 8192 * 4; // fake
                const float bufferDuration = (float)bufferSize / decoder.audioFormat.sampleRate;
                
                float audioBufferedDuration = [audioFeeder secondsQueued];
                BOOL readyForAudio = (audioBufferedDuration <= bufferDuration);
                if (readyForAudio) {
                    BOOL ok = [decoder decodeAudioWithBlock:YES :^(OGVAudioBuffer *audioBuffer) {
                        if (![self->audioFeeder bufferData:audioBuffer]) {
                            if ([self->audioFeeder isClosed]) {
                                // Audio died, perhaps due to starvation during slow decodes
                                // or something else unexpected. Close it out and we'll start
                                // up a new one.
                                [OGVKit.singleton.logger debugWithFormat:@"CLOSING OUT CLOSED AUDIO FEEDER"];
                                [self stopAudio];
                                [self startAudio:audioTimestamp];
                                [self->audioFeeder bufferData:audioBuffer];
                            }
                        }
                    }];
                    if (ok) {
                        // Go back around the loop in case we need more
                        continue;
                    } else {
                        [OGVKit.singleton.logger errorWithFormat:@"Bad audio packet or something"];
                    }
                }

                if (audioBufferedDuration <= bufferDuration) {
                    // NEED MOAR BUFFERS
                    nextDelay = 0;
                } else {
                    // Check in when the audio buffer runs low again...
                    nextDelay = fminf(nextDelay, fmaxf(audioBufferedDuration - bufferDuration / 2.0f, 0.0f));
                }
            } else {
                // Need to find some more packets
                continue;
            }

        }
        
        if (decoder.hasVideo) {
            if (decoder.frameReady) {
                if (readyToDecodeFrame) {
                    BOOL ok = [decoder decodeFrameWithBlock:YES :^(OGVVideoBuffer *frameBuffer) {
                        // Check if it's time to draw (AKA the frame timestamp is at or past the playhead)
                        // If we're already playing, DRAW!
                        [self drawFrame:frameBuffer];
                        [frameBuffer neuter];
                    }];
                    if (ok) {
                        // End the processing loop, we'll ping again after drawing
                        //return;
                    } else {
                        [OGVKit.singleton.logger errorWithFormat:@"Bad video packet or something"];
                        continue;
                    }
                }
                nextDelay = fminf(nextDelay, fmaxf(frameEndTimestamp - playbackPosition, 0.0f));
            } else if (playState != ePlayState_Play) {
                // We're all caught up but paused, will be pinged when played
                return;
            } else {
                // Need more processing; continue the loop
                continue;
            }
        }

        if (nextDelay < INFINITY) {
            [self pingProcessing:nextDelay];
            
            // End the processing loop and wait for next ping.
            return;
        } else {
            // nothing to do?
            [OGVKit.singleton.logger errorWithFormat:@"loop drop?"];
            return;
        }
        
        // End the processing loop and wait for next ping.
        return;
    }
}

- (void)pingProcessing:(float)delay
{
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC));
    dispatch_after(popTime, decodeQueue, ^() {
        [self processNextFrame];
    });
}

/**
 * Dequeue frame and schedule a frame draw on the main thread
 */
-(void)drawFrame:(OGVVideoBuffer *)frameBuffer
{
    frameEndTimestamp = frameBuffer.timestamp;
    // Note: this must be sync because memory may belong to the decoder!
    [self callDelegateSelector:@selector(ogvPlayerState:drawFrame:) sync:YES withBlock:^() {
        [self->delegate ogvPlayerState:self drawFrame:frameBuffer];
    }];
}

-(BOOL)syncAfterSeek:(float)target exact:(BOOL)exact
{
    __block OGVVideoBuffer *lastFrameBuffer = nil;
    
    void(^releaseFrame)(void) = ^() {
        if(lastFrameBuffer){
            [lastFrameBuffer neuter];
            lastFrameBuffer = nil;
        }
    };
        
    while (YES) {
        if([self->seekChancelQueue isCancel]){
            return NO;
        }
        eProcessState processState = eProcessState_Success;
        while ((decoder.hasAudio && !decoder.audioReady) || (decoder.hasVideo && !decoder.frameReady)) {
            processState = [decoder process];
            if(processState == eProcessState_Error){
                [OGVKit.singleton.logger errorWithFormat:@"Got to end of file before found data again after seek."];
                releaseFrame();
                return NO;
            } else if(processState == eProcessState_EndPacket){
                // 終端まで操作した
                if(lastFrameBuffer){
                    // 最後のフレームを表示する
                    [self drawFrame:lastFrameBuffer];
                }
                
                [self stop];
                ended = YES;
                [self callDelegateSelector:@selector(ogvPlayerStateDidEnd:) sync:NO withBlock:^() {
                    [self->delegate ogvPlayerStateDidEnd:self];
                }];
                
                releaseFrame();
                return YES;
            }
        }
        
        
        if([self->seekChancelQueue isCancel]){
            return NO;
        }
        
        if (exact) {
            while (decoder.hasAudio && decoder.audioReady && decoder.audioTimestamp < target && ![decoder audioQueueIsEmpty]) {
                [decoder decodeAudioWithBlock:NO :^(OGVAudioBuffer *audioBuffer) {
                    
                }];
            }
            while (decoder.hasVideo && decoder.frameReady && decoder.frameTimestamp < target && ![decoder videoQueueIsEmpty]) {
                // 対象時間に近づいたら画像の生成をする
                BOOL isMakeBuffer = (decoder.frameTimestamp >= target - 0.2);
                [decoder decodeFrameWithBlock:isMakeBuffer :^(OGVVideoBuffer *frameBuffer) {
                    
                    if(isMakeBuffer){
                        releaseFrame();
                        // 終端到達時の表示バッファ
                        lastFrameBuffer = frameBuffer;
                    }
                }];
            }
            if ((!decoder.hasVideo || decoder.frameTimestamp >= target) &&
                (!decoder.hasAudio || decoder.audioTimestamp >= target)) {
                
                releaseFrame();
                return YES;
            }
        } else {
            // We're ok leaving off after the keyframe
            releaseFrame();
            return YES;
        }
    }
}

#pragma mark - OGVInputStreamDelegate methods

-(void)OGVInputStreamStateChanged:(OGVInputStream *)sender
{
    switch (stream.state) {
        case OGVInputStreamStateConnecting:
            // Good... Good. Let the data flow through you!
            break;

        case OGVInputStreamStateReading:
            // Break the stream off from us and send it to the decoder.
            stream.delegate = nil;
            [self startDecoder];
            break;

        case OGVInputStreamStateFailed:
            [OGVKit.singleton.logger errorWithFormat:@"Stream file failed."];
            stream.delegate = nil;
            [stream cancel];
            stream = nil;
            break;

        case OGVInputStreamStateCanceled:
            // we canceled it, eh
            break;

        default:
            [OGVKit.singleton.logger errorWithFormat:@"Unexpected stream state change! %d", (int)stream.state];
            stream.delegate = nil;
            [stream cancel];
            stream = nil;
    }
}

-(void)OGVInputStream:(OGVInputStream *)sender customizeURLRequest:(NSMutableURLRequest *)request
{
    [self callDelegateSelector:@selector(ogvPlayerState:customizeURLRequest:) sync:YES withBlock:^() {
        [self->delegate ogvPlayerState:self customizeURLRequest:request];
    }];
}

#pragma mark - OGVAudioFeederDelegate methods
-(void)ogvAudioFeederStartUP
{
    if(playState == ePlayState_Play && audioFeeder && ![audioFeeder isClosed]){
        [audioFeeder startRun];
    }
}

@end
