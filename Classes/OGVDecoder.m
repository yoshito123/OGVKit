//
//  OGVDecoder.m
//  OGVKit
//
//  Created by Brion on 11/2/13.
//  Copyright (c) 2013-2015 Brion Vibber. All rights reserved.
//

#import "OGVKit.h"

@implementation OGVDecoder {
}

#pragma mark - stubs for subclasses to implement

- (BOOL)dequeueFrame
{
    return NO;
}

- (BOOL)videoQueueIsEmpty
{
    // TODO) webMのみ対応
    return NO;
}

- (BOOL)dequeueAudio
{
    return NO;
}

- (BOOL)audioQueueIsEmpty
{
    // TODO) webMのみ対応
    return NO;
}

- (BOOL)decodeFrameWithBlock:(BOOL)isMakeBuffer :(void (^)(OGVVideoBuffer *))block
{
    // TODO) isMakeBufferの処理はwebMのみ対応
    return NO;
}

- (BOOL)decodeAudioWithBlock:(BOOL)isMakeBuffer :(void (^)(OGVAudioBuffer *))block
{
    // TODO) isMakeBufferの処理はwebMのみ対応
    return NO;
}

// TODO)webMだけ終端パケットに対応
- (eProcessState)process
{
    return eProcessState_Error;
}

- (BOOL)seek:(float)seconds
 cancelQueue:(SeekCancelQueue*)cancelQueue
{
    return NO;
}

- (void)flush
{
}

- (float)findNextKeyframe
{
    return INFINITY;
}

#pragma mark - stub property getters

- (BOOL)seekable
{
    return NO;
}

- (float)duration
{
    return INFINITY;
}

- (BOOL)audioReady
{
    return NO;
}

- (float)audioTimestamp
{
    return -1;
}

- (BOOL)frameReady
{
    return NO;
}

- (float)frameTimestamp
{
    return -1;
}

#pragma mark - stub static methods

+ (BOOL)canPlayType:(NSString *)type
{
    return NO;
}

@end
