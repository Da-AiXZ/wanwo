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

#ifndef NXPROJECT_H
#define NXPROJECT_H

#import <Foundation/Foundation.h>
#import <LindChain/IDEFoundation/NXPlist.h>
#import <LindChain/IDEFoundation/NXType.h>
/* 万我 N4 适配（diff 登记：docs/gpl-compliance.md §N4N5）：原引用
 * trust 层 entitlement.h（N7 落位）——N4 实测有真实消费（kNXT2* 键名
 * 常量，NXProject.m 生成工程 Entitlements.plist 用；首跑 grep 模式
 * PE*/entitlement_ 未覆盖 kNXT2* 前缀致误判空引用，run 39009276643
 * undeclared 实证）——头字节级复制至 Utils/、常量实现建万我版
 * （键名品牌映射 com.wanwo.build.*），import 改指 Utils。 */
#import <LindChain/Utils/entitlement.h>

@interface NXProjectConfig : NXPlist

@property (nonatomic,readonly) NXProjectFormatKind formatKind;
@property (nonatomic,readonly) NXProjectSchemeKind schemeKind;
@property (nonatomic,strong,readonly) NSString *executable;
@property (nonatomic,strong,readonly) NSString *displayName;
@property (nonatomic,strong,readonly) NSString *organizationPrefix;
@property (nonatomic,strong,readonly) NSString *bundleid;
@property (nonatomic,strong,readonly) NSDictionary *infoDictionary;
@property (nonatomic,strong,readonly) NSArray<NSString*> *compilerFlags;
@property (nonatomic,strong,readonly) NSArray<NSString*> *linkerFlags;
@property (nonatomic,strong,readonly) NSArray<NSString*> *swiftFlags;
@property (nonatomic,strong,readonly) NSString *deploymentTarget;
@property (nonatomic,strong,readonly) NSString *outputPath;
@property (nonatomic,readonly) BOOL signMachOWithNyxianEntitlements;
@property (nonatomic,readonly) BOOL linkFrameworksAutomatically;

@property (nonatomic,readonly) BOOL deploymentTargetContainsWhitespaces;

+ (NSArray<NSString*>*)sdkCompilerFlags;

@end

@interface NXEntitlementsConfig : NXPlist
@end

@interface NXProject : NSObject

@property (nonatomic,strong,readonly) NXProjectConfig *projectConfig;
@property (nonatomic,strong,readonly) NXEntitlementsConfig *entitlementsConfig;

@property (nonatomic,strong,readonly) NSURL *url;
@property (nonatomic,strong,readonly) NSURL *cacheURL;
@property (nonatomic,strong,readonly) NSURL *resourcesURL;
@property (nonatomic,strong,readonly) NSURL *payloadURL;
@property (nonatomic,strong,readonly) NSURL *bundleURL;
@property (nonatomic,strong,readonly) NSURL *machoURL;
@property (nonatomic,strong,readonly) NSURL *packageURL;

- (instancetype)initWithURL:(NSURL*)url;
+ (instancetype)projectWithURL:(NSURL*)url;

+ (instancetype)createProjectAtURL:(NSURL*)url withName:(NSString*)name withOrganizationIdentifier:(NSString*)organizationIdentifier withBundleIdentifier:(NSString*)bundleid withSchemeKind:(NXProjectSchemeKind)schemeKind withLanguageKind:(NXProjectLanguageKind)languageKind withInterfaceKind:(NXProjectInterfaceKind)interfaceKind;
+ (NSMutableDictionary<NSString*,NSMutableArray<NXProject*>*>*)listProjectsAtURL:(NSURL*)url;

- (BOOL)syncFolderStructureToCache;

- (void)removeProject;
- (BOOL)reload;

@end

#endif /* NXPROJECT_H */
