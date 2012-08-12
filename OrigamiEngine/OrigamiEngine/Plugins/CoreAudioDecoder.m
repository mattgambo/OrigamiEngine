#import <unistd.h>
#import <AudioToolbox/AudioToolbox.h>

#import "CoreAudioDecoder.h"

@interface CoreAudioDecoder () {
    id<ORGMSource>  _source;
    AudioFileID     _audioFile;
	ExtAudioFileRef	_in;
    
	int bitrate;
	int bitsPerSample;
	int channels;
	float frequency;
	long totalFrames;
}
@property (nonatomic, retain) NSMutableDictionary* metadata;
@end

@implementation CoreAudioDecoder

- (void)dealloc {
    [self close];
    [_source release];
    [_metadata release];
    [super dealloc];
}

#pragma mark - ORGMDecoder
+ (NSArray*)fileTypes {
	OSStatus			err;
	UInt32				size;
	NSArray *sAudioExtensions;
	
	size = sizeof(sAudioExtensions);
	err	= AudioFileGetGlobalInfo(kAudioFileGlobalInfo_AllExtensions, 0, NULL,
                                 &size, &sAudioExtensions);
	if(noErr != err) {
		return nil;
	}
	
	return [sAudioExtensions autorelease];
}

- (NSDictionary*)properties {
	return [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:channels], @"channels",
            [NSNumber numberWithInt:bitsPerSample], @"bitsPerSample",
            [NSNumber numberWithInt:bitrate], @"bitrate",
            [NSNumber numberWithFloat:frequency], @"sampleRate",
            [NSNumber numberWithLong:totalFrames], @"totalFrames",
            [NSNumber numberWithBool:YES], @"seekable",
            @"big", @"endian",
            nil];
}

- (NSMutableDictionary *)metadata {
    return _metadata;
}

- (int)readAudio:(void*)buf frames:(UInt32)frames {
	OSStatus		err;
	AudioBufferList	bufferList;
	UInt32			frameCount;
	
	bufferList.mNumberBuffers			   = 1;
	bufferList.mBuffers[0].mNumberChannels = channels;
	bufferList.mBuffers[0].mData		   = buf;
	bufferList.mBuffers[0].mDataByteSize   = frames * channels * (bitsPerSample/8);
	
	frameCount = frames;
	err		   = ExtAudioFileRead(_in, &frameCount, &bufferList);
	if(err != noErr) {
		return 0;
	}
	
	return frameCount;
}

- (BOOL)open:(id<ORGMSource>)source {
    self.metadata = [NSDictionary dictionary];
    _source = [source retain];
	OSStatus result = AudioFileOpenWithCallbacks(_source, audioFile_ReadProc, NULL,
                                                 audioFile_GetSizeProc, NULL, 0,
                                                 &_audioFile);
    
    if(noErr != result) {
        return NO;
    }
    
	result = ExtAudioFileWrapAudioFileID(_audioFile, false, &_in);
	if(noErr != result) {
		return NO;
	}
	
	return [self readInfoFromExtAudioFileRef];
}

- (long)seek:(long)frame {
	OSStatus err;
	
	err = ExtAudioFileSeek(_in, frame);
	if(noErr != err) {
		return -1;
	}
	
	return frame;
}

- (void)close {
    ExtAudioFileDispose(_in);
    AudioFileClose(_audioFile);
    [_source close];
}

#pragma mark - private
- (BOOL)readInfoFromExtAudioFileRef {
	OSStatus					err;
	UInt32						size;
	AudioStreamBasicDescription	asbd;
	
	size = sizeof(asbd);
	err	 = ExtAudioFileGetProperty(_in, kExtAudioFileProperty_FileDataFormat,
                                   &size, &asbd);
	if(err != noErr) {
        ExtAudioFileDispose(_in);
		return NO;
	}
	
	SInt64 total;
	size = sizeof(total);
	err	 = ExtAudioFileGetProperty(_in, kExtAudioFileProperty_FileLengthFrames,
                                   &size, &total);
	if(err != noErr) {
		err = ExtAudioFileDispose(_in);
		return NO;
	}
	totalFrames = (long)total;	
    
    AudioFileID audioFile;
    size = sizeof(AudioFileID);
    err = ExtAudioFileGetProperty(_in,
                                  kExtAudioFileProperty_AudioFile,
                                  &size,
                                  &audioFile);
    if (err == noErr) {
        UInt32 dictionarySize = 0;
        err = AudioFileGetPropertyInfo(audioFile,
                                       kAudioFilePropertyInfoDictionary,
                                       &dictionarySize,
                                       0);
        if (err == noErr) {
            CFDictionaryRef dictionary;
            AudioFileGetProperty(audioFile,
                                 kAudioFilePropertyInfoDictionary,
                                 &dictionarySize,
                                 &dictionary);
            self.metadata =
                [NSMutableDictionary dictionaryWithDictionary:(NSDictionary*)dictionary];
            CFRelease(dictionary);
        }
        
        err = AudioFileGetPropertyInfo(audioFile,
                                       kAudioFilePropertyAlbumArtwork,
                                       &dictionarySize,
                                       0);
        if (err == noErr) {
            CFDataRef data;
            AudioFileGetProperty (audioFile,
                                  kAudioFilePropertyInfoDictionary,
                                  &dictionarySize,
                                  &data);
            [self.metadata setObject:[NSData dataWithData:(NSData*)data]
                              forKey:@"picture"];
            CFRelease(data);
        }
    }
    
	bitrate	= 0;
	bitsPerSample = asbd.mBitsPerChannel;
	channels	  = asbd.mChannelsPerFrame;
	frequency	  = asbd.mSampleRate;
	
	if(0 == bitsPerSample) {
		bitsPerSample = 16;
	}
	
	AudioStreamBasicDescription	result;
	bzero(&result, sizeof(AudioStreamBasicDescription));
	
	result.mFormatID	= kAudioFormatLinearPCM;
	result.mFormatFlags	= kAudioFormatFlagIsSignedInteger |
                          kLinearPCMFormatFlagIsBigEndian;
	
	result.mSampleRate		 = frequency;
	result.mChannelsPerFrame = channels;
	result.mBitsPerChannel	 = bitsPerSample;
	
	result.mBytesPerPacket	 = channels * (bitsPerSample / 8);
	result.mFramesPerPacket  = 1;
	result.mBytesPerFrame	 = channels * (bitsPerSample / 8);
	
	err = ExtAudioFileSetProperty(_in, kExtAudioFileProperty_ClientDataFormat,
                                  sizeof(result), &result);
	if(noErr != err) {
		err = ExtAudioFileDispose(_in);
		return NO;
	}
		
	return YES;
}

#pragma mark - callback functions
static OSStatus audioFile_ReadProc(void *inClientData,
                                   SInt64 inPosition,
                                   UInt32 requestCount,
                                   void	 *buffer,
                                   UInt32 *actualCount) {
    id<ORGMSource> source = inClientData;
    [source seek:(long)inPosition whence:0];
	*actualCount = [source read:buffer amount:requestCount];
    
	return noErr;
}

static SInt64 audioFile_GetSizeProc(void *inClientData) {
	id<ORGMSource> source = inClientData;
    SInt64 len = [source size];
	return len;
}

@end
