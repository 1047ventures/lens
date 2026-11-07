import Foundation

/// Proposes moving loose footage into `<Root>/Organized/<factor>/<factor>/.../filename`,
/// where the factors and their order come from each root's OrganizeRule (its own override,
/// or the shared default). Never proposes touching a file that's already inside an
/// Organized tree.
enum OrganizerService {
    /// `rulesByRoot` maps a scan root's path to its resolved rule (its own override, or the
    /// shared default) — computed once on the main actor and passed in as plain data so this
    /// can run freely off the main actor during a scan.
    static func proposals(for files: [MediaFile], scanRoots: [URL], rulesByRoot: [String: OrganizeRule]) -> [OrganizeProposal] {
        var result: [OrganizeProposal] = []
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        for file in files {
            guard !file.path.contains("/Organized/") else { continue }

            let root = scanRoots.first(where: { file.path.hasPrefix($0.path) }) ?? file.url.deletingLastPathComponent()
            let rule = rulesByRoot[root.path] ?? .defaultRule
            guard !rule.factors.isEmpty else { continue }

            var destination = root.appendingPathComponent("Organized")
            for factor in rule.factors {
                destination = destination.appendingPathComponent(component(for: factor, file: file, root: root, dateFormatter: dateFormatter))
            }
            destination = destination.appendingPathComponent(file.filename)

            guard destination.path != file.path else { continue }
            result.append(OrganizeProposal(file: file, proposedPath: destination.path))
        }
        return result
    }

    private static func component(for factor: OrganizeFactor, file: MediaFile, root: URL, dateFormatter: DateFormatter) -> String {
        switch factor {
        case .project:
            return projectName(for: file, root: root)
        case .date:
            return dateFormatter.string(from: file.creationDate ?? file.modificationDate)
        case .camera:
            return sanitized(file.cameraModel) ?? "Unknown Camera"
        case .location:
            return sanitized(file.locationLabel) ?? "Unknown Location"
        }
    }

    private static func projectName(for file: MediaFile, root: URL) -> String {
        let parent = file.url.deletingLastPathComponent()
        if parent.path == root.path { return "Unsorted" }
        let name = parent.lastPathComponent
        return name.isEmpty ? "Unsorted" : name
    }

    /// Strips path-hostile characters (e.g. "/" in a "City, ST" location label) so a
    /// metadata value can safely become a single folder name.
    private static func sanitized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.replacingOccurrences(of: "/", with: "-")
    }
}
