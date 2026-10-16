/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2025 - 2026 emexlab

 This file is part of Nyxian.

 Nyxian is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Nyxian is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

#ifndef NXREMOTECOMPILER_H
#define NXREMOTECOMPILER_H

#import <Foundation/Foundation.h>
#import <MobileDevelopmentKit/MobileDevelopmentKit.h>

@protocol NXCompilationServiceProtocol <NSObject>

- (void)executeJob:(MDKJob*)job withReply:(void (^)(BOOL success, NSArray<MDKDiagnostic*> *diagnostics, NSString *mainSource))reply;
- (void)setupDependencyScannerWithArguments:(NSArray<NSString*>*)arguments withReply:(void (^)(BOOL success))reply;
- (void)headersForFile:(MDKFile*)file withReply:(void (^)(NSArray<MDKFile*> *files))reply;
- (void)dependenciesForFile:(MDKFile*)file withReply:(void (^)(BOOL success, NSArray<MDKFile*> *files, NSArray<MDKDependency*> *dependencies))reply;

@end

@class NXRemoteCompiler;

@interface NXRemoteDependencyScanner : NSObject

+ (instancetype)dependencyScannerWithRemoteCompiler:(NXRemoteCompiler*)compiler;

- (NSArray<MDKFile*>*)headerFilesForFile:(MDKFile*)file;
- (BOOL)dependenciesForFile:(MDKFile*)file withHeaderFilePaths:(NSArray<MDKFile*>**)headerFilePaths withDependencies:(NSArray<MDKDependency*>**)dependencies;

@end

@interface NXRemoteCompiler : NSObject

+ (BOOL)isAvailable;
+ (instancetype)newRemoteCompiler;

- (BOOL)executeJob:(MDKJob*)job withDiagnostics:(NSArray<MDKDiagnostic*>**)diagnostics withMainSource:(NSString**)mainSource;
- (BOOL)setupDependencyScannerWithArguments:(NSArray<NSString*>*)arguments;
- (NSArray<MDKFile*>*)headersForFile:(MDKFile*)file;
- (BOOL)dependenciesForFile:(MDKFile*)file withHeaderFilePaths:(NSArray<MDKFile*>**)headerFilePaths withDependencies:(NSArray<MDKDependency*>**)dependencies;
- (MDKDependencyScanner*)dependencyScanner;

@end

#endif /* NXREMOTECOMPILER_H */
