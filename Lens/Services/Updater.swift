import Foundation
import AppKit
import Security

/// Keeps Lens up to date from its GitHub releases. A new version is only installed if it is
/// signed with Sean's Developer ID (team J55RP92WN6) and passes Apple's notarization check,
/// so a tampered download can never replace the app.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let releasesRepo = "1047ventures/lens-releases"
    static let teamID = "J55RP92WN6"

    struct Release: Equatable {
        let version: String
        let notes: String
        let zipURL: URL
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?

    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Check now, then every six hours while Lens is open.
    func start() {
        Task { await check(silent: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(silent: true) }
        }
    }

    func check(silent: Bool = false) async {
        if !silent { phase = .checking }
        defer { lastChecked = Date() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.releasesRepo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lens-Updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { ($0["name"] as? String) == "Lens.zip" }),
                  let link = zip["browser_download_url"] as? String, let url = URL(string: link)
            else {
                if !silent { phase = .upToDate }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(version, than: currentVersion) {
                available = Release(version: version, notes: (json["body"] as? String) ?? "", zipURL: url)
                phase = .idle
            } else {
                available = nil
                if !silent { phase = .upToDate }
            }
        } catch {
            if !silent { phase = .failed("Couldn't reach GitHub: \(error.localizedDescription)") }
        }
    }

    /// Downloads the new version, checks its signature, swaps it in and relaunches.
    func install() async {
        guard let release = available else { return }
        phase = .downloading
        do {
            let (zipFile, _) = try await URLSession.shared.download(from: release.zipURL)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("LensUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path])
            let newApp = work.appendingPathComponent("Lens.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError("The download didn't contain Lens.app.") }

            phase = .installing
            try verify(newApp)

            let current = Bundle.main.bundleURL
            var trashed: NSURL?
            try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
            do {
                try FileManager.default.moveItem(at: newApp, to: current)
            } catch {
                // Put the old version back if the swap fails.
                if let old = trashed as URL? { try? FileManager.default.moveItem(at: old, to: current) }
                throw error
            }

            // Reopen the new version once this one has quit.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"\(current.path)\""]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Checks

    /// Signed by Sean's team, intact, and accepted by Gatekeeper (i.e. notarized).
    private func verify(_ app: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            throw UpdateError("Couldn't read the new version's signature.")
        }
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.teamID)\""
        var requirement: SecRequirement?
        SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError("The download isn't signed by Lens's developer, so it wasn't installed.")
        }
        do {
            try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        } catch {
            throw UpdateError("The download isn't notarized by Apple, so it wasn't installed.")
        }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed") }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
