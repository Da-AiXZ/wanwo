//
//  BrowserWebView.swift
//  WanWo
//
//  【vendored 复用 · 源=OpenMinis src/ios/Agent/BrowserUse/BrowserWebView.swift，全文语义 1:1（B2 批）】
//  适配点（简报 B2 四类；逐文件裁定详见 B2 交付报告）：
//    1. 文件头注释 MinisApp → WanWo；
//    2. 品牌字符串 minis:// → wanwo://、minis-browser-use → wanwo-browser-use、
//       Minis → WanWo（print handler 名 minisPrint→wanwoPrint、JS 内部标识 __minis*→__wanwo*）；
//    3. 路径 /var/minis/** → /var/wanwo/**（与 WanWoPaths 同值常量，改字符串不改语义）；
//    4. App 层依赖：AppLogger 直连（WanWo ISHRuntime 同名同构件）；
//       AppLocalized(...) → String(localized: ...)（OpenMinis 应用内语言切换面
//       未随 M6 移植，降级为系统本地化，登记报告）；
//

import SwiftUI
import WebKit

/// UIViewRepresentable wrapper that displays a `BrowserUseManager`'s WKWebView.
struct BrowserWebView: UIViewRepresentable {
    let manager: BrowserUseManager

    func makeUIView(context: Context) -> WKWebView {
        manager.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The manager owns the webView — nothing to update here.
    }
}
