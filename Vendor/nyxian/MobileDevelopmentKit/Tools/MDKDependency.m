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

#import <MobileDevelopmentKit/MDKDependency.h>
#import <CoreCompiler/CCDependency.h>
#import <CoreCompiler/CFRuntime.h>

@implementation MDKDependency

@dynamic name;
@dynamic isFramework;

+ (void)load
{
    _CFRuntimeBridgeClasses(CCDependencyGetTypeID(), "MDKDependency");
}

+ (instancetype)dependencyWithName:(NSString*)name
                       isFramework:(BOOL)isFramework
{
    return (__bridge_transfer MDKDependency*)CCDependencyCreate(kCFAllocatorSystemDefault, (__bridge CFStringRef)name, isFramework);
}

- (BOOL)isFramework
{
    return CCDependencyIsFramework((__bridge CCDependencyRef)self);
}

- (NSString*)name
{
    return (__bridge NSString*)CCDependencyGetName((__bridge CCDependencyRef)self);
}

- (BOOL)isEqual:(id)object
{
    if(self == object)
    {
        return YES;
    }
    
    if(![object isKindOfClass:[MDKDependency class]])
    {
        return NO;
    }
    
    MDKDependency *otherDependency = (MDKDependency*)object;
    return (self.isFramework == otherDependency.isFramework && [self.name isEqual:otherDependency.name]);
}

- (NSUInteger)hash
{
    return [self.name hash] ^ (self.isFramework ? 1 : 0);
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (void)encodeWithCoder:(nonnull NSCoder *)coder
{
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:@(self.isFramework) forKey:@"isFramework"];
}

- (nullable instancetype)initWithCoder:(nonnull NSCoder *)coder
{
    NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"];
    NSNumber *framework = [coder decodeObjectOfClass:[NSNumber class] forKey:@"isFramework"];
    BOOL isFramework = [framework boolValue];
    return [MDKDependency dependencyWithName:name isFramework:isFramework];
}

@end
