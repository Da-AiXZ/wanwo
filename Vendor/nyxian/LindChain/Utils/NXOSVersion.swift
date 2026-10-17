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

/* 万我 N4 适配（diff 登记：docs/gpl-compliance.md §N4N5）——本文件自官方
 * UI 层 Nyxian/UI/FileList/iOSVersionPickerView.swift **字节级提取**
 * （fileprivate _NXSDK/NXSDK 变量 + @objc NXOSVersion 类，官方 L24-77）。
 * 提取依据：NXOSVersion 是纯数据类（MDKSDK/MDKOSVersion/NXBootstrap 依赖
 * 全部已落位，零 UI 符号），但被 N4/N5 核心件消费——NXProject.m:237-238
 * （ObjC）与 NXBuilder.swift:105-106（headsup 版本门）——放在 UI 层使 N4/N5
 * 无法编译。原文件残留的 IOSVersionPickerViewController（UI）不提取。
 */

import UIKit
import MobileDevelopmentKit

fileprivate var _NXSDK: MDKSDK? = nil
fileprivate var NXSDK: MDKSDK? {
    get {
        if(_NXSDK == nil) {
            _NXSDK = MDKSDK(forDirectoryURL: NXBootstrap.shared().sdkURL)
        }
        return _NXSDK
    }
}

fileprivate var _NXOSVersionSupportedBuildVersions: [String] = []
@objc class NXOSVersion: NSObject {
    @objc static var NXOSVersionSupportedBuildVersionsRaw: [MDKOSVersion] {
        get {
            if let sdk = NXSDK,
               let supportedVersion = sdk.supportedVersions {
                return supportedVersion
            }
            if let fallbackMin = MDKOSVersion(versionString: "15.0"),
               let fallbackMax = MDKOSVersion(versionString: "27.0"){
                return [fallbackMin, fallbackMax]
            }
            return []
        }
    }
    @objc static var NXOSVersionSupportedBuildVersions: [String] {
        get {
            if !_NXOSVersionSupportedBuildVersions.isEmpty {
                return _NXOSVersionSupportedBuildVersions
            }

            if let sdk = NXSDK,
               let supportedVersions = sdk.supportedVersions {
                for version in supportedVersions {
                    _NXOSVersionSupportedBuildVersions.append(version.versionString)
                }
                return _NXOSVersionSupportedBuildVersions
            }

            return ["15.0", "27.0"]
        }
    }
}
