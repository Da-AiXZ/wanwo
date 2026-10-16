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

#include <CoreCompiler/CCDependency.h>

static CFTypeID gCCDependencyTypeID = _kCFRuntimeNotATypeID;

struct __CCDependency {
    CFRuntimeBase _base;
    CFStringRef name;
    Boolean isFramework;
};

static void __CCDependencyFinalize(CFTypeRef dependencyRef)
{
    CCDependencyRef dependency = (CCDependencyRef)dependencyRef;
    if(dependency->name != NULL)
    {
        CFRelease(dependency->name);
    }
}

static const CFRuntimeClass gCCDependencyClass = {
    0,                              /* version */
    "CCDependency",                 /* class name */
    NULL,                           /* init */
    NULL,                           /* copy */
    __CCDependencyFinalize,         /* finalize */
    NULL,                           /* equal */
    NULL,                           /* hash */
    NULL,                           /* copyFormattingDesc */
    NULL,                           /* copyDebugDesc */
    NULL,
    NULL,
    0
};

CFTypeID CCDependencyGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCCDependencyTypeID = _CFRuntimeRegisterClass(&gCCDependencyClass);
    });
    return gCCDependencyTypeID;
}

CCDependencyRef CCDependencyCreate(CFAllocatorRef allocator,
                                   CFStringRef name,
                                   Boolean isFramework)
{
    assert(name != NULL);

    CCDependencyRef dependency = (CCDependencyRef)_CFRuntimeCreateInstance(allocator, CCDependencyGetTypeID(), sizeof(struct __CCDependency) - sizeof(CFRuntimeBase), NULL);
    if(dependency == NULL)
    {
        CFRelease(name);
        return NULL;
    }
    
    dependency->isFramework = isFramework;
    dependency->name = CFRetain(name);
    if(dependency->name == NULL)
    {
        CFRelease(name);
        CFRelease(dependency);
        return NULL;
    }

    return dependency;
}

CFStringRef CCDependencyGetName(CCDependencyRef dependency)
{
    if(dependency == NULL)
    {
        return NULL;
    }
    
    return dependency->name;
}

Boolean CCDependencyIsFramework(CCDependencyRef dependency)
{
    if(dependency == NULL)
    {
        return false;
    }
    
    return dependency->isFramework;
}
