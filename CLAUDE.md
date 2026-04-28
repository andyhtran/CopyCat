# CopyCat

**CLI-only** — no Xcode. All builds use `swift build` via SPM. Use `just` as the task runner.

- macOS 14.0+, Swift 6.0+

```bash
just dev          # Kill, build, sign, install to /Applications/CopyCat Dev.app, launch
just clean        # Remove build artifacts
just reset-grants # Wipe Accessibility grants
```

## Releasing

Bump `MARKETING_VERSION` in `version.env`, push to main, then `just publish` — signs, notarizes, creates a GitHub release, and updates the Homebrew tap.

## Icons

Canonical sources are `Icons/AppIcon.svg` and `Icons/MenuBarIcon.svg`. Regenerate `Resources/AppIcon.icns` and `Resources/MenuBarIcon.pdf` via `bash Scripts/build-icons.sh`.

`MenuBarIcon.svg` ships as a template image (solid black on transparent only) — don't add fills, gradients, or non-alpha effects.
