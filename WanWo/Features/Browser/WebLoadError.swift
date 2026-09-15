//
//  WebLoadError.swift
//  WanWo
//
//  【vendored 复用 · 源=OpenMinis src/ios/Views/Chat/WebLoadError.swift，全文语义 1:1（B2 批）】
//  【范围呈报】本文件为浏览器引擎必需依赖件（超出简报 10 文件清单，随报呈报）：
//    WebLoadError=BrowserUseManager.loadError 的错误模型（导航失败 UI 语义）；
//    BrowserResourceMonitor=BrowserTabPool 的 WebContent 诊断探针
//    （actionWillStart/actionDidFinish/livenessProbe，砍除即裁剪引擎诊断面）。
//    均零 App 层依赖（仅 Foundation/UIKit/WebKit），直连 vendored 不降级。
//  适配点：文件头注释 MinisApp → WanWo；品牌字符串 Minis → WanWo。
//

//
//  WebLoadError.swift
//  WanWo
//
//  [T-ios-webview-error-ui] Shared Safari-style error model + overlay for the
//  built-in WKWebViews. When a page fails to load (DNS not found, host
//  unreachable, offline, timeout, TLS error, …) WKWebView is left showing a
//  blank white/black page with no indication of what happened. This gives all
//  three built-in web surfaces (chat link preview, markdown link preview, and
//  the agent browser) a consistent icon + short message + Retry, mirroring what
//  Safari shows.
//

import Foundation
import SwiftUI
import WebKit

/// A normalized, user-facing description of a web navigation failure.
struct WebLoadError: Equatable {
    let title: String
    let message: String
    let systemImage: String
    /// The URL that failed, so a Retry can reload exactly it.
    let failedURL: URL?

    /// Build from a WebKit/Foundation navigation error. Returns nil for the
    /// benign "cancelled" cases (e.g. a load superseded by another, or a
    /// policy-cancelled non-http scheme handed off to the system) so the UI
    /// doesn't flash an error for a normal in-flight cancellation.
    init?(error: Error, failedURL: URL? = nil) {
        let ns = error as NSError

        // NSURLErrorCancelled (-999) and WKError frame-load-interrupted (102)
        // fire for superseded / policy-cancelled loads that are not real
        // failures — e.g. a non-http scheme handed off to the system, or a
        // load replaced by a newer one. Don't surface an error for those.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return nil }
        if ns.domain == WKError.errorDomain, ns.code == 102 { return nil }

        // Prefer the URL WebKit reports in the error, then the caller's hint.
        let urlFromError = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        self.failedURL = urlFromError ?? failedURL

        // Map the most common URLError codes to Safari-style copy. Anything
        // else falls through to a generic message that still names the host.
        let host = self.failedURL?.host
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            title = String(localized: "Cannot Open Page")
            message = host.map {
                String(localized: "WanWo can’t open the page because it can’t find the server “\($0)”.")
            } ?? String(localized: "WanWo can’t open the page because it can’t find the server.")
            systemImage = "wifi.exclamationmark"

        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            title = String(localized: "Cannot Open Page")
            message = String(localized: "WanWo can’t open the page because it can’t connect to the server.")
            systemImage = "wifi.exclamationmark"

        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorInternationalRoamingOff),
             (NSURLErrorDomain, NSURLErrorDataNotAllowed):
            title = String(localized: "You Are Not Connected to the Internet")
            message = String(localized: "The page couldn’t load because you’re not connected to the internet.")
            systemImage = "wifi.slash"

        case (NSURLErrorDomain, NSURLErrorTimedOut):
            title = String(localized: "The Connection Timed Out")
            message = host.map {
                String(localized: "The server “\($0)” took too long to respond.")
            } ?? String(localized: "The server took too long to respond.")
            systemImage = "clock.badge.exclamationmark"

        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain, NSURLErrorClientCertificateRejected),
             (NSURLErrorDomain, NSURLErrorClientCertificateRequired):
            title = String(localized: "This Connection Is Not Private")
            message = host.map {
                String(localized: "WanWo can’t verify the identity of the server “\($0)”.")
            } ?? String(localized: "WanWo can’t verify the identity of the server.")
            systemImage = "lock.slash"

        case (NSURLErrorDomain, NSURLErrorUnsupportedURL),
             (NSURLErrorDomain, NSURLErrorBadURL):
            title = String(localized: "Cannot Open Page")
            message = String(localized: "The address isn’t valid.")
            systemImage = "exclamationmark.triangle"

        default:
            title = String(localized: "Cannot Open Page")
            message = host.map {
                String(localized: "A problem occurred loading “\($0)”.")
            } ?? String(localized: "A problem occurred while loading this page.")
            systemImage = "exclamationmark.triangle"
        }
    }
}

/// Centered Safari-style error card shown over a blank WKWebView, with Retry.
struct WebLoadErrorOverlay: View {
    let error: WebLoadError
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: error.systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
            Text(error.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(error.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onRetry) {
                Label(String(localized: "Try Again"), systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
