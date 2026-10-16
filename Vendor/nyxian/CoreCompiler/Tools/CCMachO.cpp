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

#include <CoreCompiler/CCMachO.h>

/* wtf apple, stop offending poor LLVM :c */
#undef CPU_TYPE_ANY
#undef CPU_ARCH_MASK
#undef CPU_ARCH_ABI64
#undef CPU_ARCH_ABI64_32
#undef CPU_TYPE_X86
#undef CPU_TYPE_I386
#undef CPU_TYPE_ARM
#undef CPU_TYPE_ARM64
#undef CPU_TYPE_ARM64_32
#undef CPU_SUBTYPE_MASK
#undef CPU_SUBTYPE_LIB64
#undef CPU_SUBTYPE_MULTIPLE
#undef CPU_TYPE_X86_64
#undef CPU_TYPE_MC98000
#undef CPU_TYPE_SPARC
#undef CPU_TYPE_POWERPC
#undef CPU_TYPE_POWERPC64
#undef CPU_SUBTYPE_I386_ALL
#undef CPU_SUBTYPE_386
#undef CPU_SUBTYPE_486
#undef CPU_SUBTYPE_486SX
#undef CPU_SUBTYPE_586
#undef CPU_SUBTYPE_PENT
#undef CPU_SUBTYPE_PENTPRO
#undef CPU_SUBTYPE_PENTII_M3
#undef CPU_SUBTYPE_PENTII_M5
#undef CPU_SUBTYPE_CELERON
#undef CPU_SUBTYPE_CELERON_MOBILE
#undef CPU_SUBTYPE_PENTIUM_3
#undef CPU_SUBTYPE_PENTIUM_3_M
#undef CPU_SUBTYPE_PENTIUM_3_XEON
#undef CPU_SUBTYPE_PENTIUM_M
#undef CPU_SUBTYPE_PENTIUM_4
#undef CPU_SUBTYPE_PENTIUM_4_M
#undef CPU_SUBTYPE_ITANIUM
#undef CPU_SUBTYPE_ITANIUM_2
#undef CPU_SUBTYPE_XEON
#undef CPU_SUBTYPE_XEON_MP
#undef CPU_SUBTYPE_X86_ALL
#undef CPU_SUBTYPE_X86_64_ALL
#undef CPU_SUBTYPE_X86_ARCH1
#undef CPU_SUBTYPE_X86_64_H
#undef CPU_SUBTYPE_INTEL
#undef CPU_SUBTYPE_INTEL_FAMILY
#undef CPU_SUBTYPE_INTEL_MODEL
#undef CPU_SUBTYPE_ARM_ALL
#undef CPU_SUBTYPE_ARM_V4T
#undef CPU_SUBTYPE_ARM_V6
#undef CPU_SUBTYPE_ARM_V5
#undef CPU_SUBTYPE_ARM_V5TEJ
#undef CPU_SUBTYPE_ARM_XSCALE
#undef CPU_SUBTYPE_ARM_V7
#undef CPU_SUBTYPE_ARM_V7S
#undef CPU_SUBTYPE_ARM_V7K
#undef CPU_SUBTYPE_ARM_V6M
#undef CPU_SUBTYPE_ARM_V7M
#undef CPU_SUBTYPE_ARM_V7EM
#undef CPU_SUBTYPE_INTEL_FAMILY_MAX
#undef CPU_SUBTYPE_INTEL_MODEL_ALL
#undef CPU_SUBTYPE_ARM64_ALL
#undef CPU_SUBTYPE_ARM64_V8
#undef CPU_SUBTYPE_ARM64E
#undef CPU_SUBTYPE_ARM64_32_V8
#undef CPU_SUBTYPE_SPARC_ALL
#undef CPU_SUBTYPE_POWERPC_ALL
#undef CPU_SUBTYPE_POWERPC_601
#undef CPU_SUBTYPE_POWERPC_602
#undef CPU_SUBTYPE_POWERPC_603
#undef CPU_SUBTYPE_POWERPC_603e
#undef CPU_SUBTYPE_POWERPC_603ev
#undef CPU_SUBTYPE_POWERPC_604
#undef CPU_SUBTYPE_POWERPC_604e
#undef CPU_SUBTYPE_POWERPC_620
#undef CPU_SUBTYPE_POWERPC_750
#undef CPU_SUBTYPE_POWERPC_7400
#undef CPU_SUBTYPE_POWERPC_7450
#undef CPU_SUBTYPE_POWERPC_970
#undef CPU_SUBTYPE_MC98601
#undef CPU_SUBTYPE_ARM_V8M_MAIN
#undef CPU_SUBTYPE_ARM_V8M_BASE
#undef CPU_SUBTYPE_ARM_V8_1M_MAIN

#include <llvm/BinaryFormat/MachO.h>
#include <llvm/MC/TargetRegistry.h>
#include <llvm/MC/MCAsmBackend.h>
#include <llvm/MC/MCAsmInfo.h>
#include <llvm/MC/MCCodeEmitter.h>
#include <llvm/MC/MCContext.h>
#include <llvm/MC/MCInstrInfo.h>
#include <llvm/MC/MCObjectFileInfo.h>
#include <llvm/MC/MCObjectWriter.h>
#include <llvm/MC/MCRegisterInfo.h>
#include <llvm/MC/MCStreamer.h>
#include <llvm/MC/MCSubtargetInfo.h>
#include <llvm/MC/MCTargetOptions.h>
#include <llvm/Support/TargetSelect.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/TargetParser/Triple.h>

using namespace llvm;

struct MCPipeline {
  MCTargetOptions MCOptions;
  std::unique_ptr<MCRegisterInfo> MRI;
  std::unique_ptr<MCAsmInfo> MAI;
  std::unique_ptr<MCSubtargetInfo> STI;
  std::unique_ptr<MCInstrInfo> MCII;
  std::unique_ptr<MCObjectFileInfo> MOFI;
  std::unique_ptr<MCContext> Ctx;
  std::unique_ptr<MCStreamer> Streamer;
};

CFDataRef CCMachOObjectFileEmitWithText(const UInt8 *bytes,
                                        CFIndex length)
{
    std::string Err;
    Triple TT(Triple::normalize("arm64-apple-darwin")); /* basically, arm64 */
    const Target *T = TargetRegistry::lookupTarget(TT.str(), Err);
    if(!T)
    {
        return nullptr;
    }
    
    SmallVector<char, 0> Buffer;
    raw_svector_ostream  Out(Buffer);
    
    /* now we gotta make some cake with cook */
    auto P = std::make_unique<MCPipeline>();
    P->MRI.reset(T->createMCRegInfo(TT.str()));
    if(!P->MRI)
    {
        return nullptr;
    }
    P->MAI.reset(T->createMCAsmInfo(*P->MRI, TT.str(), P->MCOptions));
    if(!P->MAI)
    {
        return nullptr;
    }
    P->STI.reset(T->createMCSubtargetInfo(TT.str(), /*CPU=*/"", /*Features=*/""));
    if(!P->STI)
    {
        return nullptr;
    }
    
    /* turn the oven on tim! */
    P->MCII.reset(T->createMCInstrInfo());
    P->Ctx = std::make_unique<MCContext>(TT, P->MAI.get(), P->MRI.get(), P->STI.get(), nullptr, &P->MCOptions);
    P->MOFI.reset(T->createMCObjectFileInfo(*P->Ctx, /*PIC=*/false));
    P->Ctx->setObjectFileInfo(P->MOFI.get());
    
    /* putting the muffins in */
    MCCodeEmitter *CE = T->createMCCodeEmitter(*P->MCII, *P->Ctx);
    MCAsmBackend *MAB = T->createMCAsmBackend(*P->STI, *P->MRI, P->MCOptions);
    std::unique_ptr<MCObjectWriter> OW = MAB->createObjectWriter(Out);
    
    /* those will be nice muffins, I smell it, can you also smell it? */
    P->Streamer.reset(T->createMCObjectStreamer(TT, *P->Ctx, std::unique_ptr<MCAsmBackend>(MAB), std::move(OW), std::unique_ptr<MCCodeEmitter>(CE), *P->STI));
    if(!P->Streamer)
    {
        return nullptr;
    }
    
    /* now we gotta pull out ^^ (not sexual) */
    MCStreamer &S = *P->Streamer;
    S.initSections(/*NoExecStack=*/false, *P->STI);
    S.switchSection(P->Ctx->getObjectFileInfo()->getTextSection());
    S.emitBytes(StringRef(reinterpret_cast<const char *>(bytes), static_cast<size_t>(length)));
    S.finish();
    
    /* now some Apple frosting onto them =3 */
    return CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(Buffer.data()), static_cast<CFIndex>(Buffer.size()));
}
