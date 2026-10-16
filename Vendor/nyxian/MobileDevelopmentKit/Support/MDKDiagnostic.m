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

#import <MobileDevelopmentKit/MDKDiagnostic.h>
#import <CoreCompiler/CCDiagnostic.h>

static inline MDKDiagnosticType MDKDiagnosticTypeFromCCDiagnosticType(CCDiagnosticType type)
{
    switch(type)
    {
        case kCCDiagnosticTypeFile: return MDKDiagnosticTypeFile;
        case kCCDiagnosticTypeTargetFile: return MDKDiagnosticTypeTargetFile;
        case kCCDiagnosticTypeInternal: return MDKDiagnosticTypeInternal;
        default: return MDKDiagnosticTypeUnknown;
    }
}

static inline CCDiagnosticType CCDiagnosticTypeFromMDKDiagnosticType(MDKDiagnosticType type)
{
    switch(type)
    {
        case MDKDiagnosticTypeFile: return kCCDiagnosticTypeFile;
        case MDKDiagnosticTypeTargetFile: return kCCDiagnosticTypeTargetFile;
        case MDKDiagnosticTypeInternal: return kCCDiagnosticTypeInternal;
        default: return kCCDiagnosticTypeUnknown;
    }
}

static inline MDKDiagnosticLevel MDKDiagnosticLevelFromCCDiagnosticLevel(CCDiagnosticLevel level)
{
    switch(level)
    {
        case kCCDiagnosticLevelNote: return MDKDiagnosticLevelNote;
        case kCCDiagnosticLevelRemark: return MDKDiagnosticLevelRemark;
        case kCCDiagnosticLevelWarning: return MDKDiagnosticLevelWarning;
        case kCCDiagnosticLevelError: return MDKDiagnosticLevelError;
        case kCCDiagnosticLevelFatal: return MDKDiagnosticLevelFatal;
        default: return MDKDiagnosticLevelUnknown;
    }
}

static inline CCDiagnosticLevel CCDiagnosticLevelFromMDKDiagnosticLevel(MDKDiagnosticLevel level)
{
    switch(level)
    {
        case MDKDiagnosticLevelNote: return kCCDiagnosticLevelNote;
        case MDKDiagnosticLevelRemark: return kCCDiagnosticLevelRemark;
        case MDKDiagnosticLevelWarning: return kCCDiagnosticLevelWarning;
        case MDKDiagnosticLevelError: return kCCDiagnosticLevelError;
        case MDKDiagnosticLevelFatal: return kCCDiagnosticLevelFatal;
        default: return kCCDiagnosticLevelUnknown;
    }
}

@implementation MDKDiagnostic

+ (void)load
{
    _CFRuntimeBridgeClasses(CCDiagnosticGetTypeID(), "MDKDiagnostic");
}

+ (instancetype)diagnosticWithType:(MDKDiagnosticType)type
                             level:(MDKDiagnosticLevel)level
                        mainSource:(NSString*)mainSource
                fileSourceLocation:(MDKFileSourceLocation *)fileSourceLocation
                           message:(NSString*)message
{
    /* FIXME: will crash without message */
    return (__bridge_transfer MDKDiagnostic*)CCDiagnosticCreate(kCFAllocatorSystemDefault, CCDiagnosticTypeFromMDKDiagnosticType(type), CCDiagnosticLevelFromMDKDiagnosticLevel(level), (__bridge CFStringRef)mainSource, (__bridge CCFileSourceLocationRef)fileSourceLocation, (__bridge CFStringRef)message);
}

- (MDKDiagnosticType)type
{
    return MDKDiagnosticTypeFromCCDiagnosticType(CCDiagnosticGetType((__bridge void *)self));
}

- (MDKDiagnosticLevel)level
{
    return MDKDiagnosticLevelFromCCDiagnosticLevel(CCDiagnosticGetLevel((__bridge void *)self));
}

- (NSString*)mainSource
{
    return (__bridge NSString*)CCDiagnosticGetMainSource((__bridge void *)self);
}

- (MDKFileSourceLocation*)fileSourceLocation
{
    return (__bridge MDKFileSourceLocation*)CCDiagnosticGetFileSourceLocation((__bridge void *)self);
}

- (NSString*)message
{
    return (__bridge NSString*)CCDiagnosticGetMessage((__bridge void *)self);
}

- (void)encodeWithCoder:(nonnull NSCoder *)coder
{
    [coder encodeObject:@(self.type) forKey:@"type"];
    [coder encodeObject:@(self.level) forKey:@"level"];
    [coder encodeObject:self.mainSource forKey:@"mainSource"];
    [coder encodeObject:self.fileSourceLocation forKey:@"fileSourceLocation"];
    [coder encodeObject:self.message forKey:@"message"];
}

- (nullable instancetype)initWithCoder:(nonnull NSCoder *)coder
{
    MDKDiagnosticType type = ((NSNumber*)[coder decodeObjectOfClass:[NSNumber class] forKey:@"type"]).unsignedCharValue;
    MDKDiagnosticLevel level = ((NSNumber*)[coder decodeObjectOfClass:[NSNumber class] forKey:@"level"]).unsignedCharValue;
    NSString *mainSource = [coder decodeObjectOfClass:[NSString class] forKey:@"mainSource"];
    MDKFileSourceLocation *fileSourceLocation = [coder decodeObjectOfClass:[MDKFileSourceLocation class] forKey:@"fileSourceLocation"];
    NSString *message = [coder decodeObjectOfClass:[NSString class] forKey:@"message"];
    return [MDKDiagnostic diagnosticWithType:type level:level mainSource:mainSource fileSourceLocation:fileSourceLocation message:message];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end
