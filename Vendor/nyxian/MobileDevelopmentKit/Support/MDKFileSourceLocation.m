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

#import <MobileDevelopmentKit/MDKFileSourceLocation.h>
#import <CoreCompiler/CCFileSourceLocation.h>

static inline MDKSourceLocation MDKSourceLocationFromCCSourceLocation(CCSourceLocation location)
{
    return (MDKSourceLocation){ location.isValid, location.line, location.column };
}

static inline CCSourceLocation CCSourceLocationFromMDKSourceLocation(MDKSourceLocation location)
{
    return (CCSourceLocation){ location.isValid, location.line, location.column };
}

@implementation MDKFileSourceLocation

+ (void)load
{
    _CFRuntimeBridgeClasses(CCFileSourceLocationGetTypeID(), "MDKFileSourceLocation");
}

+ (instancetype)fileSourceLocationWithFileURL:(NSURL*)fileURL
                           withSourceLocation:(MDKSourceLocation)location
{
    return (__bridge_transfer MDKFileSourceLocation*)CCFileSourceLocationCreate(kCFAllocatorSystemDefault, (__bridge CFURLRef)fileURL, CCSourceLocationFromMDKSourceLocation(location));
}

- (NSURL*)fileURL
{
    return (__bridge NSURL*)CCFileSourceLocationGetFileURL((__bridge void *)self);
}

- (MDKSourceLocation)location
{
    return MDKSourceLocationFromCCSourceLocation(CCFileSourceLocationGetLocation((__bridge void *)self));
}

- (void)encodeWithCoder:(nonnull NSCoder *)coder
{
    [coder encodeObject:self.fileURL forKey:@"fileURL"];
    [coder encodeObject:@(self.location.isValid) forKey:@"location.isValid"];
    [coder encodeObject:@(self.location.line) forKey:@"location.line"];
    [coder encodeObject:@(self.location.column) forKey:@"location.column"];
}

- (nullable instancetype)initWithCoder:(nonnull NSCoder *)coder
{
    NSURL *fileURL = [coder decodeObjectOfClass:[NSURL class] forKey:@"fileURL"];
    BOOL isValid = ((NSNumber*)[coder decodeObjectOfClass:[NSNumber class] forKey:@"location.isValid"]).boolValue;
    if(isValid)
    {
        CFIndex line = ((NSNumber*)[coder decodeObjectOfClass:[NSNumber class] forKey:@"location.line"]).intValue;
        CFIndex column = ((NSNumber*)[coder decodeObjectOfClass:[NSNumber class] forKey:@"location.column"]).intValue;
        return [MDKFileSourceLocation fileSourceLocationWithFileURL:fileURL withSourceLocation:MDKSourceLocationMake(line, column)];
    }
    else
    {
        return [MDKFileSourceLocation fileSourceLocationWithFileURL:fileURL withSourceLocation:MDKSourceLocationZero];
    }
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

@end
