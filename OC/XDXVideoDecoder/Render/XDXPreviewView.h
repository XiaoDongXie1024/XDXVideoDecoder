//
//  XDXPreviewView.h
//  XDXVideoPreviewProject
//
//  Created by 小东邪 on 2019/6/3.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN



@interface XDXPreviewView : UIView


/**
 Whether full the screen
 */
@property (nonatomic, assign, getter=isFullScreen) BOOL fullScreen;

/**
 display
 */
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;

@end

NS_ASSUME_NONNULL_END
