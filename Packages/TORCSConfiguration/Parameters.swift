// SPDX-License-Identifier: GPL-2.0-only
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct NumericParameter: Equatable, Sendable {
    public let value: Float
    public let minimum: Float
    public let maximum: Float
    public let unit: String
}
public enum Parameter: Equatable, Sendable {
    case number(NumericParameter)
    case string(String, allowed: [String])
}
public struct ParameterSection: Equatable, Sendable {
    public let name: String
    public let parameters: [String: Parameter]
    public let sections: [ParameterSection]
    /// Public so a schema adapter can build an equivalent tree without going
    /// back through XML. Parsing remains the only way to read a file.
    public init(name: String, parameters: [String: Parameter] = [:], sections: [ParameterSection] = []) {
        self.name = name; self.parameters = parameters; self.sections = sections
    }
    public func section(_ path: String) -> ParameterSection? {
        let components = path.split(separator: "/").map(String.init)
        return components.reduce(Optional(self)) { parent, name in parent?.sections.first { $0.name == name } }
    }
    public func number(_ key: String, unit: String? = nil, default fallback: Float) -> Float {
        guard case .number(let n) = parameters[key] else { return fallback }
        return unit.map { Units.fromSI(n.value, unit: $0) } ?? n.value
    }
    public func string(_ key: String, default fallback: String = "") -> String {
        guard case .string(let value, _) = parameters[key] else { return fallback }
        return value
    }
}
public struct ParameterDocument: Equatable, Sendable {
    public let name: String
    public let root: ParameterSection
    public init(name: String, root: ParameterSection) { self.name = name; self.root = root }
    public func section(_ path: String) -> ParameterSection? { root.section(path) }

    /// Safe external entities are explicit in-memory entries, keyed by entity name.
    /// External DTDs are never fetched. Unknown entities are errors, never dropped.
    public static func parse(_ data: Data, entities: [String: Data] = [:], allowLegacyLatin1: Bool = false) throws -> Self {
        func decode(_ data: Data) -> String? {
            String(data: data, encoding: .utf8) ?? (allowLegacyLatin1 ? String(data: data, encoding: .isoLatin1) : nil)
        }
        guard data.count <= 16 * 1024 * 1024, var xml = decode(data) else {
            throw ParameterError.invalid("Expected UTF-8 XML smaller than 16 MiB")
        }
        if let start = xml.range(of: "<!DOCTYPE") {
            var quote: Character?, depth = 0, end: String.Index?
            var i = start.upperBound
            while i < xml.endIndex {
                let c = xml[i]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == "[" { depth += 1 }
                else if c == "]" { depth -= 1 }
                else if c == ">" && depth == 0 { end = xml.index(after: i); break }
                i = xml.index(after: i)
            }
            guard let end else { throw ParameterError.invalid("Unclosed DOCTYPE") }
            let dtd = String(xml[start.lowerBound..<end])
            // Only named external SYSTEM entities are supported; no nested or parameter entities.
            let declarations = try NSRegularExpression(pattern: "<!ENTITY\\s+([A-Za-z_][A-Za-z0-9_.-]*)\\s+SYSTEM\\s+[\"'][^\"']+[\"']\\s*>")
            let matches = declarations.matches(in: dtd, range: NSRange(dtd.startIndex..., in: dtd))
            let leftover = declarations.stringByReplacingMatches(in: dtd, range: NSRange(dtd.startIndex..., in: dtd), withTemplate: "")
            guard !leftover.contains("<!ENTITY") else { throw ParameterError.invalid("Unsupported entity declaration") }
            xml.removeSubrange(start.lowerBound..<end)
            for match in matches {
                let name = String(dtd[Range(match.range(at: 1), in: dtd)!])
                guard let bytes = entities[name], bytes.count <= 4 * 1024 * 1024,
                      var expansion = decode(bytes),
                      !expansion.contains("<!ENTITY"), !expansion.contains("<!DOCTYPE") else {
                    throw ParameterError.invalid("Missing or unsafe local entity: \(name)")
                }
                // External parsed entities may have a text declaration of their own.
                if expansion.hasPrefix("<?xml"), let end = expansion.range(of: "?>") {
                    expansion.removeSubrange(expansion.startIndex..<end.upperBound)
                }
                guard !expansion.contains("<?xml") else { throw ParameterError.invalid("Misplaced XML declaration in \(name)") }
                // Bound expansion before allocating it.
                let occurrences = xml.components(separatedBy: "&\(name);").count - 1
                guard xml.utf8.count + occurrences * bytes.count <= 16 * 1024 * 1024 else {
                    throw ParameterError.invalid("Expanded XML exceeds 16 MiB")
                }
                xml = xml.replacingOccurrences(of: "&\(name);", with: expansion)
            }
        }
        let delegate = ParameterParser()
        let parser = XMLParser(data: Data(xml.utf8)); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil, let result = delegate.result else {
            throw delegate.failure ?? ParameterError.invalid(parser.parserError?.localizedDescription ?? "Missing params root")
        }
        return result
    }

    public func xmlData() -> Data {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func body(_ section: ParameterSection, indent: String) -> String {
            var out = ""
            for key in section.parameters.keys.sorted() {
                switch section.parameters[key]! {
                case .number(let n):
                    // Store SI values and omit the unit to avoid a lossy conversion round trip.
                    out += "\(indent)<attnum name=\"\(escape(key))\" val=\"\(n.value)\" min=\"\(n.minimum)\" max=\"\(n.maximum)\"/>\n"
                case .string(let value, let allowed):
                    let within = allowed.isEmpty ? "" : " in=\"\(escape(allowed.joined(separator: ",")))\""
                    out += "\(indent)<attstr name=\"\(escape(key))\" val=\"\(escape(value))\"\(within)/>\n"
                }
            }
            for child in section.sections {
                out += "\(indent)<section name=\"\(escape(child.name))\">\n" + body(child, indent: indent + "  ") + "\(indent)</section>\n"
            }
            return out
        }
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<params name=\"\(escape(name))\">\n" + body(root, indent: "  ") + "</params>\n").utf8)
    }
}

public enum ParameterError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): message } }
}

private final class ParameterParser: NSObject, XMLParserDelegate {
    struct Builder {
        var name: String
        var parameters: [String: Parameter] = [:]
        var sections: [ParameterSection] = []
        /// Parameters repeated within this section. The first occurrence wins,
        /// matching the original parser; retained so the fact is observable.
        var duplicates: Set<String> = []
    }
    var stack: [Builder] = []
    var elements: [String] = []
    var result: ParameterDocument?
    var failure: ParameterError?
    var count = 0
    func numeric(_ text: String) -> Float? {
        if text.hasPrefix("0x"), let integer = UInt64(text.dropFirst(2), radix: 16) { return Float(integer) }
        return Float(text)
    }
    func fail(_ parser: XMLParser, _ message: String) { failure = .invalid("Line \(parser.lineNumber): \(message)"); parser.abortParsing() }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        count += 1
        guard count <= 200_000, elements.count < 64 else { fail(parser, "XML size/depth limit exceeded"); return }
        let parent = elements.last
        elements.append(element)
        guard let name = a["name"], !name.isEmpty else { fail(parser, "Missing name on \(element)"); return }
        switch element {
        case "params":
            guard parent == nil, result == nil else { fail(parser, "Invalid params nesting"); return }
            stack.append(Builder(name: name))
        case "section":
            guard parent == "params" || parent == "section", !name.contains("/"),
                  !stack[stack.count - 1].sections.contains(where: { $0.name == name }) else {
                fail(parser, "Invalid or duplicate section \(name)"); return
            }
            stack.append(Builder(name: name))
        case "attnum", "attstr":
            guard parent == "section" || parent == "params", let value = a["val"] else {
                fail(parser, "Invalid parameter \(name)"); return
            }
            // A repeated parameter is not an error upstream. GfParmReadFile
            // appends to a hash bucket without checking for duplicates and
            // resolves lookups from the head of that bucket, so the first
            // occurrence in document order is the one that takes effect. Some
            // shipped tracks rely on this: dirt-6 declares `profil` twice in
            // two of its segments. Rejecting the file makes that content
            // unloadable for no benefit.
            guard stack[stack.count - 1].parameters[name] == nil else {
                stack[stack.count - 1].duplicates.insert(name)
                return
            }
            if element == "attstr" {
                stack[stack.count - 1].parameters[name] = .string(value, allowed: a["in"]?.components(separatedBy: ",").filter { !$0.isEmpty } ?? [])
            } else {
                guard let value = numeric(value), value.isFinite,
                      let lo = numeric(a["min"] ?? a["val"]!), lo.isFinite,
                      let hi = numeric(a["max"] ?? a["val"]!), hi.isFinite else { fail(parser, "Invalid number \(name)"); return }
                let unit = a["unit"] ?? ""
                let v = Units.toSI(value, unit: unit), minimum = Units.toSI(min(lo, value), unit: unit), maximum = Units.toSI(max(hi, value), unit: unit)
                guard v.isFinite, minimum.isFinite, maximum.isFinite else { fail(parser, "Unit conversion overflow \(name)"); return }
                stack[stack.count - 1].parameters[name] = .number(.init(value: v, minimum: minimum, maximum: maximum, unit: unit))
            }
        default: fail(parser, "Unsupported element \(element)")
        }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard failure == nil else { return }
        elements.removeLast()
        if element == "params" || element == "section" {
            let b = stack.removeLast()
            let section = ParameterSection(name: b.name, parameters: b.parameters, sections: b.sections)
            if element == "params" { result = ParameterDocument(name: b.name, root: section) }
            else { stack[stack.count - 1].sections.append(section) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail(parser, "Unexpected text") }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(parser, "Unresolved external entity \(name)"); return nil
    }
}
