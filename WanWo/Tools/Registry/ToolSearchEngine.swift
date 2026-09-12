//
//  ToolSearchEngine.swift
//  WanWo
//
//  【平台层自实现 · BM25】出处：bm25 crate v2.3.2（codex-rs Cargo.toml:318 锁定
//  `bm25 = "2.3.2"`；Cargo.lock 锁定同版本）——F023 tool_search 的本地检索底座。
//  对拍基准（crate 源码逐文件取证）：
//    · scorer.rs:99-107  idf = ln(1 + (N - df + 0.5) / (df + 0.5))
//    · embedder.rs:157-163  tf 饱和 value = tf·(k1+1) / (tf + k1·(1 - b + b·docLen/avgdl))，
//      k1=1.2 / b=0.75（:201/:244 默认值），avgdl=语料拟合，空语料回退 256（:129 FALLBACK_AVGDL）
//    · scorer.rs:79-97  matches = 含任一查询词的文档，按分降序
//    · search.rs:118-132  search = matches.take(limit)
//    · default_tokenizer.rs:272-287  分词序：normalize → lowercase → unicode 词边界
//      切分 → 停用词过滤 → 词干化
//  平台差异登记（详见实现件呈报，不逐条重复）：
//    1. embedding 空间 = token 字符串本体（crate 用 fxhash u32——哈希碰撞是实现
//       细节，字符串键严格更精、确定）；评分数值 f64（crate f32，精度差异无语义影响）
//    2. 分词近似：deunicode 全量 ASCII 化 → diacritic folding；unicode_words →
//       ICU UAX#29 (.byWords)；停用词 = NLTK English 词表（stop_words crate 英文表同源）
//    3. 词干化 = Porter1（crate 底层 rust_stemmers English = Snowball English /
//       Porter2——经典算法近似，登记）；非 ASCII token 不做词干化
//    4. 同分排序 tie-break = id 升序（crate 依赖 HashSet 无序迭代，非确定；
//       ERR-026 同纪律：检索结果必须逐次确定）
//

import Foundation

// MARK: - 分词器

/// BM25 分词器（bm25 crate DefaultTokenizer·English 模式的 WanWo 形态；
/// 纯函数，可单测）。处理序与 crate default_tokenizer.rs:272-287 一致：
/// 规范化 → 小写 → 词边界切分 → 停用词 → 词干化。
enum BM25Tokenizer {

    /// NLTK English 停用词表（stop_words crate 英文表同源，179 词含缩略形）。
    static let stopwords: Set<String> = [
        "i", "me", "my", "myself", "we", "our", "ours", "ourselves",
        "you", "you're", "you've", "you'll", "you'd", "your", "yours",
        "yourself", "yourselves",
        "he", "him", "his", "himself", "she", "she's", "her", "hers",
        "herself", "it", "it's", "its", "itself", "they", "them", "their",
        "theirs", "themselves", "what", "which", "who", "whom", "this",
        "that", "that'll", "these", "those", "am", "is", "are", "was",
        "were", "be", "been", "being", "have", "has", "had", "having",
        "do", "does", "did", "doing", "a", "an", "the", "and", "but",
        "if", "or", "because", "as", "until", "while", "of", "at", "by",
        "for", "with", "about", "against", "between", "into", "through",
        "during", "before", "after", "above", "below", "to", "from", "up",
        "down", "in", "out", "on", "off", "over", "under", "again",
        "further", "then", "once", "here", "there", "when", "where",
        "why", "how", "all", "any", "both", "each", "few", "more", "most",
        "other", "some", "such", "no", "nor", "not", "only", "own",
        "same", "so", "than", "too", "very", "s", "t", "can", "will",
        "just", "don", "don't", "should", "should've", "now", "d", "ll",
        "m", "o", "re", "ve", "y", "ain", "aren", "aren't", "couldn",
        "couldn't", "didn", "didn't", "doesn", "doesn't", "hadn", "hadn't",
        "hasn", "hasn't", "haven", "haven't", "isn", "isn't", "ma",
        "mightn", "mightn't", "mustn", "mustn't", "needn", "needn't",
        "shan", "shan't", "shouldn", "shouldn't", "wasn", "wasn't",
        "weren", "weren't", "won", "won't", "wouldn", "wouldn't",
    ]

    /// 文本 → 词元序列（空输入返回空）。
    static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // 1. 规范化：diacritic folding（crate 用 deunicode 全量 ASCII 化；
        //    emoji→词 的 deunicode 特性不移植，差异登记 #2）。
        let normalized = text.folding(options: .diacriticInsensitive, locale: nil)
        // 2. 小写（stemming 与 stopwords 的前提，crate :275-276）。
        let lowered = normalized.lowercased()
        // 3. UAX#29 词边界切分（crate 用 unicode_segmentation 的 unicode_words；
        //    ICU .byWords 同族语义——标点剥离、数字保留、撇号连写保留）。
        var tokens: [String] = []
        lowered.enumerateSubstrings(in: lowered.startIndex..<lowered.endIndex,
                                    options: .byWords) { substring, _, _, _ in
            guard let substring else { return }
            let token = String(substring)
            // 4. 停用词过滤（词干化之前，crate :280）。
            if !stopwords.contains(token) {
                tokens.append(token)
            }
        }
        // 5. 词干化（crate :282-285）。
        return tokens.map { PorterStemmer.stem($0) }
    }
}

// MARK: - Porter 词干化

/// Porter1 词干化（Porter 1980 经典算法；Snowball 参考实现的 Swift 移植）。
/// bm25 crate 底层 rust_stemmers English = Snowball English（Porter2），
/// 此处为经典算法近似（差异登记 #3）；非 ASCII 词元原样返回（CJK 无屈折）。
private enum PorterStemmer {

    /// 词干化入口（长度 ≤2 不处理——Snowball 契约）。
    static func stem(_ word: String) -> String {
        var chars = Array(word)
        guard chars.count > 2, chars.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return word
        }
        step1a(&chars)
        step1b(&chars)
        step1c(&chars)
        step2(&chars)
        step3(&chars)
        step4(&chars)
        step5a(&chars)
        step5b(&chars)
        return String(chars)
    }

    // MARK: Porter 原语

    /// 辅音判定（Porter 定义：非 aeiou 且非「前随辅音的 y」）。
    private static func isConsonant(_ w: [Character], _ i: Int) -> Bool {
        switch w[i] {
        case "a", "e", "i", "o", "u": return false
        case "y": return i == 0 ? true : !isConsonant(w, i - 1)
        default: return true
        }
    }

    /// m 度量 = [C](VC)^m[V]（区间 0..<end）。
    private static func measure(_ w: [Character], _ end: Int) -> Int {
        var m = 0
        var i = 0
        while i < end && isConsonant(w, i) { i += 1 }
        while i < end {
            while i < end && !isConsonant(w, i) { i += 1 }
            if i >= end { break }
            m += 1
            while i < end && isConsonant(w, i) { i += 1 }
        }
        return m
    }

    /// 词干（0..<end）含元音（*v* 条件）。
    private static func containsVowel(_ w: [Character], _ end: Int) -> Bool {
        (0..<max(0, end)).contains { !isConsonant(w, $0) }
    }

    /// *d 条件：双辅音收尾。
    private static func endsWithDoubleConsonant(_ w: [Character]) -> Bool {
        w.count >= 2 && w[w.count - 1] == w[w.count - 2]
            && isConsonant(w, w.count - 1)
    }

    /// *o 条件：cvc 收尾且末辅音非 w/x/y。
    private static func endsWithCVC(_ w: [Character]) -> Bool {
        guard w.count >= 3 else { return false }
        let n = w.count
        return isConsonant(w, n - 3) && !isConsonant(w, n - 2)
            && isConsonant(w, n - 1)
            && w[n - 1] != "w" && w[n - 1] != "x" && w[n - 1] != "y"
    }

    private static func endsWith(_ w: [Character], _ suffix: String) -> Bool {
        let s = Array(suffix)
        guard w.count >= s.count else { return false }
        return Array(w[(w.count - s.count)...]) == s
    }

    /// 后缀替换（调用方已确认 endsWith）。
    private static func replaceSuffix(_ w: inout [Character],
                                      _ suffix: String, _ replacement: String) {
        w.removeLast(suffix.count)
        w.append(contentsOf: replacement)
    }

    // MARK: 五步规则

    /// Step 1a：复数。
    private static func step1a(_ w: inout [Character]) {
        if endsWith(w, "sses") {
            replaceSuffix(&w, "sses", "ss")
        } else if endsWith(w, "ies") {
            replaceSuffix(&w, "ies", "i")
        } else if endsWith(w, "ss") {
            // ss 保持不动
        } else if endsWith(w, "s") {
            w.removeLast(1)
        }
    }

    /// Step 1b：eed / ed / ing 及其后置修复。
    private static func step1b(_ w: inout [Character]) {
        var stripped = false
        if endsWith(w, "eed") {
            if measure(w, w.count - 3) > 0 {
                replaceSuffix(&w, "eed", "ee")
            }
            return
        } else if endsWith(w, "ed"), containsVowel(w, w.count - 2) {
            w.removeLast(2)
            stripped = true
        } else if endsWith(w, "ing"), containsVowel(w, w.count - 3) {
            w.removeLast(3)
            stripped = true
        }
        guard stripped else { return }
        if endsWith(w, "at") || endsWith(w, "bl") || endsWith(w, "iz") {
            w.append("e")
        } else if endsWithDoubleConsonant(w)
                    && w.last != "l" && w.last != "s" && w.last != "z" {
            w.removeLast(1)
        } else if measure(w, w.count) == 1 && endsWithCVC(w) {
            w.append("e")
        }
    }

    /// Step 1c：*v* 收尾的 y → i。
    private static func step1c(_ w: inout [Character]) {
        if endsWith(w, "y"), containsVowel(w, w.count - 1) {
            w[w.count - 1] = "i"
        }
    }

    /// Step 2 后缀对（m(stem)>0；顺序 = Porter 论文步骤 2 表，长后缀在前——
    /// IZATION 先于 ATION、ATIONAL 先于 TIONAL）。
    private static let step2Pairs: [(String, String)] = [
        ("ational", "ate"), ("tional", "tion"), ("enci", "ence"),
        ("anci", "ance"), ("izer", "ize"), ("abli", "able"),
        ("alli", "al"), ("entli", "ent"), ("eli", "e"), ("ousli", "ous"),
        ("ization", "ize"), ("ation", "ate"), ("ator", "ate"),
        ("alism", "al"), ("iveness", "ive"), ("fulness", "ful"),
        ("ousness", "ous"), ("aliti", "al"), ("iviti", "ive"),
        ("biliti", "ble"), ("logi", "log"),
    ]

    private static func step2(_ w: inout [Character]) {
        for (suffix, replacement) in step2Pairs where endsWith(w, suffix) {
            if measure(w, w.count - suffix.count) > 0 {
                replaceSuffix(&w, suffix, replacement)
            }
            return
        }
    }

    /// Step 3 后缀对（m(stem)>0）。
    private static let step3Pairs: [(String, String)] = [
        ("icate", "ic"), ("ative", ""), ("alize", "al"), ("iciti", "ic"),
        ("ical", "ic"), ("ful", ""), ("ness", ""),
    ]

    private static func step3(_ w: inout [Character]) {
        for (suffix, replacement) in step3Pairs where endsWith(w, suffix) {
            if measure(w, w.count - suffix.count) > 0 {
                replaceSuffix(&w, suffix, replacement)
            }
            return
        }
    }

    /// Step 4：m>1 的高频后缀删除（ion 额外要求词干收 s/t）。
    private static let step4Suffixes = [
        "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement",
        "ment", "ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive",
        "ize",
    ]

    private static func step4(_ w: inout [Character]) {
        for suffix in step4Suffixes where endsWith(w, suffix) {
            let stemEnd = w.count - suffix.count
            guard measure(w, stemEnd) > 1 else { return }
            if suffix == "ion" {
                let stemLast = w[stemEnd - 1]
                guard stemEnd > 0, stemLast == "s" || stemLast == "t" else {
                    return
                }
            }
            w.removeLast(suffix.count)
            return
        }
    }

    /// Step 5a：词尾 e 处置。
    private static func step5a(_ w: inout [Character]) {
        guard let last = w.last, last == "e" else { return }
        let stem = Array(w[0..<(w.count - 1)])
        let m = measure(stem, stem.count)
        if m > 1 {
            w.removeLast(1)
        } else if m == 1 && !endsWithCVC(stem) {
            w.removeLast(1)
        }
    }

    /// Step 5b：m>1 且 *d 且 *L → 单 l。
    private static func step5b(_ w: inout [Character]) {
        if measure(w, w.count) > 1 && endsWithDoubleConsonant(w) && w.last == "l" {
            w.removeLast(1)
        }
    }
}

// MARK: - 检索引擎

/// BM25 检索引擎（bm25 crate SearchEngine 的 WanWo 形态；不可变语料构建期
/// 一次性拟合，查询纯读——值类型天然 Sendable）。
struct ToolSearchEngine: Sendable {

    /// 一条命中（id = 语料构建序；score 仅供测试/排序，不上 wire）。
    struct Hit: Equatable, Sendable {
        let id: Int
        let score: Double
    }

    /// crate embedder.rs:201/:244 默认参数。
    private static let k1: Double = 1.2
    private static let b: Double = 0.75
    /// crate embedder.rs:129 FALLBACK_AVGDL（空语料/零总词元回退）。
    private static let fallbackAvgdl: Double = 256.0

    /// 每文档 token → tf 饱和值（embedder 拟合产物）。
    private let docTokenValues: [[String: Double]]
    /// 倒排索引：token → 含它的文档集（scorer.rs:25 inverted_token_index）。
    private let invertedIndex: [String: Set<Int>]
    private let docCount: Int

    /// 以语料 searchText 列表构建（crate SearchEngineBuilder.with_documents 的
    /// fit-to-corpus 语义：avgdl=语料平均词元数）。
    init(texts: [String]) {
        let tokenLists = texts.map { BM25Tokenizer.tokenize($0) }
        let totalTokens = tokenLists.reduce(0) { $0 + $1.count }
        let avgdl: Double
        if texts.isEmpty || totalTokens == 0 {
            avgdl = Self.fallbackAvgdl
        } else {
            avgdl = Double(totalTokens) / Double(texts.count)
        }

        var docValues: [[String: Double]] = []
        var index: [String: Set<Int>] = [:]
        for (id, tokens) in tokenLists.enumerated() {
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            var values: [String: Double] = [:]
            for (token, tf) in counts {
                values[token] = Self.tfValue(tf: Double(tf),
                                             docLen: Double(tokens.count),
                                             avgdl: avgdl)
            }
            for token in counts.keys {
                index[token, default: []].insert(id)
            }
            docValues.append(values)
        }
        self.docTokenValues = docValues
        self.invertedIndex = index
        self.docCount = texts.count
    }

    /// tf 饱和值（crate embedder.rs:157-163 逐式移植）。
    private static func tfValue(tf: Double, docLen: Double, avgdl: Double) -> Double {
        let numerator = tf * (k1 + 1.0)
        let denominator = tf + k1 * (1.0 - b + b * (docLen / avgdl))
        return numerator / denominator
    }

    /// IDF（crate scorer.rs:99-107 逐式移植）。
    func idf(_ token: String) -> Double {
        let df = Double(invertedIndex[token]?.count ?? 0)
        let n = Double(docCount)
        return Foundation.log(1.0 + (n - df + 0.5) / (df + 0.5))
    }

    /// 检索：返回按分降序、limit 截断的命中（crate search.rs:118-132 语义；
    /// 同分 tie-break = id 升序——确定性纪律，差异登记 #4）。
    func search(_ query: String, limit: Int) -> [Hit] {
        let queryTokens = BM25Tokenizer.tokenize(query)
        guard docCount > 0, limit > 0, !queryTokens.isEmpty else { return [] }

        // 候选集 = 含任一查询词的文档（scorer.rs:80-86 倒排并集）。
        var candidates = Set<Int>()
        for token in queryTokens {
            if let docs = invertedIndex[token] {
                candidates.formUnion(docs)
            }
        }

        // 评分：Σ 查询词元逐出现 idf·docValue（重复查询词重复计分——
        // crate embedding 逐出现携带 TokenEmbedding 的等价实现）。
        var hits: [Hit] = []
        hits.reserveCapacity(candidates.count)
        for id in candidates {
            var score = 0.0
            let values = docTokenValues[id]
            for token in queryTokens {
                score += idf(token) * (values?[token] ?? 0.0)
            }
            if score > 0 {
                hits.append(Hit(id: id, score: score))
            }
        }
        return hits
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
            .prefix(limit)
            .map { $0 }
    }
}
