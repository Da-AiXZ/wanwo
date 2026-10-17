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

/* 万我 N4 适配（diff 登记：docs/gpl-compliance.md §N4N5）——本文件实现
 * entitlement.h 声明的 kNXT2* entitlement 键名常量（NXProject.m 生成工程
 * Entitlements.plist 消费）。原实现于官方 trust 层 entitlement.c（N7 落位
 * 时其 sanitize 等函数自官方原样回归，本文件届时与官方实现合并去重）。
 *
 * 值差异（品牌映射，对齐 N0 替换规则 org.emexlabs.nyxian.*→com.wanwo.build.*）：
 * 官方值 "org.emexlabs.nyxian.X" → 万我值 "com.wanwo.build.X"。
 * 运行侧（N7 trust 链/ksurface）消费同一套键——届时同取本文件，保证一致。
 */

#import <LindChain/Utils/entitlement.h>

/* foundational */
NXT2Entitlement const kNXT2EntitlementPlatform = CFSTR("com.wanwo.build.platform");
NXT2Entitlement const kNXT2EntitlementPlatformRoot = CFSTR("com.wanwo.build.platform-root");
NXT2Entitlement const kNXT2EntitlementPlatformUser = CFSTR("com.wanwo.build.platform.user");
NXT2Entitlement const kNXT2EntitlementPlatformGroup = CFSTR("com.wanwo.build.platform.group");
NXT2Entitlement const kNXT2EntitlementGetTaskAllow = CFSTR("com.wanwo.build.get-task-allow");
NXT2Entitlement const kNXT2EntitlementTaskForPid = CFSTR("com.wanwo.build.task-for-pid");
NXT2Entitlement const kNXT2EntitlementSUGID = CFSTR("com.wanwo.build.sugid");
NXT2Entitlement const kNXT2EntitlementSystemTaskPorts = CFSTR("com.wanwo.build.system-task-ports");

/* process */
NXT2Entitlement const kNXT2EntitlementProcessEnumeration = CFSTR("com.wanwo.build.process.enumeration");
NXT2Entitlement const kNXT2EntitlementProcessKill = CFSTR("com.wanwo.build.process.kill");
NXT2Entitlement const kNXT2EntitlementProcessSpawn = CFSTR("com.wanwo.build.process.spawn");
NXT2Entitlement const kNXT2EntitlementProcessSpawnSignedOnly = CFSTR("com.wanwo.build.process.spawn.signed-only");
NXT2Entitlement const kNXT2EntitlementProcessSpawnInheriteEntitlements = CFSTR("com.wanwo.build.process.spawn.inherite-entitlements");

/* management */
NXT2Entitlement const kNXT2EntitlementManagementHost = CFSTR("com.wanwo.build.management.host");
NXT2Entitlement const kNXT2EntitlementManagementProcEnvironment = CFSTR("com.wanwo.build.management.proc-environment");

/* launch services */
NXT2Entitlement const kNXT2EntitlementLaunchServicesStart = CFSTR("com.wanwo.build.launch-services.start");
NXT2Entitlement const kNXT2EntitlementLaunchServicesStop = CFSTR("com.wanwo.build.launch-services.stop");
NXT2Entitlement const kNXT2EntitlementLaunchServicesToggle = CFSTR("com.wanwo.build.launch-services.toggle");
NXT2Entitlement const kNXT2EntitlementLaunchServicesGetEndpoint = CFSTR("com.wanwo.build.launch-services.get-endpoint");
NXT2Entitlement const kNXT2EntitlementLaunchServicesSetEndpoint = CFSTR("com.wanwo.build.launch-services.set-endpoint");
NXT2Entitlement const kNXT2EntitlementLaunchServicesGetEndpointAllowList = CFSTR("com.wanwo.build.launch-services.get-endpoint.allow-list");
NXT2Entitlement const kNXT2EntitlementLaunchServicesSetEndpointAllowList = CFSTR("com.wanwo.build.launch-services.set-endpoint.allow-list");

/* sandbox */
NXT2Entitlement const kNXT2EntitlementSandboxFileRead = CFSTR("com.wanwo.build.sandbox.file.read");
NXT2Entitlement const kNXT2EntitlementSandboxFileReadWrite = CFSTR("com.wanwo.build.sandbox.file.read-write");
NXT2Entitlement const kNXT2EntitlementSandboxNoContainer = CFSTR("com.wanwo.build.sandbox.no-container");
NXT2Entitlement const kNXT2EntitlementSandboxHost = CFSTR("com.wanwo.build.sandbox.host");

/* ksurface */
NXT2Entitlement const kNXT2EntitlementKsurfaceKEXTLoading = CFSTR("com.wanwo.build.ksurface.kernelextension.loading");
