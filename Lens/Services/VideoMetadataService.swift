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

        if let created = try? await asset.load(.creationDate), let date = try? await created.load(.dateValue) {
            file.captureDate = date
        }

        if let metadata = try? await asset.load(.metadata) {
            var make: String?
            var model: String?
            for item in metadata {
                if item.commonKey == .commonKeyMake, let value = item.stringValue { make = value }
                if item.commonKey == .commonKeyModel, let value = item.stringValue { model = value }

                if isLocation(item), let value = item.stringValue, let coords = parseISO6709(value) {
                    file.gpsLatitude = coords.lat
                    file.gpsLongitude = coords.lon
                }
            }
            file.cameraModel = FileFacts.cameraName(make: make, model: model)
        }

        if file.cameraModel == nil || file.captureDate == nil {
            let note = FileFacts.cameraNote(for: file.url)
            file.cameraModel = file.cameraModel ?? note.camera
            file.captureDate = file.captureDate ?? note.taken
        }

        if let lat = file.gpsLatitude, let lon = file.gpsLongitude {
            file.locationLabel = await PlaceBook.shared.label(lat, lon)
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

    /// GPS shows up under the common "location" key (e.g. ffmpeg-authored udta atoms) or under a
    /// QuickTime-specific ISO6709 identifier (real-camera .mov files), so both are checked.
    static func isLocation(_ item: AVMetadataItem) -> Bool {
        item.commonKey?.rawValue == "location"
            || (item.identifier?.rawValue).map {
                $0.localizedCaseInsensitiveContains("location.ISO6709") || $0.localizedCaseInsensitiveContains("GPSCoordinates")
            } == true
    }

    /// Parses an ISO 6709 location string like "+37.3349-122.0090+000.000/" into (lat, lon).
    static func parseISO6709(_ string: String) -> (lat: Double, lon: Double)? {
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
