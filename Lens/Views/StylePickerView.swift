import SwiftUI

/// "Make Lens feel like yours": pick a look (Daylight, Evening, Studio).
/// Opened from "Style" behind her picture, top right. Changes apply straight away. Simple or Everything is in the toolbar.
struct StylePickerView: View {
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Make Lens feel like yours").font(Theme.display(size: 28)).foregroundStyle(Theme.text)
                Text("Change these any time. Nothing you've saved changes.")
                    .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Look").font(Theme.font(size: 13, weight: .bold)).foregroundStyle(Theme.text3)
                HStack(spacing: 14) {
                    ForEach(Look.allCases) { look in
                        Button { appearance.look = look } label: { lookCard(look) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(appearance.look == look ? .isSelected : [])
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 640)
        .background(Theme.ground)
    }

    private func lookCard(_ look: Look) -> some View {
        let c = Theme.colors(for: look)
        let on = appearance.look == look
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(look == .daylight ? c.sidebar : c.teal).frame(width: 70, height: 8)
                RoundedRectangle(cornerRadius: 6).fill(c.panel)
            }
            .padding(10)
            .frame(height: 84)
            .background(c.ground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            Text(look.name).font(Theme.font(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Text(look.blurb).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Theme.teal : Theme.line, lineWidth: 2))
        .contentShape(Rectangle())
    }
}
