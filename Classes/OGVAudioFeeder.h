//
//  OGVAudioFeeder.h
//  OGVKit
//
//  Created by Brion on 6/28/14.
//  Copyright (c) 2014-2015 Brion Vibber. All rights reserved.
//

/**
 * Delegate
 */
@protocol OGVAudioFeederDelegate<NSObject>

/**
 * 初回起動時
 */
@optional
-(void)ogvAudioFeederStartUP;

@end

@interface OGVAudioFeeder : NSObject

@property (readonly) OGVAudioFormat *format;

/**
 * Initializer!
 */
-(id)initWithFormat:(OGVAudioFormat *)format
           delegate:(id<OGVAudioFeederDelegate>)aDelegate;


/**
 * Queue up a chunk of audio for future output.
 *
 * Audio will start automatically once enough buffers have been queued.
 * Returns YES if all looks well, NO if something has gone awry
 * such as a failure of the audio output path to work.
 */
-(BOOL)bufferData:(OGVAudioBuffer *)buffer;

/**
 * Close this audio channel.
 */
-(void)close;

/**
 * Amount of audio queued up and not yet played, in samples
 */
-(int)samplesQueued;

/**
 * Amount of audio queued up and not yet played, in seconds
 */
-(float)secondsQueued;

/**
 * Get current playback position, in seconds (maybe)
 */
-(float)playbackPosition;

/**
 * Get amount of time before the current playback & queue run out, in seconds
 */
-(float)timeAwaitingPlayback;

/**
 * Get the future playback position at which current audio will run out
 */
@property (readonly) float bufferTailPosition;

/**
 * Have we started?
 */
-(BOOL)isStarted;

/**
 * Are we closing out after end?
 */
-(BOOL)isClosing;

/**
 * Are we closed?
 */
-(BOOL)isClosed;


/**
 * 起動直後専用開始処理
 */
-(void)startRun;
/**
 * 一時停止
 */
-(void)pause;

/**
 * 一時停止解除
 */
-(void)pauseOff;

/**
 * 再生速度変更
 */
-(void)changePlayRate:(float)rate;

@end
