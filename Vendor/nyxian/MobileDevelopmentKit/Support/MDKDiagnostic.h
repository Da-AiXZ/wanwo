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

#ifndef MOBILEDEVELOPMENTKIT_MDKDIAGNOSTIC_H
#define MOBILEDEVELOPMENTKIT_MDKDIAGNOSTIC_H

#import <Foundation/Foundation.h>
#import <MobileDevelopmentKit/MDKCFType.h>
#import <MobileDevelopmentKit/MDKFileSourceLocation.h>

typedef NS_ENUM(UInt8, MDKDiagnosticType) {
    MDKDiagnosticTypeFile = 0,
    MDKDiagnosticTypeTargetFile,
    MDKDiagnosticTypeInternal,
    MDKDiagnosticTypeUnknown,
};

typedef NS_ENUM(UInt8, MDKDiagnosticLevel) {
    MDKDiagnosticLevelNote = 0,
    MDKDiagnosticLevelRemark,
    MDKDiagnosticLevelWarning,
    MDKDiagnosticLevelError,
    MDKDiagnosticLevelFatal,
    MDKDiagnosticLevelUnknown,
};

@interface MDKDiagnostic : MDKCFType <NSSecureCoding>

@property (nonatomic, readonly) MDKDiagnosticType type;
@property (nonatomic, readonly) MDKDiagnosticLevel level;
@property (nonatomic, readonly) NSString *mainSource;
@property (nonatomic, readonly) MDKFileSourceLocation *fileSourceLocation;
@property (nonatomic, readonly) NSString *message;

+ (instancetype)diagnosticWithType:(MDKDiagnosticType)type level:(MDKDiagnosticLevel)level mainSource:(NSString*)mainSource fileSourceLocation:(MDKFileSourceLocation *)fileSourceLocation message:(NSString*)message;

@end

#endif /* MOBILEDEVELOPMENTKIT_MDKDIAGNOSTIC_H */
