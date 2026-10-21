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

/*
 * 【WanWo N10a 落位，登记 docs/gpl-compliance.md §N10】官方 0.10.3
 * Nyxian/UI/UIInit/Terminal.swift（147 行 wrapper）落位万我 GuestWindow 面
 * （万我树内副本，非 vendored 路径——vendored 树零 diff）。官方原样语义 +
 * 三处最小适配（万我无官方 UI 层主题系统，逐行登记）：
 *   适配 1：currentTheme（官方 UIInit.swift:24 全局 `var currentTheme:
 *     LDETheme?`，LDETheme 属官方 UI 层——万我未落位）引用整段移除，取其
 *     `??` 系统回退值（官方回退语义逐行保留：.secondarySystemBackground /
 *     gibDynamicColor(light: .label, dark:)）；
 *   适配 2：gibDynamicColor（官方 CodeEditor+Theme.swift:84-98）语义等义
 *     内联为本文件私有副本（dynamicProvider 明暗双轨逐行同源）；
 *   适配 3：handleThemeChange（官方主题切换通知 uiColorChangeNotif——万我
 *     无主题系统、通知不发生）保留原结构，内容改为系统回退重涂。
 * 其余逐行与官方 0.10.3 一致（TerminalViewObjC / TerminalViewDelegateObjC /
 * ObjCDelegateAdapter——vendored NXWindowSessionTerminal.m 经 WanWo-Swift.h
 * 消费，N8 import 适配行已就位零新增）。
 * 依赖：SwiftTerm 1.13.0（SPM，project.yml packages 段——拍板项 1，官方
 * 0.10.3 Package.resolved 同版本同源 github.com/migueldeicaza/SwiftTerm）。
 */

import SwiftTerm
import UIKit

@objc protocol TerminalViewDelegateObjC: AnyObject {
    @objc optional func sizeChanged(source: TerminalView, newCols: Int, newRows: Int)
    @objc optional func setTerminalTitle(source: TerminalView, title: String)
    @objc optional func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)
    @objc optional func send(source: TerminalView, data: Data)
    @objc optional func scrolled(source: TerminalView, position: Double)
    @objc optional func requestOpenLink(source: TerminalView, link: String, params: [String: String])
    @objc optional func bell(source: TerminalView)
    @objc optional func clipboardCopy(source: TerminalView, content: Data)
    @objc optional func iTermContent(source: TerminalView, content: Data)
    @objc optional func rangeChanged(source: TerminalView, startY: Int, endY: Int)
}

@objc class TerminalViewObjC: TerminalView {
    @objc var ttyHandle: FileHandle?

    // MARK: 【N10e 修 I】utility 输出 tee（万我自有新增——官方原样零语义改动）

    /// 待认领 tee 槽：GuestWindowBridge.openUtilityTerminal 开窗前置入，
    /// 本类 init 时认领取走（一窗一 tee，多窗互不串流；nil=无落盘）。
    private static var _pendingTee: UtilityTeeLog?
    @objc public class var pendingTee: UtilityTeeLog? {
        get { return _pendingTee }
        set { _pendingTee = newValue }
    }

    /// 本实例认领的 tee（init 时从 pendingTee 取走；只读——readabilityHandler
    /// 后台线程消费安全）。
    private let tee: UtilityTeeLog?

    private var _objcDelegateAdapter: ObjCDelegateAdapter?
    @objc public weak var objcDelegate: (any TerminalViewDelegateObjC)? {
        didSet {
            if let d = objcDelegate {
                _objcDelegateAdapter = ObjCDelegateAdapter(d)
                self.terminalDelegate = _objcDelegateAdapter
            } else {
                self.delegate = nil
            }
        }
    }

    private class ObjCDelegateAdapter: TerminalViewDelegate {
        weak var objcDelegate: TerminalViewDelegateObjC?

        init(_ delegate: TerminalViewDelegateObjC) {
            self.objcDelegate = delegate
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            objcDelegate?.sizeChanged?(source: source, newCols: newCols, newRows: newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            objcDelegate?.setTerminalTitle?(source: source, title: title)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            objcDelegate?.hostCurrentDirectoryUpdate?(source: source, directory: directory)
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            objcDelegate?.send?(source: source, data: Data(data))
        }
        func scrolled(source: TerminalView, position: Double) {
            objcDelegate?.scrolled?(source: source, position: position)
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            objcDelegate?.requestOpenLink?(source: source, link: link, params: params)
        }
        func bell(source: TerminalView) {
            objcDelegate?.bell?(source: source)
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            objcDelegate?.clipboardCopy?(source: source, content: content)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
            objcDelegate?.iTermContent?(source: source, content: Data(content))
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            objcDelegate?.rangeChanged?(source: source, startY: startY, endY: endY)
        }
    }

    // 适配 1：官方行 `self.backgroundColor = currentTheme?.backgroundColor ?? .secondarySystemBackground`
    // 的系统回退值直取（LDETheme 未落位——见文件头适配登记）。
    @objc public init (
        frame: CGRect,
        masterFD: Int32
    ){
        self.ttyHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)

        super.init(frame: frame)

        // 修 I：认领 pendingTee（先于 readabilityHandler 安装——tee 只读后
        // 消费，无并发面）。
        let claimed = TerminalViewObjC.pendingTee
        TerminalViewObjC.pendingTee = nil
        self.tee = claimed

        self.isOpaque = false;
        self.backgroundColor = .secondarySystemBackground
        self.nativeForegroundColor = gibDynamicColor(light: .label, dark: self.nativeForegroundColor)
        self.caretTextColor = gibDynamicColor(light: .label, dark: self.nativeForegroundColor)
        self.font = UIFont.monospacedSystemFont(ofSize: (UIDevice.current.userInterfaceIdiom == .pad) ? 14 : 10, weight: .regular)

        self.ttyHandle?.readabilityHandler = { [weak self] fileHandle in
            guard let self = self else { return }
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }

            // 修 I：masterFD 输出分流 tee（串行队列落盘——feed 渲染链不动）。
            self.tee?.appendRaw(data)

            DispatchQueue.main.async {
                self.feed(byteArray: ArraySlice<UInt8>(data))
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if(newWindow == nil) {
            NotificationCenter.default.removeObserver(self)
        } else {
            NotificationCenter.default.addObserver(self, selector: #selector(handleThemeChange(_:)), name: Notification.Name("uiColorChangeNotif"), object: nil)
        }
        handleThemeChange(nil)
    }

    // 适配 3：官方主题通知不发生（万我无主题系统）——保留原结构，内容为
    // 系统回退重涂（与 init 同一适配语义）。
    @objc func handleThemeChange(_ notification: Notification?) {
        self.backgroundColor = .secondarySystemBackground
        self.nativeForegroundColor = gibDynamicColor(light: .label, dark: self.nativeForegroundColor)
        self.caretTextColor = gibDynamicColor(light: .label, dark: self.nativeForegroundColor)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }

        if self.isFirstResponder {
            _ = self.resignFirstResponder()
            _ = self.becomeFirstResponder()
        }
    }
}

// 适配 2：gibDynamicColor 私有副本（官方 CodeEditor+Theme.swift:84-98 语义
// 等义——dynamicProvider 明暗双轨逐行同源；万我侧无官方 UI 层可引）。
private func gibDynamicColor(light: UIColor, dark: UIColor) -> UIColor {
    return UIColor(dynamicProvider: { traits in
        switch traits.userInterfaceStyle {
        case .light, .unspecified:
            return light

        case .dark:
            return dark

        @unknown default:
            assertionFailure("Unknown userInterfaceStyle: \(traits.userInterfaceStyle)")
            return light
        }
    })
}

// MARK: - 【N10e 修 I】utility 终端输出 tee（万我自有——登记 docs/gpl-compliance.md §N10e）
//
// 钩子考古结论（修 I 实现依据）：TerminalViewObjC 的 ttyHandle（=masterFD）
// readabilityHandler 是 SwiftTerm 输出数据的唯一入口（每个输出分块先经
// availableData 读出再 DispatchQueue.main feed 进终端模拟器）——在此分流
// tee 即可拿到全部 raw 输出，无需 SwiftTerm 内部钩子（降级条件不成立）。
//
// UtilityTeeLog：串行队列收敛全部写入（readabilityHandler 在后台线程触发，
// FileHandle 非线程安全；footer 与 append 同队列 FIFO 有序）。本类与
// pendingTee 认领机制均为万我自有新增（本文件已是万我树内副本非 vendored）。

/// utility 终端 raw 输出落盘盒（BuildArtifacts/run_log-<HHmmss>.txt——AI
/// fs/read 直取；头部/尾部由 GuestWindowBridge（pid 可及点）与
/// GuestRunService.unregisterUtilityProcess（退出注记点）分别写入）。
@objc public final class UtilityTeeLog: NSObject {
    /// 落盘文件路径（事件 runLog 字段/结果文本直显用）。
    @objc public let path: String

    /// 写入串行队列（handle/closed 只在本队列读写——queue-confined 状态）。
    private let queue = DispatchQueue(label: "wanwo.utility.teelog")
    private var handle: FileHandle?
    private var closed = false

    /// 创建落盘文件并打开追加句柄（open 动作入队——与后续写入同队列 FIFO
    /// 有序，早于任何 header/append）。
    @objc public init(path: String) {
        self.path = path
        super.init()
        queue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: self.path) {
                fm.createFile(atPath: self.path, contents: nil)
            }
            let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: self.path))
            try? h?.seekToEnd()
            self.handle = h
        }
    }

    /// 头部行（run start + pid——GuestWindowBridge 开窗成功后主线程写入）。
    @objc public func writeHeader(_ text: String) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }
            try? self.handle?.write(contentsOf: Data(text.utf8))
        }
    }

    /// raw 输出分块（TerminalViewObjC.readabilityHandler 后台线程调用——
    /// 转投串行队列；终端字节流原样落盘，含 ANSI 控制序列）。
    @objc public func appendRaw(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self, !self.closed, let h = self.handle else { return }
            try? h.write(contentsOf: data)
        }
    }

    /// 尾部行（run end + 退出注记——GuestRunService.unregisterUtilityProcess
    /// 收尾点写入，写完即 close；此后 appendRaw 静默丢弃防已关句柄异常）。
    @objc public func writeFooter(_ text: String) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }
            try? self.handle?.write(contentsOf: Data(text.utf8))
            try? self.handle?.close()
            self.handle = nil
            self.closed = true
        }
    }
}
