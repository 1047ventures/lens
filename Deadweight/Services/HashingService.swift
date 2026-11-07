import Foundation
import CryptoKit

/// Duplicate detection tuned for huge 4K files: never hashes a whole file up front.
/// Files are first grouped by size, then by a cheap "quick fingerprint" sampled from the
/// start/middle/end of the file, and only fingerprint collisions get a full-file hash to
/// confirm they're truly identical before being offered up for removal.
enum HashingService {
    static let chunkSize = 2 * 1024 * 1024 // 2MB per sampled chunk

    static func quickFingerprint(path: String, sizeBytes: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        hasher.update(data: withUnsafeBytes(of: sizeBytes) { Data($0) })

        let offsets: [UInt64]
        if sizeBytes <= Int64(chunkSize) * 3 {
            offsets = [0]
        } else {
            let mid = UInt64(sizeBytes / 2)
            let end = UInt64(max(0, sizeBytes - Int64(chunkSize)))
            offsets = [0, mid, end]
        }

        for offset in offsets {
            do {
                try handle.seek(toOffset: offset)
                let data = handle.readData(ofLength: chunkSize)
                hasher.update(data: data)
            } catch {
                return nil
            }
        }

        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 4 * 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    static func findDuplicates(among files: [MediaFile]) -> [DuplicateGroup] {
        var bySize: [Int64: [MediaFile]] = [:]
        for file in files { bySize[file.sizeBytes, default: []].append(file) }

        var groups: [DuplicateGroup] = []

        for (size, candidates) in bySize where size > 0 && candidates.count > 1 {
            var byFingerprint: [String: [MediaFile]] = [:]
            for var file in candidates {
                guard let fp = quickFingerprint(path: file.path, sizeBytes: file.sizeBytes) else { continue }
                file.quickFingerprint = fp
                byFingerprint[fp, default: []].append(file)
            }

            for (_, fpMatches) in byFingerprint where fpMatches.count > 1 {
                var byFullHash: [String: [MediaFile]] = [:]
                for var file in fpMatches {
                    guard let full = fullHash(path: file.path) else { continue }
                    file.fullHash = full
                    byFullHash[full, default: []].append(file)
                }
                for (_, confirmed) in byFullHash where confirmed.count > 1 {
                    groups.append(DuplicateGroup(files: confirmed))
                }
            }
        }

        return groups
    }
}
