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

#include <CoreCompiler/CCASTUnit.h>
#include <clang/Frontend/ASTUnit.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Tooling/Tooling.h>
#include <clang/Basic/DiagnosticOptions.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/ADT/StringRef.h>
#include <clang/Basic/LLVM.h>
#include <clang/AST/RecursiveASTVisitor.h>
#include <swift/Frontend/Frontend.h>
#include <swift/AST/DiagnosticConsumer.h>
#include <swift/AST/DiagnosticEngine.h>
#include <swift/Basic/SourceManager.h>
#include <llvm/Support/MemoryBuffer.h>
#include <CoreCompiler/CCUtils.h>

using namespace clang;
using namespace clang::driver;

struct CapturedDiag {
    swift::DiagID id;
    swift::DiagnosticKind kind;
    std::string message;
    std::string file;
    unsigned line = 0, column = 0;
};

class CapturingConsumer : public swift::DiagnosticConsumer {
public:
    std::vector<CapturedDiag> diags;

    void handleDiagnostic(swift::SourceManager &SM,
                          const swift::DiagnosticInfo &Info) override
    {
        CapturedDiag d;
        d.id = Info.ID;
        d.kind = Info.Kind;
        
        llvm::SmallString<256> buf;
        {
            llvm::raw_svector_ostream os(buf);
            swift::DiagnosticEngine::formatDiagnosticText(os, Info.FormatString, Info.FormatArgs);
        }
        d.message = std::string(buf);

        if(Info.Loc.isValid())
        {
            auto lc = SM.getPresumedLineAndColumnForLoc(Info.Loc);
            d.line = lc.first;
            d.column = lc.second;
            d.file = SM.getDisplayNameForLoc(Info.Loc).str();
        }
        diags.push_back(std::move(d));
    }
};

static CFTypeID gCCASTUnitTypeID = _kCFRuntimeNotATypeID;

struct __CCASTUnit {
    CFRuntimeBase _base;
    CCASTUnitType type;
    Boolean isMutable;
    
    /* clang ast unit property */
    std::unique_ptr<ASTUnit> unit;
    std::unique_ptr<clang::FrontendAction> action;
    
    /* swift driver properties */
    std::unique_ptr<swift::CompilerInstance> CI;
    std::unique_ptr<llvm::MemoryBuffer> primaryBuffer;
    CapturingConsumer consumer;
    
    /* shared ast unit properties */
    std::vector<std::string> BaseArgs;
    CCFileRef file;
    CFArrayRef diagnostics;
};

static void CCASTUnitFinalize(CFTypeRef cf)
{
    CCMutableASTUnitRef unit = (CCMutableASTUnitRef)cf;
    
    if(unit->CI != nullptr)
    {
        unit->CI->freeASTContext();
    }
    unit->CI.~unique_ptr();
    unit->primaryBuffer.~unique_ptr();
    unit->consumer.~CapturingConsumer();
    unit->unit.~unique_ptr();
    unit->action.~unique_ptr();
    unit->BaseArgs.~vector();
    
    if(unit->file != nullptr)
    {
        CFRelease(unit->file);
    }
    if(unit->diagnostics != nullptr)
    {
        CFRelease(unit->diagnostics);
    }
}

static void CCASTUnitInit(CFTypeRef cf)
{
    CCMutableASTUnitRef unit = (CCMutableASTUnitRef)cf;
    new (&unit->BaseArgs) std::vector<std::string>();
    new (&unit->unit) std::unique_ptr<ASTUnit>();
    new (&unit->action) std::unique_ptr<clang::FrontendAction>();
    new (&unit->CI) std::unique_ptr<swift::CompilerInstance>();
    new (&unit->primaryBuffer) std::unique_ptr<llvm::MemoryBuffer>();
    new (&unit->consumer) CapturingConsumer();
    unit->isMutable = true;
    unit->file = nullptr;
    unit->diagnostics = nullptr;
}

static const CFRuntimeClass gCCASTUnitClass = {
    0,                              /* version */
    "CCASTUnit",                    /* class name */
    CCASTUnitInit,                  /* init */
    NULL,                           /* copy */
    CCASTUnitFinalize,              /* finalize */
    NULL,                           /* equal */
    NULL,                           /* hash */
    NULL,                           /* copyFormattingDesc */
    NULL,                           /* copyDebugDesc */
    NULL,
    NULL,
    0
};

CFTypeID CCASTUnitGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCCASTUnitTypeID = _CFRuntimeRegisterClass(&gCCASTUnitClass);
    });
    return gCCASTUnitTypeID;
}

Boolean _CCASTUnitRefillDiagnosticArrayClang(CCMutableASTUnitRef mutableUnit)
{
    if(mutableUnit->diagnostics != nullptr)
    {
        return false;
    }
    
    CFAllocatorRef allocator = CFGetAllocator(mutableUnit);
    
    /* now parse the diagnostics */
    CFIndex count = mutableUnit->unit->stored_diag_size();
    CFMutableArrayRef diagnostics = CFArrayCreateMutable(allocator, count, &kCFTypeArrayCallBacks);
    if(diagnostics == nullptr)
    {
        return false;
    }
    
    CFURLRef fileURL = CCFileGetFileURL(mutableUnit->file);
    CFStringRef filePath = CFURLCopyFileSystemPath(fileURL, kCFURLPOSIXPathStyle);
    
    /* now indice for indice */
    for(CFIndex i = 0; i < count; i++)
    {
        CCDiagnosticType type = kCCDiagnosticTypeFile;
        CCDiagnosticLevel level;
        CFURLRef fileURL = nullptr;
        CCSourceLocation location;
        CFStringRef message;
        
        const StoredDiagnostic &diag = mutableUnit->unit->stored_diag_begin()[i];
        clang::PresumedLoc loc = mutableUnit->unit->getSourceManager().getPresumedLoc(diag.getLocation());
        
        std::string fileNameStr;
        const char *fileName = nullptr;
        
        if(loc.isValid())
        {
            if(mutableUnit->file != nullptr)
            {
                char filePath[PATH_MAX];
                if(CFURLGetFileSystemRepresentation(CCFileGetFileURL(mutableUnit->file), true, (UInt8*)filePath, sizeof(filePath)))
                {
                    type = (strncmp(filePath, loc.getFilename(), PATH_MAX) == 0) ? kCCDiagnosticTypeTargetFile : kCCDiagnosticTypeFile;
                }
            }
            
            fileName = loc.getFilename();
            location = CCSourceLocationMake(loc.getLine(), loc.getColumn());
        }
        else
        {
            type = kCCDiagnosticTypeInternal;
            location = CCSourceLocationZero;
            
            fileNameStr = mutableUnit->unit->getOriginalSourceFileName().str();
            if(!fileNameStr.empty())
            {
                fileName = fileNameStr.c_str();
            }
        }
        
        if(fileName == nullptr)
        {
            continue;
        }
        
        CFStringRef fileStr = CFStringCreateWithCString(allocator, fileName, kCFStringEncodingUTF8);
        if(fileStr == nullptr)
        {
            continue;
        }
        
        fileURL = CFURLCreateWithFileSystemPath(allocator, fileStr, kCFURLPOSIXPathStyle, false);
        CFRelease(fileStr);
        if(fileURL == nullptr)
        {
            /* in-case fileURL is nullptr then it would crash when creating CCFileSourceLocation */
            continue;
        }
        
        message = CFStringCreateWithCString(allocator, diag.getMessage().str().c_str(), kCFStringEncodingUTF8);
        
        /* resolves message severity  mapping */
        switch(diag.getLevel())
        {
            case clang::DiagnosticsEngine::Note:
                level = kCCDiagnosticLevelNote;
                break;
            case clang::DiagnosticsEngine::Remark:
                level = kCCDiagnosticLevelRemark;
                break;
            case clang::DiagnosticsEngine::Warning:
                level = kCCDiagnosticLevelWarning;
                break;
            case clang::DiagnosticsEngine::Error:
                level = kCCDiagnosticLevelError;
                break;
            case clang::DiagnosticsEngine::Fatal:
                level = kCCDiagnosticLevelFatal;
                break;
            default:
                level = kCCDiagnosticLevelUnknown;
                break;
        }
        
        CCFileSourceLocationRef fileSourceLocation = CCFileSourceLocationCreate(allocator, fileURL, location);
        CCDiagnosticRef result = CCDiagnosticCreate(allocator, type, level, filePath, fileSourceLocation, message);
        if(fileSourceLocation != NULL)
        {
            CFRelease(fileSourceLocation);
        }
        if(fileURL)
        {
            CFRelease(fileURL);
        }
        CFRelease(message);
        
        CFArrayAppendValue(diagnostics, result);
        CFRelease(result); /* array owns now a reference */
    }
    
    CFRelease(filePath);
    
    mutableUnit->diagnostics = diagnostics;
    
    return true;
}

static Boolean _CCASTUnitRefillDiagnosticArraySwift(CCMutableASTUnitRef u)
{
    CFAllocatorRef allocator = CFGetAllocator(u);
    CFMutableArrayRef diagnostics = CFArrayCreateMutable(allocator, u->consumer.diags.size(), &kCFTypeArrayCallBacks);
    if(diagnostics == nullptr)
    {
        return false;
    }
    
    char unitPath[PATH_MAX];
    CFURLGetFileSystemRepresentation(CCFileGetFileURL(u->file), true, (UInt8 *)unitPath, sizeof(unitPath));
    CFStringRef filePath = CFURLCopyFileSystemPath(CCFileGetFileURL(u->file), kCFURLPOSIXPathStyle);
    
    for(const CapturedDiag &d : u->consumer.diags)
    {
        CCDiagnosticLevel level;
        switch(d.kind)
        {
            case swift::DiagnosticKind::Note:
                level = kCCDiagnosticLevelNote;
                break;
            case swift::DiagnosticKind::Remark:
                level = kCCDiagnosticLevelRemark;
                break;
            case swift::DiagnosticKind::Warning:
                level = kCCDiagnosticLevelWarning;
                break;
            case swift::DiagnosticKind::Error:
                level = kCCDiagnosticLevelError;
                break;
            default:
                level = kCCDiagnosticLevelUnknown;
                break;
        }
        if(level == kCCDiagnosticLevelUnknown)
        {
            continue;
        }
        
        CCDiagnosticType type;
        CCSourceLocation location;
        CCFileSourceLocationRef fileSourceLocation = nullptr;
        
        if(d.file.empty())
        {
            type = kCCDiagnosticTypeInternal;
            location = CCSourceLocationZero;
        }
        else
        {
            type = (d.file == unitPath) ? kCCDiagnosticTypeTargetFile : kCCDiagnosticTypeFile;
            location = CCSourceLocationMake(d.line, d.column);
            
            CFStringRef fileStr = CFStringCreateWithCString(allocator, d.file.c_str(), kCFStringEncodingUTF8);
            if(fileStr != nullptr)
            {
                CFURLRef fileURL = CFURLCreateWithFileSystemPath(allocator, fileStr, kCFURLPOSIXPathStyle, false);
                CFRelease(fileStr);
                if(fileURL != nullptr)
                {
                    fileSourceLocation = CCFileSourceLocationCreate(allocator, fileURL, location);
                    CFRelease(fileURL);
                }
            }
        }
        
        CFStringRef message = CFStringCreateWithCString(allocator, d.message.c_str(), kCFStringEncodingUTF8);
        if(message == nullptr)
        {
            if(fileSourceLocation) { CFRelease(fileSourceLocation); }
            continue;
        }
        
        CCDiagnosticRef result = CCDiagnosticCreate(allocator, type, level, filePath, fileSourceLocation, message);
        CFRelease(message);
        if(fileSourceLocation)
        {
            CFRelease(fileSourceLocation);
        }
        if(result == nullptr)
        {
            continue;
        }
        
        CFArrayAppendValue(diagnostics, result);
        CFRelease(result);
    }
    
    CFRelease(filePath);
    u->diagnostics = diagnostics;
    return true;
}

Boolean _CCASTUnitRefillDiagnosticArray(CCMutableASTUnitRef mutableUnit)
{
    if(mutableUnit->diagnostics != nullptr)
    {
        return true;
    }
    switch(mutableUnit->type)
    {
        case kCCASTUnitTypeClang:
            return _CCASTUnitRefillDiagnosticArrayClang(mutableUnit);
        case kCCASTUnitTypeSwift:
            return _CCASTUnitRefillDiagnosticArraySwift(mutableUnit);
        default:
            return false;
    }
}

CCMutableASTUnitRef CCASTUnitCreateMutable(CFAllocatorRef allocator,
                                           CCASTUnitType type)
{
    CCMutableASTUnitRef unit = (CCMutableASTUnitRef)_CFRuntimeCreateInstance(allocator, CCASTUnitGetTypeID(), sizeof(__CCASTUnit) - sizeof(CFRuntimeBase), nullptr);
    if(unit == nullptr)
    {
        return nullptr;
    }
    unit->type = type;
    return unit;
}

CCASTUnitRef CCASTUnitCreateWithASTUnit(CFAllocatorRef allocator,
                                        std::unique_ptr<clang::ASTUnit> astUnit,
                                        std::unique_ptr<clang::FrontendAction> action)
{
    assert(astUnit != nullptr);

    CCFileRef file = nullptr;
    std::string originalInputFileName = astUnit->getOriginalSourceFileName().str();
    if(originalInputFileName.empty())
    {
        return nullptr;
    }
    
    const char *originalInputFileNameCStr = originalInputFileName.c_str();
    file = CCFileCreateWithCString(allocator, originalInputFileNameCStr, kCFStringEncodingUTF8);
    if(file == nullptr)
    {
        return nullptr;
    }
    
    CCMutableASTUnitRef unit = (CCMutableASTUnitRef)_CFRuntimeCreateInstance(allocator, CCASTUnitGetTypeID(), sizeof(__CCASTUnit) - sizeof(CFRuntimeBase), nullptr);
    if(unit == nullptr)
    {
        CFRelease(file);
        return nullptr;
    }
    
    unit->file = file;
    unit->unit = std::move(astUnit);
    unit->action = std::move(action);
    
    _CCASTUnitRefillDiagnosticArray(unit);

    /* marking immutable, since not a live AST object */
    unit->isMutable = false;

    return (CCASTUnitRef)unit;
}

static const char *_CCASTUnitLangFlagForFile(CCFileRef file)
{
    switch(CCFileGetType(file))
    {
        case kCCFileTypeC:
            return "c";
        /*
         * MARK: special mapping, due to missing indexing in CoreCompiler for now
         *
         * case CCFileTypeCHeader:
         *    return "c-header";
        */
        case kCCFileTypeObjC:
            return "objective-c";
        case kCCFileTypeCHeader:
        case kCCFileTypeObjCHeader:
            return "objective-c-header";
        case kCCFileTypeCXX:
            return "c++";
        case kCCFileTypeCXXHeader:
            return "c++-header";
        case kCCFileTypeObjCXX:
            return "objective-c++";
        case kCCFileTypeObjCXXHeader:
            return "objective-c++-header";
        default:
            return nullptr;
    }
}

Boolean _CCASTUnitReparseClang(CCMutableASTUnitRef mutableUnit)
{
    assert(mutableUnit->isMutable);
    
    /*
     * releasing diagnostics array, because
     * the data it contains is now invalid
     * anyways.
     */
    if(mutableUnit->diagnostics != nullptr)
    {
        CFRelease(mutableUnit->diagnostics);
        
        /* so the data is officially not valid anymore */
        mutableUnit->diagnostics = nullptr;
    }
    
    if(mutableUnit->BaseArgs.size() == 0)
    {
        /* arguments havent been set */
        return false;
    }
    
    /* setting up argument */
    SmallVector<const char *, 64> args;
    for(const std::string &arg : mutableUnit->BaseArgs)
    {
        args.push_back(arg.c_str());
    }
    
    char filePath[PATH_MAX];
    CFURLGetFileSystemRepresentation(CCFileGetFileURL(mutableUnit->file), true, (UInt8*)filePath, sizeof(filePath));
    
    args.push_back(filePath);
    
    IntrusiveRefCntPtr<DiagnosticIDs> diagID(new DiagnosticIDs());
    auto diagOpts = std::make_shared<DiagnosticOptions>();
    IntrusiveRefCntPtr<DiagnosticsEngine> diags(new DiagnosticsEngine(diagID, *diagOpts, new clang::IgnoringDiagConsumer(), /*ShouldOwnClient=*/true));
    
    SmallVector<ASTUnit::RemappedFile, 4> remaps;
    CFDataRef data = CCFileGetUnsavedData(mutableUnit->file);
    if(data != nullptr)
    {
        llvm::StringRef contentRef((const char*)CFDataGetBytePtr(data), CFDataGetLength(data));
        std::unique_ptr<llvm::MemoryBuffer> buf = llvm::MemoryBuffer::getMemBufferCopy(contentRef, filePath);
        auto remap = clang::ASTUnit::RemappedFile(filePath, buf.release());
        remaps.push_back(remap);
    }
    ArrayRef<ASTUnit::RemappedFile> remapRef = remaps;
    
    if(mutableUnit->unit == nullptr)
        reparse_from_nothing:
    {
        mutableUnit->unit = ASTUnit::LoadFromCommandLine(args.data(),
                                                         args.data() + args.size(),
                                                         std::make_shared<PCHContainerOperations>(),
                                                         diagOpts,
                                                         diags,
                                                         "",    /* resources comes from arguments */
                                                         /*StorePreamblesInMemory=*/true,
                                                         /*PreambleStoragePath=*/"",
                                                         /*OnlyLocalDecls=*/false,
                                                         clang::CaptureDiagsKind::All,
                                                         remapRef,
                                                         /*RemappedFilesKeepOriginalName=*/true,
                                                         /*PrecompilePreambleAfterNParses=*/0,  // 0 = no preamble precompilation
                                                         clang::TU_Complete,
                                                         /*CacheCodeCompletionResults=*/false,
                                                         /*IncludeBriefComments=*/false,
                                                         /*AllowPCHWithCompilerErrors=*/false,
                                                         clang::SkipFunctionBodiesScope::None,
                                                         /*SingleFileParse=*/false,
                                                         /*UserFilesAreVolatile=*/false,
                                                         /*ForSerialization=*/false,
                                                         /*RetainExcludedConditionalBlocks=*/false,
                                                         /*ModuleFormat=*/std::nullopt,
                                                         nullptr);
    }
    else if(mutableUnit->unit->Reparse(std::make_shared<PCHContainerOperations>(), remapRef))
    {
        /*
         * failed reparse, gonna have to
         * parse from 0.
         */
        mutableUnit->unit.reset();
        remaps.clear();
        if(data != nullptr)
        {
            llvm::StringRef contentRef((const char*)CFDataGetBytePtr(data), CFDataGetLength(data));
            remaps.push_back(ASTUnit::RemappedFile(filePath, llvm::MemoryBuffer::getMemBufferCopy(contentRef, filePath).release()));
        }
        remapRef = remaps;
        goto reparse_from_nothing;
    }
    
    if((mutableUnit->unit != nullptr) && !_CCASTUnitRefillDiagnosticArray(mutableUnit))
    {
        return false;
    }
    
    return true;
}

static Boolean _CCASTUnitReparseSwift(CCMutableASTUnitRef mutableUnit)
{
    if(mutableUnit->CI != nullptr)
    {
        mutableUnit->CI->freeASTContext();
        mutableUnit->CI.reset();
    }
    mutableUnit->primaryBuffer.reset();
    mutableUnit->consumer.diags.clear();
    
    char primaryPath[PATH_MAX];
    if(!CFURLGetFileSystemRepresentation(CCFileGetFileURL(mutableUnit->file), true, (UInt8 *)primaryPath, sizeof(primaryPath)))
    {
        return false;
    }
    
    auto CI = std::make_unique<swift::CompilerInstance>();
    CI->addDiagnosticConsumer(&mutableUnit->consumer);
    
    llvm::SmallVector<const char *, 64> args;
    for(size_t i = 0; i < mutableUnit->BaseArgs.size(); i++)
    {
        const std::string &arg = mutableUnit->BaseArgs[i];
        if(arg == "-Xfrontend")
        {
            if(i + 1 < mutableUnit->BaseArgs.size())
            {
                args.push_back(mutableUnit->BaseArgs[++i].c_str());
            }
            continue;
        }
        args.push_back(arg.c_str());
    }
    
    swift::CompilerInvocation invocation;
    if(invocation.parseArgs(args, CI->getDiags(), nullptr, "", ""))
    {
        return false;
    }
    
    invocation.getFrontendOptions().RequestedAction = swift::FrontendOptions::ActionType::Typecheck;
    
    /* load unsaved buffer */
    CFDataRef data = CCFileGetUnsavedData(mutableUnit->file);
    if(data != nullptr)
    {
        llvm::StringRef content((const char *)CFDataGetBytePtr(data), CFDataGetLength(data));
        mutableUnit->primaryBuffer = llvm::MemoryBuffer::getMemBufferCopy(content, primaryPath);
    }
    
    {
        auto &io = invocation.getFrontendOptions().InputsAndOutputs;
        swift::FrontendInputsAndOutputs rebuilt;
        for(const auto &in : io.getAllInputs())
        {
            bool isPrimary = (in.getFileName() == primaryPath);
            rebuilt.addInput(swift::InputFile(in.getFileName(), isPrimary, isPrimary ? mutableUnit->primaryBuffer.get() : nullptr));
        }
        io = std::move(rebuilt);
    }
    
    /* so it can build properly */
    CCInitializeSwiftModulesOnce();

    std::string error;
    if(CI->setup(invocation, error))
    {
        return false;
    }
    
    CI->performSema();
    
    mutableUnit->CI = std::move(CI);
    
    return _CCASTUnitRefillDiagnosticArray(mutableUnit);
}

Boolean CCASTUnitReparse(CCMutableASTUnitRef mutableUnit)
{
    assert(mutableUnit->isMutable);
    
    if(mutableUnit->diagnostics != nullptr)
    {
        CFRelease(mutableUnit->diagnostics);
        mutableUnit->diagnostics = nullptr;
    }
    if(mutableUnit->BaseArgs.empty())
    {
        return false;
    }

    switch(mutableUnit->type)
    {
        case kCCASTUnitTypeClang:
            return _CCASTUnitReparseClang(mutableUnit);
        case kCCASTUnitTypeSwift:
            return _CCASTUnitReparseSwift(mutableUnit);
        default:
            return false;
    }
}

void CCASTUnitSetArguments(CCMutableASTUnitRef mutableUnit,
                           CFArrayRef arguments)
{
    assert(mutableUnit->isMutable);
    
    mutableUnit->unit.reset();
    if(mutableUnit->CI != nullptr)
    {
        mutableUnit->CI->freeASTContext();
    }
    mutableUnit->CI.reset();
    mutableUnit->primaryBuffer.reset();
    mutableUnit->BaseArgs.clear();
    
    if(mutableUnit->type == kCCASTUnitTypeClang)
    {
        mutableUnit->BaseArgs.push_back("clang");
        
        const char *lang = _CCASTUnitLangFlagForFile(mutableUnit->file);
        if(lang)
        {
            mutableUnit->BaseArgs.push_back("-x");
            mutableUnit->BaseArgs.push_back(lang);
        }
        
        /*
         * silencing those weird linker warnings
         * on live typechecking, which libclang
         * doesn't do automatically, but it should
         * be done automatically to not piss of
         * developers and engineers like me.
         */
        mutableUnit->BaseArgs.push_back("--start-no-unused-arguments");
        const char *homeEnv = std::getenv("HOME");
        if(homeEnv)
        {
            std::string cachePath = std::string(homeEnv) + "/Documents/Cache/Clang";
            if(!llvm::sys::fs::create_directories(cachePath))
            {
                mutableUnit->BaseArgs.push_back("-fmodules-cache-path=" + cachePath);
            }
        }
        
        CFIndex count = CFArrayGetCount(arguments);
        for(CFIndex i = 0; i < count; i++)
        {
            CFStringRef arg = (CFStringRef)CFArrayGetValueAtIndex(arguments, i);
            const char *ptr = CFStringGetCStringPtr(arg, kCFStringEncodingUTF8);
            if(ptr)
            {
                mutableUnit->BaseArgs.push_back(ptr);
            }
            else
            {
                char buf[1024];
                CFStringGetCString(arg, buf, sizeof(buf), kCFStringEncodingUTF8);
                mutableUnit->BaseArgs.push_back(buf);
            }
        }
        mutableUnit->BaseArgs.push_back("--end-no-unused-arguments");
    }
    else
    {
        mutableUnit->BaseArgs.push_back("-typecheck");
        CFIndex count = CFArrayGetCount(arguments);
        for(CFIndex i = 0; i < count; i++)
        {
            CFStringRef arg = (CFStringRef)CFArrayGetValueAtIndex(arguments, i);
            const char *ptr = CFStringGetCStringPtr(arg, kCFStringEncodingUTF8);
            if(ptr)
            {
                mutableUnit->BaseArgs.push_back(ptr);
            }
            else
            {
                char buf[1024];
                CFStringGetCString(arg, buf, sizeof(buf), kCFStringEncodingUTF8);
                mutableUnit->BaseArgs.push_back(buf);
            }
        }
    }
}

void CCASTUnitSetFile(CCMutableASTUnitRef mutableUnit,
                      CCFileRef file)
{
    assert(mutableUnit->isMutable);

    if(mutableUnit->file != nullptr)
    {
        if(!CFEqual(CCFileGetFileURL(mutableUnit->file), CCFileGetFileURL(file)))
        {
            mutableUnit->unit.reset();
        }
        CFRelease(mutableUnit->file);
    }
    mutableUnit->file = (CCFileRef)CFRetain(file);
}

CCFileRef CCASTUnitGetFile(CCASTUnitRef unit)
{
    return unit->file;
}

CCFileRef CCASTUnitCopyFile(CCASTUnitRef unit)
{
    if(unit->file == nullptr)
    {
        return nullptr;
    }
    return CCFileCreateCopy(CFGetAllocator(unit), unit->file);
}

Boolean CCASTUnitErrorOccured(CCASTUnitRef unit)
{
    switch(unit->type)
    {
        case kCCASTUnitTypeClang:
            return unit->unit ? unit->unit->getDiagnostics().hasErrorOccurred() : true;
        case kCCASTUnitTypeSwift:
            return unit->CI ? unit->CI->getDiags().hadAnyError() : true;
        default:
            return true;
    }
}

class DeclAtLocationVisitor : public RecursiveASTVisitor<DeclAtLocationVisitor> {
public:
    SourceLocation targetLoc;
    SourceManager *SM;
    Decl *found = nullptr;
    
    bool shouldVisitTemplateInstantiations() const { return true; }
    
    bool VisitDeclRefExpr(DeclRefExpr *E)
    {
        if(SM->getSpellingLoc(E->getLocation()) == SM->getSpellingLoc(targetLoc))
        {
            found = E->getDecl();
            return false;
        }
        return true;
    }
    
    bool VisitMemberExpr(MemberExpr *E)
    {
        if(SM->getSpellingLoc(E->getMemberLoc()) == SM->getSpellingLoc(targetLoc))
        {
            found = E->getMemberDecl();
            return false;
        }
        return true;
    }
    
    bool VisitObjCMessageExpr(ObjCMessageExpr *E)
    {
        if(SM->getSpellingLoc(E->getSelectorStartLoc()) == SM->getSpellingLoc(targetLoc))
        {
            found = E->getMethodDecl();
            return false;
        }
        return true;
    }
    
    bool VisitObjCPropertyRefExpr(ObjCPropertyRefExpr *E)
    {
        if(SM->getSpellingLoc(E->getLocation()) == SM->getSpellingLoc(targetLoc))
        {
            if(E->isExplicitProperty())
            {
                found = E->getExplicitProperty();
            }
            return false;
        }
        return true;
    }
    
    bool VisitObjCInterfaceDecl(ObjCInterfaceDecl *D)
    {
        if(D->getSuperClass() &&
           SM->getSpellingLoc(D->getSuperClassLoc()) == SM->getSpellingLoc(targetLoc))
        {
            found = D->getSuperClass()->getDefinition();
            if(!found)
            {
                found = D->getSuperClass();
            }
            return false;
        }
        
        auto locIt = D->protocol_loc_begin();
        for(auto *proto : D->protocols())
        {
            if(SM->getSpellingLoc(*locIt) == SM->getSpellingLoc(targetLoc))
            {
                found = proto->getDefinition();
                if(!found)
                {
                    found = proto;
                }
                return false;
            }
            ++locIt;
        }
        
        return true;
    }
    
    bool VisitObjCCategoryDecl(ObjCCategoryDecl *D)
    {
        if(D->getClassInterface() &&
           SM->getSpellingLoc(D->getLocation()) == SM->getSpellingLoc(targetLoc))
        {
            found = D->getClassInterface()->getDefinition();
            return false;
        }
        return true;
    }
    
    bool VisitObjCImplementationDecl(ObjCImplementationDecl *D)
    {
        if(SM->getSpellingLoc(D->getLocation()) == SM->getSpellingLoc(targetLoc))
        {
            ObjCInterfaceDecl *iface = D->getClassInterface();
            if(iface)
            {
                found = iface->getDefinition();
                return false;
            }
        }
        return true;
    }
    
    bool VisitObjCInterfaceTypeLoc(ObjCInterfaceTypeLoc TL)
    {
        if(SM->getSpellingLoc(TL.getNameLoc()) == SM->getSpellingLoc(targetLoc))
        {
            ObjCInterfaceDecl *iface = TL.getIFaceDecl();
            if(iface)
            {
                found = iface->getDefinition();
                if(!found)
                {
                    found = iface;
                }
                return false;
            }
        }
        return true;
    }
    
    bool VisitNamedDecl(NamedDecl *D)
    {
        if(SM->getSpellingLoc(D->getLocation()) == SM->getSpellingLoc(targetLoc))
        {
            found = D;
            return false;
        }
        return true;
    }
};

CCFileSourceLocationRef CCASTUnitCopyDefinitionAtLocation(CCASTUnitRef unit,
                                                          CCSourceLocation location)
{
    if(unit->unit == nullptr || unit->file == nullptr || unit->type == kCCASTUnitTypeSwift)
    {
        return nullptr;
    }
    
    char filePath[PATH_MAX];
    if(!CFURLGetFileSystemRepresentation(CCFileGetFileURL(unit->file), true, (UInt8*)filePath, sizeof(filePath)))
    {
        return nullptr;
    }
    
    SourceManager &SM = unit->unit->getSourceManager();
    FileManager &FM = unit->unit->getFileManager();
    
    auto fileEntry = FM.getFileRef(filePath);
    if(!fileEntry)
    {
        return nullptr;
    }
    
    FileID fileID = SM.translateFile(*fileEntry);
    if(fileID.isInvalid())
    {
        return nullptr;
    }
    
    SourceLocation loc = SM.translateLineCol(fileID, (unsigned int)location.line, (unsigned int)location.column);
    if(loc.isInvalid())
    {
        return nullptr;
    }
    
    DeclAtLocationVisitor visitor;
    visitor.targetLoc = loc;
    visitor.SM = &SM;
    visitor.TraverseAST(unit->unit->getASTContext());
    
    Decl *cursor = visitor.found;
    if(!cursor)
    {
        return nullptr;
    }
    
    Decl *defDecl = nullptr;
    
    /* getting definition (hopefully) */
    if(auto *ID = dyn_cast<ObjCInterfaceDecl>(cursor))
    {
        defDecl = ID->getDefinition();
    }
    else if(auto *PD = dyn_cast<ObjCProtocolDecl>(cursor))
    {
        defDecl = PD->getDefinition();
    }
    else if(auto *TD = dyn_cast<TagDecl>(cursor))
    {
        defDecl = TD->getDefinition();
    }
    else if(auto *FD = dyn_cast<FunctionDecl>(cursor))
    {
        defDecl = FD->getDefinition();
    }
    
    /* last resort */
    if(defDecl == nullptr)
    {
        defDecl = cursor->getCanonicalDecl();
    }
    
    if(!defDecl)
    {
        return nullptr;
    }
    
    SourceLocation defLoc = defDecl->getLocation();
    PresumedLoc presumed = SM.getPresumedLoc(defLoc);
    
    if(presumed.isInvalid())
    {
        return nullptr;
    }
    
    CFAllocatorRef allocator = CFGetAllocator(unit);
    CFStringRef fileStr = CFStringCreateWithCString(allocator, presumed.getFilename(), kCFStringEncodingUTF8);
    CFURLRef fileURL = CFURLCreateWithFileSystemPath(allocator, fileStr, kCFURLPOSIXPathStyle, false);
    CFRelease(fileStr);
    
    CCSourceLocation resultLoc = CCSourceLocationMake(presumed.getLine(), presumed.getColumn());
    CCFileSourceLocationRef result = CCFileSourceLocationCreate(allocator, fileURL, resultLoc);
    CFRelease(fileURL);
    return result;
}

CFArrayRef CCASTUnitCopyDiagnostics(CCASTUnitRef unit)
{
    if(unit->diagnostics == nullptr)
    {
        return nullptr;
    }
    return (CFArrayRef)CFRetain(unit->diagnostics);
}
