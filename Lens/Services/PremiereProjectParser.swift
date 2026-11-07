import Foundation

/// .prproj files are gzip-compressed XML listing every media file the project references.
/// Parsing them lets the rest of the app know which footage is "linked" so it never proposes
/// removing or archiving something a live project depends on.
enum PremiereProjectParser {
    static func linkedMediaPaths(prprojPath: String) -> Set<String> {
        guard let xmlData = decompressGzip(path: prprojPath) else { return [] }
        return extractPaths(from: xmlData)
    }

    private static func decompressGzip(path: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-dc", path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    /// Premiere stores referenced media under elements like <ActualMediaFilePath> and
    /// <PathUrl>; the exact element names have drifted across versions, so this regex-scans
    /// rather than fully parsing Premiere's schema.
    private static func extractPaths(from xmlData: Data) -> Set<String> {
        guard let xml = String(data: xmlData, encoding: .utf8) ?? String(data: xmlData, encoding: .isoLatin1) else {
            return []
        }
        var paths = Set<String>()
        let pattern = #"(?:ActualMediaFilePath|PathUrl|FilePath)>([^<]+)<"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsrange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        regex.enumerateMatches(in: xml, range: nsrange) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: xml) else { return }
            var value = String(xml[range])
            if value.hasPrefix("file://") {
                value = String(value.dropFirst("file://".count))
                value = value.removingPercentEncoding ?? value
            }
            paths.insert(value)
        }
        return paths
    }

    /// Tags every MediaFile that's referenced by any of the given .prproj files.
    static func annotateLinkedFiles(_ files: inout [MediaFile], projectFiles: [URL]) {
        guard !projectFiles.isEmpty else { return }

        var pathToProjects: [String: [String]] = [:]
        for project in projectFiles {
            // Release each project's unzipped text before opening the next one.
            let linked = autoreleasepool { linkedMediaPaths(prprojPath: project.path) }
            for path in linked {
                pathToProjects[path, default: []].append(project.lastPathComponent)
            }
        }
        guard !pathToProjects.isEmpty else { return }

        for i in files.indices {
            if let projects = pathToProjects[files[i].path] {
                files[i].linkedProjects = projects
            }
        }
    }
}
