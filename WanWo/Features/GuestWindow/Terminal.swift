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

        self.isOpaque = false;
        self.backgroundColor = .secondarySystemBackground
        self.nativeForegroundColor = gibDynamicColor(light: .label, dark: self.nativeForegroundColor)
        self.caretTextColor = gibDynamicColor(light: .label, dark: self.nativeForegroundColor)
        self.font = UIFont.monospacedSystemFont(ofSize: (UIDevice.current.userInterfaceIdiom == .pad) ? 14 : 10, weight: .regular)

        self.ttyHandle?.readabilityHandler = { [weak self] fileHandle in
            guard let self = self else { return }
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }

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
