//
//  [Vendored] CurrentRoot.h
//  WanWo / Platform
//
//  出处：逐字 vendored 自 ish-arm64 原版 app/CurrentRoot.h
//  （repos/ish-arm64-master/app/CurrentRoot.h，与 Vendor/ish/app/CurrentRoot.h
//  字节一致；09 决策 #6 复用范围）。仅添加本出处注释，其余原样。
//
//  职责（ERR-019）：声明 rootfs overlay 补丁链入口 FsApplyOverlay()——
//  boot 时按 RootfsPatch.bundle/manifest.plist 将 files/lib/*.js 补丁
//  写入 guest rootfs /lib/，以 /ish/overlay-version 做版本管理、跳过已安装。
//

//
//  CurrentRoot.h
//  iSH
//
//  Created by Theodore Dubois on 11/4/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern int fs_ish_version;
extern int fs_ish_apk_version;

void FsInitialize(void);
bool FsIsManaged(void);
bool FsNeedsRepositoryUpdate(void);
void FsUpdateOnlyRepositoriesFile(void);
void FsUpdateRepositories(void);

/// An integer representing the current major version of the apk repositories. An upgrade will be run if the number in /ish/apk-version is smaller. After a successful upgrade, the newer number is copied into /ish/apk-version.
/// To upgrade:
/// - update the default rootfs to the same version
/// - update gen_apk_repositories.py to generate the new version of /etc/apk/repositories
/// - set both of the following constants appropriately, making sure to use a larger number than the previous one
#define CURRENT_APK_VERSION 31900
#define CURRENT_APK_VERSION_STRING "Alpine v3.19"

/// Apply rootfs patches from RootfsPatch.bundle on boot.
/// The bundle contains a manifest.plist with a version number and file list.
/// Files are written to guest fs when the bundle version exceeds /ish/overlay-version.
void FsApplyOverlay(void);

extern NSString *const FsUpdatedNotification;

NS_ASSUME_NONNULL_END
