//
//  XDXFFmpegVideoDecoder.h
//  XDXVideoDecoder
//
//  Created by 小东邪 on 2019/6/6.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>

// FFmpeg Header File
#ifdef __cplusplus
extern "C" {
#endif
    
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/opt.h"
    
#ifdef __cplusplus
};
#endif

NS_ASSUME_NONNULL_BEGIN

@protocol XDXFFmpegVideoDecoderDelegate <NSObject>

@optional
- (void)getDecodeVideoDataByFFmpeg:(CMSampleBufferRef)sampleBuffer;

@end

@interface XDXFFmpegVideoDecoder : NSObject

@property (weak, nonatomic) id<XDXFFmpegVideoDecoderDelegate> delegate;

- (instancetype)initWithFormatContext:(AVFormatContext *)formatContext videoStreamIndex:(int)videoStreamIndex;
- (void)startDecodeVideoDataWithAVPacket:(AVPacket)packet;
- (void)stopDecoder;

@end

NS_ASSUME_NONNULL_END
