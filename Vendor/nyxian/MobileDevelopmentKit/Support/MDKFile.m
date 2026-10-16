/*
 * MIT License
 *
 * Copyright (c) 2026 emexlab
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#import <MobileDevelopmentKit/MDKFile.h>
#import <CoreCompiler/CCFile.h>
#import <objc/runtime.h>

@implementation MDKFile

+ (void)load
{
    _CFRuntimeBridgeClasses(CCFileGetTypeID(), "MDKFile");
}

+ (instancetype)fileWithURL:(NSURL*)fileURL
{
    return (__bridge_transfer MDKFile*)CCFileCreate(kCFAllocatorSystemDefault, (__bridge CFURLRef)fileURL);
}

+ (instancetype)fileWithPath:(NSString*)filePath
{
    return (__bridge_transfer MDKFile*)CCFileCreateWithFilePath(kCFAllocatorSystemDefault, (__bridge CFStringRef)filePath);
}

+ (instancetype)fileWithCString:(const char*)path
                       encoding:(NSStringEncoding)encoding
{
    return (__bridge_transfer MDKFile*)CCFileCreateWithCString(kCFAllocatorSystemDefault, path, CFStringConvertNSStringEncodingToEncoding(encoding));
}

- (NSURL*)fileURL
{
    return (__bridge NSURL*)CCFileGetFileURL((__bridge void *)self);
}

- (NSData*)unsavedData
{
    return (__bridge NSData*)CCFileGetUnsavedData((__bridge void *)self);
}

- (MDKFileType)type
{
    CCFileType type = CCFileGetType((__bridge void *)self);
    switch(type)
    {
        case kCCFileTypeC: return MDKFileTypeC;
        case kCCFileTypeCHeader: return MDKFileTypeCHeader;
        case kCCFileTypeCXX: return MDKFileTypeCXX;
        case kCCFileTypeCXXHeader: return MDKFileTypeCXXHeader;
        case kCCFileTypeObjC: return MDKFileTypeObjC;
        case kCCFileTypeObjCHeader: return MDKFileTypeObjCHeader;
        case kCCFileTypeObjCXX: return MDKFileTypeObjCXX;
        case kCCFileTypeObjCXXHeader: return MDKFileTypeObjCXXHeader;
        case kCCFileTypeSwift: return MDKFileTypeSwift;
        case kCCFileTypeObject: return MDKFileTypeObject;
        default: return MDKFileTypeUnknown;
    }
}

- (BOOL)isSwift
{
    return (self.type == MDKFileTypeSwift);
}

- (BOOL)isClang
{
    return (self.type < MDKFileTypeSwift);
}

- (BOOL)isObject
{
    return (self.type == MDKFileTypeObject);
}

- (nonnull id)copyWithZone:(nullable NSZone *)zone
{
    return (__bridge_transfer MDKFile*)CCFileCreateCopy(kCFAllocatorSystemDefault, (__bridge CCFileRef)self);
}

- (nonnull id)mutableCopyWithZone:(nullable NSZone *)zone
{
    MDKFile *obj = (__bridge_transfer MDKFile*)CCFileCreateMutableCopy(kCFAllocatorSystemDefault, (__bridge CCFileRef)self);
    object_setClass(obj, [MDKMutableFile class]);
    return (MDKMutableFile *)obj;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (void)encodeWithCoder:(nonnull NSCoder *)coder
{
    [coder encodeObject:self.fileURL forKey:@"fileURL"];
}

- (nullable instancetype)initWithCoder:(nonnull NSCoder *)coder
{
    NSURL *fileURL = [coder decodeObjectOfClass:[NSURL class] forKey:@"fileURL"];
    return [MDKFile fileWithURL:fileURL];
}

@end

@implementation MDKMutableFile

@dynamic fileURL;
@dynamic unsavedData;

+ (instancetype)fileWithURL:(NSURL*)fileURL
{
    MDKFile *obj = (__bridge_transfer MDKFile*)CCFileCreateMutable(kCFAllocatorSystemDefault, (__bridge CFURLRef)fileURL);
    object_setClass(obj, [MDKMutableFile class]);
    return (MDKMutableFile *)obj;
}

+ (instancetype)fileWithURL:(NSURL*)fileURL
            withUnsavedData:(NSData*)unsavedData
{
    MDKFile *obj = (__bridge_transfer MDKFile*)CCFileCreateMutableWithUnsavedData(kCFAllocatorSystemDefault, (__bridge CFURLRef)fileURL, (__bridge CFDataRef)unsavedData);
    object_setClass(obj, [MDKMutableFile class]);
    return (MDKMutableFile *)obj;
}

- (void)setFileURL:(NSURL*)fileURL
{
    CCFileSetFileURL((__bridge void *)self, (__bridge CFURLRef)fileURL);
}

- (void)setUnsavedData:(NSData*)unsavedData
{
    CCFileSetUnsavedData((__bridge void *)self, (__bridge CFDataRef)unsavedData);
}

- (void)encodeWithCoder:(nonnull NSCoder *)coder
{
    [coder encodeObject:self.fileURL forKey:@"fileURL"];
    [coder encodeObject:self.unsavedData forKey:@"unsavedData"];
}

- (nullable instancetype)initWithCoder:(nonnull NSCoder *)coder
{
    NSURL *fileURL = [coder decodeObjectOfClass:[NSURL class] forKey:@"fileURL"];
    NSData *unsavedData = [coder decodeObjectOfClass:[NSData class] forKey:@"unsavedData"];
    return [MDKMutableFile fileWithURL:fileURL withUnsavedData:unsavedData];
}

@end
