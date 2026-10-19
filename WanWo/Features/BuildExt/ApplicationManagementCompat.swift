//
//  ApplicationManagementCompat.swift
//  WanWo
//
//  【N8 · 万我侧兼容壳】ApplicationManagementViewController（XCButtonCompat
//  先例同构）。vendored 宿主代理面 LDEApplicationWorkspace.m（0.10.3
//  LiveProcess 组追加给 emexDE 的 3 件之一，主 App 编入）作为
//  LDEApplicationWorkspaceProtocol observer 被 installd daemon 回调：
//    :364 applicationWasInstalled:      :371 applicationWithBundleIdentifierWasUninstalled:
//  官方实现=UI 层 ApplicationManagement.swift 的应用管理界面刷新——万我 UI 层
//  未落位（N9/N10），本壳提供同签名 no-op 承接（协议回调不可缺——缺失时 daemon
//  侧 ObjC 消息派发异常）。类名必须与官方一致（vendored 文件直引该名，经
//  WanWo-Swift.h 暴露）。登记 docs/gpl-compliance.md §N8。
//

import Foundation

@objc(ApplicationManagementViewController)
final class ApplicationManagementViewController: NSObject {

    /// vendored LDEApplicationWorkspace.m 调 [[ApplicationManagementViewController shared] ...]
    /// （计算属性形态——static stored property 的 @objc 暴露在 swiftc 5.9 下形态不稳）
    private static let instance = ApplicationManagementViewController()
    @objc static var shared: ApplicationManagementViewController {
        return instance
    }

    /// observer 回调 no-op。官方语义（0.10.3 ApplicationManagement.swift）＝
    /// installd daemon 安装/卸载完成后经此回调刷新应用管理 UI 列表；万我当前
    /// no-op 的理由：应用管理 UI 面未落位（无消费方），N9（guest 承载面）接棒
    /// 时复议是否挂接万我侧呈现。app 参数用 Any?（万我壳不消费对象；消除对
    /// vendored LDEApplicationObject 的 Swift 导入面依赖——selector 不变，
    /// daemon 侧 ObjC 派发只匹配 selector）。
    @objc func applicationWasInstalled(_ app: Any?) {
        // no-op（万我壳）
    }

    /// observer 回调 no-op（同上，卸载通知；N9 复议）
    @objc func applicationWithBundleIdentifierWasUninstalled(_ bundleIdentifier: String?) {
        // no-op（万我壳）
    }
}
