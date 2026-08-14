<p align="center">
  <img src="docs/images/watt-icon.png" width="144" alt="Watt app icon">
</p>

<h1 align="center">Watt</h1>

Watt is a lightweight, native macOS menu-bar app for monitoring Claude Code and Codex subscription usage. It detects Claude Code and Codex when they are installed, shows the limits that matter at a glance, and stays out of the Dock.

![Watt showing Claude and Codex usage](docs/images/watt-popover.png)

## Install

Watt requires macOS 14 or newer on Apple Silicon, plus Claude Code and/or Codex installed and signed in.

```sh
brew install --cask josipmusa/tap/watt
open -a Watt
```

Watt is not currently notarized. If macOS blocks it, try opening Watt once, then go to **System Settings › Privacy & Security** and choose **Open Anyway**. Alternatively, remove only the quarantine attribute and open Watt:

```sh
xattr -dr com.apple.quarantine /Applications/Watt.app
open /Applications/Watt.app
```

## Use without Homebrew

Download the latest `Watt-*-macos-arm64.zip` from [GitHub Releases](https://github.com/josipmusa/watt/releases/latest), unzip it, and move `Watt.app` to `/Applications`. Open it from there.

The same macOS security prompt described above may appear.

## Usage

Launch Watt and click its menu-bar item to see current usage and reset times for Claude Code and Codex. You can choose which limit to show in the menu bar and enable **Launch at Login** from the bottom of the popover if wanted.

Claude and Codex authentication remain managed by their respective command-line tools. Watt asks each installed tool for usage information and never reads their credentials.

## Privacy

Watt has no analytics, telemetry, third-party backend, or third-party dependencies. It requests usage through the installed Claude Code and Codex tools, never reads prompts, conversations, projects, source code, or authentication credentials.

## License

[MIT](LICENSE)
