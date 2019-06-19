//
//  XDXFFmpegVideoDecoder.m
//  XDXVideoDecoder
//
//  Created by 小东邪 on 2019/6/6.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "XDXFFmpegVideoDecoder.h"
#include "log4cplus.h"

#define kModuleName "XDXParseHandler"

@interface XDXFFmpegVideoDecoder ()
{
    /*  FFmpeg  */
    AVFormatContext          *m_formatContext;
    AVCodecContext           *m_videoCodecContext;
    AVFrame                  *m_videoFrame;
    
    int     m_videoStreamIndex;
    BOOL    m_isFindIDR;
    int64_t m_base_time;
}

@end

@implementation XDXFFmpegVideoDecoder

#pragma mark - C Function
AVBufferRef *hw_device_ctx = NULL;
static int InitHardwareDecoder(AVCodecContext *ctx, const enum AVHWDeviceType type) {
    int err = av_hwdevice_ctx_create(&hw_device_ctx, type, NULL, NULL, 0);
    if (err < 0) {
        log4cplus_error("XDXParseParse", "Failed to create specified HW device.\n");
        return err;
    }
    ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
    return err;
}

static int DecodeGetAVStreamFPSTimeBase(AVStream *st) {
    CGFloat fps, timebase = 0.0;
    
    if (st->time_base.den && st->time_base.num)
        timebase = av_q2d(st->time_base);
    else if(st->codec->time_base.den && st->codec->time_base.num)
        timebase = av_q2d(st->codec->time_base);
    
    if (st->avg_frame_rate.den && st->avg_frame_rate.num)
        fps = av_q2d(st->avg_frame_rate);
    else if (st->r_frame_rate.den && st->r_frame_rate.num)
        fps = av_q2d(st->r_frame_rate);
    else
        fps = 1.0 / timebase;
    
    return fps;
}

#pragma mark - Lifecycle
- (instancetype)initWithFormatContext:(AVFormatContext *)formatContext videoStreamIndex:(int)videoStreamIndex {
    if (self = [super init]) {
        m_formatContext     = formatContext;
        m_videoStreamIndex  = videoStreamIndex;
        
        m_isFindIDR = NO;
        m_base_time = 0;
        
        [self initDecoder];
    }
    return self;
}

- (void)initDecoder {
    AVStream *videoStream = m_formatContext->streams[m_videoStreamIndex];
    m_videoCodecContext = [self createVideoEncderWithFormatContext:m_formatContext
                                                            stream:videoStream
                                                  videoStreamIndex:m_videoStreamIndex];
    if (!m_videoCodecContext) {
        log4cplus_error(kModuleName, "%s: create video codec failed",__func__);
        return;
    }
    
    // Get video frame
    m_videoFrame = av_frame_alloc();
    if (!m_videoFrame) {
        log4cplus_error(kModuleName, "%s: alloc video frame failed",__func__);
        avcodec_close(m_videoCodecContext);
    }
}

#pragma mark - Public
- (void)startDecodeVideoDataWithAVPacket:(AVPacket)packet {
    if (packet.flags == 1 && m_isFindIDR == NO) {
        m_isFindIDR = YES;
        m_base_time =  m_videoFrame->pts;
    }
    
    if (m_isFindIDR == YES) {
        [self startDecodeVideoDataWithAVPacket:packet
                             videoCodecContext:m_videoCodecContext
                                    videoFrame:m_videoFrame
                                      baseTime:m_base_time
                              videoStreamIndex:m_videoStreamIndex];
    }
}

- (void)stopDecoder {
    [self freeAllResources];
}

#pragma mark - Private
- (AVCodecContext *)createVideoEncderWithFormatContext:(AVFormatContext *)formatContext stream:(AVStream *)stream videoStreamIndex:(int)videoStreamIndex {
    AVCodecContext *codecContext = NULL;
    AVCodec *codec = NULL;
    
    const char *codecName = av_hwdevice_get_type_name(AV_HWDEVICE_TYPE_VIDEOTOOLBOX);
    enum AVHWDeviceType type = av_hwdevice_find_type_by_name(codecName);
    if (type != AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
        log4cplus_error(kModuleName, "%s: Not find hardware codec.",__func__);
        return NULL;
    }
    
    int ret = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (ret < 0) {
        log4cplus_error(kModuleName, "av_find_best_stream faliture");
        return NULL;
    }
    
    codecContext = avcodec_alloc_context3(codec);
    if (!codecContext){
        log4cplus_error(kModuleName, "avcodec_alloc_context3 faliture");
        return NULL;
    }
    
    ret = avcodec_parameters_to_context(codecContext, formatContext->streams[videoStreamIndex]->codecpar);
    if (ret < 0){
        log4cplus_error(kModuleName, "avcodec_parameters_to_context faliture");
        return NULL;
    }
    
    ret = InitHardwareDecoder(codecContext, type);
    if (ret < 0){
        log4cplus_error(kModuleName, "hw_decoder_init faliture");
        return NULL;
    }
    
    ret = avcodec_open2(codecContext, codec, NULL);
    if (ret < 0) {
        log4cplus_error(kModuleName, "avcodec_open2 faliture");
        return NULL;
    }
    
    return codecContext;
}

- (void)startDecodeVideoDataWithAVPacket:(AVPacket)packet videoCodecContext:(AVCodecContext *)videoCodecContext videoFrame:(AVFrame *)videoFrame baseTime:(int64_t)baseTime videoStreamIndex:(int)videoStreamIndex {
    Float64 current_timestamp = [self getCurrentTimestamp];
    AVStream *videoStream = m_formatContext->streams[videoStreamIndex];
    int fps = DecodeGetAVStreamFPSTimeBase(videoStream);
    
    
    avcodec_send_packet(videoCodecContext, &packet);
    while (0 == avcodec_receive_frame(videoCodecContext, videoFrame))
    {
        CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)videoFrame->data[3];
        CMTime presentationTimeStamp = kCMTimeInvalid;
        int64_t originPTS = videoFrame->pts;
        int64_t newPTS    = originPTS - baseTime;
        presentationTimeStamp = CMTimeMakeWithSeconds(current_timestamp + newPTS * av_q2d(videoStream->time_base) , fps);
        CMSampleBufferRef sampleBufferRef = [self convertCVImageBufferRefToCMSampleBufferRef:(CVPixelBufferRef)pixelBuffer
                                                                   withPresentationTimeStamp:presentationTimeStamp];
        
        if (sampleBufferRef) {
            if ([self.delegate respondsToSelector:@selector(getDecodeVideoDataByFFmpeg:)]) {
                [self.delegate getDecodeVideoDataByFFmpeg:sampleBufferRef];
            }
            
            CFRelease(sampleBufferRef);
        }
    }
}

- (void)freeAllResources {
    if (m_videoCodecContext) {
        avcodec_send_packet(m_videoCodecContext, NULL);
        avcodec_flush_buffers(m_videoCodecContext);
        
        if (m_videoCodecContext->hw_device_ctx) {
            av_buffer_unref(&m_videoCodecContext->hw_device_ctx);
            m_videoCodecContext->hw_device_ctx = NULL;
        }
        avcodec_close(m_videoCodecContext);
        m_videoCodecContext = NULL;
    }
    
    if (m_videoFrame) {
        av_free(m_videoFrame);
        m_videoFrame = NULL;
    }
}

#pragma mark - Other
- (CMSampleBufferRef)convertCVImageBufferRefToCMSampleBufferRef:(CVImageBufferRef)pixelBuffer withPresentationTimeStamp:(CMTime)presentationTimeStamp
{
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    CMSampleBufferRef newSampleBuffer = NULL;
    OSStatus res = 0;
    
    CMSampleTimingInfo timingInfo;
    timingInfo.duration              = kCMTimeInvalid;
    timingInfo.decodeTimeStamp       = presentationTimeStamp;
    timingInfo.presentationTimeStamp = presentationTimeStamp;
    
    CMVideoFormatDescriptionRef videoInfo = NULL;
    res = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &videoInfo);
    if (res != 0) {
        log4cplus_error(kModuleName, "%s: Create video format description failed!",__func__);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return NULL;
    }
    
    res = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                             pixelBuffer,
                                             true,
                                             NULL,
                                             NULL,
                                             videoInfo,
                                             &timingInfo, &newSampleBuffer);
    
    CFRelease(videoInfo);
    if (res != 0) {
        log4cplus_error(kModuleName, "%s: Create sample buffer failed!",__func__);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return NULL;
        
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return newSampleBuffer;
}


- (Float64)getCurrentTimestamp {
    CMClockRef hostClockRef = CMClockGetHostTimeClock();
    CMTime hostTime = CMClockGetTime(hostClockRef);
    return CMTimeGetSeconds(hostTime);
}

@end
