# App Store submission kit

Everything needed to fill in App Store Connect for **Pano 360**. Copy the texts into
App Store Connect → your app → *App Information* / *1.0 Prepare for Submission*.

| File | Where it goes in App Store Connect |
| --- | --- |
| `metadata/en-US/name.txt` | App Information → Name (max 30 chars, must be unique on the store) |
| `metadata/en-US/subtitle.txt` | App Information → Subtitle (max 30) |
| `metadata/en-US/promotional_text.txt` | Version → Promotional Text (max 170, editable anytime) |
| `metadata/en-US/description.txt` | Version → Description (max 4000) |
| `metadata/en-US/keywords.txt` | Version → Keywords (max 100, comma-separated) |
| `metadata/en-US/release_notes.txt` | Version → What's New (not shown for 1.0) |
| `metadata/de-DE/*` | Optional German localization |
| `privacy-policy.md` | Host it publicly (e.g. GitHub Pages) → App Information → Privacy Policy URL |
| `app-privacy.md` | App Privacy questionnaire answers ("Data Not Collected") |
| `review-notes.md` | Version → App Review Information → Notes |
| `screenshots.md` | What to capture for the required screenshots |

Other settings:
- **Category:** Primary *Photo & Video*, secondary *Travel* (optional)
- **Age rating:** 4+ (answer "None" to every content question)
- **Price:** your choice; the app has no in-app purchases or ads
- **Export compliance:** already declared in the build (`ITSAppUsesNonExemptEncryption = NO`)
- **Support URL / Marketing URL:** required / optional. A GitHub Pages page works.
- **Copyright:** e.g. `2026 Moritz Wolf`
- **Device:** iPhone only. ARKit is required, so iPads aren't offered the app.
