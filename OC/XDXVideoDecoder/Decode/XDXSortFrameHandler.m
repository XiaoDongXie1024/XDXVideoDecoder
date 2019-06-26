//
//  XDXSortFrameHandler.m
//  XDXVideoDecoder
//
//  Created by 小东邪 on 2019/6/24.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "XDXSortFrameHandler.h"

const static int g_maxSize = 4;

struct XDXSortLinkList {
    CMSampleBufferRef dataArray[g_maxSize];
    int index;
};

typedef struct XDXSortLinkList XDXSortLinkList;

@interface XDXSortFrameHandler ()
{
    XDXSortLinkList _sortLinkList;
}

@end

@implementation XDXSortFrameHandler

#pragma mark - Lifecycle
- (instancetype)init {
    if (self = [super init]) {
        XDXSortLinkList linkList = {
            .index = 0,
            .dataArray = {0},
        };
        
        _sortLinkList = linkList;
    }
    return self;
}

#pragma mark - Public
- (void)addDataToLinkList:(CMSampleBufferRef)sampleBufferRef {
    CFRetain(sampleBufferRef);
    _sortLinkList.dataArray[_sortLinkList.index] = sampleBufferRef;
    _sortLinkList.index++;
    
    if (_sortLinkList.index == g_maxSize) {
        _sortLinkList.index = 0;
        
        // sort
        [self selectSortWithLinkList:&_sortLinkList];
        
        for (int i = 0; i < g_maxSize; i++) {
            if ([self.delegate respondsToSelector:@selector(getSortedVideoNode:)]) {
                [self.delegate getSortedVideoNode:_sortLinkList.dataArray[i]];
                CFRelease(_sortLinkList.dataArray[i]);
            }
        }
    }
}

#pragma mark - Private
- (void)selectSortWithLinkList:(XDXSortLinkList *)sortLinkList {
    for (int i = 0; i < g_maxSize; i++) {
        int64_t minPTS = i;
        for (int j = i + 1; j < g_maxSize; j++) {
            if ([self getPTS:sortLinkList->dataArray[j]] < [self getPTS:sortLinkList->dataArray[minPTS]]) {
                minPTS = j;
            }
        }
        
        if (i != minPTS) {
            void *tmp = sortLinkList->dataArray[i];
            sortLinkList->dataArray[i] = sortLinkList->dataArray[minPTS];
            sortLinkList->dataArray[minPTS] = tmp;
        }
    }
}

- (int64_t)getPTS:(CMSampleBufferRef)sampleBufferRef {
    int64_t pts = (int64_t)(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBufferRef)) * 1000);
    return pts;
}

@end


