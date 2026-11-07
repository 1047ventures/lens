import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The "darkroom" palette from the storyboard. Each accent has one job:
/// teal = something you can act on, amber = needs attention, coral = overdue/at risk.
enum Theme {
    static let ground = Color(hex: 0x131211)
    static let sidebar = Color(hex: 0x171615)
    static let panel = Color(hex: 0x1B1A19)
    static let raised = Color(hex: 0x232120)
    static let line = Color(hex: 0x2A2725)
    static let lineSoft = Color(hex: 0x26231F)
    static let track = Color(hex: 0x36322F)

    static let text = Color(hex: 0xF1EDE7)
    static let text2 = Color(hex: 0xE6E1DA)
    static let text3 = Color(hex: 0xC3BCB3)
    static let muted = Color(hex: 0xA8A29A)

    static let teal = Color(hex: 0x3FD1C2)
    static let tealDim = Color(hex: 0x2F9F95)
    static let onTeal = Color(hex: 0x0D1F1D)
    static let amber = Color(hex: 0xF5A35B)
    static let coral = Color(hex: 0xFF7E6B)

    // Storage chart categories (validated for colour-blind separation on the panel colour).
    static let chartActive = Color(hex: 0x21A99C)
    static let chartReady = Color(hex: 0x3987E5)
    static let chartDuplicates = Color(hex: 0xD55181)
    static let chartCache = Color(hex: 0xC98500)
    static let chartOther = Color(hex: 0x5B5550)
}

/// The seven-step progress bar that follows a project everywhere it appears.
struct StageBar: View {
    let stage: ProjectStage
    var height: CGFloat = 3

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProjectStage.allCases) { step in
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color(for: step))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(stage.rawValue + 1) of 7, \(stage.label)")
    }

    private func color(for step: ProjectStage) -> Color {
        if step.rawValue < stage.rawValue { return Theme.tealDim }
        if step == stage { return Theme.text }
        return Theme.track
    }
}

/// Small uppercase section heading.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(Theme.muted)
    }
}

struct PanelModifier: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}

extension View {
    func panel(padding: CGFloat = 20) -> some View { modifier(PanelModifier(padding: padding)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(Theme.teal.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundStyle(Theme.onTeal)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Theme.raised.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundStyle(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0x3A3532)))
    }
}

/// Big light-weight number used for money and storage headlines.
struct HeadlineNumber: View {
    let text: String
    var size: CGFloat = 32
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .light))
            .monospacedDigit()
            .foregroundStyle(Theme.text)
    }
}

enum DriveInfo {
    struct Capacity {
        let name: String
        let total: Int64
        let free: Int64
        var used: Int64 { max(0, total - free) }
        var fractionUsed: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    static func capacity(for url: URL) -> Capacity? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return Capacity(name: values.volumeName ?? url.lastPathComponent, total: Int64(total), free: free)
    }
}

/// One colour per section, so each part of a page is recognisable at a glance.
/// Kept clear of the meaning colours above (teal = act, amber = attention, coral = overdue).
enum Palette {
    static let blue = Color(hex: 0x5EAEFF)
    static let violet = Color(hex: 0xA48BFF)
    static let orchid = Color(hex: 0xE27FD3)
    static let lime = Color(hex: 0xB4D865)
    static let gold = Color(hex: 0xF2CF5B)
    static let mint = Color(hex: 0x7FD6A0)
    static let sand = Color(hex: 0xCDB592)
    static let rose = Color(hex: 0xF28CA8)
    static let slate = Color(hex: 0x9AA7B8)
}

/// A coloured section heading: a small dot plus the label in the section's colour.
struct ColorLabel: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(color)
        }
    }
}

extension View {
    /// A coloured bar down the left edge of a panel or card.
    func accentBar(_ color: Color, cornerRadius: CGFloat = 14) -> some View {
        overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
