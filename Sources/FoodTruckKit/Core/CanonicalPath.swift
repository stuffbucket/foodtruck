import Foundation

/// Resolves every existing symlink component while preserving descendants that
/// do not exist yet. Foundation's `resolvingSymlinksInPath()` can spell an
/// existing ancestor and its missing child with different aliases (notably
/// `/var` and `/private/var` on macOS), which makes containment checks lie.
enum CanonicalPath {
    enum Failure: LocalizedError {
        case tooManySymbolicLinks

        var errorDescription: String? { "too many symbolic links in path" }
    }

    static func resolve(_ url: URL, remainingLinks: Int = 40) throws -> URL {
        let components = lexicalComponents(of: url.path)
        var current = URL(filePath: "/", directoryHint: .isDirectory)

        for (offset, component) in components.enumerated() {
            let next = current.appending(path: component)
            guard let destination = try? FileManager.default
                .destinationOfSymbolicLink(atPath: next.path) else {
                current = next
                continue
            }
            guard remainingLinks > 0 else { throw Failure.tooManySymbolicLinks }
            let prefix = destination.hasPrefix("/") ? destination
                : current.path + "/" + destination
            let remainder = components.dropFirst(offset + 1).joined(separator: "/")
            let redirected = remainder.isEmpty ? prefix : prefix + "/" + remainder
            return try resolve(
                URL(filePath: lexicalPath(redirected)),
                remainingLinks: remainingLinks - 1)
        }
        return current
    }

    private static func lexicalComponents(of path: String) -> [String] {
        var result: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !result.isEmpty { result.removeLast() }
            default: result.append(String(component))
            }
        }
        return result
    }

    private static func lexicalPath(_ path: String) -> String {
        "/" + lexicalComponents(of: path).joined(separator: "/")
    }
}
