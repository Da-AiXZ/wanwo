//
//  ToolSearchEngineTests.swift
//  WanWoTests
//
//  【M4-C1 测试锚】ToolSearchEngine（Swift BM25）对拍单测——对拍基准 =
//  bm25 crate v2.3.2 源码测试（repos/bm25-2.3.2/src/{default_tokenizer,scorer,
//  search}.rs 同款断言移植）+ Porter 词干化行为锚。
//  纪律：纯函数判定面（无 IO、无并发竞态），全部确定性断言。
//

import XCTest
@testable import WanWo

final class ToolSearchEngineTests: XCTestCase {

    // MARK: 分词器（bm25 default_tokenizer.rs 测试移植）

    /// lowercase + 标点剥离（crate it_converts_to_lowercase / it_removes_punctuation）。
    func testTokenizeLowercasesAndDropsPunctuation() {
        XCTAssertEqual(BM25Tokenizer.tokenize("Space, Station!"), ["space", "station"])
        XCTAssertEqual(BM25Tokenizer.tokenize("SPACE STATION"), ["space", "station"])
    }

    /// 空白杂讯剥离（crate it_removes_whitespace）。
    func testTokenizeStripsWhitespaceNoise() {
        XCTAssertEqual(BM25Tokenizer.tokenize("\tspace\r\nstation\n  station"),
                       ["space", "station", "station"])
    }

    /// 停用词过滤（crate it_removes_stopwords——NLTK 表开头逐词）。
    func testTokenizeRemovesEnglishStopwords() {
        XCTAssertEqual(
            BM25Tokenizer.tokenize("i me my myself we our ours ourselves you"),
            [])
    }

    /// 数字保留（crate it_keeps_numbers——整数词元）。
    func testTokenizeKeepsNumbers() {
        XCTAssertEqual(BM25Tokenizer.tokenize("42 1337"), ["42", "1337"])
    }

    /// 词干化（crate it_stems_words 同款词族收敛）。
    func testTokenizeStemsEnglishInflections() {
        XCTAssertEqual(
            BM25Tokenizer.tokenize("connection connections connected connecting connect"),
            Array(repeating: "connect", count: 5))
    }

    /// diacritic folding（crate normalize 的平台近似——é→e 同族；
    /// "cafe" 走 step5a 时 m=1 且 *o 成立（cvc 收尾）→ e 保留）。
    func testTokenizeFoldsDiacritics() {
        XCTAssertEqual(BM25Tokenizer.tokenize("café"), ["cafe"])
    }

    /// 空输入回空。
    func testTokenizeEmptyInput() {
        XCTAssertEqual(BM25Tokenizer.tokenize(""), [])
    }

    /// Porter 步骤抽查（经典算法已知结果——逐式 trace 核对）：
    /// sses→ss；ing 剥离后双辅音非 lsz 收单；eed 在 m>0 时→ee。
    func testPorterKnownResults() {
        XCTAssertEqual(BM25Tokenizer.tokenize("caresses"), ["caress"])
        XCTAssertEqual(BM25Tokenizer.tokenize("running"), ["run"])
        XCTAssertEqual(BM25Tokenizer.tokenize("agreed"), ["agree"])
    }

    // MARK: 引擎（bm25 search.rs / scorer.rs 测试移植）

    private func makeEngine(_ corpus: [String]) -> ToolSearchEngine {
        ToolSearchEngine(texts: corpus)
    }

    /// 无交集查询回空（crate search_does_not_return_unrelated_documents）。
    func testSearchDoesNotReturnUnrelatedDocuments() {
        let engine = makeEngine(["space station", "bacon and avocado sandwich"])
        XCTAssertTrue(engine.search("maths and computer science", limit: 5).isEmpty)
    }

    /// 相关文档命中且分数为正（crate search_returns_relevant_documents）。
    func testSearchReturnsRelevantDocuments() {
        let engine = makeEngine(["space station", "bacon and avocado sandwich"])
        let results = engine.search("sandwich with bacon", limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, 1)
        XCTAssertGreaterThan(results[0].score, 0)
    }

    /// 稀有词命中分高于常见词（crate scorer it_scores_rare_indices_higher_than_common_ones）。
    func testRareTokenOutranksCommonToken() {
        let engine = makeEngine(["alpha beta", "alpha beta", "gamma delta"])
        let commonScore = engine.search("alpha", limit: 5)[0].score
        let rareScore = engine.search("gamma", limit: 5)[0].score
        XCTAssertGreaterThan(rareScore, commonScore,
                             "BM25 must score rare token matches higher than common ones")
    }

    /// 短文档同命中排前（crate it_ranks_shorter_documents_higher）。
    func testShorterDocumentOutranksLongerOnSameMatch() {
        let engine = makeEngine([
            "correct horse battery staple bacon bacon bacon",
            "correct horse battery staple",
        ])
        let results = engine.search("staple", limit: 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, 1)
        XCTAssertEqual(results[1].id, 0)
        XCTAssertGreaterThan(results[0].score, results[1].score)
    }

    /// 结果按分降序（crate it_returns_results_sorted_by_score）。
    func testResultsSortedByScoreDescending() {
        let engine = makeEngine([
            "create calendar events and reminders",
            "create calendar event",
            "calendar sync widget",
        ])
        let results = engine.search("create calendar event", limit: 5)
        XCTAssertGreaterThanOrEqual(results.count, 2)
        for pair in zip(results, results.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.score, pair.1.score)
        }
    }

    /// limit 截断。
    func testLimitTruncatesResults() {
        let engine = makeEngine([
            "widget alpha", "widget beta", "widget gamma",
        ])
        XCTAssertEqual(engine.search("widget", limit: 2).count, 2)
        XCTAssertEqual(engine.search("widget", limit: 10).count, 3)
    }

    /// 逐次确定性（同语料同查询 → 同结果序列；差异登记 #4 tie-break=id 升序）。
    func testRepeatedSearchIsDeterministic() {
        let engine = makeEngine([
            "calendar create event", "calendar list events", "event reminder tool",
        ])
        let first = engine.search("calendar event", limit: 3)
        let second = engine.search("calendar event", limit: 3)
        XCTAssertEqual(first, second)
    }

    /// 空语料 / 空查询 / limit 0 → 回空。
    func testDegenerateInputsReturnEmpty() {
        XCTAssertTrue(makeEngine([]).search("anything", limit: 5).isEmpty)
        XCTAssertTrue(makeEngine(["space station"]).search("", limit: 5).isEmpty)
        XCTAssertTrue(makeEngine(["space station"]).search("space", limit: 0).isEmpty)
    }

    /// IDF 公式抽查（crate scorer.rs:99-107：N=1、df=1 → ln(2)）。
    func testIdfSingleDocumentFormula() {
        let engine = makeEngine(["space"])
        XCTAssertEqual(engine.idf("space"), Foundation.log(2.0), accuracy: 1e-9)
    }
}
