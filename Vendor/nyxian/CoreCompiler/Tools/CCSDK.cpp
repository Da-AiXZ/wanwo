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

#include <CoreCompiler/CCSDK.h>
#include <clang/Basic/DarwinSDKInfo.h>
#include <llvm/Support/VirtualFileSystem.h>

using namespace clang;
using namespace llvm;

static CFTypeID gCCSDKTypeID = _kCFRuntimeNotATypeID;

struct __CCSDK {
    CFRuntimeBase _base;
    CFURLRef directoryURL;
    std::unique_ptr<clang::DarwinSDKInfo>(sdkInfo);
    CFArrayRef supportedVersions;
};

static CFTypeRef CCSDKCopy(CFAllocatorRef allocator,
                           CFTypeRef cf)
{
    return CFRetain(cf);
}

static void CCSDKFinalize(CFTypeRef cf)
{
    CCSDKRef sdkRef = (CCSDKRef)cf;
    sdkRef->sdkInfo.reset();
}

static const CFRuntimeClass gCCSDKClass = {
    0,                              /* version */
    "CCSDK",                        /* class name */
    NULL,                           /* init */
    CCSDKCopy,                      /* copy */
    CCSDKFinalize,                  /* finalize */
    NULL,                           /* equal */
    NULL,                           /* hash */
    NULL,                           /* copyFormattingDesc */
    NULL,                           /* copyDebugDesc */
    NULL,
    NULL,
    0
};

CFTypeID CCSDKGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCCSDKTypeID = _CFRuntimeRegisterClass(&gCCSDKClass);
    });
    return gCCSDKTypeID;
}

CCSDKRef CCSDKCreateWithDirectoryURL(CFAllocatorRef allocator,
                                     CFURLRef directoryURL)
{
    assert(directoryURL != nullptr);
    
    CCSDKRef sdkRef = (CCSDKRef)_CFRuntimeCreateInstance(allocator, CCSDKGetTypeID(), sizeof(struct __CCSDK) - sizeof(CFRuntimeBase), NULL);
    if(sdkRef == nullptr)
    {
        return nullptr;
    }
    
    sdkRef->directoryURL = (CFURLRef)CFRetain(directoryURL);
    if(sdkRef->directoryURL == nullptr)
    {
        CFRelease(sdkRef);
        return nullptr;
    }
    
    CFStringRef pathStr = CFURLGetString(directoryURL);
    if(pathStr == nullptr)
    {
        CFRelease(sdkRef);
        return nullptr;
    }
    
    const char *cPathStr = CFStringGetCStringPtr(pathStr, kCFStringEncodingUTF8);
    if(cPathStr == nullptr)
    {
        CFRelease(sdkRef);
        return nullptr;
    }
    
    auto result = clang::parseDarwinSDKInfo(
        *llvm::vfs::getRealFileSystem(),
        std::string(cPathStr)
    );
    
    if(!result)
    {
        CFRelease(sdkRef);
        return nullptr;
    }
    
    if(!*result)
    {
        sdkRef->sdkInfo = nullptr;
        return sdkRef;
    }
    
    sdkRef->sdkInfo = std::make_unique<clang::DarwinSDKInfo>(
        std::move(**result)
    );
    
    return sdkRef;
}

CFStringRef CCSDKCopyVersion(CCSDKRef sdk)
{
    if(sdk == nullptr)
    {
        return nullptr;
    }
    
    VersionTuple versionTuple = sdk->sdkInfo->getVersion();
    std::string versionStr = versionTuple.getAsString();
    if(versionStr.empty())
    {
        return nullptr;
    }
    
    const char *versionCStr = versionStr.c_str();
    if(versionCStr == nullptr)
    {
        return nullptr;
    }
    
    return CFStringCreateWithCString(CFGetAllocator(sdk), versionCStr, kCFStringEncodingUTF8);
}

CFURLRef CCSDKGetDirectoryURL(CCSDKRef sdk)
{
    if(sdk == nullptr)
    {
        return nullptr;
    }
    
    return sdk->directoryURL;
}

CCSDKOSType CCSDKGetOSType(CCSDKRef sdk)
{
    if(sdk == nullptr)
    {
        return kCCSDKOSTypeUnknown;
    }
    
    switch(sdk->sdkInfo->getOS())
    {
        case Triple::OSType::Darwin:
            return kCCSDKOSTypeDarwin;
        default:
            return kCCSDKOSTypeUnknown;
    }
}

CFArrayRef CCSDKGetSupportedVersions(CCSDKRef sdk)
{
    if(sdk == nullptr)
    {
        return nullptr;
    }
    
    if(sdk->supportedVersions)
    {
        return sdk->supportedVersions;
    }
    
    CFAllocatorRef allocator = CFGetAllocator(sdk);
    CFURLRef settingsURL = CFURLCreateCopyAppendingPathComponent(allocator, sdk->directoryURL, CFSTR("SDKSettings.plist"), false);
    if(settingsURL == nullptr)
    {
        return nullptr;
    }
    
    CFStringRef settingsPath = CFURLCopyFileSystemPath(settingsURL, kCFURLPOSIXPathStyle);
    CFRelease(settingsURL);
    if(settingsPath == nullptr)
    {
        return nullptr;
    }
    
    const char *fileSystemPath = CFStringGetCStringPtr(settingsPath, kCFStringEncodingUTF8);
    if(fileSystemPath == nullptr)
    {
        CFRelease(settingsPath);
        return nullptr;
    }
    
    std::FILE *file = std::fopen(fileSystemPath, "rb");
    if(file == nullptr)
    {
        CFRelease(settingsPath);
        return nullptr;
    }
    
    std::fseek(file, 0, SEEK_END);
    long length = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    
    UInt8 *buffer = (UInt8*)std::malloc(length);
    std::fread(buffer, 1, length, file);
    std::fclose(file);
    
    CFDataRef plistData = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, buffer, length, kCFAllocatorMalloc);
    CFRelease(settingsPath);
    if(plistData == nullptr)
    {
        return nullptr;
    }
    
    CFErrorRef error = NULL;
    CFPropertyListFormat format;
    CFDictionaryRef plist = (CFDictionaryRef)CFPropertyListCreateWithData(kCFAllocatorDefault, plistData, kCFPropertyListImmutable, &format, &error);
    CFRelease(plistData);
    if(plist == nullptr)
    {
        return nullptr;
    }
    
    if(CFGetTypeID(plist) != CFDictionaryGetTypeID())
    {
        CFRelease(plist);
        return nullptr;
    }
    
    CFTypeRef validDeploymentTargets = nullptr;
    
    /*
     * this is a modern apple SDK, from now on
     * we already know that the legacy path is
     * not working if this doesn't.
     */
    CFTypeRef supportedTargets = CFDictionaryGetValue(plist, CFSTR("SupportedTargets"));
    if(supportedTargets != nullptr && CFGetTypeID(supportedTargets) == CFDictionaryGetTypeID())
    {
        CFTypeRef platform = CFDictionaryGetValue((CFDictionaryRef)supportedTargets, CFSTR("iphoneos"));
        if(platform != nullptr && CFGetTypeID(platform) == CFDictionaryGetTypeID())
        {
            validDeploymentTargets = CFDictionaryGetValue((CFDictionaryRef)platform, CFSTR("ValidDeploymentTargets"));
            if(validDeploymentTargets != nullptr && CFGetTypeID(validDeploymentTargets) == CFArrayGetTypeID())
            {
                validDeploymentTargets = validDeploymentTargets;
                goto got_targets;
            }
        }
    }
    
    /*
     * must be a legacy SDK, usually not shipped
     * on Nyxian, weird. Maybe someone using MDK
     * in a 3rd party IDE x3 Thank you for your
     * support!
     */
    validDeploymentTargets = CFDictionaryGetValue((CFDictionaryRef)plist, CFSTR("ValidDeploymentTargets"));
    
got_targets:
    
    if(validDeploymentTargets == nullptr || CFGetTypeID(validDeploymentTargets) != CFArrayGetTypeID())
    {
        CFRelease(plist);
        return nullptr;
    }
    
    /*
     * type validation, it shall only contain strings
     * never numbers, etc.
     */
    CFIndex count = CFArrayGetCount((CFArrayRef)validDeploymentTargets);
    for(CFIndex index = 0; index < count; index++)
    {
        CFTypeRef value = CFArrayGetValueAtIndex((CFArrayRef)validDeploymentTargets, index);
        if(CFGetTypeID(value) != CFStringGetTypeID())
        {
            CFRelease(plist);
            return nullptr;
        }
    }
    
    sdk->supportedVersions = (CFArrayRef)CFRetain(validDeploymentTargets);
    CFRelease(plist);
    if(sdk->supportedVersions == nullptr)
    {
        return nullptr;
    }
    
    return sdk->supportedVersions;
}
