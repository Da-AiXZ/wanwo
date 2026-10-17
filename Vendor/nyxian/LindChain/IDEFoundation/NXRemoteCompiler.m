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

/* 万我 N4 适配（diff 登记：docs/gpl-compliance.md §N4N5）——本文件为
 * 【万我空壳实现】替换官方实现。原实现是 compilerd 守护进程的远程编译
 * 客户端（PELaunchServiceManager/PEProcessObserver/Nyxian-Swift，均属
 * 未落位层）。
 *
 * 万我拍板（2026-10-16 ⑤）：compilerd 默认关——进程内编译为唯一路径。
 * NXBuilder 的 remoteCompiler 分支在 isAvailable=NO 时自动回退本地
 * MDKDependencyScanner（NXBuilder.swift init 逻辑原样保留该回退）。
 * 本空壳语义：远程编译永不可用；类与接口完整保留以维持 NXBuilder.swift
 * 的类型引用与链接（官方 .h 原样未动）。
 */

#import <LindChain/IDEFoundation/NXRemoteCompiler.h>

@implementation NXRemoteDependencyScanner

+ (instancetype)dependencyScannerWithRemoteCompiler:(NXRemoteCompiler*)compiler
{
    return nil; /* 万我：远程路径永不可用 */
}

- (NSArray<MDKFile*>*)headerFilesForFile:(MDKFile*)file
{
    return @[];
}

- (BOOL)dependenciesForFile:(MDKFile*)file withHeaderFilePaths:(NSArray<MDKFile*>**)headerFilePaths withDependencies:(NSArray<MDKDependency*>**)dependencies
{
    return NO;
}

@end

@implementation NXRemoteCompiler

+ (BOOL)isAvailable
{
    /* 万我：compilerd 守护进程未启用（拍板 ⑤）——进程内编译是唯一路径 */
    return NO;
}

+ (instancetype)newRemoteCompiler
{
    return nil; /* isAvailable=NO 的语义化结果 */
}

- (BOOL)executeJob:(MDKJob*)job withDiagnostics:(NSArray<MDKDiagnostic*>**)diagnostics withMainSource:(NSString**)mainSource
{
    return NO;
}

- (BOOL)setupDependencyScannerWithArguments:(NSArray<NSString*>*)arguments
{
    return NO;
}

- (NSArray<MDKFile*>*)headersForFile:(MDKFile*)file
{
    return @[];
}

- (BOOL)dependenciesForFile:(MDKFile*)file withHeaderFilePaths:(NSArray<MDKFile*>**)headerFilePaths withDependencies:(NSArray<MDKDependency*>**)dependencies
{
    return NO;
}

- (MDKDependencyScanner*)dependencyScanner
{
    return nil;
}

@end
