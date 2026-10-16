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

#import <MobileDevelopmentKit/MDKJob.h>
#import <CoreCompiler/CCJob.h>

@implementation MDKJob

+ (void)load
{
    _CFRuntimeBridgeClasses(CCJobGetTypeID(), "MDKJob");
}

+ (instancetype)jobWithType:(MDKJobType)type
              withArguments:(NSArray<NSString*>*)arguments
          withInputFileURLs:(NSArray<NSURL *> *)inputFileURLs
          withOutputFileURL:(NSURL *)outputFileURL
{
    CCJobType ccType = kCCJobTypeUnknown;
    switch(type)
    {
        case MDKJobTypeCompiler:
            ccType = kCCJobTypeCompiler;
            break;
        case MDKJobTypeDriver:
            ccType = kCCJobTypeDriver;
            break;
        case MDKJobTypeSwiftCompiler:
            ccType = kCCJobTypeSwiftCompiler;
            break;
        case MDKJobTypeSwiftDriver:
            ccType = kCCJobTypeSwiftDriver;
            break;
        case MDKJobTypeLinker:
            ccType = kCCJobTypeLinker;
            break;
        default:
            break;
    }
    return (__bridge_transfer MDKJob*)CCJobCreate(kCFAllocatorSystemDefault, ccType, (__bridge CFArrayRef)arguments, (__bridge CFArrayRef)inputFileURLs, (__bridge CFURLRef)outputFileURL);
}

- (MDKJobType)type
{
    CCJobType type = CCJobGetType((__bridge void*)self);
    switch(type)
    {
        case kCCJobTypeCompiler: return MDKJobTypeCompiler;
        case kCCJobTypeDriver: return MDKJobTypeDriver;
        case kCCJobTypeSwiftCompiler: return MDKJobTypeSwiftCompiler;
        case kCCJobTypeSwiftDriver: return MDKJobTypeSwiftDriver;
        case kCCJobTypeLinker: return MDKJobTypeLinker;
        default: return MDKJobTypeUnknown;
    }
}

- (NSArray<NSString*>*)baseArguments
{
    return (__bridge NSArray<NSString*>*)CCJobGetBaseArguments((__bridge CCJobRef)self);
}

- (NSArray<NSURL*>*)inputFileURLs
{
    return (__bridge NSArray<NSURL*>*)CCJobGetInputFileURLs((__bridge CCJobRef)self);
}

- (NSURL*)outputFileURL
{
    return (__bridge NSURL*)CCJobGetOutputFileURL((__bridge CCJobRef)self);
}

- (NSArray<NSString*>*)arguments
{
    return (__bridge_transfer NSArray<NSString*>*)CCJobCreateArguments(kCFAllocatorSystemDefault, (__bridge CCJobRef)self);
}

- (BOOL)executeJobWithOutDiagnostics:(NSArray<MDKDiagnostic*>**)outDiagnostic
                   withOutMainSource:(NSString**)outMainSource
{
    CFArrayRef array = nil;
    CFStringRef string = nil;
    BOOL success = CCJobExecuteJob((__bridge CCJobRef)self, &array, &string);
    
    if(array != nil)
    {
        if(outDiagnostic != nil)
        {
            *outDiagnostic = (__bridge_transfer NSArray<MDKDiagnostic*>*)array;
        }
        else
        {
            CFRelease(array);
        }
    }
    
    if(string != nil)
    {
        if(outMainSource != nil)
        {
            *outMainSource = (__bridge_transfer NSString*)string;
        }
        else
        {
            CFRelease(string);
        }
    }
    
    return success;
}

- (void)encodeWithCoder:(nonnull NSCoder *)coder
{
    [coder encodeObject:@(self.type) forKey:@"type"];
    [coder encodeObject:self.baseArguments forKey:@"baseArguments"];
    [coder encodeObject:self.inputFileURLs forKey:@"inputFileURLs"];
    [coder encodeObject:self.outputFileURL forKey:@"outputFileURL"];
}

- (nullable instancetype)initWithCoder:(nonnull NSCoder *)coder
{
    MDKJobType type = ((NSNumber*)[coder decodeObjectOfClass:[NSNumber class] forKey:@"type"]).unsignedCharValue;
    NSArray<NSString*> *baseArguments = [coder decodeObjectOfClasses:[NSSet setWithArray:@[[NSArray class],[NSString class]]] forKey:@"baseArguments"];
    NSArray<NSURL*> *inputFileURLs = [coder decodeObjectOfClasses:[NSSet setWithArray:@[[NSArray class],[NSURL class]]] forKey:@"inputFileURLs"];
    NSURL *outputFileURL = [coder decodeObjectOfClass:[NSURL class] forKey:@"outputFileURL"];
    return [MDKJob jobWithType:type withArguments:baseArguments withInputFileURLs:inputFileURLs withOutputFileURL:outputFileURL];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end
