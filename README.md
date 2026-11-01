# JustSpeak

> Built with [Claude Code](https://claude.ai/code) - AI-assisted development from concept to completion. 🤖

A lightweight macOS menu bar app for fully offline voice dictation. Hold your recording shortcut, speak, and your words appear at your cursor.

## Features

- **Offline Transcription** - Core speech-to-text runs locally with Parakeet on Apple’s Neural Engine
- **System-Wide** - Works in any application where you can type
- **Customizable Shortcut** - Hold Right Command by default, or record your preferred shortcut
- **Cancel Anytime** - Press Escape while holding to cancel recording
- **Private** - Audio and transcription stay on your Mac
- **Accurate** - Powered by NVIDIA's Parakeet TDT 0.6B v2 model
- **Native macOS** - Built with Swift, optimized for Apple Silicon

## Requirements

- macOS 14.6 or later
- Apple Silicon
- Microphone access permission

## Installation

### Download Pre-built App

Install the latest release with one command:

```bash
curl -fsSL https://raw.githubusercontent.com/zyuapp/just-speak/main/install.sh | sh
```

The script verifies the download's checksum and installs the signed, notarized
app in `/Applications` (or `~/Applications` when that is not writable).

Or install with Homebrew Cask:

```bash
brew install --cask zyuapp/tap/just-speak
```

Or download the latest DMG from the GitHub Releases page and drag Just Speak
to Applications. The same signed and notarized DMG is used for Sparkle updates.

### Build from Source

```bash
# Clone
git clone https://github.com/zyuapp/just-speak.git
cd just-speak

# Build with local development signing
make build

# Install an OTA-disabled Just Speak Dev build in /Applications
make install
```

The Makefile installs `/Applications/Just Speak Dev.app` with the
`com.zyu.just-speak.dev` bundle identifier, leaving the production app intact.
It uses an available Apple signing certificate from the local Keychain so the
dev app's microphone and Accessibility grants survive rebuilds. If no suitable
certificate is available, the build safely uses ad-hoc signing and warns that
macOS may request those permissions again.

Local builds are release-optimized but disable production OTA checks and are
not notarized. Tagged public releases retain `com.zyu.just-speak`, enable OTA,
and are signed, notarized, and published by GitHub Actions.

## Usage

1. **First Launch** - Grant microphone permission and wait for the Parakeet model download
2. **Record** - Hold Right Command by default and speak
3. **Transcribe** - Release the shortcut to stop and auto-paste
4. **Cancel** - Press Escape while recording to abort
5. **Customize** - Choose Change Shortcut… from the menu bar app
6. **Update** - Download and restart into new versions from the menu bar

## Tech Stack

- **SwiftUI + AppKit** - Menu bar app with NSApplicationDelegateAdaptor
- **AVFoundation** - Native audio recording (16kHz mono WAV)
- **FluidAudio + CoreML** - Local Parakeet inference on Apple’s Neural Engine
- **Native Integration** - Uses macOS microphone and accessibility APIs directly

## Development

See [CLAUDE.md](CLAUDE.md) for architecture details and development guidelines.
Third-party attributions and license texts are bundled with the app under
[`JustSpeak/ThirdPartyLicenses`](JustSpeak/ThirdPartyLicenses).

## Acknowledgments

- [FluidAudio](https://github.com/FluidInference/FluidAudio) - CoreML speech recognition runtime
- [NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) - English speech recognition model
