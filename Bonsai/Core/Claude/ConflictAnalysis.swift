import Foundation

enum ConflictAnalysis {
    enum Segment: Equatable {
        case common([String])
        case conflict(main: [String], branch: [String])
    }

    static let context = 2

    static func segments(_ text: String) -> [Segment]? {
        var result: [Segment] = []
        var common: [String] = []
        var main: [String] = []
        var branch: [String] = []
        enum State { case common, main, base, branch }
        var state = State.common
        for line in lines(text) {
            switch state {
            case .common:
                if line.hasPrefix("<<<<<<<") {
                    if !common.isEmpty { result.append(.common(common)) }
                    common = []
                    state = .main
                } else {
                    common.append(line)
                }
            case .main:
                if line.hasPrefix("|||||||") { state = .base }
                else if line.hasPrefix("=======") { state = .branch }
                else { main.append(line) }
            case .base:
                if line.hasPrefix("=======") { state = .branch }
            case .branch:
                if line.hasPrefix(">>>>>>>") {
                    result.append(.conflict(main: main, branch: branch))
                    main = []
                    branch = []
                    state = .common
                } else {
                    branch.append(line)
                }
            }
        }
        guard state == .common else { return nil }
        if !common.isEmpty { result.append(.common(common)) }
        return result
    }

    static func analyze(conflicted: String, resolved: String) -> [ResolvedConflict]? {
        guard let segments = segments(conflicted), segments.contains(where: { if case .conflict = $0 { true } else { false } }) else { return nil }
        let out = lines(resolved)
        var position = 0
        var pending: (main: [String], branch: [String])?
        var result: [ResolvedConflict] = []

        func close(until end: Int) {
            guard let conflict = pending else { return }
            result.append(classify(main: conflict.main, branch: conflict.branch, resolved: out, range: position..<end))
            pending = nil
        }

        for segment in segments {
            switch segment {
            case .common(let block):
                guard let found = find(block, in: out, from: position) else { return nil }
                if pending != nil { close(until: found) } else if found != position { return nil }
                position = found + block.count
            case .conflict(let main, let branch):
                if pending != nil { return nil }
                pending = (main, branch)
            }
        }
        close(until: out.count)
        return result
    }

    static func classify(main: [String], branch: [String], resolved: [String], range: Range<Int>) -> ResolvedConflict {
        let mainSet = Set(main.map(normalize))
        let branchSet = Set(branch.map(normalize))
        var lines: [ResolvedConflict.Line] = []
        for index in max(0, range.lowerBound - context)..<range.lowerBound {
            lines.append(.init(number: index + 1, text: resolved[index], origin: .context))
        }
        var kept = Set<String>()
        var usedMain = false, usedBranch = false, own = false
        for index in range {
            let text = resolved[index]
            let key = normalize(text)
            kept.insert(key)
            let origin: ResolvedConflict.Line.Origin
            if mainSet.contains(key) && branchSet.contains(key) {
                origin = .context
            } else if mainSet.contains(key) {
                origin = .main
                usedMain = true
            } else if branchSet.contains(key) {
                origin = .branch
                usedBranch = true
            } else if key.isEmpty {
                origin = .context
            } else {
                origin = .own
                own = true
            }
            lines.append(.init(number: index + 1, text: text, origin: origin))
        }
        for index in range.upperBound..<min(resolved.count, range.upperBound + context) {
            lines.append(.init(number: index + 1, text: resolved[index], origin: .context))
        }
        var dropped: [ResolvedConflict.Line] = []
        for line in main where !kept.contains(normalize(line)) && !normalize(line).isEmpty {
            dropped.append(.init(number: nil, text: line, origin: .main))
        }
        for line in branch where !kept.contains(normalize(line)) && !normalize(line).isEmpty {
            dropped.append(.init(number: nil, text: line, origin: .branch))
        }
        let source: ResolvedConflict.Source = own ? .own : (usedMain && usedBranch ? .both : usedMain ? .main : usedBranch ? .branch : .both)
        return ResolvedConflict(startLine: range.lowerBound + 1, endLine: max(range.lowerBound + 1, range.upperBound),
                                source: source, lines: lines, dropped: dropped)
    }

    static func normalize(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(",") { value.removeLast() }
        return value
    }

    static func lines(_ text: String) -> [String] {
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        return all
    }

    private static func find(_ block: [String], in lines: [String], from start: Int) -> Int? {
        guard !block.isEmpty else { return start }
        guard lines.count - block.count >= start else { return nil }
        for index in start...(lines.count - block.count) where Array(lines[index..<(index + block.count)]) == block {
            return index
        }
        return nil
    }
}

enum DiffParser {
    static func parse(_ diff: String) -> [FixFile] {
        var files: [FixFile] = []
        var current: FixFile?
        var hunk: DiffHunk?

        func flushHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let file = current { files.append(file) }
            current = nil
        }

        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                flushFile()
                let path = line.components(separatedBy: " b/").last ?? line
                current = FixFile(path: path, kind: .diff)
            } else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") || line.hasPrefix("rename ") {
                if line.hasPrefix("+++ b/") { current?.path = String(line.dropFirst(6)) }
            } else if line.hasPrefix("@@") {
                flushHunk()
                let numbers = line.split(separator: " ").dropFirst().prefix(2).map { part in
                    Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                hunk = DiffHunk(header: line, oldStart: numbers.first ?? 0, newStart: numbers.last ?? 0, lines: [])
            } else if hunk != nil {
                if line.hasPrefix("+") {
                    hunk?.lines.append(.init(kind: .added, text: String(line.dropFirst())))
                    current?.added += 1
                } else if line.hasPrefix("-") {
                    hunk?.lines.append(.init(kind: .removed, text: String(line.dropFirst())))
                    current?.removed += 1
                } else if line.hasPrefix(" ") {
                    hunk?.lines.append(.init(kind: .context, text: String(line.dropFirst())))
                }
            }
        }
        flushFile()
        return files
    }

    static func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let parts = lower.split(separator: "/")
        return parts.contains { ["test", "tests", "spec", "specs", "__tests__", "testing"].contains($0) }
            || name.hasPrefix("test_") || name.contains("_test.") || name.contains(".test.") || name.contains(".spec.")
            || name.contains("_spec.") || name.hasSuffix("tests.swift") || name.hasSuffix("test.swift")
    }
}
