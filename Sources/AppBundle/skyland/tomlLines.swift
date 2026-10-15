// skyland: read and change one `key = value` line of the TOML config without
// rewriting the file, so comments, order and formatting stay as the user wrote
// them. Enough for the settings window: scalar values (numbers, booleans,
// single or double quoted strings without '#'). Section "" is the top level.

/// Value text of `key` in `[section]`, quotes kept, trailing comment removed.
func tomlValue(_ text: String, section: String, key: String) -> String? {
    var current = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if let header = tomlHeader(line) { current = header; continue }
        if current == section, let value = tomlLineValue(line, key: key) { return value }
    }
    return nil
}

/// `text` with `key` of `[section]` set to `value` (raw TOML: `12`, `true`, `'x'`).
/// A missing key is added after the last key of the section (top level: before the
/// first table); a missing section is appended.
func tomlSet(_ text: String, section: String, key: String, value: String) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var current = ""
    var lastKeyLine: Int? = nil
    var sectionFound = section == ""
    var firstHeader: Int? = nil
    for (index, line) in lines.enumerated() {
        if let header = tomlHeader(Substring(line)) {
            if firstHeader == nil { firstHeader = index }
            current = header
            if header == section { sectionFound = true; lastKeyLine = index }
            continue
        }
        guard current == section else { continue }
        if tomlLineValue(Substring(line), key: key) != nil {
            let start = line.range(of: "=")!.upperBound
            let rest = line[start...]
            let comment = tomlCommentStart(rest).map { " " + rest[$0...] } ?? ""
            lines[index] = String(line[..<start]) + " " + value + comment
            return lines.joined(separator: "\n")
        }
        if line.contains("="), !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { lastKeyLine = index }
    }
    let newLine = "\(key) = \(value)"
    if !sectionFound {
        if lines.last == "" { lines.removeLast() }
        lines += ["", "[\(section)]", newLine, ""]
    } else if let lastKeyLine {
        lines.insert(newLine, at: lastKeyLine + 1)
    } else {
        lines.insert(newLine, at: firstHeader ?? lines.count)
    }
    return lines.joined(separator: "\n")
}

/// `name` of a `[name]` header line, `[[name]]` for an array of tables header, nil otherwise.
private func tomlHeader(_ line: Substring) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("[[") { return trimmed }
    guard trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") else { return nil }
    return String(trimmed[trimmed.index(after: trimmed.startIndex) ..< end])
}

private func tomlLineValue(_ line: Substring, key: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(key), let equal = trimmed.firstIndex(of: "="),
          trimmed[..<equal].trimmingCharacters(in: .whitespaces) == key else { return nil }
    var value = trimmed[trimmed.index(after: equal)...]
    if let hash = tomlCommentStart(value) { value = value[..<hash] }
    return value.trimmingCharacters(in: .whitespaces)
}

struct TomlEntry: Equatable {
    var key: String
    var value: String // raw TOML
    var comment: String // trailing comment text, without '#'
}

/// `key = value # comment` lines of `[section]`, in file order.
func tomlEntries(_ text: String, section: String) -> [TomlEntry] {
    var current = ""
    var result: [TomlEntry] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if let header = tomlHeader(line) { current = header; continue }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard current == section, !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { continue }
        let key = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
        var rest = trimmed[trimmed.index(after: equal)...]
        var comment = ""
        if let hash = tomlCommentStart(rest) {
            comment = rest[rest.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            rest = rest[..<hash]
        }
        result.append(TomlEntry(key: key, value: rest.trimmingCharacters(in: .whitespaces), comment: comment))
    }
    return result
}

/// Replace the whole `key` line of `[section]` with `entry` (rename, new value, new
/// comment), or remove it when `entry` is nil. Unchanged text if the key is missing.
func tomlReplace(_ text: String, section: String, key: String, with entry: TomlEntry?) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var current = ""
    for (index, line) in lines.enumerated() {
        if let header = tomlHeader(Substring(line)) { current = header; continue }
        guard current == section, tomlLineValue(Substring(line), key: key) != nil else { continue }
        if let entry {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            lines[index] = "\(indent)\(entry.key) = \(entry.value)" + (entry.comment.isEmpty ? "" : " # \(entry.comment)")
        } else {
            lines.remove(at: index)
        }
        break
    }
    return lines.joined(separator: "\n")
}

/// First '#' outside quotes.
private func tomlCommentStart(_ text: Substring) -> Substring.Index? {
    var quote: Character? = nil
    for index in text.indices {
        let char = text[index]
        if let open = quote { if char == open { quote = nil } }
        else if char == "'" || char == "\"" { quote = char }
        else if char == "#" { return index }
    }
    return nil
}
