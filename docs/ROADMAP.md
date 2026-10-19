# Luna Roadmap

Where Luna is headed. Nothing here is a promise or a date; items move as we learn.
Have an idea or want to pick something up? [Open an issue](https://github.com/Rahul4301/Luna/issues).

**Status key:** 🔍 In review (a pull request exists) · 🛠 Next · 🌙 Later · 💭 Exploring

## Agents and computer use

| | Feature | Notes |
|---|---|---|
| 🔍 | Computer-use agent in the AI panel | `/agent <goal>` drives the current tab. Each step is picked by TypeSafe Jev from a DOM snapshot, with your chosen model as fallback. Ported from browser-use/jev-ultrafast (MIT). |
| 🔍 | MCP bridge for outside agents | Claude Code, Codex and other MCP clients get Luna's browser tools over loopback, with a token and per-session approval. |
| 🔍 | Key grabber | The agent creates an API key and saves it to the Keychain and clipboard. Agents and models never see the value. |
| 🔍 | Dev mode (Luna Dev build) | Runs Claude Code and Codex from the sidebar: chat and a real terminal on one session, auto-found projects and sessions, live sync with sessions open in other terminals. |
| 🛠 | More agent harnesses | Gemini CLI, opencode, Cursor agent and pi via a generic ACP adapter. |
| 🛠 | Agent runs across tabs | Let one agent task open, read and act on several tabs, with a step timeline. |
| 🌙 | Scheduled and background agents | Run a saved agent task on a schedule ("check my orders every morning") with a results inbox. |
| 🌙 | Native input fallback | Real mouse and keyboard events for sites that ignore synthetic DOM events. |
| 💭 | Local computer-use model | A small on-device model as the step picker, so agent mode works offline. |

## Personalization and look

| | Feature | Notes |
|---|---|---|
| 🔍 | Personalization (opt-in, local) | Usage stays on your Mac. The AI can change Luna only through a typed settings list, with preview and undo. |
| 🔍 | Layout templates | Luna and Chrome. Applying a template is one undoable change. |
| 🔍 | Shader wallpapers and a shader moon | WebGPU wallpapers for the start page, built on the MIT `shaders` library. |
| 🛠 | Liquid Glass toggle and custom menus | Turn Liquid Glass off for a solid look. Menus are custom, Chrome-style. |
| 🛠 | More templates | Safari and Arc layouts. |
| 🌙 | Wallpaper gallery | Import your own shader presets and share them. |

## Passwords, accounts and import

| | Feature | Notes |
|---|---|---|
| 🔍 | No more Keychain prompts | Moves to the data protection keychain with Luna's access group; existing items are migrated once. |
| 🔍 | iCloud Keychain sync | Luna's saved logins sync across your Macs, matched by profile name. API keys stay on one device. |
| 🔍 | Import from other browsers | Chrome, Brave, Edge, Vivaldi, Arc and Firefox bookmarks and history, plus Safari's bookmark export. Optional keep-in-sync. |
| 🔍 | 1Password import | Import logins from a 1Password `.1pux` or CSV export. |
| 🛠 | **1Password live integration** | See [1Password](#1password) below. |
| 🛠 | Onboarding | A short first run: default browser, import, AI sign-in, look and privacy. |
| 🛠 | Passkeys | WebAuthn and passkeys in web pages. This needs Apple's browser passkey entitlement. |
| 🌙 | Other password managers | Bitwarden (CLI and export), Dashlane and Proton Pass exports. |
| 🌙 | Import open tabs and extensions | Restore your Chrome or Arc session and suggest matching extensions. |

### 1Password

1Password matters to many people who would try Luna, so we want first-class support. In three steps:

1. **Now: Universal Autofill.** 1Password for Mac can fill logins in any app with ⌘\. Luna will document this and test that it works on Luna's web views, including focus and field detection.
2. **Next: import.** A `.1pux` or CSV export imports into Luna's vault, with guided steps and a reminder to delete the export file. This is in review.
3. **Next: live integration.** Fill, save and generate passwords from 1Password inside Luna without keeping a copy:
   - **Browser extension.** Run the 1Password extension through Luna's extension host. The extension only talks to the 1Password app from browsers 1Password has verified, so Luna needs to get on 1Password's supported-browser list. We'll reach out to 1Password.
   - **1Password CLI (`op`).** In the Luna Dev build, an "Autofill from 1Password" action using `op` with biometric unlock. No secrets are stored in Luna.
   - **Agent key grabber.** Optionally save grabbed API keys to a 1Password vault instead of the Keychain.

## Browsing

| | Feature | Notes |
|---|---|---|
| 🛠 | Tab groups and saved sessions | Named groups that sync with the sidebar folders. |
| 🛠 | Reader mode and page translation | Built on the configured AI provider, with an on-device option. |
| 🌙 | Study mode | Focus timer with optional on-device attention detection (from `THINGS_TO_DO.md`). |
| 🌙 | Bundled local model | A small (6–7B) fine-tuned model that runs on your Mac, and Ollama Cloud as a provider option (from `THINGS_TO_DO.md`). |
| 💭 | Sync across devices | Bookmarks, history, settings and open tabs through iCloud (CloudKit), end-to-end encrypted. |
| 💭 | Luna for iPad | Shared core with a touch-first shell. |

## Quality

| | Feature | Notes |
|---|---|---|
| 🛠 | Settings cleanup | Fewer panes and clearer labels. No setting in two places, and pickers instead of typed values. |
| 🛠 | Notarized releases | Signed, notarized DMG so the "Open Anyway" step goes away. |
| 🌙 | Accessibility pass | VoiceOver labels everywhere, full keyboard navigation, Reduce Motion and Increase Contrast. |
| 🌙 | Performance budget | Track memory per tab, startup time and energy impact in CI. |
