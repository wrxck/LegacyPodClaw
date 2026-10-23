---
title: "Troubleshooting"
description: "Common problems and their solutions"
weight: 7
---

## SSH connection errors

iOS 6 uses old SSH algorithms. If you see this error:

```
no matching host key type found
```

Add these options to the SSH and SCP commands:

```bash
-o HostKeyAlgorithms=ssh-rsa -o KexAlgorithms=diffie-hellman-group14-sha1
```

The error `no matching key exchange method found` has the same cause. Add `-o KexAlgorithms=diffie-hellman-group14-sha1`.

## The home-button hold does not open LegacyPodClaw

1. Make sure that MobileSubstrate is installed.
2. Make sure that the device is unlocked. The overlay never opens on the lock screen.
3. Check that the tweak loaded: `grep LegacyPodClaw /var/log/syslog`. Look for `Loaded in SpringBoard`.
4. Restart SpringBoard: `killall SpringBoard`.
5. On the iPhone 4S, if Siri opens, restart the device and try again.

## A key or token does not save

The app shows **Not Saved** when `clawpodd` does not store a value.

1. Unlock the device. The keychain is not available while the device is locked.
2. Check that `clawpodd` runs: `launchctl list | grep legacypodclaw`.
3. If it does not run, load it: `launchctl load /Library/LaunchDaemons/pro.matthesketh.legacypodclaw.daemon.plist`.

## The overlay or the widget says "Not Configured"

The overlay and the Notification Center widget use the provider that you set in the app. That provider needs a base URL and, if it asks for one, an API key. Open the app, tap the gear button and set them.

## High memory use

The app has a memory budget of 80 MB. If the app reaches the limit:

{{< screenshot src="img/screens/diagnostics.png" caption="Diagnostics shows the memory budget and the device RAM" >}}

- Close background apps.
- Start a new session.
- Lower **Max Context Tokens** in **Settings > LegacyPodClaw > Local Agent**.

The app checks its memory use every 5 seconds. Above 60 % of the budget, it trims the message windows. Above 90 %, it also clears the agent context and the channel conversations.

## Provider errors

- **401 Unauthorized:** check the API key for the selected provider.
- **429 Rate Limited:** wait and try again. The app does not change to a different provider.
- **No reply from a non-Anthropic provider:** enter a model ID in **Model**. Only the Anthropic entry has a default model ID.
- **Timeout:** an HTTPS request waits up to 120 seconds for data. The app stops a request after 600 seconds in total. On a slow connection, try a faster model.

## A tool call fails

- **"the user denied this tool call":** you tapped **Deny**, or nobody answered the alert in 60 seconds.
- **"tool timed out":** the tool took longer than its timeout. The tool can still complete.
- **"Path must be absolute"** or **"BLOCKED":** the guardrails refused the path. See [Tools](/guide/tools/).

## A chat channel does not answer

1. Open the channel screen and look at the **Status** row. The full error shows below the row.
   - **Stopped** with "refused the bot token" or "refused the app token": enter the correct token. The channel starts again.
   - **Stopped** with Discord code 4014: turn on the **Message Content** intent in the Discord Developer Portal, then turn the channel off and on.
   - **Retrying**: the network or the service failed. The channel tries again.
   - "Telegram refused the poll (HTTP 409)": another program polls the same bot, or the bot has a webhook. Stop the other program or delete the webhook.
2. Make sure that your ID is in the allow list. An empty list ignores everyone.
3. Make sure that the app runs. The channels stop when iOS suspends the app.
4. In a Discord or Slack channel, mention the bot. In an IRC channel, start the line with the bot's nick.

## Music downloads fail

1. Check that the proxy runs: `curl http://YOUR_COMPUTER_IP:18790/t/TOKEN/health`.
2. Make sure that the device and the computer are on the same network.
3. Make sure that the proxy listens on the LAN (`--host 0.0.0.0`).
4. Make sure that the **Music Proxy URL** includes `/t/TOKEN`.
