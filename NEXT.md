# Where Lens is at (Nov 6, 2026)

Read CLAUDE.md first for how the project works.

## Shipping
- v1.0.0 was submitted to Apple for notarization from Sean's Mac (submission e2a8f481…). If that run
  finished, the release is at github.com/1047ventures/lens-releases. If not, check with
  `xcrun notarytool info e2a8f481-e4ad-48bc-b9cd-a2cc726d503d --keychain-profile lens-notary`.
- Emma can run the signed build from `Lens-for-Emma.zip` (System Settings → Privacy & Security → Open Anyway once).
- Releases from Sean's Mac: `./release.sh <version> "notes"`.

## Feedback loop (set up, needs secrets)
1. Run `./tools/setup-github-secrets.sh` on Sean's Mac (needs `~/Desktop/Lens signing/` for the certificate).
2. Install https://github.com/apps/claude on 1047ventures/lens.
3. On Emma's Mac, Lens → Log-ins → GitHub: a fine-grained token with Issues read/write on 1047ventures/lens only.
Then: Emma asks Ask Lens → issue "[Emma] …" → `.github/workflows/claude.yml` opens a PR →
Sean merges → `.github/workflows/release.yml` signs, notarizes, publishes → Lens offers Install.

## Not built yet
- Inquiry pathways: each channel (website form, email, Instagram/Facebook DM, Zoom call, referral,
  directories) feeding the pipeline with a drafted reply and an intake form (Google Form planned).
- Gmail sync (threads attached to deals/projects; Zoom AI summaries; payment emails), Calendar
  section (EventKit), Drive project folder on a won deal, contracts/invoices, PDF export.
- Ask Lens streaming and web search are built but have not been tested with a real API key.
