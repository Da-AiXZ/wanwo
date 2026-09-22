//
//  WOBrand.swift
//  WanWo
//
//  环 2 批 A —— FishLogo（7.2.6）/ ReferenceIcon（7.2.7）/ BrandWordmark 结构（7.2.9）。
//  万我品牌名以鱼形几何 + 文字标呈现；path 数据 1:1 取自细读文档。
//

import SwiftUI

// MARK: - 鱼形 logo（FISH_LOGO_PATH：单条复合贝塞尔，吻部/背鳍/腹弧/尾内凹）

public enum WOFishLogo {
    /// 原生 viewBox 尺寸（23.16 × 17.04）
    public static let viewBox = CGSize(width: 23.16, height: 17.04)
    /// 细读文档 3213 行：FISH_LOGO_PATH（1:1 照录）
    public static let path =
        "M10.8499 0.677124C6.91699 0.677124 3.84869 3.24062 2.34827 5.10712C1.76462 5.83109 0.79236 6.42938 0.578086 7.32612C0.409138 8.03372 0.861814 8.88342 1.26153 9.47112C2.82309 11.7528 6.09302 14.1447 9.26102 15.2647C12.7878 16.5085 17.2561 16.7617 20.3398 14.5225C21.5496 13.6352 22.5226 12.4129 22.8813 10.9531C23.1641 9.79942 22.9555 8.53922 22.3373 7.52692C21.2625 5.77742 19.2811 4.50162 17.3645 3.66312C15.2942 2.75032 13.0597 2.04362 10.8499 2.19042C10.5039 2.21332 10.1554 2.25072 9.81613 2.32632C9.46365 2.40492 9.10749 2.50352 8.77921 2.65572C8.20828 2.91842 7.70551 3.33302 7.31353 3.82712C6.98361 4.24242 6.73591 4.72532 6.59743 5.23472C6.46543 5.72042 6.42961 6.23232 6.49981 6.72812C6.60199 7.44092 6.93217 8.10742 7.42351 8.62912C8.03893 9.28232 8.86799 9.72092 9.74839 9.89502C10.7105 10.0865 11.7225 10.0012 12.6292 9.65832C13.6597 9.26872 14.5557 8.54522 15.1081 7.60112C15.4237 7.06042 15.6185 6.44912 15.6481 5.82872C15.6721 5.33012 15.5953 4.82702 15.4169 4.36112C15.2567 3.94142 15.0179 3.55202 14.7163 3.21902C14.1269 2.57202 13.3323 2.13242 12.4797 1.94402C11.9519 1.82742 11.4021 1.80042 10.8655 1.85622L10.8499 0.677124Z"
    public static let path2 =
        "M10.2697 3.80602C10.2697 3.80602 11.9581 3.46922 13.0441 4.33952C14.13 5.20982 14.1688 6.21602 14.0875 6.96422C14.0062 7.71242 13.4584 8.64632 12.4411 9.11402C11.4238 9.58172 10.0771 9.52832 9.16117 8.98742C8.24523 8.44652 7.87441 7.70102 7.82689 6.97682C7.76777 6.08282 8.19775 5.26352 8.62041 4.92452C8.62041 4.92452 9.22057 4.48802 9.89365 4.62932C10.5667 4.77062 10.2697 3.80602 10.2697 3.80602Z"

    /// 鱼标（fill=currentColor 染色；aria-hidden——无障碍语义由搭配的 wordmark 提供）
    public static func logo(size: CGFloat = 24) -> some View {
        let height = size * viewBox.height / viewBox.width
        return ZStack {
            fishPath
        }
        .frame(width: size, height: height)
    }

    static var fishPath: some View {
        Group {
            Path { p in
                p.addPath(PathGenerator.path(from: path, scaledTo: viewBox))
            }
            .fill(Color.primary)
            Path { p in
                p.addPath(PathGenerator.path(from: path2, scaledTo: viewBox))
            }
            .fill(Color.primary)
        }
    }
}

// MARK: - 星形品牌标（批10：原型 wanwo-ui-prototype.html hero h-fish 34px
// 四芒星 path 1:1——「M12 2L14.6 9.4L22 12L14.6 14.6L12 22L9.4 14.6L2 12L9.4
// 9.4L12 2Z」，viewBox 24×24；2026-09-22 用户令：鱼标换原型星形）

public enum WOBrandMark {
    public static let viewBox = CGSize(width: 24, height: 24)
    public static let path =
        "M12 2L14.6 9.4L22 12L14.6 14.6L12 22L9.4 14.6L2 12L9.4 9.4L12 2Z"

    /// 星形标（fill=currentColor 染色；正方形 viewBox——width=height=size）。
    public static func mark(size: CGFloat = 24) -> some View {
        Path { p in
            p.addPath(PathGenerator.path(from: path, scaledTo: viewBox))
        }
        .fill(Color.primary)
        .frame(width: size, height: size)
    }
}

/// dsh 矢量 path → SwiftUI Path 的最小解析（M/L/H/V/C/Z 子集；Figma 导出值 1:1）
enum PathGenerator {
    static func path(from d: String, scaledTo viewbox: CGSize) -> Path {
        var p = Path()
        var i = d.startIndex
        var current: CGPoint = .zero
        var numbers: [CGFloat] = []
        var command: Character = "M"

        func readNumber() -> CGFloat? {
            skipWhitespace()
            let start = i
            if i < d.endIndex, d[i] == "-" { i = d.index(after: i) }
            while i < d.endIndex, d[i].isNumber || d[i] == "." { i = d.index(after: i) }
            guard start != i, let v = Double(d[start..<i]) else { return nil }
            return CGFloat(v)
        }
        func skipWhitespace() {
            while i < d.endIndex, " \t\n\r".contains(d[i]) { i = d.index(after: i) }
        }
        func readNumbers(_ count: Int) -> Bool {
            numbers = []
            skipWhitespace()
            if i < d.endIndex, d[i] == "," { i = d.index(after: i) }
            for _ in 0..<count {
                guard let v = readNumber() else { return false }
                numbers.append(v)
                skipWhitespace()
                if i < d.endIndex, d[i] == "," { i = d.index(after: i) }
            }
            return true
        }

        while i < d.endIndex {
            let ch = d[i]
            if ch.isLetter {
                command = ch
                i = d.index(after: i)
            }
            switch command {
            case "M":
                guard readNumbers(2) else { return p }
                current = CGPoint(x: numbers[0], y: numbers[1]); p.move(to: current)
                command = "L"
            case "L":
                guard readNumbers(2) else { return p }
                current = CGPoint(x: numbers[0], y: numbers[1]); p.addLine(to: current)
            case "C":
                guard readNumbers(6) else { return p }
                let c1 = CGPoint(x: numbers[0], y: numbers[1])
                let c2 = CGPoint(x: numbers[2], y: numbers[3])
                let to = CGPoint(x: numbers[4], y: numbers[5])
                p.addCurve(to: to, control1: c1, control2: c2)
                current = to
            case "Z":
                // 字母消费已由上方 isLetter 分支完成——此处再 after 会越过 endIndex（启动闪退根因）
                p.closeSubpath()
            default:
                // 未知命令：跳过其参数直到下一个命令字母/endIndex（防死循环）
                while i < d.endIndex, !d[i].isLetter { i = d.index(after: i) }
            }
        }
        return p
    }
}

// MARK: - 行内引用域图标（7.2.7：session 内联手绘；file/folder 复用通用图标语义）

public enum WOReferenceKind: String {
    case session, file, folder
}

public struct WOReferenceIcon: View {
    public let kind: WOReferenceKind
    public var size: CGFloat = 16

    public init(kind: WOReferenceKind, size: CGFloat = 16) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        switch kind {
        case .session:
            Image(systemName: "bubble.left.and.bubble.right") // 会话引用专属语义（内联 glyph）
                .resizable().scaledToFit()
                .frame(width: size, height: size)
        case .file:
            Image(systemName: "doc") // IconBrowseOutline16 语义
                .resizable().scaledToFit()
                .frame(width: size, height: size)
        case .folder:
            Image(systemName: "folder") // IconFolderClose16 语义
                .resizable().scaledToFit()
                .frame(width: size, height: size)
        }
    }
    // 全部 fill=currentColor：SwiftUI 前景继承调用方颜色
}
