/*
 * MIT License
 *
 * Copyright (c) 2026 emexlab
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import Foundation

extension MDKDiagnosticType: Codable {}
extension MDKDiagnosticLevel: Codable {}

extension MDKSourceLocation: Codable {
    public static let zero: MDKSourceLocation = MDKSourceLocationZero
    
    enum CodingKeys: String, CodingKey {
        case isValid = "is_valid"
        case line
        case column
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isValid.boolValue, forKey: .isValid)
        try container.encode(line, forKey: .line)
        try container.encode(column, forKey: .column)
    }
    
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isValid = DarwinBoolean(try container.decode(Bool.self, forKey: .isValid))
        self.line = try container.decode(CFIndex.self, forKey: .line)
        self.column = try container.decode(CFIndex.self, forKey: .column)
    }
}

extension MDKFileType: Codable {
    public var isSwift: Bool {
        return self == .swift
    }
    
    public var isClang: Bool {
        let swift: MDKFileType = .swift
        return self.rawValue < swift.rawValue
    }
    
    public var isObject: Bool {
        return self == .object
    }
}
