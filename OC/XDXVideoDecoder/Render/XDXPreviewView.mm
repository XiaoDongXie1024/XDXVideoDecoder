//
//  XDXPreviewView.m
//  XDXVideoPreviewProject
//
//  Created by 小东邪 on 2019/6/3.
//  Copyright © 2019 小东邪. All rights reserved.
//

#import "XDXPreviewView.h"
#import <AVFoundation/AVUtilities.h>
#import <OpenGLES/ES2/glext.h>
#import "log4cplus.h"

#define kModuleName "XDXPreviewView"

#define IS_IPAD UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad

typedef enum : NSUInteger {
    XDXPixelBufferTypeNone = 0,
    XDXPixelBufferTypeNV12,
    XDXPixelBufferTypeRGB,
} XDXPixelBufferType;

enum
{
    UNIFORM_Y,
    UNIFORM_UV,
    UNIFORM_COLOR_CONVERSION_MATRIX,
    NUM_UNIFORMS
};
GLint uniforms[NUM_UNIFORMS];

enum
{
    ATTRIB_VERTEX,
    ATTRIB_TEXCOORD,
    NUM_ATTRIBUTES
};

GLfloat kXDXPreViewColorConversion601FullRange[] = {
    1.0,    1.0,    1.0,
    0.0,    -0.343, 1.765,
    1.4,    -0.711, 0.0,
};

GLfloat quadTextureData[] = {
    0.0f, 1.0f,
    1.0f, 1.0f,
    0.0f, 0.0f,
    1.0f, 0.0f,
};

GLfloat quadVertexData[] = {
    -1.0f, -1.0f,
    1.0f, -1.0f,
    -1.0f, 1.0f,
    1.0f, 1.0f,
};


@interface XDXPreviewView ()
{
    GLint _backingWidth;
    GLint _backingHeight;
    
    EAGLContext *_context;
    CVOpenGLESTextureCacheRef _videoTextureCache;
    
    GLuint _frameBufferHandle;
    GLuint _colorBufferHandle;
    
    // NV12
    GLuint               _nv12Program;
    CVOpenGLESTextureRef _lumaTexture;
    CVOpenGLESTextureRef _chromaTexture;
    const GLfloat        *_preferredConversion;
    
    // RGB
    GLuint                  _rgbProgram;
    CVOpenGLESTextureRef    _renderTexture;
    GLint                   _displayInputTextureUniform;
}

@property (nonatomic, assign) BOOL      lastFullScreen;
@property (nonatomic, assign) CGFloat   pixelbufferWidth;
@property (nonatomic, assign) CGFloat   pixelbufferHeight;
@property (nonatomic, assign) CGSize    screenResolutionSize;
@property (nonatomic, assign) XDXPixelBufferType bufferType;
@property (nonatomic, assign) XDXPixelBufferType lastBufferType;

// 记录屏幕宽度,启动时如果是竖屏状态,会切换到横屏,所以屏幕宽高会改变,需要重新计算画面的尺寸。
@property (nonatomic, assign) CGFloat screenWidth;

@end

@implementation XDXPreviewView

#pragma mark - life cycle
- (id)initWithCoder:(NSCoder *)aDecoder
{
    if ((self = [super initWithCoder:aDecoder])) {
        [self initPreview];
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        [self initPreview];
    }
    return self;
}

- (void)dealloc {
    [self cleanUpTextures];
    
    if(_videoTextureCache) {
        CFRelease(_videoTextureCache);
    }
}

#pragma mark - public methods
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    [self displayPixelBuffer:pixelBuffer
           videoTextureCache:_videoTextureCache
                     context:_context
                backingWidth:_backingWidth
               backingHeight:_backingHeight
           frameBufferHandle:_frameBufferHandle
                 nv12Program:_nv12Program
                  rgbProgram:_rgbProgram
         preferredConversion:_preferredConversion
  displayInputTextureUniform:_displayInputTextureUniform
           colorBufferHandle:_colorBufferHandle];
}

#pragma mark - private methods
+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (void)initPreview {
    self.userInteractionEnabled = NO;
    self.fullScreen = YES;
    self.lastFullScreen = NO;
    self.pixelbufferWidth = 0;
    self.pixelbufferHeight = 0;
    self.screenWidth = 0;
    self.bufferType = XDXPixelBufferTypeNV12;
    self.lastBufferType = XDXPixelBufferTypeNone;
    _preferredConversion = kXDXPreViewColorConversion601FullRange;
    
    _context = [self createOpenGLContextWithWidth:&_backingWidth
                                           height:&_backingHeight
                                videoTextureCache:&_videoTextureCache
                                colorBufferHandle:&_colorBufferHandle
                                frameBufferHandle:&_frameBufferHandle];
}

#pragma mark Render
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer videoTextureCache:(CVOpenGLESTextureCacheRef)videoTextureCache context:(EAGLContext *)context backingWidth:(GLint)backingWidth backingHeight:(GLint)backingHeight frameBufferHandle:(GLuint)frameBufferHandle nv12Program:(GLuint)nv12Program rgbProgram:(GLuint)rgbProgram preferredConversion:(const GLfloat *)preferredConversion displayInputTextureUniform:(GLuint)displayInputTextureUniform colorBufferHandle:(GLuint)colorBufferHandle{
    if (pixelBuffer == NULL) {
        return;
    }
    
    CVReturn error;
    
    int frameWidth  = (int)CVPixelBufferGetWidth(pixelBuffer);
    int frameHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
    
    if (!videoTextureCache) {
        log4cplus_error(kModuleName, "No video texture cache");
        return;
    }
    if ([EAGLContext currentContext] != context) {
        [EAGLContext setCurrentContext:context];
    }
    
    [self cleanUpTextures];
    
    XDXPixelBufferType bufferType;
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        bufferType = XDXPixelBufferTypeNV12;
    } else if (CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA) {
        bufferType = XDXPixelBufferTypeRGB;
    }else {
        log4cplus_error(kModuleName, "Not support current format.");
        return;
    }
    
    CVOpenGLESTextureRef lumaTexture,chromaTexture,renderTexture;
    if (bufferType == XDXPixelBufferTypeNV12) {
        // Y
        glActiveTexture(GL_TEXTURE0);
        
        error = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                             videoTextureCache,
                                                             pixelBuffer,
                                                             NULL,
                                                             GL_TEXTURE_2D,
                                                             GL_LUMINANCE,
                                                             frameWidth,
                                                             frameHeight,
                                                             GL_LUMINANCE,
                                                             GL_UNSIGNED_BYTE,
                                                             0,
                                                             &lumaTexture);
        if (error) {
            log4cplus_error(kModuleName, "Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", error);
        }else {
            _lumaTexture = lumaTexture;
        }
        
        glBindTexture(CVOpenGLESTextureGetTarget(lumaTexture), CVOpenGLESTextureGetName(lumaTexture));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        // UV
        glActiveTexture(GL_TEXTURE1);
        error = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                             videoTextureCache,
                                                             pixelBuffer,
                                                             NULL,
                                                             GL_TEXTURE_2D,
                                                             GL_LUMINANCE_ALPHA,
                                                             frameWidth / 2,
                                                             frameHeight / 2,
                                                             GL_LUMINANCE_ALPHA,
                                                             GL_UNSIGNED_BYTE,
                                                             1,
                                                             &chromaTexture);
        if (error) {
            log4cplus_error(kModuleName, "Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", error);
        }else {
            _chromaTexture = chromaTexture;
        }
        
        glBindTexture(CVOpenGLESTextureGetTarget(chromaTexture), CVOpenGLESTextureGetName(chromaTexture));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
    } else if (bufferType == XDXPixelBufferTypeRGB) {
        // RGB
        glActiveTexture(GL_TEXTURE0);
        error = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                             videoTextureCache,
                                                             pixelBuffer,
                                                             NULL,
                                                             GL_TEXTURE_2D,
                                                             GL_RGBA,
                                                             frameWidth,
                                                             frameHeight,
                                                             GL_BGRA,
                                                             GL_UNSIGNED_BYTE,
                                                             0,
                                                             &renderTexture);
        if (error) {
            log4cplus_error(kModuleName, "Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", error);
        }else {
            _renderTexture = renderTexture;
        }
        
        glBindTexture(CVOpenGLESTextureGetTarget(renderTexture), CVOpenGLESTextureGetName(renderTexture));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, frameBufferHandle);
    
    glViewport(0, 0, backingWidth, backingHeight);
    
    glClearColor(0.1f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    
    if (bufferType == XDXPixelBufferTypeNV12) {
        if (self.lastBufferType != bufferType) {
            glUseProgram(nv12Program);
            glUniform1i(uniforms[UNIFORM_Y], 0);
            glUniform1i(uniforms[UNIFORM_UV], 1);
            glUniformMatrix3fv(uniforms[UNIFORM_COLOR_CONVERSION_MATRIX], 1, GL_FALSE, preferredConversion);
        }
    } else if (bufferType == XDXPixelBufferTypeRGB) {
        if (self.lastBufferType != bufferType) {
            glUseProgram(rgbProgram);
            glUniform1i(displayInputTextureUniform, 0);
        }
    }
    
    static CGSize normalizedSamplingSize;
    
    if (self.lastFullScreen != self.isFullScreen || self.pixelbufferWidth != frameWidth || self.pixelbufferHeight != frameHeight
        || normalizedSamplingSize.width == 0 || normalizedSamplingSize.height == 0  || self.screenWidth != [UIScreen mainScreen].bounds.size.width) {
        
        normalizedSamplingSize = [self getNormalizedSamplingSize:CGSizeMake(frameWidth, frameHeight)];
        self.lastFullScreen = self.isFullScreen;
        self.pixelbufferWidth = frameWidth;
        self.pixelbufferHeight = frameHeight;
        self.screenWidth = [UIScreen mainScreen].bounds.size.width;
        
        quadVertexData[0] = -1 * normalizedSamplingSize.width;
        quadVertexData[1] = -1 * normalizedSamplingSize.height;
        quadVertexData[2] = normalizedSamplingSize.width;
        quadVertexData[3] = -1 * normalizedSamplingSize.height;
        quadVertexData[4] = -1 * normalizedSamplingSize.width;
        quadVertexData[5] = normalizedSamplingSize.height;
        quadVertexData[6] = normalizedSamplingSize.width;
        quadVertexData[7] = normalizedSamplingSize.height;
    }
    
    glVertexAttribPointer(ATTRIB_VERTEX, 2, GL_FLOAT, 0, 0, quadVertexData);
    glEnableVertexAttribArray(ATTRIB_VERTEX);
    
    glVertexAttribPointer(ATTRIB_TEXCOORD, 2, GL_FLOAT, 0, 0, quadTextureData);
    glEnableVertexAttribArray(ATTRIB_TEXCOORD);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    
    glBindRenderbuffer(GL_RENDERBUFFER, colorBufferHandle);
    
    if ([EAGLContext currentContext] == context) {
        [context presentRenderbuffer:GL_RENDERBUFFER];
    }
    
    self.lastBufferType = self.bufferType;
}

- (EAGLContext *)createOpenGLContextWithWidth:(int *)width height:(int *)height videoTextureCache:(CVOpenGLESTextureCacheRef *)videoTextureCache colorBufferHandle:(GLuint *)colorBufferHandle frameBufferHandle:(GLuint *)frameBufferHandle {
    self.contentScaleFactor = [[UIScreen mainScreen] scale];
    
    CAEAGLLayer *eaglLayer       = (CAEAGLLayer *)self.layer;
    eaglLayer.opaque = YES;
    eaglLayer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking   : [NSNumber numberWithBool:NO],
                                     kEAGLDrawablePropertyColorFormat       : kEAGLColorFormatRGBA8};
    
    EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:context];
    
    [self setupBuffersWithContext:context
                            width:width
                           height:height
                colorBufferHandle:colorBufferHandle
                frameBufferHandle:frameBufferHandle];
    
    [self loadShaderWithBufferType:XDXPixelBufferTypeNV12];
    [self loadShaderWithBufferType:XDXPixelBufferTypeRGB];
    
    if (!*videoTextureCache) {
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, context, NULL, videoTextureCache);
        if (err != noErr)
            log4cplus_error(kModuleName, "Error at CVOpenGLESTextureCacheCreate %d",err);
    }
    
    return context;
}

- (void)setupBuffersWithContext:(EAGLContext *)context width:(int *)width height:(int *)height colorBufferHandle:(GLuint *)colorBufferHandle frameBufferHandle:(GLuint *)frameBufferHandle {
    glDisable(GL_DEPTH_TEST);
    
    glEnableVertexAttribArray(ATTRIB_VERTEX);
    glVertexAttribPointer(ATTRIB_VERTEX, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), 0);
    
    glEnableVertexAttribArray(ATTRIB_TEXCOORD);
    glVertexAttribPointer(ATTRIB_TEXCOORD, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), 0);
    
    glGenFramebuffers(1, frameBufferHandle);
    glBindFramebuffer(GL_FRAMEBUFFER, *frameBufferHandle);
    
    glGenRenderbuffers(1, colorBufferHandle);
    glBindRenderbuffer(GL_RENDERBUFFER, *colorBufferHandle);
    
    [context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH , width);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, height);
    
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, *colorBufferHandle);
}

- (void)loadShaderWithBufferType:(XDXPixelBufferType)type {
    GLuint vertShader, fragShader;
    NSURL  *vertShaderURL, *fragShaderURL;
    
    NSString *shaderName;
    GLuint   program;
    program = glCreateProgram();
    
    if (type == XDXPixelBufferTypeNV12) {
        shaderName = @"XDXPreviewNV12Shader";
        _nv12Program = program;
    } else if (type == XDXPixelBufferTypeRGB) {
        shaderName = @"XDXPreviewRGBShader";
        _rgbProgram = program;
    }
    
    vertShaderURL = [[NSBundle mainBundle] URLForResource:shaderName withExtension:@"vsh"];
    if (![self compileShader:&vertShader type:GL_VERTEX_SHADER URL:vertShaderURL]) {
        log4cplus_error(kModuleName, "Failed to compile vertex shader");
        return;
    }
    
    fragShaderURL = [[NSBundle mainBundle] URLForResource:shaderName withExtension:@"fsh"];
    if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER URL:fragShaderURL]) {
        log4cplus_error(kModuleName, "Failed to compile fragment shader");
        return;
    }
    
    glAttachShader(program, vertShader);
    glAttachShader(program, fragShader);
    
    glBindAttribLocation(program, ATTRIB_VERTEX  , "position");
    glBindAttribLocation(program, ATTRIB_TEXCOORD, "inputTextureCoordinate");
    
    if (![self linkProgram:program]) {
        if (vertShader) {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader) {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (program) {
            glDeleteProgram(program);
            program = 0;
        }
        return;
    }
    
    if (type == XDXPixelBufferTypeNV12) {
        uniforms[UNIFORM_Y] = glGetUniformLocation(program , "luminanceTexture");
        uniforms[UNIFORM_UV] = glGetUniformLocation(program, "chrominanceTexture");
        uniforms[UNIFORM_COLOR_CONVERSION_MATRIX] = glGetUniformLocation(program, "colorConversionMatrix");
    } else if (type == XDXPixelBufferTypeRGB) {
        _displayInputTextureUniform = glGetUniformLocation(program, "inputImageTexture");
    }
    
    if (vertShader) {
        glDetachShader(program, vertShader);
        glDeleteShader(vertShader);
    }
    if (fragShader) {
        glDetachShader(program, fragShader);
        glDeleteShader(fragShader);
    }
}

- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type URL:(NSURL *)URL {
    NSError *error;
    NSString *sourceString = [[NSString alloc] initWithContentsOfURL:URL
                                                            encoding:NSUTF8StringEncoding
                                                               error:&error];
    if (sourceString == nil) {
        log4cplus_error(kModuleName, "Failed to load vertex shader: %s", [error localizedDescription].UTF8String);
        return NO;
    }
    
    GLint status;
    const GLchar *source;
    source = (GLchar *)[sourceString UTF8String];
    
    *shader = glCreateShader(type);
    glShaderSource(*shader, 1, &source, NULL);
    glCompileShader(*shader);
    
    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        glDeleteShader(*shader);
        return NO;
    }
    return YES;
}

- (BOOL)linkProgram:(GLuint)prog {
    GLint status;
    glLinkProgram(prog);
    
    glGetProgramiv(prog, GL_LINK_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    return YES;
}

#pragma mark Clean

- (void)cleanUpTextures {
    if (_lumaTexture) {
        CFRelease(_lumaTexture);
        _lumaTexture = NULL;
    }
    
    if (_chromaTexture) {
        CFRelease(_chromaTexture);
        _chromaTexture = NULL;
    }
    
    if (_renderTexture) {
        CFRelease(_renderTexture);
        _renderTexture = NULL;
    }
    
    CVOpenGLESTextureCacheFlush(_videoTextureCache, 0);
}

#pragma mark Other
- (CGSize)getNormalizedSamplingSize:(CGSize)frameSize {
    CGFloat width = 0, height = 0;
    if (self.isFullScreen) {
        if (IS_IPAD) {
            width = frameSize.width * self.screenResolutionSize.height / frameSize.height;
            return CGSizeMake(width / self.screenResolutionSize.width, 1.0);
        }
        height = frameSize.height * self.screenResolutionSize.width / frameSize.width;
        return CGSizeMake(1.0, height / self.screenResolutionSize.height);
    }
    
    if (IS_IPAD) {
        height = frameSize.height * self.screenResolutionSize.width / frameSize.width;
        return CGSizeMake(1.0, height / self.screenResolutionSize.height);
    }
    width = frameSize.width * self.screenResolutionSize.height / frameSize.height;
    return CGSizeMake(width / self.screenResolutionSize.width, 1.0);
}

- (CGSize)screenResolutionSize {
    CGFloat width  = [UIScreen mainScreen].bounds.size.width;
    CGFloat height = [UIScreen mainScreen].bounds.size.height;
    
    CGSize screenResolutionSize = CGSizeMake(width * [UIScreen mainScreen].scale,  height * [UIScreen mainScreen].scale);
    return screenResolutionSize;
}

@end
