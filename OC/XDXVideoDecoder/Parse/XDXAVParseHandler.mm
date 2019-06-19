//
//  XDXAVParseHandler.m
//  XDXVideoDecoder
//
//  Created by 小东邪 on 2019/6/2.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "XDXAVParseHandler.h"
#import <UIKit/UIKit.h>
#include "log4cplus.h"

#pragma mark - Global Var

#define kModuleName "XDXParseHandler"

static const int kXDXParseSupportMaxFps     = 60;
static const int kXDXParseFpsOffSet         = 5;
static const int kXDXParseWidth1920         = 1920;
static const int kXDXParseHeight1080        = 1080;
static const int kXDXParseSupportMaxWidth   = 3840;
static const int kXDXParseSupportMaxHeight  = 2160;

@interface XDXAVParseHandler ()
{
    /*  Flag  */
    BOOL m_isStopParse;
    
    /*  FFmpeg  */
    AVFormatContext          *m_formatContext;
    AVBitStreamFilterContext *m_bitFilterContext;
//    AVBSFContext             *m_bsfContext;
    
    int m_videoStreamIndex;
    int m_audioStreamIndex;
    
    /*  Video info  */
    int m_video_width, m_video_height, m_video_fps;
}

@end

@implementation XDXAVParseHandler

#pragma mark - C Function
static int GetAVStreamFPSTimeBase(AVStream *st) {
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

#pragma mark - Init
+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        av_register_all();
    });
}

- (instancetype)initWithPath:(NSString *)path {
    if (self = [super init]) {
        [self prepareParseWithPath:path];
    }
    return self;
}

#pragma mark - public methods
- (void)startParseWithCompletionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, struct XDXParseVideoDataInfo *videoInfo, struct XDXParseAudioDataInfo *audioInfo))handler {
    [self startParseWithFormatContext:m_formatContext
                     videoStreamIndex:m_videoStreamIndex
                     audioStreamIndex:m_audioStreamIndex
                    completionHandler:handler];
}

- (void)startParseGetAVPackeWithCompletionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, AVPacket packet))handler {
    [self startParseGetAVPacketWithFormatContext:m_formatContext
                                videoStreamIndex:m_videoStreamIndex
                                audioStreamIndex:m_audioStreamIndex
                               completionHandler:handler];
}

- (void)stopParse {
    m_isStopParse = YES;
}

#pragma mark Get Method
- (AVFormatContext *)getFormatContext {
    return m_formatContext;
}

- (int)getVideoStreamIndex {
    return m_videoStreamIndex;
}

- (int)getAudioStreamIndex {
    return m_audioStreamIndex;
}

#pragma mark - Private
#pragma mark Prepare
- (void)prepareParseWithPath:(NSString *)path {
    // Create format context
    m_formatContext = [self createFormatContextbyFilePath:path];
    
    if (m_formatContext == NULL) {
        log4cplus_error(kModuleName, "%s: create format context failed.",__func__);
        return;
    }
    
    // Get video stream index
    m_videoStreamIndex = [self getAVStreamIndexWithFormatContext:m_formatContext
                                                   isVideoStream:YES];
    
    // Get video stream
    AVStream *videoStream = m_formatContext->streams[m_videoStreamIndex];
    m_video_width  = videoStream->codecpar->width;
    m_video_height = videoStream->codecpar->height;
    m_video_fps    = GetAVStreamFPSTimeBase(videoStream);
    log4cplus_info(kModuleName, "%s: video index:%d, width:%d, height:%d, fps:%d",__func__,m_videoStreamIndex,m_video_width,m_video_height,m_video_fps);
    
    BOOL isSupport = [self isSupportVideoStream:videoStream
                                  formatContext:m_formatContext
                                    sourceWidth:m_video_width
                                   sourceHeight:m_video_height
                                      sourceFps:m_video_fps];
    if (!isSupport) {
        log4cplus_error(kModuleName, "%s: Not support the video stream",__func__);
        return;
    }
    
    // Get audio stream index
    m_audioStreamIndex = [self getAVStreamIndexWithFormatContext:m_formatContext
                                                   isVideoStream:NO];
    
    // Get audio stream
    AVStream *audioStream = m_formatContext->streams[m_audioStreamIndex];
    
    isSupport = [self isSupportAudioStream:audioStream
                             formatContext:m_formatContext];
    if (!isSupport) {
        log4cplus_error(kModuleName, "%s: Not support the audio stream",__func__);
        return;
    }
}

- (AVFormatContext *)createFormatContextbyFilePath:(NSString *)filePath {
    if (filePath == nil) {
        log4cplus_error(kModuleName, "%s: file path is NULL",__func__);
        return NULL;
    }
    
    AVFormatContext  *formatContext = NULL;
    AVDictionary     *opts          = NULL;
    
    av_dict_set(&opts, "timeout", "1000000", 0);//设置超时1秒
    
    formatContext = avformat_alloc_context();
    BOOL isSuccess = avformat_open_input(&formatContext, [filePath cStringUsingEncoding:NSUTF8StringEncoding], NULL, &opts) < 0 ? NO : YES;
    av_dict_free(&opts);
    if (!isSuccess) {
        if (formatContext) {
            avformat_free_context(formatContext);
        }
        return NULL;
    }
    
    if (avformat_find_stream_info(formatContext, NULL) < 0) {
        avformat_close_input(&formatContext);
        return NULL;
    }
    
    return formatContext;
}

- (int)getAVStreamIndexWithFormatContext:(AVFormatContext *)formatContext isVideoStream:(BOOL)isVideoStream {
    int avStreamIndex = -1;
    for (int i = 0; i < formatContext->nb_streams; i++) {
        if ((isVideoStream ? AVMEDIA_TYPE_VIDEO : AVMEDIA_TYPE_AUDIO) == formatContext->streams[i]->codecpar->codec_type) {
            avStreamIndex = i;
        }
    }
    
    if (avStreamIndex == -1) {
        log4cplus_error(kModuleName, "%s: Not find video stream",__func__);
        return NULL;
    }else {
        return avStreamIndex;
    }
}

- (BOOL)isSupportVideoStream:(AVStream *)stream formatContext:(AVFormatContext *)formatContext sourceWidth:(int)sourceWidth sourceHeight:(int)sourceHeight sourceFps:(int)sourceFps {
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {   // Video
        AVCodecID codecID = stream->codecpar->codec_id;
        log4cplus_info(kModuleName, "%s: Current video codec format is %s",__func__, avcodec_find_decoder(codecID)->name);
        // 目前只支持H264、H265(HEVC iOS11)编码格式的视频文件
        if ((codecID != AV_CODEC_ID_H264 && codecID != AV_CODEC_ID_HEVC) || (codecID == AV_CODEC_ID_HEVC && [[UIDevice currentDevice].systemVersion floatValue] < 11.0)) {
            log4cplus_error(kModuleName, "%s: Not suuport the codec",__func__);
            return NO;
        }
        
        // iPhone 8以上机型支持有旋转角度的视频
        AVDictionaryEntry *tag = NULL;
        tag = av_dict_get(formatContext->streams[m_videoStreamIndex]->metadata, "rotate", tag, 0);
        if (tag != NULL) {
            int rotate = [[NSString stringWithFormat:@"%s",tag->value] intValue];
            if (rotate != 0 /* && >= iPhone 8P*/) {
                log4cplus_error(kModuleName, "%s: Not support rotate for device ",__func__);
            }
        }
        
        /*
         各机型支持的最高分辨率和FPS组合:
         
         iPhone 6S: 60fps -> 720P
         30fps -> 4K
         
         iPhone 7P: 60fps -> 1080p
         30fps -> 4K
         
         iPhone 8: 60fps -> 1080p
         30fps -> 4K
         
         iPhone 8P: 60fps -> 1080p
         30fps -> 4K
         
         iPhone X: 60fps -> 1080p
         30fps -> 4K
         
         iPhone XS: 60fps -> 1080p
         30fps -> 4K
         */
        
        // 目前最高支持到60FPS
        if (sourceFps > kXDXParseSupportMaxFps + kXDXParseFpsOffSet) {
            log4cplus_error(kModuleName, "%s: Not support the fps",__func__);
            return NO;
        }
        
        // 目前最高支持到3840*2160
        if (sourceWidth > kXDXParseSupportMaxWidth || sourceHeight > kXDXParseSupportMaxHeight) {
            log4cplus_error(kModuleName, "%s: Not support the resolution",__func__);
            return NO;
        }
        
        // 60FPS -> 1080P
        if (sourceFps > kXDXParseSupportMaxFps - kXDXParseFpsOffSet && (sourceWidth > kXDXParseWidth1920 || sourceHeight > kXDXParseHeight1080)) {
            log4cplus_error(kModuleName, "%s: Not support the fps and resolution",__func__);
            return NO;
        }
        
        // 30FPS -> 4K
        if (sourceFps > kXDXParseSupportMaxFps / 2 + kXDXParseFpsOffSet && (sourceWidth >= kXDXParseSupportMaxWidth || sourceHeight >= kXDXParseSupportMaxHeight)) {
            log4cplus_error(kModuleName, "%s: Not support the fps and resolution",__func__);
            return NO;
        }
        
        // 6S
//        if ([[XDXAnywhereTool deviceModelName] isEqualToString:@"iPhone 6s"] && sourceFps > kXDXParseSupportMaxFps - kXDXParseFpsOffSet && (sourceWidth >= kXDXParseWidth1920  || sourceHeight >= kXDXParseHeight1080)) {
//            log4cplus_error(kModuleName, "%s: Not support the fps and resolution",__func__);
//            return NO;
//        }
        return YES;
    }else {
        return NO;
    }
    
}

- (BOOL)isSupportAudioStream:(AVStream *)stream formatContext:(AVFormatContext *)formatContext {
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
        AVCodecID codecID = stream->codecpar->codec_id;
        log4cplus_info(kModuleName, "%s: Current audio codec format is %s",__func__, avcodec_find_decoder(codecID)->name);
        // 本项目只支持AAC格式的音频
        if (codecID != AV_CODEC_ID_AAC) {
            log4cplus_error(kModuleName, "%s: Only support AAC format for the demo.",__func__);
            return NO;
        }
        
        return YES;
    }else {
        return NO;
    }
}

#pragma mark Start Parse
- (void)startParseWithFormatContext:(AVFormatContext *)formatContext videoStreamIndex:(int)videoStreamIndex audioStreamIndex:(int)audioStreamIndex completionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, struct XDXParseVideoDataInfo *videoInfo, struct XDXParseAudioDataInfo *audioInfo))handler{
    m_isStopParse = NO;
    
    dispatch_queue_t parseQueue = dispatch_queue_create("parse_queue", DISPATCH_QUEUE_SERIAL);
    dispatch_async(parseQueue, ^{
        int fps = GetAVStreamFPSTimeBase(formatContext->streams[videoStreamIndex]);
        
        AVPacket    packet;
        AVRational  input_base;
        input_base.num = 1;
        input_base.den = 1000;
        
        Float64 current_timestamp = [self getCurrentTimestamp];
        while (!self->m_isStopParse) {
            av_init_packet(&packet);
            if (!formatContext) {
                break;
            }
            
            int size = av_read_frame(formatContext, &packet);
            if (size < 0 || packet.size < 0) {
                handler(YES, YES, NULL, NULL);
                log4cplus_error(kModuleName, "%s: Parse finish",__func__);
                break;
            }
            
            if (packet.stream_index == videoStreamIndex) {
                XDXParseVideoDataInfo videoInfo = {0};
                
                // get the rotation angle of video
                AVDictionaryEntry *tag = NULL;
                tag = av_dict_get(formatContext->streams[videoStreamIndex]->metadata, "rotate", tag, 0);
                if (tag != NULL) {
                    int rotate = [[NSString stringWithFormat:@"%s",tag->value] intValue];
                    switch (rotate) {
                        case 90:
                            videoInfo.videoRotate = 90;
                            break;
                        case 180:
                            videoInfo.videoRotate = 180;
                            break;
                        case 270:
                            videoInfo.videoRotate = 270;
                            break;
                        default:
                            videoInfo.videoRotate = 0;
                            break;
                    }
                }
                
                if (videoInfo.videoRotate != 0 /* &&  <= iPhone 8*/) {
                    log4cplus_error(kModuleName, "%s: Not support the angle",__func__);
                    break;
                }
                
                int video_size = packet.size;
                uint8_t *video_data = (uint8_t *)malloc(video_size);
                memcpy(video_data, packet.data, video_size);
                
                static char filter_name[32];
                if (formatContext->streams[videoStreamIndex]->codecpar->codec_id == AV_CODEC_ID_H264) {
                    strncpy(filter_name, "h264_mp4toannexb", 32);
                    videoInfo.videoFormat = XDXH264EncodeFormat;
                } else if (formatContext->streams[videoStreamIndex]->codecpar->codec_id == AV_CODEC_ID_HEVC) {
                    strncpy(filter_name, "hevc_mp4toannexb", 32);
                    videoInfo.videoFormat = XDXH265EncodeFormat;
                } else {
                    break;
                }
                
                /* new API can't get correct sps, pps.
                if (!self->m_bsfContext) {
                    const AVBitStreamFilter *filter = av_bsf_get_by_name(filter_name);
                    av_bsf_alloc(filter, &self->m_bsfContext);
                    av_bsf_init(self->m_bsfContext);
                    avcodec_parameters_copy(self->m_bsfContext->par_in, formatContext->streams[videoStreamIndex]->codecpar);
                }
                */
                
                // get sps,pps. If not call it, get sps , pps is incorrect. use new_packet to resolve memory leak.
                AVPacket new_packet = packet;
                if (self->m_bitFilterContext == NULL) {
                    self->m_bitFilterContext = av_bitstream_filter_init(filter_name);
                }
                av_bitstream_filter_filter(self->m_bitFilterContext, formatContext->streams[videoStreamIndex]->codec, NULL, &new_packet.data, &new_packet.size, packet.data, packet.size, 0);
                
                //log4cplus_info(kModuleName, "%s: extra data : %s , size : %d",__func__,formatContext->streams[videoStreamIndex]->codec->extradata,formatContext->streams[videoStreamIndex]->codec->extradata_size);
                
                CMSampleTimingInfo timingInfo;
                CMTime presentationTimeStamp     = kCMTimeInvalid;
                presentationTimeStamp            = CMTimeMakeWithSeconds(current_timestamp + packet.pts * av_q2d(formatContext->streams[videoStreamIndex]->time_base), fps);
                timingInfo.presentationTimeStamp = presentationTimeStamp;
                timingInfo.decodeTimeStamp       = CMTimeMakeWithSeconds(current_timestamp + av_rescale_q(packet.dts, formatContext->streams[videoStreamIndex]->time_base, input_base), fps);
                
                videoInfo.data          = video_data;
                videoInfo.dataSize      = video_size;
                videoInfo.extraDataSize = formatContext->streams[videoStreamIndex]->codec->extradata_size;
                videoInfo.extraData     = (uint8_t *)malloc(videoInfo.extraDataSize);
                videoInfo.timingInfo    = timingInfo;
                videoInfo.pts           = packet.pts * av_q2d(formatContext->streams[videoStreamIndex]->time_base);
                videoInfo.fps           = fps;
                
                memcpy(videoInfo.extraData, formatContext->streams[videoStreamIndex]->codec->extradata, videoInfo.extraDataSize);
                av_free(new_packet.data);
                
                // send videoInfo
                if (handler) {
                    handler(YES, NO, &videoInfo, NULL);
                }
                
                free(videoInfo.extraData);
                free(videoInfo.data);
            }
            
            if (packet.stream_index == audioStreamIndex) {
                XDXParseAudioDataInfo audioInfo = {0};
                audioInfo.data = (uint8_t *)malloc(packet.size);
                memcpy(audioInfo.data, packet.data, packet.size);
                audioInfo.dataSize = packet.size;
                audioInfo.channel = formatContext->streams[audioStreamIndex]->codecpar->channels;
                audioInfo.sampleRate = formatContext->streams[audioStreamIndex]->codecpar->sample_rate;
                audioInfo.pts = packet.pts * av_q2d(formatContext->streams[audioStreamIndex]->time_base);
                
                // send audio info
                if (handler) {
                    handler(NO, NO, NULL, &audioInfo);
                }
                
                free(audioInfo.data);
            }
            
            av_packet_unref(&packet);
        }
        
        [self freeAllResources];
    });
}

- (void)startParseGetAVPacketWithFormatContext:(AVFormatContext *)formatContext videoStreamIndex:(int)videoStreamIndex audioStreamIndex:(int)audioStreamIndex completionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, AVPacket packet))handler{
    m_isStopParse = NO;
    dispatch_queue_t parseQueue = dispatch_queue_create("parse_queue", DISPATCH_QUEUE_SERIAL);
    dispatch_async(parseQueue, ^{
        AVPacket    packet;
        while (!self->m_isStopParse) {
            if (!formatContext) {
                break;
            }

            av_init_packet(&packet);            
            int size = av_read_frame(formatContext, &packet);
            if (size < 0 || packet.size < 0) {
                handler(YES, YES, packet);
                log4cplus_error(kModuleName, "%s: Parse finish",__func__);
                break;
            }
            
            if (packet.stream_index == videoStreamIndex) {
                handler(YES, NO, packet);
            }else {
                handler(NO, NO, packet);
            }
            
            av_packet_unref(&packet);
        }
        
        [self freeAllResources];
    });
}


- (void)freeAllResources {
    log4cplus_error(kModuleName, "%s: Free all resources !",__func__);
    if (m_formatContext) {
        avformat_close_input(&m_formatContext);
        m_formatContext = NULL;
    }
    
    if (m_bitFilterContext) {
        av_bitstream_filter_close(m_bitFilterContext);
        m_bitFilterContext = NULL;
    }
    
//    if (m_bsfContext) {
//        av_bsf_free(&m_bsfContext);
//        m_bsfContext = NULL;
//    }
}

#pragma mark Other
- (Float64)getCurrentTimestamp {
    CMClockRef hostClockRef = CMClockGetHostTimeClock();
    CMTime hostTime = CMClockGetTime(hostClockRef);
    return CMTimeGetSeconds(hostTime);
}

@end
