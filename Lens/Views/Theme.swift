import SwiftUI
import CoreText

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Look and detail

/// How Lens looks. Daylight and Evening use the owner's own brand colours; Studio is the original dark look.
enum Look: String, CaseIterable, Identifiable {
    case daylight, evening, studio
    var id: String { rawValue }
    var name: String {
        switch self {
        case .daylight: return "Daylight"
        case .evening: return "Evening"
        case .studio: return "Studio"
        }
    }
    var blurb: String {
        switch self {
        case .daylight: return "Cream and deep teal, soft and bright."
        case .evening: return "Deep teal and seafoam, easy on the eyes at night."
        case .studio: return "Dark and detailed, the way Lens first looked."
        }
    }
    var isDark: Bool { self != .daylight }
}

/// How much each screen shows. Simple keeps only what's needed today; Everything shows every number and option.
enum Detail: String, CaseIterable, Identifiable {
    case simple, everything
    var id: String { rawValue }
    var name: String { self == .simple ? "Simple" : "Everything" }
    var blurb: String {
        self == .simple ? "Just what you need today. Every screen, clean and calm."
                        : "Every number, chart and option, for when you want to dig in."
    }
}

/// The look and detail level, saved on this Mac. Changing the look redraws the whole window.
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()

    @Published var look: Look {
        didSet {
            UserDefaults.standard.set(look.rawValue, forKey: Self.lookKey)
            Theme.current = Theme.colors(for: look)
            Theme.look = look
        }
    }
    @Published var detail: Detail {
        didSet { UserDefaults.standard.set(detail.rawValue, forKey: Self.detailKey) }
    }
    var simple: Bool { detail == .simple }

    private static let lookKey = "lens.look"
    private static let detailKey = "lens.detail"

    private init() {
        let look = UserDefaults.standard.string(forKey: Self.lookKey).flatMap(Look.init) ?? .daylight
        self.look = look
        self.detail = UserDefaults.standard.string(forKey: Self.detailKey).flatMap(Detail.init) ?? .simple
        Theme.current = Theme.colors(for: look)
        Theme.look = look
    }
}

// MARK: - Colours

/// Every colour a look defines. Each accent has one job: teal = something you can act on,
/// amber = needs attention, coral = overdue or at risk.
struct ThemeColors {
    var ground, sidebar, panel, raised, line, lineSoft, track: Color
    var text, text2, text3, muted: Color
    var teal, tealDim, onTeal, amber, coral: Color
    var chartActive, chartReady, chartDuplicates, chartCache, chartOther: Color
    // The sidebar can be dark on a light look, so it has its own text colours.
    var sideText, sideMuted, sideTrack, sideAccent: Color
    // Section colours (see Palette).
    var blue, violet, orchid, lime, gold, mint, sand, rose, slate: Color
    var buttonBorder: Color
}

enum Theme {
    /// The colours of the current look. Set by `Appearance`.
    static var current = colors(for: .daylight)
    static var look: Look = .daylight
    static var isStudio: Bool { look == .studio }

    static var ground: Color { current.ground }
    static var sidebar: Color { current.sidebar }
    static var panel: Color { current.panel }
    static var raised: Color { current.raised }
    static var line: Color { current.line }
    static var lineSoft: Color { current.lineSoft }
    static var track: Color { current.track }

    static var text: Color { current.text }
    static var text2: Color { current.text2 }
    static var text3: Color { current.text3 }
    static var muted: Color { current.muted }

    static var teal: Color { current.teal }
    static var tealDim: Color { current.tealDim }
    static var onTeal: Color { current.onTeal }
    static var amber: Color { current.amber }
    static var coral: Color { current.coral }

    // Storage chart categories (validated for colour-blind separation on the panel colour).
    static var chartActive: Color { current.chartActive }
    static var chartReady: Color { current.chartReady }
    static var chartDuplicates: Color { current.chartDuplicates }
    static var chartCache: Color { current.chartCache }
    static var chartOther: Color { current.chartOther }

    static var sideText: Color { current.sideText }
    static var sideMuted: Color { current.sideMuted }

    static func colors(for look: Look) -> ThemeColors {
        switch look {
        case .studio:
            return ThemeColors(
                ground: Color(hex: 0x131211), sidebar: Color(hex: 0x171615), panel: Color(hex: 0x1B1A19),
                raised: Color(hex: 0x232120), line: Color(hex: 0x2A2725), lineSoft: Color(hex: 0x26231F),
                track: Color(hex: 0x36322F),
                text: Color(hex: 0xF1EDE7), text2: Color(hex: 0xE6E1DA), text3: Color(hex: 0xC3BCB3), muted: Color(hex: 0xA8A29A),
                teal: Color(hex: 0x3FD1C2), tealDim: Color(hex: 0x2F9F95), onTeal: Color(hex: 0x0D1F1D),
                amber: Color(hex: 0xF5A35B), coral: Color(hex: 0xFF7E6B),
                chartActive: Color(hex: 0x21A99C), chartReady: Color(hex: 0x3987E5), chartDuplicates: Color(hex: 0xD55181),
                chartCache: Color(hex: 0xC98500), chartOther: Color(hex: 0x5B5550),
                sideText: Color(hex: 0xF1EDE7), sideMuted: Color(hex: 0xC3BCB3), sideTrack: Color(hex: 0x36322F),
                sideAccent: Color(hex: 0x2F9F95),
                blue: Color(hex: 0x5EAEFF), violet: Color(hex: 0xA48BFF), orchid: Color(hex: 0xE27FD3), lime: Color(hex: 0xB4D865),
                gold: Color(hex: 0xF2CF5B), mint: Color(hex: 0x7FD6A0), sand: Color(hex: 0xCDB592), rose: Color(hex: 0xF28CA8),
                slate: Color(hex: 0x9AA7B8),
                buttonBorder: Color(hex: 0x3A3532))
        case .daylight:
            return ThemeColors(
                ground: Color(hex: 0xF7F4EC), sidebar: Color(hex: 0x003631), panel: Color(hex: 0xFFFFFF),
                raised: Color(hex: 0xEFEBE1), line: Color(hex: 0xDCD8CC), lineSoft: Color(hex: 0xE6E2D7),
                track: Color(hex: 0xDCD8CC),
                text: Color(hex: 0x0F3B39), text2: Color(hex: 0x1F4644), text3: Color(hex: 0x2F4E4C), muted: Color(hex: 0x4F6866),
                teal: Color(hex: 0x0B4A44), tealDim: Color(hex: 0x3E8A7C), onTeal: Color(hex: 0xF7F4EC),
                amber: Color(hex: 0x9A5A0E), coral: Color(hex: 0xA8391F),
                chartActive: Color(hex: 0x2E8C7B), chartReady: Color(hex: 0x3A73B8), chartDuplicates: Color(hex: 0xB0467A),
                chartCache: Color(hex: 0xB07A12), chartOther: Color(hex: 0xA9A598),
                sideText: Color(hex: 0xF3F0E7), sideMuted: Color(hex: 0xBFD3CF), sideTrack: Color(hex: 0x1E5A52),
                sideAccent: Color(hex: 0x73C3AE),
                blue: Color(hex: 0x2A64A3), violet: Color(hex: 0x5A4472), orchid: Color(hex: 0x8A3C7C), lime: Color(hex: 0x3B6644),
                gold: Color(hex: 0x86650A), mint: Color(hex: 0x1E6B57), sand: Color(hex: 0x7A5F3E), rose: Color(hex: 0x9E3A5A),
                slate: Color(hex: 0x4D6172),
                buttonBorder: Color(hex: 0xB9C9C4))
        case .evening:
            return ThemeColors(
                ground: Color(hex: 0x003631), sidebar: Color(hex: 0x002A26), panel: Color(hex: 0x08433D),
                raised: Color(hex: 0x0E4F48), line: Color(hex: 0x1E5A52), lineSoft: Color(hex: 0x164F48),
                track: Color(hex: 0x2A6A61),
                text: Color(hex: 0xF3F0E7), text2: Color(hex: 0xE6E9E3), text3: Color(hex: 0xC9D8D4), muted: Color(hex: 0xA9C3BF),
                teal: Color(hex: 0x73C3AE), tealDim: Color(hex: 0x5BA896), onTeal: Color(hex: 0x00302B),
                amber: Color(hex: 0xF2C078), coral: Color(hex: 0xF28F78),
                chartActive: Color(hex: 0x73C3AE), chartReady: Color(hex: 0x9FC9E8), chartDuplicates: Color(hex: 0xE0A6D6),
                chartCache: Color(hex: 0xF2D58A), chartOther: Color(hex: 0x5E8A84),
                sideText: Color(hex: 0xF3F0E7), sideMuted: Color(hex: 0xBFD3CF), sideTrack: Color(hex: 0x1E5A52),
                sideAccent: Color(hex: 0x73C3AE),
                blue: Color(hex: 0x9FC9E8), violet: Color(hex: 0xB69FD1), orchid: Color(hex: 0xE0A6D6), lime: Color(hex: 0xAED9A4),
                gold: Color(hex: 0xF2D58A), mint: Color(hex: 0x9FDCCB), sand: Color(hex: 0xE0CBA8), rose: Color(hex: 0xF2A9BC),
                slate: Color(hex: 0xB9C7D3),
                buttonBorder: Color(hex: 0x3E7C72))
        }
    }

    // MARK: Type

    /// The body font: Karla on Daylight and Evening, the system font on Studio. Large sizes use the
    /// display serif. Monospaced text always uses the system font.
    static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        if isStudio || design != .default { return .system(size: size, weight: weight, design: design) }
        if size >= 20 && weight != .light && weight != .ultraLight && weight != .thin { return display(size: size) }
        return .custom("Karla", size: size + 1).weight(weight == .regular ? .regular : weight)
    }

    /// The display serif for titles (Young Serif), or the system font on Studio.
    static func display(size: CGFloat) -> Font {
        isStudio ? .system(size: size, weight: .semibold) : .custom("YoungSerif-Regular", size: size)
    }

    /// The handwritten font, for a small personal touch.
    static func script(size: CGFloat) -> Font {
        isStudio ? .system(size: size, weight: .medium) : .custom("Caveat", size: size).weight(.semibold)
    }

    /// Loads the bundled fonts. Call once when Lens starts.
    static func registerFonts() {
        for name in ["FontYoungSerif", "FontKarla", "FontCaveat"] {
            guard let data = NSDataAsset(name: name)?.data as CFData?,
                  let provider = CGDataProvider(data: data),
                  let font = CGFont(provider) else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
        }
    }

    /// Corner radius for panels and cards.
    static var radius: CGFloat { isStudio ? 14 : 18 }
}

/// The seven-step progress bar that follows a project everywhere it appears.
struct StageBar: View {
    let stage: ProjectStage
    var height: CGFloat = 3
    /// On the sidebar, which can be dark on a light look.
    var onSidebar = false

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
        let c = Theme.current
        if step.rawValue < stage.rawValue { return onSidebar ? c.sideAccent.opacity(0.7) : Theme.tealDim }
        if step == stage { return onSidebar ? c.sideText : (Theme.isStudio ? Theme.text : Theme.teal) }
        return onSidebar ? c.sideTrack : Theme.track
    }
}

extension ProjectStage {
    /// One colour per step, so a project's history reads at a glance.
    var color: Color {
        switch self {
        case .lead: return Palette.slate
        case .booked: return Palette.blue
        case .shoot: return Palette.violet
        case .edit: return Palette.orchid
        case .delivered: return Palette.gold
        case .paid: return Palette.lime
        case .archived: return Theme.muted
        }
    }
}

/// Small section heading: uppercase on Studio, a gentle serif heading on the other looks.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        if Theme.isStudio {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(Theme.muted)
        } else {
            Text(text)
                .font(Theme.display(size: 17))
                .foregroundStyle(Theme.text)
        }
    }
}

struct PanelModifier: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .clipShape(shape)
            .overlay(shape.stroke(Theme.look == .daylight ? Color.clear : Theme.line))
            .shadow(color: Theme.look == .daylight ? Color(hex: 0x003631).opacity(0.07) : .clear, radius: 10, y: 3)
    }
}

extension View {
    func panel(padding: CGFloat = 20) -> some View { modifier(PanelModifier(padding: padding)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let studio = Theme.isStudio
        configuration.label
            .font(Theme.font(size: 13, weight: studio ? .semibold : .bold))
            .padding(.horizontal, studio ? 16 : 18)
            .frame(minHeight: studio ? 34 : 36)
            .background(Theme.teal.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundStyle(Theme.onTeal)
            .clipShape(RoundedRectangle(cornerRadius: studio ? 8 : 18))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let studio = Theme.isStudio
        let shape = RoundedRectangle(cornerRadius: studio ? 8 : 18)
        configuration.label
            .font(Theme.font(size: 13, weight: studio ? .semibold : .bold))
            .padding(.horizontal, studio ? 14 : 16)
            .frame(minHeight: studio ? 34 : 36)
            .background((studio ? Theme.raised : Theme.panel).opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundStyle(Theme.text)
            .clipShape(shape)
            .overlay(shape.stroke(Theme.current.buttonBorder, lineWidth: studio ? 1 : 1.5))
    }
}

/// Big light-weight number used for money and storage headlines.
struct HeadlineNumber: View {
    let text: String
    var size: CGFloat = 32
    var body: some View {
        Text(text)
            .font(Theme.isStudio ? .system(size: size, weight: .light) : Theme.display(size: size))
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
    static var blue: Color { Theme.current.blue }
    static var violet: Color { Theme.current.violet }
    static var orchid: Color { Theme.current.orchid }
    static var lime: Color { Theme.current.lime }
    static var gold: Color { Theme.current.gold }
    static var mint: Color { Theme.current.mint }
    static var sand: Color { Theme.current.sand }
    static var rose: Color { Theme.current.rose }
    static var slate: Color { Theme.current.slate }
}

/// A coloured section heading: a small dot plus the label in the section's colour.
/// On Daylight and Evening it's a serif heading in the page's text colour, with the dot keeping the colour.
struct ColorLabel: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        HStack(spacing: Theme.isStudio ? 7 : 9) {
            Circle().fill(color).frame(width: Theme.isStudio ? 7 : 9, height: Theme.isStudio ? 7 : 9)
            if Theme.isStudio {
                Text(text.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(color)
            } else {
                Text(text)
                    .font(Theme.display(size: 18))
                    .foregroundStyle(Theme.text)
            }
        }
    }
}

extension View {
    /// A coloured bar down the left edge of a panel or card (Studio only; the other looks keep cards clean).
    func accentBar(_ color: Color, cornerRadius: CGFloat = 14) -> some View {
        overlay(alignment: .leading) {
            if Theme.isStudio { Rectangle().fill(color).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.isStudio ? cornerRadius : Theme.radius))
    }
}
