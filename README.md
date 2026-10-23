# LegacyPodClaw

[![GitHub release](https://img.shields.io/github/v/release/wrxck/LegacyPodClaw?color=red)](https://github.com/wrxck/LegacyPodClaw/releases)
[![Platform](https://img.shields.io/badge/platform-iOS%206-blue)](https://github.com/wrxck/LegacyPodClaw)
[![Architecture](https://img.shields.io/badge/arch-ARMv7-orange)](https://github.com/wrxck/LegacyPodClaw)
[![Language](https://img.shields.io/badge/language-Objective--C-yellow)](https://github.com/wrxck/LegacyPodClaw)
[![License](https://img.shields.io/github/license/wrxck/LegacyPodClaw)](LICENSE)

> **Formerly known as ClawPod.** Renamed to LegacyPodClaw to avoid a naming conflict with an existing project.

**AI assistant for iOS 6** — a native Objective-C port of [OpenClaw](https://openclaw.ai) for jailbroken devices.

~19,000 lines of Objective-C. One vendored dependency ([wolfSSL](https://www.wolfssl.com/) for TLS 1.2). Everything else is hand-written for the memory constraints of legacy iOS 6 hardware.

## Supported Devices

LegacyPodClaw supports **all iOS 6 devices**:

| Device | RAM | iOS Version | Notes |
|--------|-----|-------------|-------|
| iPod Touch 4th gen | 256MB | 6.0–6.1.6 | Requires headset mic for voice input |
| iPhone 3GS | 256MB | 6.0–6.1.6 | |
| iPhone 4 | 512MB | 6.0–6.1.3 | |
| iPhone 4S | 512MB | 6.0–6.1.3 | Home hold intercepts Siri |
| iPad 2 | 512MB | 6.0–6.1.3 | |
| iPad 3rd gen | 1GB | 6.0–6.1.3 | |
| iPad mini 1st gen | 512MB | 6.0–6.1.3 | |

## Quick Start

1. Grab the `.deb` from [Releases](https://github.com/wrxck/LegacyPodClaw/releases)
2. Install via SSH, iFile, or Filza (see [Install](#install))
3. **Settings → LegacyPodClaw → Local Agent** → Enter your API key
4. **Hold the home button** → LegacyPodClaw appears

## How It Works

LegacyPodClaw hooks into iOS via MobileSubstrate to replace system surfaces with AI-powered alternatives:

| Gesture | What Happens |
|---------|-------------|
| Hold home button | AI overlay (replaces Voice Control/Siri) |
| Swipe left from home | Dashboard (replaces Spotlight) |
| Pull down Notification Center | Quick-ask widget |
| Lock device | Status display on lock screen |
| Double-tap home | Widget page in app switcher |
| Shake in any app | Opens AI overlay |

## Features

**AI Providers** — Pick the provider, model, API key and base URL in the app's Settings. The in-app chat, the chat channels and the gateway server use that choice. Two adapters do the work, both with streaming and tool calling:

- Anthropic Messages API (default model `claude-sonnet-5-5`; also `claude-opus-5-5`, `claude-haiku-5-5`, `claude-fable-5-1`)
- OpenAI-compatible chat completions, shared by OpenAI, Google Gemini (through its OpenAI-compatible endpoint), Groq, Together AI, OpenRouter, Mistral, DeepSeek, Ollama and any custom endpoint

Each provider keeps its own API key in the keychain. HTTPS goes through wolfSSL; plain HTTP is allowed for a local server such as Ollama. There is no automatic failover between providers. The home-button overlay and the Notification Center widget always use Anthropic. The widget needs the SpringBoard tweak, because it sends HTTPS through the tweak's wolfSSL client.

**Tool System** — Shell execution, file operations, web search, Notes & Reminders (direct database writes), Messages.app integration, system controls (brightness, volume, app launching), YouTube music search & download, device diagnostics, persistent memory.

**Chat Channels** — Talk to the assistant from Telegram (long polling), Discord (gateway websocket), Slack (Socket Mode, so no public URL is needed), IRC (plain or TLS) and a generic webhook. Set each one up in the app: Settings, Chat Channels. Every chat gets its own conversation, and the reply goes back to the same chat. Each channel has an allow list of user or chat IDs; messages from anyone else are ignored, and an empty list ignores everyone. Chat text is untrusted, so channel conversations get no tools unless you turn on "Tools in Chats", and even then the device asks you to approve every tool call. In Discord and Slack channels, and IRC rooms, the bot answers only when it is mentioned or addressed by nick. Channels run while the app runs; iOS 6 suspends a backgrounded app after about ten minutes.

**Gateway Server** — Run the device as an OpenClaw-compatible API server (HTTP + WebSocket on port 18789). The webhook channel receives messages through `POST /webhook/incoming` on this server, with the gateway access token as a bearer token, and posts replies to your callback URL. With "Start on Boot" on, the app starts the server and channels when the tweak signals that SpringBoard has booted, if the app is running.

**Plugins** — The app loads `.bundle` plugins from `/Library/LegacyPodClaw/Plugins`. It refuses the directory or a bundle unless root owns it and neither group nor others can write to it, so only a package installed as root can add code. A plugin's principal class conforms to `OCPlugin` (see `Frameworks/Plugin/PluginSDK.h`). `providedTools` returns `OCToolDefinition` objects or dictionaries with `name`, `description`, `inputSchema` and a `handler` block; the app always asks before a plugin tool runs, and a plugin tool cannot replace a built-in one. `providedChannels` returns objects that conform to `OCChannel`; set their allow list with the `<channelId>AllowedIds` preference.

**System Daemon** — `clawpodd` provides root-level access via CPDistributedMessagingCenter IPC: battery/hardware info via IOKit, syslog monitoring, sandbox reading.

**Safety** — Protected system paths, blocked dangerous commands, rate limiting, confirmation prompts for destructive operations.

## Install

**Requirements:** Jailbroken iOS 6.0–6.1.6 device with MobileSubstrate and PreferenceLoader.

<details>
<summary><b>SSH via USB (macOS/Linux)</b></summary>

```bash
brew install libimobiledevice sshpass
iproxy 2222:22 &

sshpass -p 'alpine' scp \
  -o HostKeyAlgorithms=ssh-rsa \
  -o KexAlgorithms=diffie-hellman-group14-sha1 \
  -P 2222 \
  pro.matthesketh.legacypodclaw_0.3.0_iphoneos-arm.deb \
  root@127.0.0.1:/tmp/legacypodclaw.deb

sshpass -p 'alpine' ssh \
  -o HostKeyAlgorithms=ssh-rsa \
  -o KexAlgorithms=diffie-hellman-group14-sha1 \
  -p 2222 root@127.0.0.1 \
  'dpkg -i /tmp/legacypodclaw.deb && su mobile -c /usr/bin/uicache && killall SpringBoard'
```
</details>

<details>
<summary><b>SSH via WiFi</b></summary>

Find your device IP in **Settings → Wi-Fi → (i)**, then:

```bash
scp -o HostKeyAlgorithms=ssh-rsa \
  pro.matthesketh.legacypodclaw_0.3.0_iphoneos-arm.deb \
  root@DEVICE_IP:/tmp/legacypodclaw.deb

ssh -o HostKeyAlgorithms=ssh-rsa root@DEVICE_IP \
  'dpkg -i /tmp/legacypodclaw.deb && su mobile -c /usr/bin/uicache && killall SpringBoard'
# Default password: alpine
```
</details>

<details>
<summary><b>SSH via USB (Windows)</b></summary>

1. Install [iTunes](https://www.apple.com/itunes/) (USB drivers)
2. Run [iproxy](https://github.com/libimobiledevice-win32/imobiledevice-net): `iproxy 2222 22`
3. Connect with [WinSCP](https://winscp.net/) → `127.0.0.1:2222` (root/alpine)
4. Upload `.deb` to `/tmp/legacypodclaw.deb`
5. In PuTTY: `dpkg -i /tmp/legacypodclaw.deb && su mobile -c /usr/bin/uicache && killall SpringBoard`
</details>

<details>
<summary><b>iFile / Filza</b></summary>

Transfer the `.deb` to your device → Open in iFile or Filza → Tap Install → Respring.
</details>

> **Note:** iOS 6 uses legacy SSH algorithms. If you see `no matching host key type found`, add `-o HostKeyAlgorithms=ssh-rsa -o KexAlgorithms=diffie-hellman-group14-sha1` to your SSH/SCP commands.

## Music Downloads

LegacyPodClaw can search YouTube and download songs to the Music app. Search works directly on device via YouTube's InnerTube API. Downloading requires a lightweight proxy server running on your network (YouTube now requires JavaScript signature deciphering that can't run on iOS 6).

```bash
pip3 install yt-dlp
python3 LegacyPodClawMCP/music_proxy.py
```

Then set the proxy URL in **Settings → LegacyPodClaw → Local Agent → Music Proxy URL** to `http://YOUR_COMPUTER_IP:18790`.

## Building from Source

```bash
export THEOS=~/theos
export PATH="$THEOS/bin:$PATH"

# Get SDKs (if needed)
cd $THEOS/sdks
curl -sLO https://github.com/theos/sdks/archive/master.tar.gz
tar xzf master.tar.gz --strip-components=1 && rm master.tar.gz

# Build
cd /path/to/LegacyPodClaw
make clean && make package FINALPACKAGE=1
```

## LegacyPodClawMCP

A Python MCP server for AI-assisted iOS 6 development — SSH/SCP, class-dumping, private header search, Theos build/install, crash analysis.

```bash
pip3 install mcp paramiko
python3 LegacyPodClawMCP/server.py
```

See [LegacyPodClawMCP/README.md](LegacyPodClawMCP/README.md) for details.

## Architecture

| Component | Description |
|-----------|------------|
| **LegacyPodClaw.app** | Main application — chat UI, agent loop, tool execution, model providers, chat channels, plugins |
| **LegacyPodClawTweak** | MobileSubstrate tweak — home button, Spotlight, lock screen, NC, app switcher hooks |
| **LegacyPodClawNC** | Notification Center widget (BBWeeAppController) |
| **LegacyPodClawPrefs** | Settings.app preference bundle |
| **LegacyPodClawDaemon** | Root daemon (`clawpodd`) — IPC, IOKit, syslog |
| **wolfSSL** | Vendored TLS 1.2 library (iOS 6 system SSL only supports TLS 1.0) |

| Metric | Value |
|--------|-------|
| Source files | 77 |
| Lines of code | ~19,700 |
| Package size | ~400KB |
| Target | ARMv7, iOS 6.0+ |

## What Changed in v0.3.0

- **Renamed** from ClawPod to LegacyPodClaw (naming conflict with existing project)
- **Expanded device support** to all iOS 6 devices (iPhone 3GS/4/4S, iPad 2/3/mini, iPod Touch 4)
- **Fixed tweak filter** — no longer loads into every app (was `com.apple.UIKit`, now `com.apple.springboard`). This fixes interference with Camera.app and other apps
- **Fixed uninstall** — resprings on removal so tweak hooks don't persist after uninstall
- **Added iPhone 4S support** — hooks Siri activation (`SBAssistantController`) in addition to Voice Control
- **Added iPad support** — UIDeviceFamily includes iPad, layout adapts to screen size
- **Updated package identifier** to `pro.matthesketh.legacypodclaw`

## Providers and Channels Removed or Limited

- **Automatic provider failover** was removed. It never ran, and a silent switch to another provider would send your data somewhere you did not choose.
- **Gemini** is supported only through Google's OpenAI-compatible endpoint, not the native `generateContent` API.
- **Slack incoming webhooks and the Events API** were removed. Both need a public URL that a device on a home network does not have; Socket Mode replaces them.
- **Telegram, Discord and Slack reactions, edits and deletes** were removed. Nothing used them.

## Credits

- [Matt Hesketh](https://github.com/wrxck)
- Based on [OpenClaw](https://openclaw.ai)
- Inspired by [PicoClaw](https://github.com/sipeed/picoclaw) and [NanoClaw](https://github.com/qwibitai/nanoclaw)
- Built with [Theos](https://theos.dev)
- Headers from [iOS-6-Headers](https://github.com/pigigaldi/iOS-6-Headers)

## License

MIT
