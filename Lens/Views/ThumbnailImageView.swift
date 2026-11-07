import SwiftUI

/// A small frame-grab thumbnail for a video file, loaded asynchronously via ThumbnailService.
/// Falls back to a plain icon while loading or if generation fails — used anywhere a row
/// used to show a bare SF Symbol.
struct ThumbnailImageView: View {
    let file: MediaFile
    var fallbackSystemImage: String = "film"
    var size: CGSize = CGSize(width: 64, height: 36)

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: fallbackSystemImage)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: file.path) {
            image = await ThumbnailService.thumbnail(for: file)
        }
    }
}
