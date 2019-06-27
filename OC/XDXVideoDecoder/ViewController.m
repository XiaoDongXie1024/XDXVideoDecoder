//
//  ViewController.m
//  XDXVideoDecoder
//
//  Created by 小东邪 on 2019/6/2.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "ViewController.h"
#import "XDXAVParseHandler.h"
#import "XDXPreviewView.h"
#import "XDXVideoDecoder.h"
#import "XDXFFmpegVideoDecoder.h"
#import "XDXSortFrameHandler.h"

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

@interface ViewController ()<XDXVideoDecoderDelegate,XDXFFmpegVideoDecoderDelegate, XDXSortFrameHandlerDelegate>

@property (strong, nonatomic) XDXPreviewView    *previewView;
@property (weak, nonatomic  ) IBOutlet UIButton *startBtn;

@property (nonatomic, assign) BOOL isH265File;

@property (strong, nonatomic) XDXSortFrameHandler *sortHandler;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupUI];
    
    self.isH265File = YES;
    
    self.sortHandler = [[XDXSortFrameHandler alloc] init];
    self.sortHandler.delegate = self;
}

- (void)setupUI {
    self.previewView = [[XDXPreviewView alloc] initWithFrame:self.view.frame];
    [self.view addSubview:self.previewView];
    [self.view bringSubviewToFront:self.startBtn];
}

- (IBAction)startParseDidClicked:(id)sender {
    BOOL isUseFFmpeg = NO;
    if (isUseFFmpeg) {
        [self startDecodeByFFmpegWithIsH265Data:self.isH265File];
    }else {
        [self startDecodeByVTSessionWithIsH265Data:self.isH265File];
    }
    
}

- (void)startDecodeByVTSessionWithIsH265Data:(BOOL)isH265 {
    NSString *path = [[NSBundle mainBundle] pathForResource:isH265 ? @"testh265" : @"testh264"  ofType:@"MOV"];
    XDXAVParseHandler *parseHandler = [[XDXAVParseHandler alloc] initWithPath:path];
    XDXVideoDecoder *decoder = [[XDXVideoDecoder alloc] init];
    decoder.delegate = self;
    [parseHandler startParseWithCompletionHandler:^(BOOL isVideoFrame, BOOL isFinish, struct XDXParseVideoDataInfo *videoInfo, struct XDXParseAudioDataInfo *audioInfo) {
        if (isFinish) {
            [decoder stopDecoder];
            return;
        }
        
        if (isVideoFrame) {
            [decoder startDecodeVideoData:videoInfo];
        }
    }];
}

- (void)startDecodeByFFmpegWithIsH265Data:(BOOL)isH265 {
    NSString *path = [[NSBundle mainBundle] pathForResource:isH265 ? @"testh265" : @"testh264" ofType:@"MOV"];
    XDXAVParseHandler *parseHandler = [[XDXAVParseHandler alloc] initWithPath:path];
    XDXFFmpegVideoDecoder *decoder = [[XDXFFmpegVideoDecoder alloc] initWithFormatContext:[parseHandler getFormatContext] videoStreamIndex:[parseHandler getVideoStreamIndex]];
    decoder.delegate = self;
    [parseHandler startParseGetAVPackeWithCompletionHandler:^(BOOL isVideoFrame, BOOL isFinish, AVPacket packet) {
        if (isFinish) {
            [decoder stopDecoder];
            return;
        }
        
        if (isVideoFrame) {
            [decoder startDecodeVideoDataWithAVPacket:packet];
        }
    }];
}

#pragma mark - Decode Callback
- (void)getVideoDecodeDataCallback:(CMSampleBufferRef)sampleBuffer isFirstFrame:(BOOL)isFirstFrame {
    if (self.isH265File) {
        // Note : the first frame not need to sort.
        if (isFirstFrame) {
            [self.sortHandler cleanLinkList];
            CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sampleBuffer);
            [self.previewView displayPixelBuffer:pix];
            return;
        }
        
        [self.sortHandler addDataToLinkList:sampleBuffer];
    }else {
        CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sampleBuffer);
        [self.previewView displayPixelBuffer:pix];
    }
}

-(void)getDecodeVideoDataByFFmpeg:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sampleBuffer);
    [self.previewView displayPixelBuffer:pix];
}


#pragma mark - Sort Callback
- (void)getSortedVideoNode:(CMSampleBufferRef)sampleBuffer {
    int64_t pts = (int64_t)(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000);
    static int64_t lastpts = 0;
    NSLog(@"Test marigin - %lld",pts - lastpts);
    lastpts = pts;
    
    [self.previewView displayPixelBuffer:CMSampleBufferGetImageBuffer(sampleBuffer)];
}

@end
