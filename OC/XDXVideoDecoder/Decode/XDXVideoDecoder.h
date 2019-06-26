//
//  XDXVideoDecoder.h
//  XDXVideoDecoder
//
//  Created by 小东邪 on 2019/6/4.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "XDXAVParseHandler.h"

NS_ASSUME_NONNULL_BEGIN

@protocol XDXVideoDecoderDelegate <NSObject>

@optional
- (void)getVideoDecodeDataCallback:(CMSampleBufferRef)sampleBuffer isFirstFrame:(BOOL)isFirstFrame;

@end

@interface XDXVideoDecoder : NSObject

@property (weak, nonatomic) id<XDXVideoDecoderDelegate> delegate;


/**
    Start / Stop decoder
 */
- (void)startDecodeVideoData:(struct XDXParseVideoDataInfo *)videoInfo;
- (void)stopDecoder;


/**
    Reset timestamp when you parse a new file (only use the decoder as global var)
 */
- (void)resetTimestamp;

@end

NS_ASSUME_NONNULL_END
