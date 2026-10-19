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
   ░░     . .'''`,:;-~=~~~=+*xoaaaaBKIT·MOONLOexoae#eoae █
   █..      .''`,:::;-~~~==*xxxoaaaT·LUNA·BROaeaooooaxxoo░█▓     ▒  ░░
█▒▒█     ....'`,,:::;--~~~=++**xxoaR·SWIFT·WEaeaxxxoooooo+██
█▓░        ..'``,::;;;-~~=====++*xoT·MOONLIGHOao***xooeeex░▒
   .  .      '`,,:;;---~~===~~~=++xooaeaROWSEeax*+**xxaOea=
   ..  . ..  '`,,:;--~~~===+====++*xxoeOWEBKIaax+=+*+xaOOe+
░▓▒ .       ..'`,::;---~~~==++KIT·M**oaeGHT·LUNA·B**xoeO#e*
▓▓▓           '``,,::::;;;;-=+·LUNA*xoaeSER·SWIFT·OOOOOOOa*
 █▒.  . .  . . ''`,,,,,,::;-~+*xxxxT·WEBKIT·MaeO#%@%####Oe
 ▓▓▓ .     . .  ''`````,,::;-~=+xxoLIGHT·LUNA#%%%&&ee%%%%#
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

<p align="center"><img src="site/icon.png" width="112" alt="Luna icon"></p>

<h1 align="center">Luna</h1>

<p align="center"><b>A quieter browser for the Mac.</b><br>
Native Swift and WebKit, with an AI assistant that shows up when you ask and stays out of the way when you don't.</p>

<p align="center">
  <a href="https://rahul4301.github.io/Luna/">Website</a> ·
  <a href="https://github.com/Rahul4301/Luna/releases/latest">Download</a> ·
  <a href="https://github.com/Rahul4301/Luna/issues">Report an issue</a>
</p>

<p align="center">
  <img alt="macOS 15.4+" src="https://img.shields.io/badge/macOS-15.4%2B-111?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-WebKit-111?style=flat-square">
  <img alt="Xcode 26" src="https://img.shields.io/badge/Xcode-26-111?style=flat-square">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-111?style=flat-square">
</p>

> [!WARNING]
> Luna is in early development and not ready for everyday use yet. Expect rough edges, and please [tell us about them](https://github.com/Rahul4301/Luna/issues).

---

## Why Luna

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

**Luna AI**

- Side panel that chats about the page you're on (`⌘E`)
- Add other tabs or files as context: PDF, TXT, MD, JSON, CSV, XML, HTML
- Per-tab chat history with summaries
- Markdown, code and LaTeX in answers
- Browser commands in plain language: "open a new tab", "go to…"

**Privacy**

- uBlock Origin Lite, bundled
- API keys stored in the macOS Keychain
- App sandbox with minimal permissions

## Get Luna

1. Download `Luna.dmg` from the [latest release](https://github.com/Rahul4301/Luna/releases/latest).
2. Open it and drag Luna into Applications.
3. Open Luna. Luna isn't notarized yet, so the first time macOS warns that it can't verify the app. Click **Done**, then go to **System Settings › Privacy & Security**, scroll to Security and click **Open Anyway** next to the message about Luna. Confirm with your password. You only need to do this once.

## Bring your own model

Luna works with the provider you already use. Pick one in **Settings › AI & Models**:

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

Then in Luna, open **Settings › AI & Models**, choose **Ollama** and pick the model.

## Build from source

You need Xcode 26 and macOS 15.4 or later.

```bash
git clone https://github.com/Rahul4301/Luna.git
cd Luna
./scripts/setup.sh
```

Set your Apple Team ID in `Signing.xcconfig` (the setup script creates it). Find yours under [Membership details](https://developer.apple.com/account#MembershipDetailsCard):

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Then open `Luna.xcodeproj` and press `⌘R`.

The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) and isn't checked in. Run `xcodegen` again after changing `project.yml` or pulling changes to the project structure.

### Luna Dev (unsandboxed)

Dev mode drives the Claude Code and Codex CLIs, which can't run inside the App Sandbox. They run only in the **LunaDev** target. It builds the same sources without the sandbox, under its own bundle id (`com.luna.browser.dev`), so its settings and data stay separate from the regular app.

Pick the **LunaDev** scheme in Xcode and press `⌘R`, or build it from the command line:

```bash
xcodebuild -project Luna.xcodeproj -scheme LunaDev -configuration Debug build
```

`claude` and `codex` must already be installed and signed in. Luna finds them on your login shell's `PATH` (`zsh -lic`), so they need to work in Terminal first. The regular **Luna** scheme stays sandboxed and doesn't offer Dev mode.

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

## Credits

Start page wallpapers are built from components of [Shaders](https://github.com/shader-effects-inc/shaders) by Shader Effects Inc. (MIT), running on [TypeGPU](https://github.com/software-mansion/TypeGPU) by Software Mansion (MIT). A trimmed build ships offline in `Luna/Wallpaper/WallpaperWeb`; licenses are in `LICENSE-shaders.txt` there. Rebuild it with `scripts/wallpaper/build.mjs`.

## License

[MIT](LICENSE). Use it, fork it and ship it, as long as the copyright notice comes along.

Agent mode (`/agent <goal>` in the AI panel) is a native port of [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) (MIT, Copyright (c) 2026 Browser Use).

## Credits

- Agent mode: [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) (MIT, Copyright (c) 2026 Browser Use).
- Dev mode's chat layout and work log are inspired by [T3 Code](https://github.com/pingdotgg/t3code) (MIT). No T3 Code source is bundled.
- Terminal rendering: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT).
