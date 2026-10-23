# LegacyPodClaw

[![GitHub release](https://img.shields.io/github/v/release/wrxck/LegacyPodClaw?color=red)](https://github.com/wrxck/LegacyPodClaw/releases)
[![Platform](https://img.shields.io/badge/platform-iOS%206-blue)](https://github.com/wrxck/LegacyPodClaw)
[![Architecture](https://img.shields.io/badge/arch-ARMv7-orange)](https://github.com/wrxck/LegacyPodClaw)
[![Language](https://img.shields.io/badge/language-Objective--C-yellow)](https://github.com/wrxck/LegacyPodClaw)
[![License](https://img.shields.io/github/license/wrxck/LegacyPodClaw)](LICENSE)

> **Earlier name: ClawPod.** The project changed its name to LegacyPodClaw, because another project uses the name ClawPod.

**An AI assistant for iOS 6.** LegacyPodClaw is a native Objective-C port of [OpenClaw](https://openclaw.ai) for jailbroken devices.

The code has about 22,000 lines of Objective-C. It has one vendored dependency: [wolfSSL](https://www.wolfssl.com/) 5.9.4 for TLS 1.2. The rest is written for the small memory of iOS 6 hardware.

Documentation: <https://legacypodclaw.hesketh.pro/>

## Supported devices

LegacyPodClaw runs on all iOS 6 devices:

| Device | RAM | iOS version | Notes |
|--------|-----|-------------|-------|
| iPod touch 4th gen | 256 MB | 6.0 to 6.1.6 | |
| iPhone 3GS | 256 MB | 6.0 to 6.1.6 | |
| iPhone 4 | 512 MB | 6.0 to 6.1.3 | |
| iPhone 4S | 512 MB | 6.0 to 6.1.3 | The home-button hold opens the overlay, not Siri |
| iPad 2 | 512 MB | 6.0 to 6.1.3 | |
| iPad 3rd gen | 1 GB | 6.0 to 6.1.3 | |
| iPad mini 1st gen | 512 MB | 6.0 to 6.1.3 | |

## Quick start

1. Get the `.deb` from [Releases](https://github.com/wrxck/LegacyPodClaw/releases).
2. Install it through SSH, iFile or Filza. See [Install](#install).
3. Go to **Settings > LegacyPodClaw > Local Agent** and enter your Anthropic key in **Anthropic Key**.
4. Hold the home button. The LegacyPodClaw overlay opens.

To use a different provider, open the app, tap the gear button and set **Model Provider**.

## Entry points

The tweak loads only into SpringBoard.

| Action | Result |
|---|---|
| Hold the home button | The overlay opens. It replaces Voice Control, or Siri on the iPhone 4S. |
| Swipe left from the first home screen page | The dashboard opens in place of Spotlight |
| Pull down Notification Center | The quick-ask widget shows |
| Lock the device | A status label shows below the date |
| Double-click the home button | The app switcher has a LegacyPodClaw status page |
| Shake the device on the home screen | The overlay opens |
| Use the lock screen camera gesture with no passcode | The device unlocks and the overlay opens |

The overlay never opens while the device is locked. The overlay and the widget have no tools.

## Features

**AI providers.** Select the provider, model, API key and base URL in the app's Settings screen. The in-app chat, the chat channels and the gateway server use that choice. Two adapters do the work. Both stream the reply and support tool calls:

- The Anthropic Messages API. The default model is `claude-sonnet-5-5`. The suggested models are `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` and `claude-fable-5-1`.
- OpenAI-compatible chat completions. OpenAI, Google Gemini (through its OpenAI-compatible endpoint), Groq, Together AI, OpenRouter, Mistral, DeepSeek, Ollama and a custom endpoint use it.

Each provider keeps its own API key in the keychain. HTTPS goes through wolfSSL. Plain HTTP is allowed for a local server such as Ollama. There is no automatic failover between providers. The home-button overlay and the Notification Center widget use the same provider as the app. The widget needs the SpringBoard tweak, because it sends HTTPS through the tweak's wolfSSL client.

**Tools.** The app has tools for the shell, files, the web, Notes, Reminders (EventKit) and Messages. It also has system controls (brightness, volume, Wi-Fi, app launch, lock), YouTube music, device information and a persistent memory. Every tool call goes through one dispatcher. The dispatcher checks the input, applies the path guardrails, enforces a timeout and asks you before a risky tool runs. The approval alert has **Allow** and **Deny** buttons. Up to two MCP servers can add more tools.

**Chat channels.** Talk to the assistant from Telegram (long polling), Discord (gateway WebSocket), Slack (Socket Mode), IRC (plain or TLS) and a generic webhook. Slack Socket Mode needs no public URL. Set up each channel in the app: Settings, Chat Channels. Each chat gets its own conversation, and the reply goes back to the same chat. Each channel has an allow list of user or chat IDs. The app ignores messages from all other senders, and an empty list ignores everyone. Chat text is untrusted, so channel conversations get no tools unless you turn on **Tools in Chats**. Then the device asks you to approve every tool call. In Discord and Slack channels, and in IRC channels, the bot answers only when you mention it or address it by nick. The channels run only while the app runs.

**Gateway server.** Run the device as an OpenClaw-compatible API server (HTTP and WebSocket on port 18789). Each request needs a random 256-bit access token, except `GET /healthz`. The webhook channel receives messages through `POST /webhook/incoming` on this server, with the access token as a bearer token. It posts replies to your callback URL. With **Start on Boot** on, the app starts the server and the channels after SpringBoard boots. The app must already run.

**Remote gateway.** The app can connect to an OpenClaw gateway (protocol v3) with a token or password. A self-signed certificate needs a SHA-256 pin.

**Plugins.** The app loads `.bundle` plugins from `/Library/LegacyPodClaw/Plugins`. It refuses the directory or a bundle unless root owns it and neither group nor others can write to it. Only a package that installs as root can thus add code. A plugin's principal class conforms to `OCPlugin` (see `Frameworks/Plugin/PluginSDK.h`). `providedTools` returns `OCToolDefinition` objects or dictionaries with `name`, `description`, `inputSchema` and a `handler` block. The app always asks before a plugin tool runs, and a plugin tool cannot replace a built-in tool. `providedChannels` returns objects that conform to `OCChannel`. Set their allow list with the `<channelId>AllowedIds` preference.

**System daemon.** `clawpodd` answers fixed read-only questions (ping, status, battery, processes, crash list and an allow-listed sysctl) over `CPDistributedMessagingCenter`. It also keeps the API keys and tokens in the keychain and serves them over a mach service. It starts as root to register its services, then drops to `mobile`.

**Safety.** The tool guardrails block writes to system paths and reads of the keychain and other private data. `bash` has no command denylist. You approve each command. See [SECURITY.md](SECURITY.md).

## Install

**Requirements:** a jailbroken iOS 6.0 to 6.1.6 device with MobileSubstrate and PreferenceLoader.

<details>
<summary><b>SSH over USB (macOS or Linux)</b></summary>

```bash
brew install libimobiledevice sshpass
iproxy 2222:22 &

sshpass -p 'alpine' scp \
  -o HostKeyAlgorithms=ssh-rsa \
  -o KexAlgorithms=diffie-hellman-group14-sha1 \
  -P 2222 \
  pro.matthesketh.legacypodclaw_0.4.2_iphoneos-arm.deb \
  root@127.0.0.1:/tmp/legacypodclaw.deb

sshpass -p 'alpine' ssh \
  -o HostKeyAlgorithms=ssh-rsa \
  -o KexAlgorithms=diffie-hellman-group14-sha1 \
  -p 2222 root@127.0.0.1 \
  'dpkg -i /tmp/legacypodclaw.deb && su mobile -c /usr/bin/uicache && killall SpringBoard'
```
</details>

<details>
<summary><b>SSH over Wi-Fi</b></summary>

Find the device IP address in **Settings > Wi-Fi > (i)**. Then run:

```bash
scp -o HostKeyAlgorithms=ssh-rsa \
  pro.matthesketh.legacypodclaw_0.4.2_iphoneos-arm.deb \
  root@DEVICE_IP:/tmp/legacypodclaw.deb

ssh -o HostKeyAlgorithms=ssh-rsa root@DEVICE_IP \
  'dpkg -i /tmp/legacypodclaw.deb && su mobile -c /usr/bin/uicache && killall SpringBoard'
# default password: alpine
```
</details>

<details>
<summary><b>SSH over USB (Windows)</b></summary>

1. Install [iTunes](https://www.apple.com/itunes/) for the USB drivers.
2. Run [iproxy](https://github.com/libimobiledevice-win32/imobiledevice-net): `iproxy 2222 22`.
3. Connect [WinSCP](https://winscp.net/) to `127.0.0.1:2222` as `root`.
4. Upload the `.deb` to `/tmp/legacypodclaw.deb`.
5. In PuTTY, run `dpkg -i /tmp/legacypodclaw.deb && su mobile -c /usr/bin/uicache && killall SpringBoard`.
</details>

<details>
<summary><b>iFile or Filza</b></summary>

Copy the `.deb` to the device. Open it in iFile or Filza, tap **Install**, then restart SpringBoard.
</details>

> **Note:** iOS 6 uses old SSH algorithms. If you see `no matching host key type found`, add `-o HostKeyAlgorithms=ssh-rsa -o KexAlgorithms=diffie-hellman-group14-sha1` to the SSH and SCP commands.

A plain remove keeps the settings and keys. `dpkg --purge pro.matthesketh.legacypodclaw` also deletes the settings and the keys in the keychain.

## Music downloads

LegacyPodClaw can search YouTube and add songs to the Music app. Search runs on the device through YouTube's InnerTube API. A download needs the music proxy on a computer on your network, because YouTube now needs JavaScript signature deciphering that iOS 6 cannot do.

```bash
pip3 install yt-dlp==2026.8.19
brew install ffmpeg
python3 LegacyPodClawMCP/music_proxy.py --host 0.0.0.0
```

On a LAN address, the proxy needs a token. It writes the token to `~/.config/legacypodclaw/music_proxy.token`. Set **Settings > LegacyPodClaw > Local Agent > Music Proxy URL** to `http://YOUR_COMPUTER_IP:18790/t/TOKEN`.

## Build from source

The build runs on macOS with Theos at `~/theos` and the iPhoneOS 14.5 SDK. The deployment target is iOS 6.0.

```bash
export THEOS=~/theos
export PATH="$THEOS/bin:$PATH"

cd /path/to/LegacyPodClaw
make clean && make package FINALPACKAGE=1
make test   # host tests on macOS
```

See [BUILD.md](BUILD.md) for the details.

## LegacyPodClawMCP

A Python MCP server for iOS 6 development. It has tools for SSH and SCP, class dumps, private header search, Theos builds and crash reports.

```bash
pip3 install mcp==1.30.0
brew install sshpass libimobiledevice
python3 LegacyPodClawMCP/server.py
```

See [LegacyPodClawMCP/README.md](LegacyPodClawMCP/README.md) for the details.

## Architecture

| Component | Description |
|-----------|------------|
| **LegacyPodClaw.app** | The main app: chat UI, agent loop, tools, model providers, chat channels, gateway server, plugins |
| **LegacyPodClawTweak** | MobileSubstrate tweak in SpringBoard: overlay, Spotlight dashboard, lock screen, app switcher page, widget loader |
| **LegacyPodClawNC** | Notification Center widget (`BBWeeAppController`) |
| **LegacyPodClawPrefs** | Settings app preference bundle |
| **LegacyPodClawDaemon** | `clawpodd`: read-only system information and the keychain secret service |
| **wolfSSL 5.9.4** | Vendored TLS library. The iOS 6 TLS stack cannot reach modern servers safely. |

| Metric | Value |
|--------|-------|
| Objective-C source files | 103 |
| Lines of Objective-C | about 22,000 |
| Target | ARMv7, iOS 6.0 or later |

## What changed in v0.4.0

Version 0.4.0 is a full rewrite of the network, secret, tool and package code. HTTPS now goes through wolfSSL 5.9.4, and secrets live in the keychain. Every tool call goes through one dispatcher. The gateway server needs an access token. See the [changelog](https://legacypodclaw.hesketh.pro/changelog/).

## Removed or limited

- **Automatic provider failover** was removed. It never ran, and a silent change to a different provider would send your data to a place that you did not select.
- **Gemini** works only through Google's OpenAI-compatible endpoint, not the native `generateContent` API.
- **Slack incoming webhooks and the Events API** were removed. Both need a public URL, and a device on a home network does not have one. Socket Mode replaces them.
- **Telegram, Discord and Slack reactions, edits and deletes** were removed. Nothing used them.

## Credits

- [Matt Hesketh](https://github.com/wrxck)
- Based on [OpenClaw](https://openclaw.ai)
- Inspired by [PicoClaw](https://github.com/sipeed/picoclaw) and [NanoClaw](https://github.com/qwibitai/nanoclaw)
- Built with [Theos](https://theos.dev)
- Headers from [iOS-6-Headers](https://github.com/pigigaldi/iOS-6-Headers)

## Licence

MIT
