# Watt

Watt is a lightweight, native macOS menu-bar utility for monitoring Claude and Codex subscription limits. It automatically shows every supported harness configured on the Mac: Claude, Codex, or both. It includes an optional draggable floating HUD and has no Dock icon, analytics, telemetry, third-party backend, or third-party dependencies.

## Quick start

Requirements: macOS 14 or newer, Claude Code and/or Codex installed and signed in, and Xcode 16 or recent Swift 6 Command Line Tools.

```sh
./scripts/build-app.sh release
open .build/Watt.app
```

The script builds, packages, and ad-hoc signs `.build/Watt.app`. Full Xcode is optional; open `Watt.xcodeproj` if you prefer its Run workflow. To keep Watt in a stable location, drag the built app into `/Applications` and open that copy.

On first launch, Watt discovers supported harnesses and shows one compact HUD row per configured harness. Turn off **Keep Visible** in the menu-bar popover if you want to use only the menu-bar item; Watt remembers that choice.

On first use, macOS may ask Watt for access to the `Claude Code-credentials` Keychain item. Choose **Allow** or **Always Allow**. Watt extracts the OAuth access token in memory and stores its own app-restricted copy in the user's login Keychain—never in the project or UserDefaults. The login Keychain is used intentionally so locally/ad-hoc signed builds work without a paid signing-team Keychain entitlement.

For a network-free UI demo showing both harnesses:

```sh
./scripts/build-app.sh debug
open -n .build/Watt.app --args --demo --show-hud
```

Add `--expanded-hud` to start with the HUD expanded. Demo flags exist only in Debug builds.

Use `--demo-claude-only` or `--demo-codex-only` instead of `--demo` to preview either single-harness layout.

## Launch at login

Use **Launch at Login** in Watt’s menu-bar popover. This uses Apple’s `SMAppService`; it launches after the user logs in, not before the macOS login screen. Move Watt to `/Applications` first so cleaning the repository’s `.build` directory cannot remove the registered app. macOS may require approval in **System Settings › General › Login Items**.

When replacing a development build manually, turn **Launch at Login** off in the old copy, quit Watt, replace `/Applications/Watt.app`, open the new copy, and turn **Launch at Login** back on. A Homebrew installation always uses the stable `/Applications/Watt.app` location, so the login item should continue to target the same path after an upgrade. Because Watt is currently ad-hoc signed, verify this once with a real cask upgrade before publishing broadly.

## Releases and Homebrew

Watt currently ships an Apple Silicon release archive. Build it locally with a semantic version and positive build number:

```sh
./scripts/package-release.sh 1.0.0 1
```

This creates `dist/Watt-1.0.0-macos-arm64.zip` plus its SHA-256 file. The archive contains an ad-hoc signed app whose embedded version is set from the command line without modifying the source `Info.plist`.

Pushing a tag such as `v1.0.0` runs the release workflow, tests Watt, builds the archive on an Apple Silicon GitHub runner, generates `watt.rb` for the repository, and creates the GitHub release. The workflow can also be run manually; in that case it creates the matching tag.

To make the cask after the release archive exists, substitute your real GitHub source repository:

```sh
./scripts/generate-cask.sh josipmusa/watt 1.0.0
```

Copy the generated `dist/watt.rb` to `Casks/watt.rb` in the separate public repository `josipmusa/homebrew-tap`. Homebrew strips the conventional `homebrew-` prefix, so users address that repository as the shorter tap name `josipmusa/tap` and install Watt with:

```sh
brew install --cask josipmusa/tap/watt
open -a Watt
```

Watt is currently ad-hoc signed and not notarized. After trying to open it once, macOS may require the user to open **System Settings › Privacy & Security**, scroll to **Security**, and choose **Open Anyway**. Users should override Gatekeeper only when they trust the tap and release. This approval may be required again after an upgrade because each ad-hoc build has a different signing identity. A future Developer ID-signed and notarized build removes this friction.

An advanced alternative, after verifying that the tap and release are the intended ones, is to remove only the quarantine attribute and then open Watt:

```sh
xattr -dr com.apple.quarantine /Applications/Watt.app
open /Applications/Watt.app
```

Do not use `xattr -cr` here: it clears every extended attribute recursively, while the targeted command above removes only `com.apple.quarantine`. Homebrew may apply quarantine to the replacement app again during a later upgrade, requiring this step to be repeated.

For each update, publish a new tag, download the `watt.rb` generated alongside that GitHub release, and commit the cask to `homebrew-tap`. The release-generated cask must be used because its checksum matches the archive built by GitHub Actions. Homebrew users update with:

```sh
brew update
brew upgrade --cask watt
open -a Watt
```

Homebrew replaces the app in `/Applications` and may quit it during the upgrade, so `open -a Watt` starts the new build immediately. Otherwise, an enabled login item starts it at the next login. This initial setup intentionally keeps tap updates manual; automating changes to a second repository would require a narrowly scoped GitHub App or token.

## License

Watt is available under the MIT License. See `LICENSE`.

## Authentication, network, and privacy

For Claude subscription usage, Watt reads only the macOS generic-password item with service `Claude Code-credentials`, then stores its imported token under service `app.watt.Watt.oauth`, account `claude-oauth-access-token`. All credential fixtures are synthetic. No real credential, username, home-directory path, or machine-specific configuration is included in this repository.

Claude usage is requested directly from Anthropic:

```text
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <OAuth token from Keychain>
anthropic-beta: oauth-2025-04-20
```

The endpoint is internal and undocumented, so all endpoint headers, response DTOs, and model-specific parsing are isolated in `ClaudeOAuthUsageProvider`. It may need updating if Anthropic changes the endpoint. Watt never reads prompts, conversations, Claude transcripts, projects, or source code.

If the Keychain subscription credential is absent, Watt checks `claude auth status --json` once and recognizes environment-token, API-key, Bedrock, Vertex, and Foundry configurations. Those configurations remain visible in Watt with an explanation that personal subscription quota is unavailable; Watt does not import their secrets. Set `WATT_CLAUDE_PATH` when testing a non-standard Claude CLI location.

For Codex, Watt looks for the CLI in the current `PATH`, Homebrew locations, `~/.local/bin`, `~/.codex/bin`, and the Codex app bundle. It starts one long-lived `codex app-server` child process and uses the documented JSONL protocol methods `account/read` and `account/rateLimits/read`. Codex retains ownership of authentication and token refresh; Watt never reads or copies Codex credentials. API-key and Bedrock configurations are detected but do not expose ChatGPT subscription limits.

Set `WATT_CODEX_PATH` to an executable path when testing a non-standard Codex installation.

## Development

```sh
swift build
swift test
```

Codex normally refreshes every 60 seconds and Claude every 5 minutes. Each harness has an independent schedule, so one provider succeeding cannot cancel another provider's backoff. Opening the popover refreshes only stale providers. Claude 429 responses honor `Retry-After` and otherwise back off through 5, 15, 30, and 60 minute intervals with jitter. The last result and provider cooldown are cached in `~/Library/Application Support/Watt/usage-cache.json`, preventing menu opens and app relaunches from repeatedly hitting a throttled endpoint. UserDefaults contains only HUD visibility and position; credentials remain in Keychain.
