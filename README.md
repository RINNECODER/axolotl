```text
                              ████▒▓
                           ░██▓▒█▓▓▓ ▓ ▒█░░▓
                     █░▒   :-==-;~+ ▓░░▓▓▓░  ▓      ▒
                    `:;-~=++**xxx+~~=+=*ox▒▒▓   ▓ ▓ ▒     ░
                 '`::-~~~=+*xxxoaox**=~~=+*xo·▒▓█░▒    ▒
               .`,,:-~~==+**xxxoaooooooxxx++oNA%B░▓             ░
           .  '`,::;;~=+*xooxx*xeO##%&&&&%###%@&%%E               ▒░▓
          ....'`::;~=+*xxx***xxxxoeO&@@@@&&&@@@@@@@%·             ▒▒░
      ░.     .'`,:;~++*******xxoooxaO&@@@@@@@&%@@&@@@S    ▓        ░
           ...''`,:-~++++=~+xxxxoooaaeeO#%&@@%Oe#&&%·%O  ▓ ▓        ░
   ░░     . .'''`,:;-~=~~~=+*xoaaaaBKIT·AXOLOTexoae#eoae █
   █..      .''`,:::;-~~~==*xxxoaaaT·AXOLOTL·BROaeaooooaxxoo░█▓     ▒  ░░
█▒▒█     ....'`,,:::;--~~~=++**xxoaR·SWIFT·WEaeaxxxoooooo+██
█▓░        ..'``,::;;;-~~=====++*xoT·AXOLOTL·Oao***xooeeex░▒
   .  .      '`,,:;;---~~===~~~=++xooaeaROWSEeax*+**xxaOea=
   ..  . ..  '`,,:;--~~~===+====++*xxoeOWEBKIaax+=+*+xaOOe+
░▓▒ .       ..'`,::;---~~~==++KIT·M**oaeGHT·AXOLOTL·B**xoeO#e*
▓▓▓           '``,,::::;;;;-=+·AXOLOTL*xoaeSER·SWIFT·OOOOOOOa*
 █▒.  . .  . . ''`,,,,,,::;-~+*xxxxT·WEBKIT·MaeO#%@%####Oe
 ▓▓▓ .     . .  ''`````,,::;-~=+xxoLIGHT·AXOLOTL#%%%&&ee%%%%#
   ▒.       .    .''````,:;;;~=+xxooooaaaaeO#%%%&e*=*O%#O▓░
   ░▓.            ''``,,,:;;-~=+*xxxxxooooeO##%&ex=+xOea ▒
         . .       ''`,,,::;-~ONLIG*xxxxoaeeOO##o**xoox▒▓
               .    .'`,,,,:;--ROWS+*xooxoooooooaox+*+▒
      █▒░.      ..  . '```,,:;-~~~~=+*xxxx**xxxx**=+
      ▒▒░   .       . . '``,::;---~~~~~=***xxxx*+~-
           ░░      ..     ''`,:::;--;;-~~=+==I;;;
             ▓▓▓..    ..  .  '``,,,,:::;;-;:,,
                  ░▓ ..   .     ..''''``''██▒
                  ▓▒▒░░█   .   . .        █▓░
                                       █░▓
```

<p align="center"><img src="site/icon.png" width="112" alt="Axolotl icon"></p>

<h1 align="center">Axolotl</h1>

<p align="center"><b>A quieter browser for the Mac.</b><br>
Native Swift and WebKit, with an AI assistant that shows up when you ask and stays out of the way when you don't.</p>

<p align="center"><sub>My browser, built on <a href="https://github.com/Rahul4301/Luna">Luna</a> by Rahul Suthar.</sub></p>

<p align="center">
  <a href="https://github.com/RINNECODER/axolotl-releases/releases/latest">Download</a> ·
  <a href="https://github.com/RINNECODER/axolotl/issues">Report an issue</a>
</p>

<p align="center">
  <img alt="macOS 15.4+" src="https://img.shields.io/badge/macOS-15.4%2B-111?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-WebKit-111?style=flat-square">
  <img alt="Xcode 26" src="https://img.shields.io/badge/Xcode-26-111?style=flat-square">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-111?style=flat-square">
</p>

> [!WARNING]
> Axolotl is in early development and not ready for everyday use yet. Expect rough edges, and please [tell us about them](https://github.com/RINNECODER/axolotl/issues).

> [!NOTE]
> Axolotl is my own customized variation of [Luna](https://github.com/Rahul4301/Luna), the open-source macOS browser by [Rahul Suthar](https://github.com/Rahul4301). Luna is the foundation; Axolotl reshapes it around my own ideas: Chrome- and Brave-style browsing, personalization of everything, and features that cost nothing when they're off. All credit for the original browser goes to Luna and its author.

---

## Why Axolotl

- **Native, not ported.** SwiftUI on WebKit, the engine behind Safari. No Electron, no Chromium.
- **Search first.** The start page sends lookups to Google. Chat is one `⌘↩` away, never in the way.
- **Bring your own model.** Sign in with ChatGPT, use an API key from Anthropic, OpenAI or Google Gemini, or run models locally with Ollama.
- **Private by default.** uBlock Origin Lite built in, API keys in your Keychain, nothing collected.

## Features

**Browsing**

- Tabs in a sidebar or along the top, with drag to reorder, pinned tabs and favorites
- Drag a tab into another window, or out onto the desktop for a new window
- Split view: drop one tab onto another to see both side by side
- Address bar with autocomplete, search suggestions and history
- Downloads hub, find in page, print, zoom and keyboard shortcuts for everything

**Axolotl AI**

- Side panel that chats about the page you're on (`⌘E`)
- Add other tabs or files as context: PDF, TXT, MD, JSON, CSV, XML, HTML
- Per-tab chat history with summaries
- Markdown, code and LaTeX in answers
- Browser commands in plain language: "open a new tab", "go to…"

**Privacy**

- uBlock Origin Lite, bundled
- API keys stored in the macOS Keychain
- App sandbox with minimal permissions

## Get Axolotl

1. Download `Axolotl-<version>.zip` from the [latest release](https://github.com/RINNECODER/axolotl-releases/releases/latest).
2. Unzip it and drag Axolotl into Applications. After that, Axolotl updates itself.
3. Open Axolotl. Axolotl isn't notarized yet, so the first time macOS warns that it can't verify the app. Click **Done**, then go to **System Settings › Privacy & Security**, scroll to Security and click **Open Anyway** next to the message about Axolotl. Confirm with your password. You only need to do this once.

## Bring your own model

Axolotl works with the provider you already use. Pick one in **Settings › AI & Models**:

| Provider | How it connects |
| --- | --- |
| ChatGPT | Sign in with your ChatGPT Plus or Pro account |
| Anthropic | API key from the Claude Console |
| OpenAI | API key from the OpenAI platform |
| Google Gemini | API key from Google AI Studio |
| Ollama | Any model running locally on your Mac; nothing leaves your computer |

API keys are stored in the macOS Keychain.

To run an open-weight model locally, install [Ollama](https://ollama.com/download) and pull a model, for example [gpt-oss](https://ollama.com/library/gpt-oss):

```bash
ollama run gpt-oss:120b
```

Then in Axolotl, open **Settings › AI & Models**, choose **Ollama** and pick the model.

## Build from source

You need Xcode 26 and macOS 15.4 or later.

```bash
git clone https://github.com/RINNECODER/axolotl.git
cd Axolotl
./scripts/setup.sh
```

Set your Apple Team ID in `Signing.xcconfig` (the setup script creates it). Find yours under [Membership details](https://developer.apple.com/account#MembershipDetailsCard):

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Then open `Axolotl.xcodeproj` and press `⌘R`.

The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) and isn't checked in. Run `xcodegen` again after changing `project.yml` or pulling changes to the project structure.

### Axolotl Dev (unsandboxed)

Dev mode drives the Claude Code and Codex CLIs, which can't run inside the App Sandbox. They run only in the **AxolotlDev** target. It builds the same sources without the sandbox, under its own bundle id (`com.axolotl.browser.dev`), so its settings and data stay separate from the regular app.

Pick the **AxolotlDev** scheme in Xcode and press `⌘R`, or build it from the command line:

```bash
xcodebuild -project Axolotl.xcodeproj -scheme AxolotlDev -configuration Debug build
```

`claude` and `codex` must already be installed and signed in. Axolotl finds them on your login shell's `PATH` (`zsh -lic`), so they need to work in Terminal first. The regular **Axolotl** scheme stays sandboxed and doesn't offer Dev mode.

## Releasing

Axolotl updates itself with [Sparkle](https://sparkle-project.org), like Chrome: it checks at launch and every 24 hours, downloads in the background, shows an **Update** button next to the ⋯ menu, and installs when you relaunch or quit. Binaries and the update feed live in the public [axolotl-releases](https://github.com/RINNECODER/axolotl-releases) repo; the feed is `releases/latest/download/appcast.xml`. Axolotl Dev doesn't include Sparkle.

```bash
./scripts/release.sh 1.0.3
```

It bumps the version in `project.yml`, archives the **Axolotl** scheme, exports it with Developer ID, notarizes and staples it when a notary profile exists (otherwise it ships Developer ID-signed only), signs the update with the Sparkle EdDSA key and publishes `Axolotl-<version>.zip` and `appcast.xml` as release `v<version>`. Commit the version bump afterwards.

One-time setup on the release Mac:

1. A **Developer ID Application** certificate: Xcode › Settings › Accounts › your team › Manage Certificates › + › Developer ID Application.
2. Optional, a notary profile: `xcrun notarytool store-credentials axolotl-notary --apple-id <Apple ID> --team-id <Team ID>` with an app-specific password from [account.apple.com](https://account.apple.com).
3. The Sparkle EdDSA private key in the login Keychain (account `axolotl`). Its public key is `SUPublicEDKey` in `Axolotl/Sparkle-Info.plist`. Back it up with Sparkle's `generate_keys --account axolotl -x <file>`; if it's lost, installed copies can't update.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘T` | New tab |
| `⌘W` | Close tab |
| `⌘L` | Focus the address bar |
| `⌘E` | Toggle the AI panel |
| `⌘F` | Find in page |
| `⌘Y` | History |
| `⌘1`–`⌘9` | Jump to a tab |
| `⌘+` / `⌘−` / `⌘0` | Zoom in, out, reset |

## Contributing

Contributions are welcome.

1. Fork the repo and create a branch: `git checkout -b feature/your-feature`
2. Run `./scripts/setup.sh` and set up signing as above.
3. Make your change, then build and test.
4. Don't commit `Signing.xcconfig` or anything containing your Team ID.
5. Open a pull request against `main`.

## License

[MIT](LICENSE). Use it, fork it and ship it, as long as the copyright notice comes along.

Agent mode (`/agent <goal>` in the AI panel) is a native port of [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) (MIT, Copyright (c) 2026 Browser Use).

## Credits

- **[Luna](https://github.com/Rahul4301/Luna)** by [Rahul Suthar](https://github.com/Rahul4301) (MIT). Axolotl started as a fork of Luna and keeps its MIT license and copyright notice. Thank you, Rahul.
- Agent mode: [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) (MIT, Copyright (c) 2026 Browser Use).
- Dev mode's chat layout and work log are inspired by [T3 Code](https://github.com/pingdotgg/t3code) (MIT). No T3 Code source is bundled.
- Terminal rendering: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT).
- Start page wallpapers are built from components of [Shaders](https://github.com/shader-effects-inc/shaders) by Shader Effects Inc. (MIT), running on [TypeGPU](https://github.com/software-mansion/TypeGPU) by Software Mansion (MIT). A trimmed build ships offline in `Axolotl/Wallpaper/WallpaperWeb`; licenses are in `LICENSE-shaders.txt` there. Rebuild it with `scripts/wallpaper/build.mjs`.
