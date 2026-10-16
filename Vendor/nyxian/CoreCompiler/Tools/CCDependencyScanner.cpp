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

#include <CoreCompiler/CCDependencyScanner.h>
#include <clang/Tooling/DependencyScanning/DependencyScanningTool.h>
#include <clang/Tooling/DependencyScanning/DependencyScanningService.h>
#include <clang/Tooling/CompilationDatabase.h>
#include <llvm/Support/VirtualFileSystem.h>

using namespace clang;
using namespace clang::tooling::dependencies;

static CFTypeID gCCDependencyScannerTypeID = _kCFRuntimeNotATypeID;

struct __CCDependencyScanner {
    CFRuntimeBase _base;
    DependencyScanningService service;
    std::vector<std::string> BaseArgs;
    std::string sysroot;
    std::string resourceDir;
};

static void CCDependencyScannerFinalize(CFTypeRef cf)
{
    CCDependencyScannerRef dependencyScanner = (CCDependencyScannerRef)cf;
    dependencyScanner->service.~DependencyScanningService();
    dependencyScanner->BaseArgs.~vector();
    dependencyScanner->sysroot.~basic_string();
    dependencyScanner->resourceDir.~basic_string();
}

static void CCDependencyScannerInit(CFTypeRef cf)
{
    CCDependencyScannerRef dependencyScanner = (CCDependencyScannerRef)cf;
    new (&dependencyScanner->service) DependencyScanningService(ScanningMode::DependencyDirectivesScan, ScanningOutputFormat::Full, CASOptions{}, /*CAS=*/nullptr, /*Cache=*/nullptr);
    new (&dependencyScanner->BaseArgs) std::vector<std::string>();
    new (&dependencyScanner->sysroot) std::string();
    new (&dependencyScanner->resourceDir) std::string();
}

static const CFRuntimeClass gCCDependencyScannerClass = {
    0,                              /* version */
    "CCDependencyScanner",          /* class name */
    CCDependencyScannerInit,        /* init */
    NULL,                           /* copy */
    CCDependencyScannerFinalize,    /* finalize */
    NULL,                           /* equal */
    NULL,                           /* hash */
    NULL,                           /* copyFormattingDesc */
    NULL,                           /* copyDebugDesc */
    NULL,
    NULL,
    0
};

CFTypeID CCDependencyScannerGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCCDependencyScannerTypeID = _CFRuntimeRegisterClass(&gCCDependencyScannerClass);
    });
    return gCCDependencyScannerTypeID;
}

CCDependencyScannerRef CCDependencyScannerCreate(CFAllocatorRef allocator,
                                                 CFArrayRef arguments)
{
    assert(arguments != nullptr);
    
    CCDependencyScannerRef dependencyScanner = (CCDependencyScannerRef)_CFRuntimeCreateInstance(allocator, CCDependencyScannerGetTypeID(), sizeof(struct __CCDependencyScanner) - sizeof(CFRuntimeBase), NULL);
    if(dependencyScanner == nullptr)
    {
        return nullptr;
    }
    
    dependencyScanner->BaseArgs.push_back("clang");
    const char *homeEnv = std::getenv("HOME");
    if(homeEnv)
    {
        dependencyScanner->BaseArgs.push_back("-fmodules");
        dependencyScanner->BaseArgs.push_back("-fimplicit-module-maps");
        dependencyScanner->BaseArgs.push_back("-fmodules-cache-path=" + std::string(homeEnv) + "/Documents/Cache/Clang");
    }
    CFIndex count = CFArrayGetCount(arguments);
    for(CFIndex i = 0; i < count; i++)
    {
        CFStringRef arg = (CFStringRef)CFArrayGetValueAtIndex(arguments, i);
        const char *ptr = CFStringGetCStringPtr(arg, kCFStringEncodingUTF8);
        if(ptr)
        {
            dependencyScanner->BaseArgs.push_back(ptr);
        }
        else
        {
            char buf[1024];
            CFStringGetCString(arg, buf, sizeof(buf), kCFStringEncodingUTF8);
            dependencyScanner->BaseArgs.push_back(buf);
        }
    }
    
    for(size_t i = 0; i < dependencyScanner->BaseArgs.size(); i++)
    {
        if(dependencyScanner->BaseArgs[i] == "-isysroot" && i + 1 < dependencyScanner->BaseArgs.size())
        {
            dependencyScanner->sysroot = dependencyScanner->BaseArgs[i + 1];
            i++;
        }
        else if(llvm::StringRef(dependencyScanner->BaseArgs[i]).starts_with("-isysroot") && dependencyScanner->BaseArgs[i].size() > 9)
        {
            dependencyScanner->sysroot = dependencyScanner->BaseArgs[i].substr(9);
        }
        else if(dependencyScanner->BaseArgs[i] == "-resource-dir" && i + 1 < dependencyScanner->BaseArgs.size())
        {
            dependencyScanner->resourceDir = dependencyScanner->BaseArgs[i + 1];
            i++;
        }
        else if(llvm::StringRef(dependencyScanner->BaseArgs[i]).starts_with("-resource-dir="))
        {
            dependencyScanner->resourceDir = dependencyScanner->BaseArgs[i].substr(strlen("-resource-dir="));
        }
    }
    
    return dependencyScanner;
}

CFArrayRef CCDependencyScannerCopyDependencyFilesForFile(CCDependencyScannerRef dependencyScanner,
                                                         CCFileRef file)
{
    assert(file != nullptr);
    
    __block CFArrayRef headers = nullptr;
    CCDependencyScannerCopyDependenciesForFile(dependencyScanner, file, ^(Boolean success, CFArrayRef headerFilePaths, CFArrayRef dependencies){
        if(success)
        {
            headers = headerFilePaths;
        }
    });
    return headers;
}

void CCDependencyScannerCopyDependenciesForFile(CCDependencyScannerRef dependencyScanner,
                                                CCFileRef file,
                                                void (^callback)(Boolean success, CFArrayRef headerFilePaths, CFArrayRef dependencies))
{
    assert(file != nullptr);
    
    CFURLRef fileURL = CCFileGetFileURL(file);
    if(fileURL == nullptr)  /* MARK: might be guranteed */
    {
        callback(false, nullptr, nullptr);
        return;
    }
    
    CFStringRef filePath = CFURLCopyFileSystemPath(fileURL, kCFURLPOSIXPathStyle);
    if(filePath == nullptr)
    {
        callback(false, nullptr, nullptr);
        return;
    }
    
    const char *filePathCStr = CFStringGetCStringPtr(filePath, kCFStringEncodingUTF8);
    if(filePathCStr == nullptr)
    {
        CFRelease(filePath);
        callback(false, nullptr, nullptr);
        return;
    }
    
    std::string filePathStr(filePathCStr);
    CFRelease(filePath);
    
    DependencyScanningTool tool(dependencyScanner->service);
    
    std::vector<std::string> Args = dependencyScanner->BaseArgs;
    Args.push_back(filePathStr.c_str());
    
    CFMutableArrayRef dependencyArray = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if(dependencyArray == nullptr)
    {
        callback(false, nullptr, nullptr);
        return;
    }
    
    llvm::DenseSet<ModuleID> alreadySeen;
    auto lookupModuleOutput = [dependencyArray](const ModuleDeps &MD, ModuleOutputKind kind) -> std::string
    {
        switch(kind)
        {
            case ModuleOutputKind::ModuleFile:
            {
                for(auto library = MD.LinkLibraries.begin(); library != MD.LinkLibraries.end(); ++library)
                {
                    CFStringRef libraryStr = CFStringCreateWithCString(kCFAllocatorDefault, library->Library.c_str(), kCFStringEncodingUTF8);
                    if(libraryStr == nullptr)
                    {
                        continue;
                    }
                    
                    CCDependencyRef dependency = CCDependencyCreate(kCFAllocatorDefault, libraryStr, library->IsFramework);
                    CFRelease(libraryStr);
                    if(dependency == nullptr)
                    {
                        continue;
                    }
                    
                    CFArrayAppendValue(dependencyArray, dependency);
                    CFRelease(dependency);
                }
                
                std::string name = MD.ID.ModuleName;
                for(char &c : name)
                {
                    if(!std::isalnum(static_cast<unsigned char>(c)) && c != '_' && c != '-')
                    {
                        c = '_';
                    }
                }
                return "/__CCDependencyScanner__/" + name + "-" + MD.ID.ContextHash + ".pcm";
            }
                
            case ModuleOutputKind::DependencyFile:
            case ModuleOutputKind::DependencyTargets:
            case ModuleOutputKind::DiagnosticSerializationFile:
                return "";
        }
        
        return "";
    };
    
    llvm::Expected<TranslationUnitDeps> depsOrErr = tool.getTranslationUnitDependencies(Args, "/", alreadySeen, lookupModuleOutput);
    if(!depsOrErr)
    {
        llvm::errs() << llvm::toString(depsOrErr.takeError()) << '\n';
        CFRelease(dependencyArray);
        callback(false, nullptr, nullptr);
        return;
    }
    
    const TranslationUnitDeps &deps = *depsOrErr;
    CFAllocatorRef allocator = CFGetAllocator(dependencyScanner);
    
    CFMutableArrayRef headers = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);
    if(!headers)
    {
        CFRelease(dependencyArray);
        callback(false, nullptr, nullptr);
        return;
    }
    
    llvm::StringSet<> seen;
    auto addDependency = [&](llvm::StringRef path)
    {
        if(path.empty())
        {
            return;
        }
        
        if(path == filePathCStr)
        {
            return;
        }
        
        if(!dependencyScanner->sysroot.empty() && path.starts_with(dependencyScanner->sysroot))
        {
            return;
        }
        
        if(!dependencyScanner->resourceDir.empty() && path.starts_with(dependencyScanner->resourceDir))
        {
            return;
        }
        
        if(!seen.insert(path).second)
        {
            return;
        }
        
        std::string pathStr = path.str();
        
        CCFileRef depFile =
        CCFileCreateWithCString(allocator, pathStr.c_str(), kCFStringEncodingUTF8);
        
        if(!depFile)
        {
            return;
        }
        
        CFArrayAppendValue(headers, depFile);
        CFRelease(depFile);
    };
    
    for(const std::string &path : deps.FileDeps)
    {
        addDependency(path);
    }
    
    for(const ModuleDeps &module : deps.ModuleGraph)
    {
        module.forEachFileDep([&](llvm::StringRef path){
            addDependency(path);
        });
    }
    
    return callback(true, headers, dependencyArray);
}
