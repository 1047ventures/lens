import Foundation
import AVFoundation
import CoreMedia
import CoreLocation

/// Best-effort per-file video metadata: duration, resolution, codec, frame rate, camera
/// model, and GPS-derived location. Every field is optional — a file whose container
/// doesn't carry a piece of info (or that fails to load at all) just comes back with that
/// field nil rather than throwing, so the rest of the app never has to special-case errors.
enum VideoMetadataService {

    static func enrich(_ file: MediaFile) async -> MediaFile {
        var file = file
        let asset = AVURLAsset(url: file.url)

        do {
            let duration = try await asset.load(.duration).seconds
            if duration.isFinite { file.duration = duration }
        } catch {
            // leave duration nil
        }

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let naturalSize = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = naturalSize.applying(transform)
                file.width = Int(abs(transformed.width))
                file.height = Int(abs(transformed.height))
            }
            if let frameRate = try? await track.load(.nominalFrameRate), frameRate.isFinite, frameRate > 0 {
                file.frameRate = Double(frameRate)
            }
            if let format = try? await track.load(.formatDescriptions).first {
                file.codec = codecName(for: CMFormatDescriptionGetMediaSubType(format))
            }
        }

        if let metadata = try? await asset.load(.metadata) {
            var make: String?
            var model: String?
            for item in metadata {
                if item.commonKey == .commonKeyMake, let value = item.stringValue { make = value }
                if item.commonKey == .commonKeyModel, let value = item.stringValue { model = value }

                // GPS shows up under the common "location" key (e.g. ffmpeg-authored udta atoms)
                // or under a QuickTime-specific ISO6709 identifier (real-camera .mov files) —
                // check both rather than assuming one container's convention.
                let looksLikeLocation = item.commonKey?.rawValue == "location"
                    || (item.identifier?.rawValue).map {
                        $0.localizedCaseInsensitiveContains("location.ISO6709") || $0.localizedCaseInsensitiveContains("GPSCoordinates")
                    } == true
                if looksLikeLocation, let value = item.stringValue, let coords = parseISO6709(value) {
                    file.gpsLatitude = coords.lat
                    file.gpsLongitude = coords.lon
                }
            }
            if let model {
                file.cameraModel = make.map { "\($0) \(model)" } ?? model
            } else {
                file.cameraModel = make
            }
        }

        if let lat = file.gpsLatitude, let lon = file.gpsLongitude {
            file.locationLabel = await GeocodeCache.shared.label(for: lat, lon)
        }

        return file
    }

    /// Enriches every file with bounded concurrency — matters once a drive has thousands
    /// of clips, since opening each one's metadata isn't free.
    static func enrichAll(_ files: [MediaFile], maxConcurrent: Int = 8) async -> [MediaFile] {
        guard !files.isEmpty else { return files }
        var results = files

        await withTaskGroup(of: (Int, MediaFile).self) { group in
            var nextIndex = 0

            func addNext() {
                guard nextIndex < files.count else { return }
                let i = nextIndex
                nextIndex += 1
                let file = files[i]
                group.addTask { (i, await enrich(file)) }
            }

            for _ in 0..<min(maxConcurrent, files.count) {
                addNext()
            }
            while let (i, enriched) = await group.next() {
                results[i] = enriched
                addNext()
            }
        }
        return results
    }

    private static func codecName(for subtype: FourCharCode) -> String {
        switch fourCCString(subtype) {
        case "avc1": return "H.264"
        case "hvc1", "hev1": return "H.265 (HEVC)"
        case "apcn", "apcs", "apco", "apch": return "ProRes 422"
        case "ap4h", "ap4x": return "ProRes 4444"
        case "mp4v": return "MPEG-4"
        case let other: return other
        }
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff)
        ]
        let string = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return string.isEmpty ? "Unknown" : string
    }

    /// Parses an ISO 6709 location string like "+37.3349-122.0090+000.000/" into (lat, lon).
    private static func parseISO6709(_ string: String) -> (lat: Double, lon: Double)? {
        let pattern = #"[+-][0-9]+\.[0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
        guard matches.count >= 2,
              let latRange = Range(matches[0].range, in: string),
              let lonRange = Range(matches[1].range, in: string),
              let lat = Double(string[latRange]),
              let lon = Double(string[lonRange]) else { return nil }
        return (lat, lon)
    }
}

/// Reverse-geocodes GPS coordinates into a short place name, caching by rounded
/// coordinate so clips shot in the same session don't each trigger a network lookup.
/// CLGeocoder only calls back on a thread with a run loop and can stall when offline or
/// rate-limited, so lookups run on the main actor, share in-flight requests, and give up
/// after a few seconds — a missing place name must never hold up a scan.
@MainActor
private final class GeocodeCache {
    static let shared = GeocodeCache()

    private var cache: [String: String?] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    nonisolated func label(for lat: Double, _ lon: Double) async -> String? {
        await lookup(lat, lon)
    }

    private func lookup(_ lat: Double, _ lon: Double) async -> String? {
        let key = String(format: "%.3f,%.3f", lat, lon)
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task { @MainActor in await Self.reverseGeocode(lat, lon) }
        inFlight[key] = task
        let label = await task.value
        inFlight[key] = nil
        cache[key] = label
        return label
    }

    private static func reverseGeocode(_ lat: Double, _ lon: Double, timeout: TimeInterval = 4) async -> String? {
        let geocoder = CLGeocoder()
        // Cancelling makes the completion handler fire with an error, so the wait always ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { geocoder.cancelGeocode() }
        return await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { placemarks, _ in
                let label = placemarks?.first.map {
                    [$0.locality, $0.administrativeArea].compactMap { $0 }.joined(separator: ", ")
                }
                continuation.resume(returning: (label?.isEmpty ?? true) ? nil : label)
            }
        }
    }
}
