//
//  SCSession.m
//  SCAudioVideoRecorder
//
//  Created by Simon CORSIN on 27/03/14.
//  Copyright (c) 2014 rFlex. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "SCRecordSession_Internal.h"
#import "SCRecorder.h"

#pragma mark - Private definition

NSString *SCRecordSessionSegmentFilenamesKey = @"RecordSegmentFilenames";
NSString *SCRecordSessionDurationKey = @"Duration";
NSString *SCRecordSessionIdentifierKey = @"Identifier";
NSString *SCRecordSessionDateKey = @"Date";
NSString *SCRecordSessionDirectoryKey = @"Directory";

NSString *SCRecordSessionTemporaryDirectory = @"TemporaryDirectory";
NSString *SCRecordSessionCacheDirectory = @"CacheDirectory";

@implementation SCRecordSession

- (id)initWithDictionaryRepresentation:(NSDictionary *)dictionaryRepresentation {
    self = [self init];
    
    if (self) {
        NSString *directory = dictionaryRepresentation[SCRecordSessionDirectoryKey];
        if (directory != nil) {
            _recordSegmentsDirectory = directory;
        }
        
        NSArray *recordSegments = [dictionaryRepresentation objectForKey:SCRecordSessionSegmentFilenamesKey];
        
        int i = 0;
        BOOL shouldRecomputeDuration = NO;
        for (NSString *recordSegment in recordSegments) {
            NSURL *url = [SCRecordSession segmentURLForFilename:recordSegment andDirectory:_recordSegmentsDirectory];
            
            if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
                [_segments addObject:[SCRecordSessionSegment segmentWithURL:url]];
            } else {
                NSLog(@"Skipping record segment %d: File does not exist", i);
                shouldRecomputeDuration = YES;
            }
            i++;
        }
        _currentSegmentCount = i;
        
        NSNumber *recordDuration = [dictionaryRepresentation objectForKey:SCRecordSessionDurationKey];
        if (recordDuration != nil) {
            _segmentsDuration = CMTimeMakeWithSeconds(recordDuration.doubleValue, 10000);
        } else {
            shouldRecomputeDuration = YES;
        }
        
        if (shouldRecomputeDuration) {
            _segmentsDuration = self.assetRepresentingSegments.duration;
            
            if (CMTIME_IS_INVALID(_segmentsDuration)) {
                NSLog(@"Unable to set the segments duration: one or most input assets are invalid");
                NSLog(@"The imported SCRecordSession is probably not useable.");
            }
        }
        
        _identifier = [dictionaryRepresentation objectForKey:SCRecordSessionIdentifierKey];
        _date = [dictionaryRepresentation objectForKey:SCRecordSessionDateKey];
    }
    
    return self;
}

- (id)init {
    self = [super init];
    
    if (self) {
        _segments = [[NSMutableArray alloc] init];
        
        _assetWriter = nil;
        _videoInput = nil;
        _audioInput = nil;
        _audioInitializationFailed = NO;
        _videoInitializationFailed = NO;
        _currentSegmentCount = 0;
        _timeOffset = kCMTimeZero;
        _lastTimeAudio = kCMTimeZero;
        _currentSegmentDuration = kCMTimeZero;
        _segmentsDuration = kCMTimeZero;
        _date = [NSDate date];
        _recordSegmentsDirectory = SCRecordSessionTemporaryDirectory;
        _identifier = [NSString stringWithFormat:@"%ld", (long)[_date timeIntervalSince1970]];
        _videoQueue = dispatch_queue_create("me.corsin.SCRecorder.Video", nil);
        _audioQueue = dispatch_queue_create("me.corsin.SCRecorder.Audio", nil);
        dispatch_set_target_queue(_videoQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    }
    
    return self;
}

+ (NSURL *)segmentURLForFilename:(NSString *)filename andDirectory:(NSString *)directory {
    NSURL *directoryUrl = nil;
    
    if ([SCRecordSessionTemporaryDirectory isEqualToString:directory]) {
        directoryUrl = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    } else if ([SCRecordSessionCacheDirectory isEqualToString:directory]) {
        NSArray *myPathList = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        directoryUrl = [NSURL fileURLWithPath:myPathList.firstObject];
    } else {
        directoryUrl = [NSURL fileURLWithPath:directory];
    }
    
    return [directoryUrl URLByAppendingPathComponent:filename];
}

+ (id)recordSession {
    return [[SCRecordSession alloc] init];
}

+ (id)recordSession:(NSDictionary *)dictionaryRepresentation {
    return [[SCRecordSession alloc] initWithDictionaryRepresentation:dictionaryRepresentation];
}

+ (NSError*)createError:(NSString*)errorDescription {
    return [NSError errorWithDomain:@"SCRecordSession" code:200 userInfo:@{NSLocalizedDescriptionKey : errorDescription}];
}

- (void)dispatchSyncOnSessionQueue:(void(^)())block {
    SCRecorder *recorder = self.recorder;
    
    if (recorder == nil || [SCRecorder isSessionQueue]) {
        block();
    } else {
        dispatch_sync(recorder.sessionQueue, block);
    }
}

- (void)removeFile:(NSURL *)fileUrl {
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:fileUrl.path error:&error];
}

- (void)removeSegment:(SCRecordSessionSegment *)segment {
    [self dispatchSyncOnSessionQueue:^{
        NSUInteger index = [_segments indexOfObject:segment];
        if (index != NSNotFound) {
            [self removeSegmentAtIndex:index deleteFile:NO];
        }
    }];
}


- (void)removeSegmentAtIndex:(NSInteger)segmentIndex deleteFile:(BOOL)deleteFile {
    [self dispatchSyncOnSessionQueue:^{
        SCRecordSessionSegment *segment = [_segments objectAtIndex:segmentIndex];
        [_segments removeObjectAtIndex:segmentIndex];
        
        CMTime segmentDuration = segment.duration;
        
        if (CMTIME_IS_VALID(segmentDuration)) {
//            NSLog(@"Removed duration of %fs", CMTimeGetSeconds(segmentDuration));
            _segmentsDuration = CMTimeSubtract(_segmentsDuration, segmentDuration);
        } else {
            NSLog(@"Removed invalid segment index %d. Recomputing duration manually", (int)segmentIndex);
            _segmentsDuration = self.assetRepresentingSegments.duration;
        }
        
        if (deleteFile) {
            [segment deleteFile];
        }
    }];
}

- (void)removeLastSegment {
    [self dispatchSyncOnSessionQueue:^{
        if (_segments.count > 0) {
            [self removeSegmentAtIndex:_segments.count - 1 deleteFile:YES];
        }
    }];
}

- (void)removeAllSegments {
    [self removeAllSegments:YES];
}

- (void)removeAllSegments:(BOOL)removeFiles {
    [self dispatchSyncOnSessionQueue:^{
        while (_segments.count > 0) {
            if (removeFiles) {
                SCRecordSessionSegment *segment = [_segments objectAtIndex:0];
                [segment deleteFile];
            }
            [_segments removeObjectAtIndex:0];
        }
        
        _segmentsDuration = kCMTimeZero;
    }];
}

- (NSString*)_suggestedFileType {
    NSString *fileType = self.fileType;
    
    if (fileType == nil) {
        SCRecorder *recorder = self.recorder;
        if (recorder.videoEnabledAndReady) {
            fileType = AVFileTypeMPEG4;
        } else if (recorder.audioEnabledAndReady) {
            fileType = AVFileTypeAppleM4A;
        }
    }
    
    return fileType;
}

- (NSString *)_suggestedFileExtension {
    NSString *extension = self.fileExtension;
    
    if (extension != nil) {
        return extension;
    }
    
    NSString *fileType = [self _suggestedFileType];
    
    if (fileType == nil) {
        return nil;
    }
    
    if ([fileType isEqualToString:AVFileTypeMPEG4]) {
        return @"mp4";
    } else if ([fileType isEqualToString:AVFileTypeAppleM4A]) {
        return @"m4a";
    } else if ([fileType isEqualToString:AVFileTypeAppleM4V]) {
        return @"m4v";
    } else if ([fileType isEqualToString:AVFileTypeQuickTimeMovie]) {
        return @"mov";
    } else if ([fileType isEqualToString:AVFileTypeWAVE]) {
        return @"wav";
    } else if ([fileType isEqualToString:AVFileTypeMPEGLayer3]) {
        return @"mp3";
    }
    
    return nil;
}

- (NSURL *)nextFileURL:(NSError **)error {
    NSString *extension = [self _suggestedFileExtension];

    if (extension != nil) {
        NSString *filename = [NSString stringWithFormat:@"%@SCVideo.%d.%@", _identifier, _currentSegmentCount, extension];
        NSURL *file = [SCRecordSession segmentURLForFilename:filename andDirectory:self.recordSegmentsDirectory];
        
        [self removeFile:file];
        
        _currentSegmentCount++;
        
        return file;

    } else {
        if (error != nil) {
            *error = [SCRecordSession createError:[NSString stringWithFormat:@"Unable to find an extension"]];
        }

        return nil;
    }
}

- (AVAssetWriter *)createWriter:(NSError **)error {
    NSError *theError = nil;
    AVAssetWriter *writer = nil;
    
    NSString *fileType = [self _suggestedFileType];
    
    if (fileType != nil) {
        NSURL *file = [self nextFileURL:&theError];
        
        if (file != nil) {
            writer = [[AVAssetWriter alloc] initWithURL:file fileType:fileType error:&theError];
        }
    } else {
        theError = [SCRecordSession createError:@"No fileType has been set in the SCRecordSession"];
    }
    
    if (theError == nil) {
        writer.shouldOptimizeForNetworkUse = YES;
        
        if (_videoInput != nil) {
            if ([writer canAddInput:_videoInput]) {
                [writer addInput:_videoInput];
            } else {
                theError = [SCRecordSession createError:@"Cannot add videoInput to the assetWriter with the currently applied settings"];
            }
        }
        
        if (_audioInput != nil) {
            if ([writer canAddInput:_audioInput]) {
                [writer addInput:_audioInput];
            } else {
                theError = [SCRecordSession createError:@"Cannot add audioInput to the assetWriter with the currently applied settings"];
            }
        }
        
        if ([writer startWriting]) {
            //                NSLog(@"Starting session at %fs", CMTimeGetSeconds(_lastTime));
            [writer startSessionAtSourceTime:kCMTimeZero];
            _timeOffset = kCMTimeInvalid;
            //                _sessionStartedTime = _lastTime;
            //                _currentRecordDurationWithoutCurrentSegment = _currentRecordDuration;
            _recordSegmentReady = YES;
        } else {
            theError = writer.error;
            writer = nil;
        }
    }
    
    if (error != nil) {
        *error = theError;
    }
    
    return writer;
}

- (void)deinitialize {
    [self dispatchSyncOnSessionQueue:^{
        [self endSegment:nil];
        
        _audioConfiguration = nil;
        _videoConfiguration = nil;
        _audioInitializationFailed = NO;
        _videoInitializationFailed = NO;
        _videoInput = nil;
        _audioInput = nil;
        _videoPixelBufferAdaptor = nil;
    }];
}

- (void)initializeVideo:(NSDictionary *)videoSettings formatDescription:(CMFormatDescriptionRef)formatDescription error:(NSError *__autoreleasing *)error {
    NSError *theError = nil;
    @try {
        _videoConfiguration = self.recorder.videoConfiguration;
        _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings sourceFormatHint:formatDescription];
        _videoInput.expectsMediaDataInRealTime = YES;
        _videoInput.transform = _videoConfiguration.affineTransform;
        
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        
        NSDictionary *pixelBufferAttributes = @{
                                                (id)kCVPixelBufferPixelFormatTypeKey : [NSNumber numberWithInt:kCVPixelFormatType_32BGRA],
                                                (id)kCVPixelBufferWidthKey : [NSNumber numberWithInt:dimensions.width],
                                                (id)kCVPixelBufferHeightKey : [NSNumber numberWithInt:dimensions.height]
                                                    };
        
        _videoPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoInput sourcePixelBufferAttributes:pixelBufferAttributes];
    } @catch (NSException *exception) {
        theError = [SCRecordSession createError:exception.reason];
    }
    
    _videoInitializationFailed = theError != nil;
    
    if (error != nil) {
        *error = theError;
    }
}

- (void)initializeAudio:(NSDictionary *)audioSettings formatDescription:(CMFormatDescriptionRef)formatDescription error:(NSError *__autoreleasing *)error {
    NSError *theError = nil;
    @try {
        _audioConfiguration = self.recorder.audioConfiguration;
        _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings sourceFormatHint:formatDescription];
        _audioInput.expectsMediaDataInRealTime = YES;
    } @catch (NSException *exception) {
        theError = [SCRecordSession createError:exception.reason];
    }
    
    _audioInitializationFailed = theError != nil;
    
    if (error != nil) {
        *error = theError;
    }
}

- (void)addSegment:(SCRecordSessionSegment *)segment {
    CMTime duration = segment.duration;
    
    if (CMTIME_IS_VALID(duration)) {
        [self _addSegment:segment duration:duration];
    } else {
        NSLog(@"Unable to read asset at url %@", segment.url);
    }
}

- (void)insertSegment:(SCRecordSessionSegment *)segment atIndex:(NSInteger)segmentIndex {
    CMTime duration = segment.duration;
    
    if (CMTIME_IS_VALID(duration)) {
        [self _insertSegment:segment atIndex:segmentIndex duration:duration];
    } else {
        NSLog(@"Unable to read asset at url %@", segment.url);
    }
}

- (void)_addSegment:(SCRecordSessionSegment *)segment duration:(CMTime)duration {
    [self dispatchSyncOnSessionQueue:^{
        [_segments addObject:segment];
        _segmentsDuration = CMTimeAdd(_segmentsDuration, duration);
    }];
}

- (void)_insertSegment:(SCRecordSessionSegment *)segment atIndex:(NSInteger)segmentIndex duration:(CMTime)duration {
    [self dispatchSyncOnSessionQueue:^{
        [_segments insertObject:segment atIndex:segmentIndex];
        _segmentsDuration = CMTimeAdd(_segmentsDuration, duration);
    }];
}

//
// The following function is from http://www.gdcl.co.uk/2013/02/20/iPhone-Pause.html
//
- (CMSampleBufferRef)adjustBuffer:(CMSampleBufferRef)sample withTimeOffset:(CMTime)offset andDuration:(CMTime)duration {
    CMItemCount count;
    CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
    CMSampleTimingInfo *pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
    CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
    
    for (CMItemCount i = 0; i < count; i++) {
        pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
        pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
        pInfo[i].duration = duration;
    }
    
    CMSampleBufferRef sout;
    CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
    free(pInfo);
    return sout;
}

- (void)beginSegment:(NSError**)error {
    [self dispatchSyncOnSessionQueue:^{
        if (_assetWriter == nil) {
            _assetWriter = [self createWriter:error];
            _currentSegmentHasAudio = NO;
            _currentSegmentHasVideo = NO;
        } else {
            if (error != nil) {
                *error = [SCRecordSession createError:@"A record segment has already began."];
            }
        }
    }];
}

- (void)_destroyAssetWriter {
    _currentSegmentHasAudio = NO;
    _currentSegmentHasVideo = NO;
    _assetWriter = nil;
    _lastTimeAudio = kCMTimeInvalid;
    _lastTimeVideo = kCMTimeInvalid;
    _currentSegmentDuration = kCMTimeZero;
    _movieFileOutput = nil;
}

- (void)appendRecordSegment:(void(^)(SCRecordSessionSegment *segment, NSError* error))completionHandler error:(NSError *)error url:(NSURL *)url duration:(CMTime)duration {
    [self dispatchSyncOnSessionQueue:^{
        SCRecordSessionSegment *segment = nil;
        
        if (error == nil) {
            segment = [SCRecordSessionSegment segmentWithURL:url];
            [self _addSegment:segment duration:duration];
        }
        
        [self _destroyAssetWriter];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionHandler != nil) {
                completionHandler(segment, error);
            }
        });
    }];
}

- (void)endSegment:(void(^)(SCRecordSessionSegment *segment, NSError* error))completionHandler {
    [self dispatchSyncOnSessionQueue:^{
        dispatch_sync(_videoQueue, ^{
            dispatch_sync(_audioQueue, ^{
                if (_recordSegmentReady) {
                    _recordSegmentReady = NO;
                    
                    AVAssetWriter *writer = _assetWriter;
                    
                    if (writer != nil) {
                        SCRecorder *recorder = self.recorder;
                        
                        BOOL currentSegmentEmpty = (!_currentSegmentHasVideo && recorder.videoEnabledAndReady) || (!_currentSegmentHasAudio && recorder.audioEnabledAndReady);
                        
                        if (currentSegmentEmpty) {
                            [writer cancelWriting];
                            [self _destroyAssetWriter];
                            
                            [self removeFile:writer.outputURL];
                            
                            if (completionHandler != nil) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    completionHandler(nil, nil);
                                });
                            }
                        } else {
                            //                NSLog(@"Ending session at %fs", CMTimeGetSeconds(_currentSegmentDuration));
                            [writer endSessionAtSourceTime:_currentSegmentDuration];
                            NSLog(@"Ended segment");
                            
                            [writer finishWritingWithCompletionHandler: ^{
                                [self appendRecordSegment:completionHandler error:writer.error url:writer.outputURL duration:_currentSegmentDuration];
                            }];
                        }
                    } else {
                        [_movieFileOutput stopRecording];
                    }
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completionHandler != nil) {
                            completionHandler(nil, [SCRecordSession createError:@"The current record segment is not ready for this operation"]);
                        }
                    });
                }
            });
        });
    }];
}

- (void)beginRecordSegmentUsingMovieFileOutput:(AVCaptureMovieFileOutput *)movieFileOutput error:(NSError *__autoreleasing *)error delegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    NSURL *url = [self nextFileURL:error];
    
    if (url != nil) {
        _movieFileOutput = movieFileOutput;
        _recordSegmentReady = YES;
        [movieFileOutput startRecordingToOutputFileURL:url recordingDelegate:delegate];
    }
}

- (void)mergeSegmentsUsingPreset:(NSString *)exportSessionPreset completionHandler:(void(^)(NSURL *outputUrl, NSError *error))completionHandler {
    [self dispatchSyncOnSessionQueue:^{
        NSString *fileType = [self _suggestedFileType];
        
        if (fileType == nil) {
            if (completionHandler != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(nil, [SCRecordSession createError:@"No output fileType was set"]);
                });
            }
            return;
        }
        
        NSString *fileExtension = [self _suggestedFileExtension];
        if (fileExtension == nil) {
            if (completionHandler != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(nil, [SCRecordSession createError:@"Unable to figure out a file extension"]);
                });
            }
            return;
        }
        
        NSString *filename = [NSString stringWithFormat:@"%@SCVideo-Merged.%@", _identifier, fileExtension];
        NSURL *outputUrl = [SCRecordSession segmentURLForFilename:filename andDirectory:_recordSegmentsDirectory];
        [self removeFile:outputUrl];

        if (_segments.count == 0) {
            if (completionHandler != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(nil, [SCRecordSession createError:@"The session does not contains any record segment"]);
                });
            }
        } else {
            AVAsset *asset = [self assetRepresentingSegments];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                AVAssetExportSession *exportSession = [AVAssetExportSession exportSessionWithAsset:asset presetName:exportSessionPreset];
                exportSession.outputURL = outputUrl;
                exportSession.outputFileType = fileType;
                exportSession.shouldOptimizeForNetworkUse = YES;
                [exportSession exportAsynchronouslyWithCompletionHandler:^{
                    NSError *error = exportSession.error;
                    
                    if (completionHandler != nil) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completionHandler(outputUrl, error);
                        });
                    }
                }];
            });

        }
    }];
}

- (void)finishEndSession:(NSError*)mergeError completionHandler:(void (^)(NSError *))completionHandler {
    if (mergeError == nil) {
        [self removeAllSegments];
        if (completionHandler != nil) {
            completionHandler(nil);
        }
    } else {
        if (completionHandler != nil) {
            completionHandler(mergeError);
        }
    }
}

- (void)cancelSession:(void (^)())completionHandler {
    [self dispatchSyncOnSessionQueue:^{
        if (_assetWriter == nil) {
            [self removeAllSegments];
            if (completionHandler != nil) {
                completionHandler();
            }
        } else {
            [self endSegment:^(SCRecordSessionSegment *segment, NSError *error) {
                [self removeAllSegments];
                if (completionHandler != nil) {
                    completionHandler();
                }
            }];
        }
    }];
}

- (CVPixelBufferRef)createPixelBuffer {
    CVPixelBufferRef outputPixelBuffer = nil;
    CVReturn ret = CVPixelBufferPoolCreatePixelBuffer(NULL, [_videoPixelBufferAdaptor pixelBufferPool], &outputPixelBuffer);
    
    if (ret != kCVReturnSuccess) {
        NSLog(@"UNABLE TO CREATE PIXEL BUFFER (CVReturnError: %d)", ret);
    }
    
    return outputPixelBuffer;
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)audioSampleBuffer completion:(void (^)(BOOL))completion {
    if ([_audioInput isReadyForMoreMediaData]) {
        CMTime actualBufferTime = CMSampleBufferGetPresentationTimeStamp(audioSampleBuffer);
        
        if (CMTIME_IS_INVALID(_timeOffset)) {
            _timeOffset = CMTimeSubtract(actualBufferTime, _currentSegmentDuration);
        }
        
        CMTime duration = CMSampleBufferGetDuration(audioSampleBuffer);
        CMSampleBufferRef adjustedBuffer = [self adjustBuffer:audioSampleBuffer withTimeOffset:_timeOffset andDuration:duration];
        
        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(adjustedBuffer);
        CMTime lastTimeAudio = CMTimeAdd(presentationTime, duration);
        
        BOOL appended = CMTIME_COMPARE_INLINE(presentationTime, >=, kCMTimeZero);
        
        if (appended) {
            CFRetain(adjustedBuffer);
            dispatch_async(_audioQueue, ^{
                if ([_audioInput appendSampleBuffer:adjustedBuffer]) {
                    _lastTimeAudio = lastTimeAudio;
                    
                    if (!_currentSegmentHasVideo) {
                        _currentSegmentDuration = lastTimeAudio;
                    }
                    
                    //            NSLog(@"Appending audio at %fs (buffer: %fs)", CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(adjustedBuffer)), CMTimeGetSeconds(actualBufferTime));
                    _currentSegmentHasAudio = YES;
                    
                    completion(YES);
                } else {
                    completion(NO);
                }
            
                CFRelease(adjustedBuffer);
            });
        } else {
            completion(NO);
        }
        
        CFRelease(adjustedBuffer);
    } else {
        completion(NO);
    }
}

- (void)appendVideoPixelBuffer:(CVPixelBufferRef)videoPixelBuffer atTime:(CMTime)actualBufferTime duration:(CMTime)duration completion:(void (^)(BOOL))completion {
    if ([_videoInput isReadyForMoreMediaData]) {
        CMTime bufferTimestamp;
        
        if (CMTIME_IS_INVALID(_timeOffset)) {
            _timeOffset = CMTimeSubtract(actualBufferTime, _currentSegmentDuration);
            //            NSLog(@"Recomputed time offset to: %fs", CMTimeGetSeconds(_timeOffset));
        }
        bufferTimestamp = CMTimeSubtract(actualBufferTime, _timeOffset);
        
        CGFloat videoTimeScale = _videoConfiguration.timeScale;
        if (videoTimeScale != 1.0) {
            CMTime computedFrameDuration = CMTimeMultiplyByFloat64(duration, videoTimeScale);
            if (_currentSegmentDuration.value > 0) {
                _timeOffset = CMTimeAdd(_timeOffset, CMTimeSubtract(duration, computedFrameDuration));
            }
            duration = computedFrameDuration;
        }
        
        //    CMTime timeVideo = _lastTimeVideo;
        //    CMTime actualBufferDuration = duration;
        //
        //    if (CMTIME_IS_VALID(timeVideo)) {
        //        while (CMTIME_COMPARE_INLINE(CMTimeSubtract(actualBufferTime, timeVideo), >=, CMTimeMultiply(actualBufferDuration, 2))) {
        //            NSLog(@"Missing buffer");
        //            timeVideo = CMTimeAdd(timeVideo, actualBufferDuration);
        //        }
        //    }

        CVPixelBufferRetain(videoPixelBuffer);
        dispatch_async(_videoQueue, ^{
            if ([_videoPixelBufferAdaptor appendPixelBuffer:videoPixelBuffer withPresentationTime:bufferTimestamp]) {
                _currentSegmentDuration = CMTimeAdd(bufferTimestamp, duration);
                _lastTimeVideo = actualBufferTime;
                
                _currentSegmentHasVideo = YES;
                completion(YES);
            } else {
                NSLog(@"Failed to append buffer");
                completion(NO);
            }
            
            CVPixelBufferRelease(videoPixelBuffer);
        });
    } else {
//        NSLog(@"Skipping video at %fs (since last time: %fs)", CMTimeGetSeconds(bufferTimestamp), CMTimeGetSeconds(CMTimeSubtract(actualBufferTime, _lastTimeVideo)));
        _lastTimeVideo = actualBufferTime;

        completion(NO);
    }
}

- (CMTime)_appendTrack:(AVAssetTrack *)track toCompositionTrack:(AVMutableCompositionTrack *)compositionTrack atTime:(CMTime)time withBounds:(CMTime)bounds {
    CMTimeRange timeRange = track.timeRange;
    time = CMTimeAdd(time, timeRange.start);
    
    if (CMTIME_IS_VALID(bounds)) {
        CMTime currentBounds = CMTimeAdd(time, timeRange.duration);

        if (CMTIME_COMPARE_INLINE(currentBounds, >, bounds)) {
            timeRange = CMTimeRangeMake(timeRange.start, CMTimeSubtract(timeRange.duration, CMTimeSubtract(currentBounds, bounds)));
        }
    }
    
    if (CMTIME_COMPARE_INLINE(timeRange.duration, >, kCMTimeZero)) {
        NSError *error = nil;
        [compositionTrack insertTimeRange:timeRange ofTrack:track atTime:time error:&error];
        
        if (error != nil) {
            NSLog(@"Failed to insert append %@ track: %@", compositionTrack.mediaType, error);
        } else {
            //        NSLog(@"Inserted %@ at %fs (%fs -> %fs)", track.mediaType, CMTimeGetSeconds(time), CMTimeGetSeconds(timeRange.start), CMTimeGetSeconds(timeRange.duration));
        }
        
        return CMTimeAdd(time, timeRange.duration);
    }
    
    return time;
}

- (void)appendSegmentsToComposition:(AVMutableComposition *)composition {
    [self dispatchSyncOnSessionQueue:^{
        AVMutableCompositionTrack *audioTrack = nil;
        AVMutableCompositionTrack *videoTrack = nil;
        
        int currentSegment = 0;
        CMTime currentTime = kCMTimeZero;
        for (SCRecordSessionSegment *recordSegment in _segments) {
            AVAsset *asset = recordSegment.asset;
            
            NSArray *audioAssetTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
            NSArray *videoAssetTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            
            CMTime maxBounds = kCMTimeInvalid;
            
            CMTime videoTime = currentTime;
            for (AVAssetTrack *videoAssetTrack in videoAssetTracks) {
                if (videoTrack == nil) {
                    videoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
                    videoTrack.preferredTransform = videoAssetTrack.preferredTransform;
                }
                
                videoTime = [self _appendTrack:videoAssetTrack toCompositionTrack:videoTrack atTime:videoTime withBounds:maxBounds];
                maxBounds = videoTime;
            }
            
            CMTime audioTime = currentTime;
            for (AVAssetTrack *audioAssetTrack in audioAssetTracks) {
                if (audioTrack == nil) {
                    audioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
                }
                
                audioTime = [self _appendTrack:audioAssetTrack toCompositionTrack:audioTrack atTime:audioTime withBounds:maxBounds];
            }
            
            currentTime = composition.duration;
            
            currentSegment++;
        }
    }];
}

- (AVAsset *)assetRepresentingSegments {
    __block AVAsset *asset = nil;
    [self dispatchSyncOnSessionQueue:^{
        if (_segments.count == 1) {
            SCRecordSessionSegment *segment = _segments.firstObject;
            asset = segment.asset;
        } else {
            AVMutableComposition *composition = [AVMutableComposition composition];
            [self appendSegmentsToComposition:composition];
            
            asset = composition;
        }
    }];

    return asset;
}

- (BOOL)videoInitialized {
    return _videoInput != nil;
}

- (BOOL)audioInitialized {
    return _audioInput != nil;
}

- (BOOL)recordSegmentBegan {
    return _assetWriter != nil || _movieFileOutput != nil;
}

- (BOOL)recordSegmentReady {
    return _recordSegmentReady;
}

- (BOOL)currentSegmentHasVideo {
    return _currentSegmentHasVideo;
}

- (BOOL)currentSegmentHasAudio {
    return _currentSegmentHasAudio;
}

- (CMTime)currentRecordDuration {
    return CMTimeAdd(_segmentsDuration, _movieFileOutput != nil ? _movieFileOutput.recordedDuration : _currentSegmentDuration);
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *recordSegments = [NSMutableArray array];
    
    for (SCRecordSessionSegment *recordSegment in self.segments) {
        [recordSegments addObject:recordSegment.url.lastPathComponent];
    }
    
    return @{
             SCRecordSessionSegmentFilenamesKey: recordSegments,
             SCRecordSessionDurationKey : [NSNumber numberWithDouble:CMTimeGetSeconds(_segmentsDuration)],
             SCRecordSessionIdentifierKey : _identifier,
             SCRecordSessionDateKey : _date,             
             SCRecordSessionDirectoryKey : _recordSegmentsDirectory
             };
}

- (NSURL *)outputUrl {
    NSString *fileType = [self _suggestedFileType];
    
    if (fileType == nil) {
        return nil;
    }
    
    NSString *fileExtension = [self _suggestedFileExtension];
    if (fileExtension == nil) {
        return nil;
    }
    
    NSString *filename = [NSString stringWithFormat:@"%@SCVideo-Merged.%@", _identifier, fileExtension];
    
    return [SCRecordSession segmentURLForFilename:filename andDirectory:_recordSegmentsDirectory];
}

- (BOOL)isUsingMovieFileOutput {
    return _movieFileOutput != nil;
}

@end
