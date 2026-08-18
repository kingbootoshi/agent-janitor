import Foundation

public enum Project {
    private static var cache: [String: String] = [:]

    public static func resolve(cwd: String) -> String {
        guard !cwd.isEmpty, cwd != "/" else { return "" }
        if let hit = cache[cwd] { return hit }
        if cache.count >= 4096 { cache.removeAll(keepingCapacity: true) }
        var dir = URL(fileURLWithPath: cwd)
        let fm = FileManager.default
        let markers = [".git", "package.json", "pyproject.toml", "Cargo.toml", "Package.swift"]
        for _ in 0..<12 {
            for m in markers where fm.fileExists(atPath: dir.appendingPathComponent(m).path) {
                let name = projectName(dir)
                cache[cwd] = name
                return name
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        cache[cwd] = ""
        return ""
    }

    private static func projectName(_ root: URL) -> String {
        let comps = root.pathComponents
        if let i = comps.firstIndex(of: ".forks"), i + 2 < comps.count {
            return "\(comps[i + 1]):\(comps[i + 2])"
        }
        return root.lastPathComponent
    }
}
