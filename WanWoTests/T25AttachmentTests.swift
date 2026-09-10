//
//  T25AttachmentTests.swift
//  WanWoTests
//
//  【T2.5 F042 附件系统 · 逻辑层自测】覆盖：
//    · 请求投影几何（requestImageDimensions：小图不放大/等比缩/inward/逐像素
//      递减循环/竖图分支/触底——request-projection.ts 1:1 移植的回归锚）
//    · 阶梯执行（encodeFirstWithinLimit：首达即停/全超取最小）
//    · 准入矩阵（intakeRejection + attachmentErrorText 文案 zh 逐字）
//    · 存储往返（save→read digest 回核/类型比对/损坏拒读/批次策略）
//    · E1 载荷往返 + WireMessage vision 数组形态编码
//  CI 测试轨道已拆（HEAD b94203a）——本文件随 WanWoTests 保留备日后重启。
//

import XCTest
import UniformTypeIdentifiers
@testable import WanWo

final class T25AttachmentTests: XCTestCase {

    // MARK: - 请求投影几何（request-projection.ts 1:1）

    func testRequestImageDimensionsSmallImageNotEnlarged() {
        // scale = min(1, sqrt(budget/(w*h))) == 1 → 原样返回（小图不放大）。
        XCTAssertEqual(RequestProjection.requestImageDimensions(
            width: 100, height: 100, maxPixels: 2048 * 2048).width, 100)
        XCTAssertEqual(RequestProjection.requestImageDimensions(
            width: 100, height: 100, maxPixels: 2048 * 2048).height, 100)
    }

    func testRequestImageDimensionsAspectPreservingProjection() {
        // 4096×2048 → 2048² 预算：scale=√0.5，pw=floor(2896.31)=2896，
        // ph=round(2896*2048/4096)=1448；2896*1448=4,193,408 ≤ 4,194,304。
        let projected = RequestProjection.requestImageDimensions(
            width: 4096, height: 2048, maxPixels: 2048 * 2048)
        XCTAssertEqual(projected.width, 2896)
        XCTAssertEqual(projected.height, 1448)
        XCTAssertLessThanOrEqual(projected.width * projected.height, 2048 * 2048)
    }

    func testRequestImageDimensionsInwardDecrementLoop() {
        // round() 上取整导致首轮超预算 → 宽度逐像素递减直至达标：
        // 3000×1001、预算 2,000,000：pw=2449,ph=817→2,000,833 超；
        // pw=2448,ph=817→2,000,016 超；pw=2447,ph=817→1,999,199 达标。
        let projected = RequestProjection.requestImageDimensions(
            width: 3000, height: 1001, maxPixels: 2_000_000)
        XCTAssertEqual(projected.width, 2447)
        XCTAssertEqual(projected.height, 817)
        XCTAssertLessThanOrEqual(projected.width * projected.height, 2_000_000)
    }

    func testRequestImageDimensionsPortraitBranch() {
        // 竖图走高度主导分支（request-projection.ts:29-35）。
        let projected = RequestProjection.requestImageDimensions(
            width: 1000, height: 3000, maxPixels: 2_000_000)
        XCTAssertEqual(projected.width, 816)
        XCTAssertEqual(projected.height, 2449)
    }

    func testRequestImageDimensionsFloorGuard() {
        // 极小预算触底 1×1，不产生 0 尺寸（Math.max(1, …) 语义）。
        let projected = RequestProjection.requestImageDimensions(
            width: 2, height: 1, maxPixels: 1)
        XCTAssertEqual(projected.width, 1)
        XCTAssertEqual(projected.height, 1)
    }

    // MARK: - 阶梯执行（encoding.ts encodeFirstWithinLimit）

    func testEncodeFirstWithinLimitStopsAtFirstFit() throws {
        var executed: [Int] = []
        let attempts: [() throws -> EncodedImage] = [
            { executed.append(0); return EncodedImage(data: Data(repeating: 0, count: 900),
                                                      mediaType: .jpeg, width: 1, height: 1) },
            { executed.append(1); return EncodedImage(data: Data(repeating: 0, count: 500),
                                                      mediaType: .jpeg, width: 1, height: 1) },
        ]
        let chosen = try RequestProjection.encodeFirstWithinLimit(attempts, maxBytes: 1000)
        XCTAssertEqual(chosen.data.count, 900)
        XCTAssertEqual(executed, [0])
    }

    func testEncodeFirstWithinLimitKeepsSmallestWhenExhausted() throws {
        let attempts: [() throws -> EncodedImage] = [
            { EncodedImage(data: Data(repeating: 0, count: 900),
                           mediaType: .jpeg, width: 1, height: 1) },
            { EncodedImage(data: Data(repeating: 0, count: 300),
                           mediaType: .jpeg, width: 1, height: 1) },
            { EncodedImage(data: Data(repeating: 0, count: 600),
                           mediaType: .jpeg, width: 1, height: 1) },
        ]
        let chosen = try RequestProjection.encodeFirstWithinLimit(attempts, maxBytes: 100)
        XCTAssertEqual(chosen.data.count, 300)
    }

    // MARK: - 准入矩阵（intakeRejection + 文案逐字）

    private var limits: ImageAttachmentLimits {
        ImageAttachmentLimits(maxImageBytes: 1024,
                              maxImagesPerMessage: 2,
                              maxMessageImageBytes: 2048,
                              maxImagePixels: 64,
                              maxImageDimension: 100,
                              mediaTypes: [.png, .jpeg, .webp, .gif])
    }

    func testIntakeRejectionMatrix() {
        let ok = ChatViewModel.DraftImageCandidate(data: Data(repeating: 0, count: 100),
                                                   mediaType: .png, name: nil)
        let oversized = ChatViewModel.DraftImageCandidate(data: Data(repeating: 0, count: 2000),
                                                          mediaType: .png, name: nil)
        // 格式先行（含非白名单类型的批先报格式问题）。
        let badType = ChatViewModel.DraftImageCandidate(data: Data(repeating: 0, count: 10),
                                                        mediaType: nil, name: nil)
        XCTAssertEqual(ChatViewModel.intakeRejection(
            existingCount: 0, newCandidates: [badType],
            existingBytes: 0, limits: limits),
            "仅支持 PNG、JPG、WebP、GIF 格式的图片")
        // 数量。
        XCTAssertEqual(ChatViewModel.intakeRejection(
            existingCount: 2, newCandidates: [ok],
            existingBytes: 0, limits: limits),
            "一条消息最多添加 2 张图片")
        // 单图字节（maxImageBytes=1024 → imageSizeText = 0.0MB）。
        XCTAssertEqual(ChatViewModel.intakeRejection(
            existingCount: 0, newCandidates: [oversized],
            existingBytes: 0, limits: limits),
            "单张图片不能超过 0.0MB")
        // 聚合字节（maxMessageImageBytes=2048 → 0.0MB）。
        XCTAssertEqual(ChatViewModel.intakeRejection(
            existingCount: 1, newCandidates: [ok, ok],
            existingBytes: 1900, limits: limits),
            "图片总大小超过 0.0MB，请移除部分图片")
        // 通过。
        XCTAssertNil(ChatViewModel.intakeRejection(
            existingCount: 1, newCandidates: [ok],
            existingBytes: 100, limits: limits))
    }

    func testAttachmentErrorTextCopyMatchesDshLocales() {
        // zh 逐字（ui-conversation locales.ts image.*）；限额插值含
        // imageSizeText 格式（10MB / 2.5MB）。
        XCTAssertEqual(ChatViewModel.imageSizeText(10 * 1024 * 1024), "10MB")
        XCTAssertEqual(ChatViewModel.imageSizeText(2_621_440), "2.5MB")
        XCTAssertEqual(ChatViewModel.attachmentErrorText(
            code: "MODEL_DOES_NOT_SUPPORT_IMAGES", limits: limits),
            "当前模型不支持图片，请切换支持图片的模型")
        XCTAssertEqual(ChatViewModel.attachmentErrorText(
            code: "IMAGE_TOO_MANY_PIXELS", limits: limits),
            "图片分辨率过大，请压缩后重试")
        XCTAssertEqual(ChatViewModel.attachmentErrorText(
            code: "IMAGE_DIMENSION_TOO_LARGE", limits: limits),
            "图片宽高不能超过 100px，请缩小后重试")
        XCTAssertEqual(ChatViewModel.attachmentErrorText(
            code: "TOO_MANY_IMAGES", limits: limits),
            "一条消息最多添加 2 张图片")
        XCTAssertEqual(ChatViewModel.attachmentErrorText(
            code: "UNKNOWN_REASON", limits: limits),
            "图片发送失败（UNKNOWN_REASON），请重新添加图片后再试")
    }

    // MARK: - 存储往返（content-addressed）

    /// 生成一幅 4×4 纯色 PNG（测试夹具）。
    private func makePNGData(width: Int = 4, height: Int = 4) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeStore() -> AttachmentStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t25-\(UUID().uuidString)", isDirectory: true)
        return AttachmentStore(root: root)
    }

    func testSaveAndReadRoundTrip() throws {
        let store = makeStore()
        let png = try makePNGData()
        let ref = try store.saveImage(SaveImageAttachment(data: png, mediaType: .png,
                                                          name: "/tmp/测试 图.png"))
        // content-addressed 引用（sha256:<64hex>）+ 字段核实。
        XCTAssertTrue(ref.attachmentId.hasPrefix("sha256:"))
        XCTAssertEqual(ref.attachmentId.count, 7 + 64)
        XCTAssertEqual(ref.mediaType, .png)
        XCTAssertEqual(ref.width, 4)
        XCTAssertEqual(ref.height, 4)
        XCTAssertEqual(ref.bytes, png.count)
        XCTAssertEqual(ref.name, "测试 图.png")
        XCTAssertNil(ref.originalDimensions)
        // 读回 digest + 头探测回核。
        let stored = try store.readImage(ref)
        XCTAssertEqual(stored.data, png)
        // 同图重存 → 去重同引用。
        let ref2 = try store.saveImage(SaveImageAttachment(data: png, mediaType: .png, name: nil))
        XCTAssertEqual(ref2.attachmentId, ref.attachmentId)
    }

    func testSaveRejectsTypeMismatchAndGarbage() throws {
        let store = makeStore()
        let png = try makePNGData()
        // 声明 jpeg、字节是 png → IMAGE_TYPE_MISMATCH（store.ts inspectMetadata）。
        XCTAssertThrowsError(try store.saveImage(
            SaveImageAttachment(data: png, mediaType: .jpeg, name: nil))) { error in
            XCTAssertEqual((error as? AttachmentError)?.code, "IMAGE_TYPE_MISMATCH")
        }
        // 空数据 / 垃圾字节 → INVALID_IMAGE。
        XCTAssertThrowsError(try store.saveImage(
            SaveImageAttachment(data: Data(), mediaType: .png, name: nil))) { error in
            XCTAssertEqual((error as? AttachmentError)?.code, "INVALID_IMAGE")
        }
        XCTAssertThrowsError(try store.saveImage(
            SaveImageAttachment(data: Data("not an image".utf8), mediaType: .png, name: nil))) { error in
            XCTAssertEqual((error as? AttachmentError)?.code, "INVALID_IMAGE")
        }
    }

    func testBatchPolicyAndByteLimit() throws {
        var tight = ImageAttachmentLimits()
        tight.maxImageBytes = 8
        tight.maxImagesPerMessage = 2
        tight.maxMessageImageBytes = 10
        let store = makeStore()  // 部署限制用默认；批次策略直接调 validateImageBatch
        let png = try makePNGData()
        let input = SaveImageAttachment(data: png, mediaType: .png, name: nil)
        // 数量超限（index.ts validateImageBatch 语义—— 任一失败整批拒）。
        XCTAssertThrowsError(try store.validateImageBatch([input, input, input])) { error in
            XCTAssertEqual((error as? AttachmentError)?.code, "TOO_MANY_IMAGES")
        }
        // 单图字节帽（prepareImageFile :104 顺序：字节帽先于解码）。
        let tightStore = AttachmentStore(root: store.root.appendingPathComponent("tight"),
                                         limits: tight)
        XCTAssertThrowsError(try tightStore.saveImage(input)) { error in
            XCTAssertEqual((error as? AttachmentError)?.code, "IMAGE_TOO_LARGE")
        }
        // 聚合字节帽。
        let cappedStore = AttachmentStore(root: store.root.appendingPathComponent("agg"),
                                          limits: ImageAttachmentLimits(
                                            maxImageBytes: 1024 * 1024,
                                            maxImagesPerMessage: 20,
                                            maxMessageImageBytes: 8,
                                            maxImagePixels: 64_000_000,
                                            maxImageDimension: 8192,
                                            mediaTypes: [.png, .jpeg, .webp, .gif]))
        XCTAssertThrowsError(try cappedStore.validateImageBatch([input])) { error in
            XCTAssertEqual((error as? AttachmentError)?.code, "IMAGES_TOO_LARGE")
        }
    }

    func testReadRejectsTamperedObject() throws {
        let store = makeStore()
        let png = try makePNGData()
        let ref = try store.saveImage(SaveImageAttachment(data: png, mediaType: .png, name: nil))
        // 篡改对象字节 → digest 回核失败 ATTACHMENT_CORRUPT。
        guard let sha256 = AttachmentStore.sha256Hex(of: ref) else {
            return XCTFail("合法引用应可解析")
        }
        let objectPath = AttachmentStore.objectPath(root: store.root, sha256: sha256)
        try Data("tampered".utf8).write(to: objectPath)
        XCTAssertThrowsError(try store.readImage(ref)) { error in
            XCTAssertEqual((error as? AttachmentError)?.code, "ATTACHMENT_CORRUPT")
        }
        // 非法引用 → INVALID_ATTACHMENT_REF。
        var broken = ref
        broken.attachmentId = "sha256:zzzz"
        XCTAssertThrowsError(try store.readImage(broken)) { error in
            XCTAssertEqual((error as? AttachmentError)?.code, "INVALID_ATTACHMENT_REF")
        }
    }

    // MARK: - E1 载荷往返 + 请求变体身份

    func testImagesEventPayloadRoundTrip() throws {
        let ref = ImageAttachmentRef(attachmentId: "sha256:" + String(repeating: "a", count: 64),
                                     mediaType: .jpeg, bytes: 123,
                                     width: 640, height: 480,
                                     name: "照片.jpg",
                                     originalDimensions: ImageDimensions(width: 1280, height: 960))
        let payload = try XCTUnwrap(AttachmentStore.refsJSONPayload(seq: 42, refs: [ref]))
        // 注册 schema 顶层校验通过（seq int + images array）。
        XCTAssertNil(ExtensionEventRegistry.validationReason(
            payload: payload,
            schema: ExtensionEventSchema(kind: AttachmentStore.imagesEventKind,
                                         requiredFields: [
                                            ExtensionFieldSchema("seq", .int),
                                            ExtensionFieldSchema("images", .array)])))
        let parsed = try XCTUnwrap(AttachmentStore.refsFromPayload(payload))
        XCTAssertEqual(parsed.seq, 42)
        XCTAssertEqual(parsed.refs, [ref])
    }

    func testRequestVariantIdDeterministic() {
        let ref = ImageAttachmentRef(attachmentId: "sha256:" + String(repeating: "b", count: 64),
                                     mediaType: .jpeg, bytes: 1, width: 100, height: 100,
                                     name: nil, originalDimensions: nil)
        let policy = AttachmentStore.requestPolicy
        // 同 ref + 同 policy → 恒同变体（缓存与上传索引同键的前提）。
        XCTAssertEqual(RequestProjection.requestImageVariantId(ref: ref, policy: policy),
                       RequestProjection.requestImageVariantId(ref: ref, policy: policy))
        // policy 变 → 变体变。
        XCTAssertNotEqual(
            RequestProjection.requestImageVariantId(ref: ref, policy: policy),
            RequestProjection.requestImageVariantId(
                ref: ref, policy: ImageRequestPolicy(maxPixels: 1024, maxBytes: 1024)))
    }

    // MARK: - WireMessage vision 数组形态

    func testWireMessageTextFormStaysString() throws {
        let message = WireMessage(role: "assistant", content: "hello",
                                  toolCalls: nil, toolCallID: nil)
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, "hello")
    }

    func testWireMessageVisionPartsEncoding() throws {
        let parts = [
            WireContentPart(type: "text", text: "看这张图"),
            WireContentPart(type: "image_url",
                            image_url: WireImageURL(url: "data:image/jpeg;base64,QUJD")),
        ]
        let message = WireMessage(role: "user", content: .parts(parts))
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "看这张图")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(content[1]["image_url"] as? [String: Any])
        XCTAssertTrue((imageURL["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    // MARK: - 名称清洗与引用解析

    func testDisplayNameStripsPathAndControls() {
        XCTAssertEqual(AttachmentStore.displayName("/tmp/dir/pic.png"), "pic.png")
        XCTAssertEqual(AttachmentStore.displayName("C:\\Users\\a\\pic.png"), "pic.png")
        XCTAssertEqual(AttachmentStore.displayName("  hello\u{0007}  "), "hello")
        XCTAssertNil(AttachmentStore.displayName("///"))
        XCTAssertNil(AttachmentStore.displayName(nil))
    }

    func testSha256RefParsing() {
        let valid = ImageAttachmentRef(attachmentId: "sha256:" + String(repeating: "A", count: 64),
                                       mediaType: .png, bytes: 1, width: 1, height: 1,
                                       name: nil, originalDimensions: nil)
        XCTAssertEqual(AttachmentStore.sha256Hex(of: valid),
                       String(repeating: "a", count: 64))
        XCTAssertNil(AttachmentStore.sha256Hex(of: ImageAttachmentRef(
            attachmentId: "http://evil", mediaType: .png, bytes: 1, width: 1, height: 1,
            name: nil, originalDimensions: nil)))
        XCTAssertNil(AttachmentStore.sha256Hex(of: ImageAttachmentRef(
            attachmentId: "sha256:short", mediaType: .png, bytes: 1, width: 1, height: 1,
            name: nil, originalDimensions: nil)))
    }
}
