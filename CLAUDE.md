# Lens

Lens is Emma's business app (macOS, SwiftUI, macOS 14+): pipeline and proposals, projects,
footage cleanup, money, gear, log-ins, and Ask Lens (Claude inside the app). Skelly maintains it;
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
- If a change is something Emma would notice and like, add a short line for it to `WhatsNew.notes`
  (`Views/WhatsNewView.swift`), in a new entry for the next version. Lens shows it to her once after the update.
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
- Zoom notes: `Services/ZoomAPI.swift` (Zoom sign-in, read-only API), `Services/ZoomNotes.swift` (sync and
  matching, Gmail fallback), `Views/MeetingNotesView.swift`. Setting up Zoom on Emma's Mac: `ZOOM-SETUP.md`.

## Working from Emma's Mac
Emma can change Lens herself with Claude Code. When the person at the keyboard is Emma (not Skelly):
- Work on a new branch named `emma/<short-topic>`, never on `main`. Pull `main` first.
- Check it compiles (command above; if Xcode isn't installed, skip it, GitHub checks it anyway), then commit, push the branch and open a pull request with
  `gh pr create`. Describe the change in plain words and end the description with one line
  starting "Release note:" written for Emma. Once the pull request is open it ships on its own:
  GitHub builds it, merges it and publishes the update (about 20 to 30 minutes). Tell her that.
  If GitHub comments that it doesn't build, fix the errors and push again.
- Never run `release.sh` or `package.sh`, and never try to sign or notarize. Never change
  `.github/`, `tools/`, the entitlements or Info.plist: changes to those wait for Skelly.
- She sees the change when Lens offers the update (Update ready, top right of the window).
- Explain things to her in plain English, no jargon. She knows the app, not the code.
