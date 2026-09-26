//
//  UIBatch3Tests.swift
//  WanWo
//
//  【批3 D 测试】（简报 D 清单）：
//    · 设置面板分区路由/迁移完整性（6 项全达）；
//    · BYOK 首跑 gate 矩阵（无 provider/已有/稍后配置）；
//    · API key 形校验矩阵（dsh apiKey.ts 四类裁剪）；
//    · 右栏可见性（无会话隐藏）+ 全屏状态机；
//    · 页签列表页候选（空态=页签列表页）；
//    · 文件页多开（codex「新开文件页」）；
//    · TurnNavigator 轮次选择纯函数。
//

import XCTest
@testable import WanWo

// MARK: - A. 设置面板分区路由/迁移完整性

final class UIBatch3SettingsPaneTests: XCTestCase {
    func testSixPanesComplete() {
        XCTAssertEqual(SettingsPane.allCases.count, 6)
        // 迁移目标视图一一对应（Providers/MCP/Skills/权限/外挂载/诊断）。
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.destinationIdentifier)).count, 6)
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.title.isEmpty, "\(pane) 标题缺失")
            XCTAssertFalse(pane.iconName.isEmpty, "\(pane) 图标缺失")
        }
    }

    func testDeepLinkPanePresent() {
        // 深链 wanwo://settings/permissions 落点分区存在（B1c 闭环勿断）。
        XCTAssertTrue(SettingsPane.allCases.contains(.permissions))
        XCTAssertEqual(SettingsPane.permissions.destinationIdentifier,
                       "PermissionDefaultsView")
        // 外挂载分区（批2 B③ fullScreenCover 命名卡链路宿主）。
        XCTAssertEqual(SettingsPane.mounts.destinationIdentifier,
                       "MountedFoldersSettingsView")
    }
}

// MARK: - B. BYOK 首跑 gate + API key 校验

final class UIBatch3BYOKTests: XCTestCase {
    func testOnboardingGateMatrix() {
        // 未确认 + 无凭据端点 → 引导。
        XCTAssertTrue(EndpointStore.byokOnboardingNeeded(
            confirmed: false, endpointsWithCredential: 0))
        // 已确认（「稍后配置」/保存同路）→ 不再引导。
        XCTAssertFalse(EndpointStore.byokOnboardingNeeded(
            confirmed: true, endpointsWithCredential: 0))
        // 已有凭据（含一条）→ 不引导。
        XCTAssertFalse(EndpointStore.byokOnboardingNeeded(
            confirmed: false, endpointsWithCredential: 1))
        XCTAssertFalse(EndpointStore.byokOnboardingNeeded(
            confirmed: true, endpointsWithCredential: 2))
    }

    func testAPIKeyFailureMatrix() {
        // 空串 = 通过（UI 层保留已存——dsh 空=通过）。
        XCTAssertNil(EndpointStore.apiKeyFailure(""))
        // 纯空白 = keyRequired。
        XCTAssertEqual(EndpointStore.apiKeyFailure("   "), "keyRequired")
        XCTAssertEqual(EndpointStore.apiKeyFailure(" \t\n  "), "keyRequired")
        // 合法可打印 ASCII key = 通过。
        XCTAssertNil(EndpointStore.apiKeyFailure("sk-abc123XYZ-_~!@#$%^&*()"))
        // 环境变量行 = keyIllegalCharacters（大写开头名 + = 后非 =）。
        XCTAssertEqual(EndpointStore.apiKeyFailure("DEEPSEEK_API_KEY=sk-abc"),
                       "keyIllegalCharacters")
        XCTAssertEqual(EndpointStore.apiKeyFailure("A1_B=x"),
                       "keyIllegalCharacters")
        // `=` 后是 `=`（base64 padding 形态）不判 ENV 行。
        XCTAssertNil(EndpointStore.apiKeyFailure("AB=="))
        // 引号包裹 = keyIllegalCharacters（三种引号）。
        XCTAssertEqual(EndpointStore.apiKeyFailure("\"sk-abc\""),
                       "keyIllegalCharacters")
        XCTAssertEqual(EndpointStore.apiKeyFailure("'sk-abc'"),
                       "keyIllegalCharacters")
        XCTAssertEqual(EndpointStore.apiKeyFailure("`sk-abc`"),
                       "keyIllegalCharacters")
        // 非可打印 ASCII / 非 ASCII = keyIllegalCharacters。
        XCTAssertEqual(EndpointStore.apiKeyFailure("sk abc"),      // 空格 0x20
                       "keyIllegalCharacters")
        XCTAssertEqual(EndpointStore.apiKeyFailure("sk\u{00A0}abc"), // NBSP
                       "keyIllegalCharacters")
        XCTAssertEqual(EndpointStore.apiKeyFailure("密钥abc"),
                       "keyIllegalCharacters")
    }

    func testDeleteMessageVariants() {
        let ep = EndpointConfig(name: "DeepSeek",
                                baseURL: "https://api.deepseek.com",
                                model: "deepseek-v4-flash")
        // 有凭证版：点明凭据一并清除。
        XCTAssertTrue(ProvidersView.deleteMessage(for: ep, hasCredential: true)
            .contains("一并清除凭据"))
        // 无凭证版：简洁不可恢复描述。
        XCTAssertTrue(ProvidersView.deleteMessage(for: ep, hasCredential: false)
            .contains("无法恢复"))
        XCTAssertFalse(ProvidersView.deleteMessage(for: ep, hasCredential: false)
            .contains("API Key"))
    }
}

// MARK: - C. 右栏可见性（无会话隐藏）+ 布局三态
// 【批12+右栏重构批1】语义源换 cc-haha workspaceStore（三态单值 hidden/split/
// full），旧双布尔测试面整体迁移为三态断言；WOWorkspaceStore 语义详见
// WOWorkspaceStore.swift 头注。

@MainActor
final class UIBatch3RightRailVisibilityTests: XCTestCase {
    func testSessionIDOfSelection() {
        XCTAssertEqual(WorkspaceRightSidebarView.sessionID(of: .session(id: "s1")),
                       "s1")
        XCTAssertNil(WorkspaceRightSidebarView.sessionID(of: .none))
        XCTAssertNil(WorkspaceRightSidebarView.sessionID(of: .providers))
        XCTAssertNil(WorkspaceRightSidebarView.sessionID(of: .eventStream))
    }

    func testNoSessionForcesCollapseAndExitsFullscreen() {
        let store = WOWorkspaceStore()
        store.setLayout(.full, sessionId: "s1")
        store.reconcileForNoSession()
        XCTAssertEqual(store.layout(for: "s1"), .hidden, "无会话必须强制收起（含全屏态）")
    }

    func testSessionSelectionKeepsState() {
        // 有会话时不触发 reconcile——打开的右栏保持 split。
        let store = WOWorkspaceStore()
        store.openTarget(sessionId: "s1", target: .singleton(.files))
        XCTAssertEqual(store.layout(for: "s1"), .split, "打开页签隐式展开")
    }

    func testAlreadyCollapsedIsStable() {
        let store = WOWorkspaceStore()
        store.setLayout(.hidden, sessionId: "s1")
        store.reconcileForNoSession()
        XCTAssertEqual(store.layout(for: "s1"), .hidden)
    }

    func testToggleRestoresSplitNeverFull() {
        // cc-haha :388-392："toggle 不许吞掉对话"——full 态 toggle 归 hidden，
        // 再 toggle 得 split（永不从 toggle 直达 full）。
        let store = WOWorkspaceStore()
        store.setLayout(.full, sessionId: "s1")
        store.toggleWorkspace(sessionId: "s1")
        XCTAssertEqual(store.layout(for: "s1"), .hidden)
        store.toggleWorkspace(sessionId: "s1")
        XCTAssertEqual(store.layout(for: "s1"), .split)
    }
}

// MARK: - C③/C⑥. 页签列表页候选 + 复用规则（批12+右栏重构批1：cc-haha
//  openTarget 复用语义——单例 kind 激活既有，browser 恒新建）

@MainActor
final class UIBatch3TabListPageTests: XCTestCase {
    func testCandidateKinds() {
        let store = WOWorkspaceStore()
        // 审查=git 项目时入列（第一位）；false 路径断言（true 路径需 git
        // 目录 fixture，真机验收面）。
        XCTAssertEqual(
            store.candidateKinds(),
            [.files, .sideChat, .browser, .terminal, .trajectory])
    }

    func testFilesTabSingleton() {
        // 批12+右栏重构批1：files=树签单例（cc-haha file 按 path 复用语义的
        // 万我形态——树签无 path 概念，重复打开=激活既有）。
        let store = WOWorkspaceStore()
        store.openTarget(sessionId: "s1", target: .singleton(.files))
        store.openTarget(sessionId: "s1", target: .singleton(.files))
        XCTAssertEqual(store.tabs(for: "s1").filter { $0.kind == .files }.count, 1)
        XCTAssertEqual(store.activeTab(for: "s1")?.kind, .files)
    }

    func testSingletonKindsStillDedup() {
        // 终端/侧聊保持单例（重复点选=激活既有页签）。
        let store = WOWorkspaceStore()
        store.openTarget(sessionId: "s1", target: .singleton(.terminal))
        store.openTarget(sessionId: "s1", target: .singleton(.terminal))
        XCTAssertEqual(store.tabs(for: "s1").filter { $0.kind == .terminal }.count, 1)
    }

    func testBrowserNeverReuses() {
        // cc-haha browser 不复用：连续打开=多实例页签。
        let store = WOWorkspaceStore()
        store.openTarget(sessionId: "s1", target: .browser(url: nil))
        store.openTarget(sessionId: "s1", target: .browser(url: nil))
        XCTAssertEqual(store.tabs(for: "s1").filter { $0.kind == .browser }.count, 2)
    }
}

// MARK: - C⑧. TurnNavigator 轮次选择纯函数

final class UIBatch3TurnNavigatorTests: XCTestCase {
    private func bubble(
        _ id: String,
        _ kind: ConversationProjector.Bubble.Kind
    ) -> ConversationProjector.Bubble {
        ConversationProjector.Bubble(id: id, kind: kind)
    }

    func testTurnAnchorsPerUserMessage() {
        let bubbles = [
            bubble("u1", .user("第一轮", [])),
            bubble("a1", .assistant("回复")),
            bubble("n1", .note("注记")),
            bubble("u2", .user("第二轮", [])),
            bubble("a2", .assistant("回复2")),
        ]
        let anchors = TurnNavigator.turnAnchors(in: bubbles)
        XCTAssertEqual(anchors.map(\.turn), [0, 1])
        XCTAssertEqual(anchors.map(\.bubbleID), ["u1", "u2"])
    }

    func testNoUserBubblesNoAnchors() {
        let anchors = TurnNavigator.turnAnchors(
            in: [bubble("a1", .assistant("hi")), bubble("n1", .note("x"))])
        XCTAssertTrue(anchors.isEmpty)
    }

    func testMarkerUserMessageExcluded() {
        let anchors = TurnNavigator.turnAnchors(in: [
            bubble("m1", .user("<system-reminder>内部", [])),
            bubble("u1", .user("真实轮", [])),
        ])
        XCTAssertEqual(anchors.map(\.bubbleID), ["u1"])
    }

    func testRailVisibility() {
        XCTAssertFalse(TurnNavigator.shouldShowRail(anchorCount: 0))
        XCTAssertFalse(TurnNavigator.shouldShowRail(anchorCount: 1))
        XCTAssertTrue(TurnNavigator.shouldShowRail(anchorCount: 2))
        XCTAssertTrue(TurnNavigator.shouldShowRail(anchorCount: 9))
    }
}
