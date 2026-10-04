//
//  Batch0LodyAdoptionTests.swift
//  WanWoTests
//
//  【批0 lody 机制引入·小修快补 4 件 · 单测面】纯函数缝矩阵：
//    - 件1 发送失败草稿回填：draftRestoreAfterSendFailure 决策矩阵
//      （空稿回填 / 用户已改写不覆盖 / 空快照 no-op / image-only 回填）。
//    - 件4 粘贴长文本提升：shouldPromotePastedText 阈值边界（≥2000 字符 /
//      ≥16 行——lody verification/composer/main.swift:339-347 断言同矩阵）+
//      pastedSurge 插入片段夹取（尾插/中插/删除/打字）+
//      promotionReplacement / undoReplacement 决策 + pastePromotionPath 形状。
//  不可单测面（随真机验收）：件2 独立 UIWindow（需 UIKit 窗口场景宿主）、
//  件3 触觉（UINotificationFeedbackGenerator 硬件行为）、失败回填的
//  onChange→draftCache 链（SwiftUI 集成行为）。
//

import XCTest
@testable import WanWo

final class Batch0LodyAdoptionTests: XCTestCase {

    // MARK: - fixture

    private func image(_ bytes: [UInt8] = [0x01]) -> ChatViewModel.DraftImage {
        ChatViewModel.DraftImage(id: UUID(), data: Data(bytes), mediaType: .png,
                                 name: "t.png")
    }

    // MARK: - P2-1 回合结束触觉决策矩阵

    func testTurnEndHapticMatrix() {
        // 仅操作成败事实发声。
        XCTAssertEqual(ChatViewModel.turnEndHaptic(.completed), .success)
        XCTAssertEqual(ChatViewModel.turnEndHaptic(
            .error(LlmFailure(message: "boom", code: "E"))), .error)
        // 取消/受限/截断/孤儿收尾静默（旧 else 分支误发 success 已修）。
        XCTAssertNil(ChatViewModel.turnEndHaptic(.aborted(cause: "user")))
        XCTAssertNil(ChatViewModel.turnEndHaptic(.blocked))
        XCTAssertNil(ChatViewModel.turnEndHaptic(.maxTokens))
        XCTAssertNil(ChatViewModel.turnEndHaptic(.interrupted))
    }

    // MARK: - 件1 发送失败草稿回填（决策矩阵）

    func testRestoreRestoresSnapshotWhenCurrentEmpty() {
        let out = ChatViewModel.draftRestoreAfterSendFailure(
            failedDraft: "原稿内容", failedImages: [],
            currentDraft: "", currentImages: [])
        XCTAssertEqual(out?.draft, "原稿内容")
        XCTAssertEqual(out?.images, [])
    }

    func testRestoreKeepsUserEditsWhenCurrentNonEmpty() {
        // 失败窗口内用户已重新输入 → 不覆盖（快照丢弃）。
        let out = ChatViewModel.draftRestoreAfterSendFailure(
            failedDraft: "原稿内容", failedImages: [image()],
            currentDraft: "用户新输入", currentImages: [])
        XCTAssertNil(out)
    }

    func testRestoreKeepsUserEditsWhenCurrentUserImagesNonEmpty() {
        let out = ChatViewModel.draftRestoreAfterSendFailure(
            failedDraft: "原稿内容", failedImages: [],
            currentDraft: "", currentImages: [image()])
        XCTAssertNil(out)
    }

    func testRestoreSkipsWhenSnapshotEmpty() {
        // 快照本身为空（纯空发送理论不可达，防御位）→ no-op。
        let out = ChatViewModel.draftRestoreAfterSendFailure(
            failedDraft: "   ", failedImages: [],
            currentDraft: "", currentImages: [])
        XCTAssertNil(out)
    }

    func testRestoreRestoresImageOnlyDraft() {
        // F042 image-only 发送（文本空白、仅图）失败 → 图片回填。
        let snapshot = [image(), image([0x02])]
        let out = ChatViewModel.draftRestoreAfterSendFailure(
            failedDraft: "", failedImages: snapshot,
            currentDraft: "", currentImages: [])
        XCTAssertEqual(out?.draft, "")
        XCTAssertEqual(out?.images, snapshot)
    }

    // MARK: - 件4 阈值判定（lody 断言矩阵同源）

    func testCharacterThresholdBoundary() {
        let at1999 = String(repeating: "x", count: 1_999)
        let at2000 = String(repeating: "x", count: 2_000)
        XCTAssertFalse(ChatViewModel.shouldPromotePastedText(at1999))
        XCTAssertTrue(ChatViewModel.shouldPromotePastedText(at2000))
    }

    func testLineThresholdBoundary() {
        // 15 行（14 换行）不提升；16 行（15 换行）提升
        // （lody verification:341 16 行断言）。
        let fifteen = (1...15).map { "line \($0)" }.joined(separator: "\n")
        let sixteen = (1...16).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertFalse(ChatViewModel.shouldPromotePastedText(fifteen))
        XCTAssertTrue(ChatViewModel.shouldPromotePastedText(sixteen))
    }

    func testShortTextNoPromotion() {
        XCTAssertFalse(ChatViewModel.shouldPromotePastedText("普通短粘贴"))
        XCTAssertFalse(ChatViewModel.shouldPromotePastedText(""))
    }

    // MARK: - 件4 surge 夹取

    func testSurgeTailPaste() {
        let old = "开头的话 "
        let pasted = (1...16).map { "line \($0)" }.joined(separator: "\n")
        let surge = ChatViewModel.pastedSurge(old: old, new: old + pasted)
        XCTAssertEqual(surge, pasted)
    }

    func testSurgeMiddlePaste() {
        let pasted = String(repeating: "y", count: 2_000)
        let new = "前段\(pasted)后段"
        let surge = ChatViewModel.pastedSurge(old: "前段后段", new: new)
        XCTAssertEqual(surge, pasted)
    }

    func testSurgeDeletionIsNotPaste() {
        let long = String(repeating: "x", count: 2_000)
        XCTAssertNil(ChatViewModel.pastedSurge(old: long, new: ""))
    }

    func testSurgeTypingBelowThreshold() {
        XCTAssertNil(ChatViewModel.pastedSurge(old: "hello", new: "hello world"))
    }

    func testSurgeSameValueNoOp() {
        XCTAssertNil(ChatViewModel.pastedSurge(old: "abc", new: "abc"))
    }

    // MARK: - 件4 引用替换 / 撤销回填

    func testPromotionReplacement() {
        let pasted = (1...16).map { "line \($0)" }.joined(separator: "\n")
        let draft = "看这段：\(pasted) 谢谢"
        let out = ChatViewModel.promotionReplacement(
            draft: draft, pasted: pasted, reference: "@.wanwo/pastes/paste-1.md ")
        XCTAssertEqual(out, "看这段：@.wanwo/pastes/paste-1.md  谢谢")
    }

    func testPromotionReplacementMissingTextReturnsNil() {
        XCTAssertNil(ChatViewModel.promotionReplacement(
            draft: "已被用户改写", pasted: "原文不在",
            reference: "@.wanwo/pastes/paste-1.md "))
    }

    func testUndoRestoresByReference() {
        let out = ChatViewModel.undoReplacement(
            draft: "看这段：@.wanwo/pastes/paste-1.md  谢谢",
            original: "原文",
            reference: "@.wanwo/pastes/paste-1.md ")
        XCTAssertEqual(out, "看这段：原文 谢谢")
    }

    func testUndoFillsEmptyDraft() {
        let out = ChatViewModel.undoReplacement(
            draft: "", original: "原文", reference: "@p.md ")
        XCTAssertEqual(out, "原文")
    }

    func testUndoPrependsWhenDraftRewritten() {
        // 用户已改写（引用不在稿中）→ 原文前置拼接，不覆盖新输入。
        let out = ChatViewModel.undoReplacement(
            draft: "新输入", original: "原文", reference: "@p.md ")
        XCTAssertEqual(out, "原文 新输入")
    }

    // MARK: - 件4 转存路径形状

    func testPastePromotionPathShape() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5,
            nanosecond: 123_000_000))!
        XCTAssertEqual(ChatViewModel.pastePromotionPath(at: date),
                       ".wanwo/pastes/paste-20260102-030405-123.md")
    }
}
