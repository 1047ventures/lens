# Lens

Lens is Emma's business app (macOS, SwiftUI, macOS 14+): pipeline and proposals, projects,
footage cleanup, money, gear, log-ins, and Ask Lens (Claude inside the app). Sean maintains it;
changes Emma asks for arrive as GitHub issues titled `[Emma] …`.

## Build
- The Xcode project is generated. After adding, removing or renaming a Swift file, add it to
  `FILES` in `generate_xcodeproj.py`, then run `python3 generate_xcodeproj.py`.
- Check it compiles: `xcodebuild -project Lens.xcodeproj -scheme Lens -configuration Debug build CODE_SIGNING_ALLOWED=NO`
- Never commit `Lens.xcodeproj/project.pbxproj` changes by hand; regenerate it.

## Rules
- Emma's data lives in JSON files in `~/Library/Application Support/Lens`. Never break loading of
  existing data: new stored fields on Codable models must be Optional (or the type needs a
  tolerant decoder). Never rename or remove a stored field.
- Don't touch signing, notarization or release: `package.sh`, `release.sh`, `.github/`, `Lens/Lens.entitlements`, `Lens/Info.plist`.
- Keep the look consistent: colours and components live in `Lens/Views/Theme.swift` (Theme, Palette,
  ColorLabel, `.panel()`, `.accentBar()`, PrimaryButtonStyle, SecondaryButtonStyle).
- Copy is plain English for a non-technical person. No jargon, no em dashes in UI text.
- Anything that changes Emma's data from Ask Lens must go through an approval card (see `LensAI.ask`).
- Secrets go in the Keychain (`Keychain` in `Services/Connections.swift`), never in JSON or code.

## Map
- `Lens/Views/ContentView.swift`: sidebar, navigation (`Navigator`), app-wide wiring.
- Pipeline: `Models/Deal.swift`, `Services/DealStore.swift`, `Services/Estimator.swift` (pricing),
  `Views/PipelineView.swift`, `Views/DealDetailView.swift`, `Views/ProposalBuilderView.swift`,
  `Services/ProposalRenderer.swift` (HTML proposal).
- Projects: `Models/Project.swift`, `Services/ProjectStore.swift`, `Views/ProjectsView.swift`, `Views/ProjectDetailView.swift`.
- Money and Gear: `Models/Money.swift`, `Services/MoneyStore.swift`, `Views/MoneyView.swift`, `Views/GearView.swift`.
- Ask Lens: `Services/LensAI.swift` (tools, prompt), `Views/AskLensView.swift`.
- Log-ins: `Services/Connections.swift`, `Views/LoginsView.swift`. Updates: `Services/Updater.swift`.
