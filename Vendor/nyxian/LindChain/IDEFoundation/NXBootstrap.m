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

#import <LindChain/IDEFoundation/NXBootstrap.h>
#import <LindChain/IDEFoundation/NXAlertDiagnosticPresenter.h>
#import <LindChain/Utils/Zip.h>
#import <LindChain/Utils/relax.h>
#import <MobileDevelopmentKit/MDKThreadPool.h>
#import "XCButtonCompat.h"

/* 万我 N3b 16 化适配（diff 登记：docs/gpl-compliance.md §N3b）：
 * 1) 分发方式改内嵌（用户拍板 2026-10-16 ③）——SDK 与 Shared 三 zip 随
 *    app bundle 分发，首启解压零网络；fdownload/Downloader 层依赖随之移除。
 * 2) v28 段（RootCAs/rootca/keychain）属阶段 2（N7）运行链 trust 资产，
 *    以 WANWO_BOOTSTRAP_TRUST 宏守卫（默认关）；Nyxian-Swift.h
 *    (NXApplicationState) 与 keychain.h 依赖随之移除。
 * 3) relax.h 官方字节级复制至 LindChain/Utils/（原在 ProcEnvironment，
 *    该层未落位；文件内容零改动）。
 * 4) XCButton → XCButtonCompat（万我侧同接口实现，NSNotificationCenter 汇报）。 */

extern BOOL PEURLIsContainedIn(NSURL *candidate, NSURL *root);

@interface NXBootstrap ()

@property (readwrite) UInt64 version;

@end

@implementation NXBootstrap {
    NSURL *_rootURL;
    dispatch_once_t _gatherRootURLOnce;
}

- (instancetype)init
{
    self = [super init];
    return self;
}

+ (instancetype)shared
{
    static NXBootstrap *bootstrapSingleton = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bootstrapSingleton = [[NXBootstrap alloc] init];
    });
    return bootstrapSingleton;
}

- (NSURL*)rootURL
{
    dispatch_once(&_gatherRootURLOnce, ^{
        /* 万我 N3b：工具链根收进 wanwo-build/ 子目录（13 号设计文档 §三
         * 拍板）——万我 Documents 根有自有数据，不与官方 Documents 根平铺
         * 形态混用；目录语义（SDK/Include/Projects/Cache/...）不变。 */
        _rootURL = [NSURL fileURLWithPath:[[@"/private" stringByAppendingPathComponent:NSHomeDirectory()] stringByAppendingPathComponent:@"Documents/wanwo-build"]];
    });
    return _rootURL;
}

- (NSURL*)sdkURL
{
    /* 万我 N3b：SDK 实体 27.0 → 26.5（13 号设计文档混合基线拍板——26.5 =
     * 官方 CI 同款 SDK（Xcode 26.6 编译 iphoneos26.5，B 日志实证）+
     * 0.10.3 真机实证 URL 同版本；工具链 clang 21 向后吃 26.5 无障碍）。 */
    return [self.rootURL URLByAppendingPathComponent:@"SDK/iPhoneOS26.5.sdk"];
}

- (NSURL*)includeURL
{
    return [self.rootURL URLByAppendingPathComponent:@"Include"];
}

- (NSURL*)projectsURL
{
    return [self.rootURL URLByAppendingPathComponent:@"Projects"];
}

- (NSURL*)cacheURL
{
    return [self.rootURL URLByAppendingPathComponent:@"Cache"];
}

- (NSURL*)bootstrapPlistURL
{
    return [self.rootURL URLByAppendingPathComponent:@"bootstrap.plist"];
}

- (NSURL*)swiftURL
{
    return [self.rootURL URLByAppendingPathComponent:@"swift"];
}

- (NSURL*)swiftModuleCacheURL
{
    return [self.rootURL URLByAppendingPathComponent:@"ModuleCache"];
}

- (NSURL*)rootfsURL
{
    return [self.rootURL URLByAppendingPathComponent:@"rootfs"];
}

- (UInt64)version
{
    NSDictionary *bootstrapPlist = [NSDictionary dictionaryWithContentsOfURL:self.bootstrapPlistURL];
    if(bootstrapPlist == nil)
    {
        /* plist doesn't exist or is malformed? */
        return 0;
    }
    
    NSNumber *versionNumber = bootstrapPlist[@"BootstrapVersion"];
    if(![versionNumber isKindOfClass:NSNumber.class])
    {
        /* illegal object */
        return 0;
    }
    
    return [versionNumber unsignedLongValue];
}

- (void)setVersion:(UInt64)version
{
    [XCButton updateProgressWithValue:NXBOOTSTRAP_CSTEP * version];
    [@{ @"BootstrapVersion":[NSNumber numberWithUnsignedLong:version] } writeToURL:self.bootstrapPlistURL error:nil];
}

- (BOOL)isInstalled
{
    return self.version > 0;
}

- (void)bootstrap
{
    NSLog(@"checking upon nyxian bootstrap :3");
    
    MDKPthreadDispatch(^{
        NSError *error = nil;
        
        goto skip_error_report;
        
    report_error:
        {
            NSLog(@"bootstrapping sadly failed :c");
            
            [NXAlertDiagnosticPresenter notifyUserWithLevel:NXAlertDiagnosticPresenterLevelError withMessage:[NSString stringWithFormat:@"Bootstrapping failed: %@", error.localizedDescription] withDelay:1.0];
            self.version = 0;
            [self clearURL:self.rootURL];
            return;
        }
        
    skip_error_report:
        
        /*
         * checking weither we have to create the
         * bootstraps root path.
         */
        if(![[NSFileManager defaultManager] fileExistsAtPath:self.rootURL.path])
        {
            [[NSFileManager defaultManager] createDirectoryAtURL:self.rootURL withIntermediateDirectories:YES attributes:nil error:&error];
            if(error != nil)
            {
                abort();
            }
        }
        
        NSLog(@"install status: %d", self.isInstalled);
        NSLog(@"version: %llu", self.version);
        
        if(!self.isInstalled || self.version != NXBOOTSTRAP_NEWEST_VERSION)
        {
            /*
             * need to clear the entire path if its not installed
             * otherwise garbage might be in the container.
             * we also have to clear it in case a newer version
             * of the bootstrap is installed.
             */
            if(!self.isInstalled || self.version > NXBOOTSTRAP_NEWEST_VERSION)
            {
                NSLog(@"bootstrap might be too new or not installed, clearing");
                [self clearURL:self.rootURL];
            }
            
            /*
             * now installing or upgrading the bootstrap, this is the part
             * that has to work although nobody is going to use Nyxian today
             * lol.
             */
            if(self.version < 9)
            {
                /*
                 * creating bootstrap base structure
                 * all base folders n such, you name it.
                 */
                NSLog(@"bootstrapping directory structure");
                
                [[NSFileManager defaultManager] createDirectoryAtURL:self.projectsURL withIntermediateDirectories:NO attributes:nil error:&error];
                
                if(![[NSFileManager defaultManager] createDirectoryAtURL:self.cacheURL withIntermediateDirectories:NO attributes:nil error:&error])
                {
                    goto report_error;
                }
                
                self.version = 9;
            }
            
            if(self.version < 10)
            {
                /*
                 * this step is for the rt static library
                 * which is needed for availability checks
                 * using @available in objc for example.
                 */
                NSLog(@"bootstrapping libraries");
                [[NSFileManager defaultManager] removeItemAtURL:[self.rootURL URLByAppendingPathComponent:@"lib"] error:nil];
                
                /* 万我 N3b：资源平铺形态（D2 先例 folder 展开冲突——四 zip
                 * 单文件资源落 app 根，无 Shared/ 中间层）。 */
                if(!unzipArchiveAtPath([NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"lib.zip"].path, self.rootURL.path))
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"extracting \"lib.zip\" failed" }];
                    goto report_error;
                }
                
                self.version = 10;
            }
            
            if(self.version < 15)
            {
                /*
                 * there was a DOS vulnerability in a prior
                 * version of Nyxian where a zip could of caused
                 * DOS in project import functionality. so we
                 * have to fixup paths in case they were affected.
                 * as patching the DOS entry it self does not
                 * prevent it to still cause DOS as damage
                 * might already happened.
                 */
                NSURL *tmpUrl = [NSURL fileURLWithPath:NSTemporaryDirectory()];
                NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:tmpUrl includingPropertiesForKeys:nil options:0 errorHandler:nil];
                if(enumerator == nil)
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"failed to create enumerator" }];
                    goto report_error;
                }
                
                if(![[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: @(0755) } ofItemAtPath:tmpUrl.path error:&error])
                {
                    goto report_error;
                }
                
                for(NSURL *fileURL in enumerator)
                {
                    BOOL isDirectory = NO;
                    if(![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path isDirectory:&isDirectory])
                    {
                        continue;
                    }
                    
                    if(![[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: isDirectory ? @(0755) : @(0644)} ofItemAtPath:fileURL.path error:&error])
                    {
                        goto report_error;
                    }
                }
                
                self.version = 15;
            }
            
            if(self.version < 23)
            {
                /*
                 * this is necessary so simd and normal
                 * c code work perfectly.
                 */
                NSLog(@"bootstrapping clang include and swift resources");
                [[NSFileManager defaultManager] removeItemAtURL:self.includeURL error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:self.swiftURL error:nil];
                
                if(!unzipArchiveAtPath([NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"include.zip"].path, [self.rootURL URLByAppendingPathComponent:@"Include"].path))
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"extracting \"include.zip\" failed" }];
                    goto report_error;
                }
                
                /*
                 * this is necessary so swift works
                 */
                if(!unzipArchiveAtPath([NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"swift.zip"].path, self.rootURL.path))
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"extracting \"swift.zip\" failed" }];
                    goto report_error;
                }
                
                self.version = 23;
            }
            
            /* 万我 N3b：v28（RootCAs/rootca 下载/ksurface_keychain_update）
             * 属阶段 2（N7）运行链 trust 资产——随 ProcEnvironment trust 层
             * 落位时回归。版本号 28 不落盘，v29 条件 version<29 照常成立。 */
#if defined(WANWO_BOOTSTRAP_TRUST) && WANWO_BOOTSTRAP_TRUST
            if(self.version < 28)
            {
                NSLog(@"bootstrapping rootca folder");

                [[NSFileManager defaultManager] createDirectoryAtURL:[self.rootURL URLByAppendingPathComponent:@"RootCAs"] withIntermediateDirectories:true attributes:nil error:nil];

                if(!fdownload(@"https://nyxian.app/bootstrap/com.wanwo.rootca.v1.pub.nxt2c", @"com.wanwo.rootca.v1.pub.nxt2c"))
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"downloading \"https://nyxian.app/bootstrap/com.wanwo.rootca.v1.pub.nxt2c\" failed" }];
                    goto report_error;
                }

                if(![[NSFileManager defaultManager] moveItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"com.wanwo.rootca.v1.pub.nxt2c"] toPath:[[self.rootURL URLByAppendingPathComponent:@"RootCAs/com.wanwo.rootca.v1.pub.nxt2c"] path] error:nil])
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"failed to move emexlabs public rootca key" }];
                    goto report_error;
                }

                if(!NXApplicationState.extensionLessMode)
                {
                    ksurface_keychain_update();
                }

                self.version = 28;
            }
#endif /* WANWO_BOOTSTRAP_TRUST */

            if(self.version < 29)
            {
                /*
                 * the SDK is very important to use iOS API which
                 * is very cool.
                 */
                NSLog(@"bootstrapping SDK");
                [[NSFileManager defaultManager] removeItemAtURL:[self.rootURL URLByAppendingPathComponent:@"SDK"] error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:self.swiftModuleCacheURL error:nil];    /* clearing module cache */
                
                /* 万我 N3b：SDK 改内嵌分发（拍板 ③）——从 app bundle
                 * Shared/SDK.zip（=官方 0.10.3 实证 URL 的
                 * iPhoneOS26.5.sdk.zip 实物，33,880,102 bytes）解压，
                 * 零网络依赖。 */
                if(!unzipArchiveAtPath([NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"SDK.zip"].path, [self.rootURL URLByAppendingPathComponent:@"SDK"].path))
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"extracting \"SDK.zip\" failed" }];
                    goto report_error;
                }

                /* 万我 N3b：SDK 实体=26.5（见 sdkURL 注），旧版本名符号链接
                 * 对齐 0.10.3 实证形态（26.2/26.4.1/26.4 → 26.5；main 版列表
                 * 里的 26.5 即实体本身故移除）。 */
                NSArray<NSURL*> *symlinkSDKs = @[
                    [self.rootURL URLByAppendingPathComponent:@"/SDK/iPhoneOS26.2.sdk"],
                    [self.rootURL URLByAppendingPathComponent:@"/SDK/iPhoneOS26.4.1.sdk"],
                    [self.rootURL URLByAppendingPathComponent:@"/SDK/iPhoneOS26.4.sdk"],
                ];
                
                for(NSURL *symlink in symlinkSDKs)
                {
                    if(![[NSFileManager defaultManager] createSymbolicLinkAtPath:symlink.path withDestinationPath:self.sdkURL.lastPathComponent error:&error])
                    {
                        goto report_error;
                    }
                }
                
                self.version = 29;
            }
        }
        
        [[NSFileManager defaultManager] createDirectoryAtURL:self.swiftModuleCacheURL withIntermediateDirectories:NO attributes:nil error:nil];
        
        NSLog(@"done");
    });
}

- (NSString*)relativeToBootstrapWithAbsolutePath:(NSString*)path
{
    NSURL *absolutURL = [NSURL fileURLWithPath:path];
    if(![absolutURL.path hasPrefix:[self.rootURL.path stringByAppendingString:@"/"]] &&
       ![absolutURL.path isEqualToString:self.rootURL.path])
    {
        return nil;
    }
    return [absolutURL.path stringByReplacingOccurrencesOfString:[self.rootURL.path stringByAppendingString:@"/"] withString:@""];
}

- (void)clearURL:(NSURL*)url
{
    NSArray<NSURL*> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil options:0 error:nil];
    if(entries == nil)
    {
        return;
    }
    
    for(NSURL *entry in entries)
    {
        if(!(url == self.rootURL && ([entry.lastPathComponent isEqualToString:@"Projects"] ||
                                     [entry.lastPathComponent isEqualToString:@"rootfs"] ||
                                     [entry.lastPathComponent isEqualToString:@"mntfs"] ||
                                     [entry.lastPathComponent isEqualToString:@"kmsg.txt"] ||
                                     [entry.lastPathComponent isEqualToString:@"kmsg_old.txt"])))
        {
            [[NSFileManager defaultManager] removeItemAtURL:entry error:nil];
        }
    }
}

- (void)waitTillDone
{
    if(self.version == NXBOOTSTRAP_NEWEST_VERSION)
    {
        return;
    }
    
    [XCButton switchImageWithSystemName:@"archivebox.fill" animated:YES];
    [XCButton updateProgressWithValue:0.1];
    
    while(self.version != NXBOOTSTRAP_NEWEST_VERSION)
    {
        relax();
    }
    
    [XCButton switchImageWithSystemName:@"hammer.fill" animated:YES];
}

- (void)waitTillDoneNoButton
{
    if(self.version == NXBOOTSTRAP_NEWEST_VERSION)
    {
        return;
    }
    
    [XCButton switchImageWithSystemName:@"archivebox.fill" animated:YES];
    [XCButton updateProgressWithValue:0.1];
    
    while(self.version != NXBOOTSTRAP_NEWEST_VERSION)
    {
        relax();
    }
    
    [XCButton switchImageWithSystemName:@"hammer.fill" animated:YES];
}

- (BOOL)isNewest
{
    return self.version == NXBOOTSTRAP_NEWEST_VERSION;
}

@end
