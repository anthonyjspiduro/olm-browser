import Foundation

struct MessageRemoteContentIdentity: Hashable, Sendable {
    let archiveSessionID: UUID
    let messageID: String
    let folderID: String
}

struct RemoteImageApprovalState: Equatable, Sendable {
    private(set) var approvedMessage: MessageRemoteContentIdentity?

    func isApproved(for message: MessageRemoteContentIdentity) -> Bool {
        approvedMessage == message
    }

    mutating func approve(_ message: MessageRemoteContentIdentity) {
        approvedMessage = message
    }

    mutating func block() {
        approvedMessage = nil
    }

    mutating func selectionChanged(to message: MessageRemoteContentIdentity) {
        guard approvedMessage != nil, approvedMessage != message else { return }
        approvedMessage = nil
    }
}

struct RemoteImagePolicy: Equatable, Sendable {
    let httpsOrigins: [String]
    let insecureHTTPResourceCount: Int

    var hasRemoteImages: Bool {
        !httpsOrigins.isEmpty || insecureHTTPResourceCount > 0
    }

    static func inspect(_ html: String) -> RemoteImagePolicy {
        var candidates: [String] = []

        for tag in matchingStrings(pattern: #"(?is)<\s*(?:img|image)\b[^>]*>"#, in: html) {
            candidates.append(contentsOf: imageAttributeURLs(in: tag, attributes: ["src", "srcset", "href", "xlink:href"]))
            candidates.append(contentsOf: imageStyleURLs(in: attributeValue(named: "style", in: tag) ?? ""))
        }

        for tag in matchingStrings(pattern: #"(?is)<\s*source\b[^>]*>"#, in: html) {
            candidates.append(contentsOf: imageAttributeURLs(in: tag, attributes: ["srcset"]))
        }

        for tag in matchingStrings(pattern: #"(?is)<\s*input\b[^>]*>"#, in: html)
        where attributeValue(named: "type", in: tag)?.lowercased() == "image" {
            candidates.append(contentsOf: imageAttributeURLs(in: tag, attributes: ["src"]))
        }

        for style in matchingCaptureGroup(
            pattern: #"(?is)<\s*style\b[^>]*>(.*?)<\s*/\s*style\s*>"#,
            in: html
        ) {
            candidates.append(contentsOf: imageStyleURLs(in: style))
        }

        for tag in matchingStrings(pattern: #"(?is)<[^>]+\bstyle\s*=[^>]+>"#, in: html) {
            if let style = attributeValue(named: "style", in: tag) {
                candidates.append(contentsOf: imageStyleURLs(in: style))
            }
        }

        var httpsOrigins = Set<String>()
        var insecureHTTPResources = Set<String>()
        for candidate in candidates {
            guard let components = URLComponents(string: decodeHTMLEntities(candidate)),
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host?.lowercased(),
                  !host.isEmpty else { continue }
            if scheme == "https", let origin = cspOrigin(host: host, port: components.port) {
                httpsOrigins.insert(origin)
            } else if scheme == "http" {
                insecureHTTPResources.insert(candidate)
            }
        }

        return RemoteImagePolicy(
            httpsOrigins: httpsOrigins.sorted(),
            insecureHTTPResourceCount: insecureHTTPResources.count
        )
    }

    static func sanitizedCSPOrigins(_ candidates: [String]) -> [String] {
        Array(Set(candidates.compactMap { candidate in
            guard let components = URLComponents(string: candidate),
                  components.scheme?.lowercased() == "https",
                  let host = components.host?.lowercased(),
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  components.path.isEmpty || components.path == "/" else { return nil }
            return cspOrigin(host: host, port: components.port)
        })).sorted()
    }

    private static func imageAttributeURLs(in tag: String, attributes: Set<String>) -> [String] {
        var result: [String] = []
        for attribute in attributes {
            guard let value = attributeValue(named: attribute, in: tag) else { continue }
            if attribute == "srcset" {
                result.append(contentsOf: value.split(separator: ",").compactMap { candidate in
                    candidate.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                })
            } else {
                result.append(value)
            }
        }
        return result
    }

    private static func imageStyleURLs(in css: String) -> [String] {
        let declarations = matchingCaptureGroup(
            pattern: #"(?is)(?:background(?:-image)?|border-image(?:-source)?|list-style(?:-image)?|content|cursor|mask(?:-image)?)\s*:[^;}]*"#,
            in: css,
            captureGroup: 0
        )
        return declarations.flatMap { declaration in
            matchingCaptureGroup(
                pattern: #"(?is)url\(\s*(?:\"([^\"]*)\"|'([^']*)'|([^)'\"\s]+))\s*\)"#,
                in: declaration,
                firstNonemptyCaptureGroup: 1...3
            )
        }
    }

    private static func attributeValue(named name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?is)(?:^|\s)"# + escapedName + #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
        return matchingCaptureGroup(
            pattern: pattern,
            in: tag,
            firstNonemptyCaptureGroup: 1...3
        ).first
    }

    private static func cspOrigin(host: String, port: Int?) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:")
        guard host.unicodeScalars.allSatisfy(allowed.contains),
              !host.contains(".."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        if let port {
            guard (1...65_535).contains(port) else { return nil }
            return "https://\(renderedHost):\(port)"
        }
        return "https://\(renderedHost)"
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&#38;", with: "&", options: .caseInsensitive)
    }

    private static func matchingStrings(pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private static func matchingCaptureGroup(
        pattern: String,
        in value: String,
        captureGroup: Int = 1,
        firstNonemptyCaptureGroup: ClosedRange<Int>? = nil
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            let groups = firstNonemptyCaptureGroup ?? captureGroup...captureGroup
            for group in groups where group < match.numberOfRanges {
                let matchedRange = match.range(at: group)
                if matchedRange.location != NSNotFound,
                   let swiftRange = Range(matchedRange, in: value), !swiftRange.isEmpty {
                    return String(value[swiftRange])
                }
            }
            return nil
        }
    }
}
