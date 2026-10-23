---
title: "Chat Channels"
description: "Talk to the assistant from Telegram, Discord, Slack, IRC and a webhook"
weight: 5
---

A chat channel lets you talk to the assistant from a chat service. LegacyPodClaw has five channels:

| Channel | Connection |
|---|---|
| Telegram | Bot API long polling |
| Discord | Gateway WebSocket |
| Slack | Socket Mode WebSocket. No public URL is necessary. |
| IRC | Plain or TLS connection |
| Webhook | `POST /webhook/incoming` on the gateway server |

Set up each channel in the app: tap the gear button, then a channel under **Chat Channels**. Each channel screen has an **Enabled** switch, the channel fields and a **Status** row.

## Status row

The **Status** row changes when the channel changes. It shows one of these values:

| Value | Meaning |
|---|---|
| **Off** | The channel is off, or a token or field is missing. |
| **Connecting…** | The channel starts its connection. |
| **Connected** | The service accepted the connection. |
| **Retrying** | The connection failed. The channel tries again after a delay. |
| **Stopped** | The service refused the token or the settings. The channel does not try again. |

When the channel has an error, the full error text shows below the row. After you correct a token or a field, the channel starts again.

A change to one channel restarts only that channel. The conversations on the other channels continue.

## How channels work

- Each chat or thread gets its own conversation. The reply goes back to the same chat.
- Each conversation keeps its last 20 messages.
- The channels use the provider and model that you selected in **Model Provider**.
- A message longer than 4,000 characters is cut.
- While a reply runs, the app queues up to 3 more messages from the same chat.

## Allow lists

Each channel has an allow list of IDs. The app ignores a message from a sender that is not on the list. **An empty list ignores everyone.**

Enter the IDs separated by commas or spaces. The app compares the list with the sender ID, the chat ID and, for IRC, the `nick!user@host` mask.

## Tools in chats

Chat text comes from outside the device, so the app does not trust it.

- With **Tools in Chats** off (the default), channel conversations have no tools.
- With **Tools in Chats** on, each tool call from a chat shows an approval alert on the device.

## Channels stop with the app

The channels run inside the app. They stop when iOS suspends or quits the app.

With **Start on Boot** on, the app starts the channels and the gateway server when SpringBoard finishes booting. The app must already run when this happens.

## Telegram

1. Make a bot with [@BotFather](https://t.me/botfather).
2. In the app, open **Chat Channels > Telegram**.
3. Enter the **Bot Token**.
4. Enter your user ID or chat ID in **Allowed IDs**. Your user ID is the chat ID of a private chat with the bot.
5. Turn on **Enabled**.

The bot ignores a message that is older than 10 minutes.

The **Status** row shows **Connected** after the first call to Telegram, usually in less than a few seconds. If Telegram refuses the token, the row shows **Stopped** and "Telegram refused the bot token (HTTP 401)".

The app keeps the ID of the last update in `/var/mobile/Library/LegacyPodClaw/telegram.plist`. After a restart, Telegram does not send the same update again. The file holds the bot ID, not the token.

## Discord

1. Make a bot in the [Discord Developer Portal](https://discord.com/developers).
2. Turn on the **Message Content** intent for the bot.
3. In the app, open **Chat Channels > Discord**.
4. Enter the **Bot Token**.
5. Enter user or channel IDs in **Allowed IDs**.
6. Turn on **Enabled**.

In a server, the bot answers only when you mention it. If Discord closes the connection with a fatal code (4004 or 4010 to 4014), the channel stops. The **Status** row shows **Stopped** and the full reason shows below the row. For example, code 4014 tells you to turn on the **Message Content** intent.

## Slack

1. Make a Slack app and turn on Socket Mode.
2. Make an app-level token with `connections:write`.
3. Give the bot token the scopes `chat:write`, `app_mentions:read` and `im:history`.
4. In the app, open **Chat Channels > Slack**.
5. Enter the **App Token** (`xapp-...`) and the **Bot Token** (`xoxb-...`).
6. Enter member or channel IDs in **Allowed IDs**.
7. Turn on **Enabled**.

In a channel, the app answers only when you mention it. A long reply is sent in parts of at most 3,500 characters.

If Slack refuses a token (for example `invalid_auth` or `not_allowed_token_type`), the channel stops. The **Status** row shows **Stopped** and, for example, "Slack refused the bot token (invalid_auth)". `not_allowed_token_type` usually means that the app token and the bot token are in the wrong fields.

## IRC

1. In the app, open **Chat Channels > IRC**.
2. Enter the **Server** and the **Nickname**.
3. Optional: enter the **Port**. The default is 6697 with TLS and 6667 without TLS.
4. Turn on **Use TLS** if the server supports it.
5. Optional: enter a **Password**. The app sends it as the server password (`PASS`).
6. Enter the **Channels** to join, for example `#one, #two`.
7. Enter `nick!user@host` masks or nicks in **Allowed**.
8. Turn on **Enabled**.

In a channel, the bot answers only lines that start with its nick. Use the full `nick!user@host` mask where you can, because anyone can take a bare nick. The bot removes Markdown marks from its replies.

## Webhook

The webhook channel receives messages through the gateway server on the device. The gateway server must run.

1. In the app, open **Chat Channels > Webhook**.
2. Enter the **Callback URL**. The app posts each reply to this URL.
3. Optional: enter a **Callback Token**. The app sends it as `Authorization: Bearer <token>` with each reply.
4. Enter the `senderId` values to accept in **Allowed Senders**.
5. Turn on **Enabled**.

To send a message, post JSON to the gateway server with the gateway access token:

```bash
curl -X POST http://DEVICE_IP:18789/webhook/incoming \
  -H "Authorization: Bearer GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello", "senderId": "me", "chatId": "main"}'
```

The reply is a POST to the callback URL with the body `{"text": "...", "chatId": "main"}`. The `text` field can have at most 8,000 characters.

## Plugin channels

A plugin can add a channel. Set its allow list with the `<channelId>AllowedIds` preference. See [Plugin SDK](/developer/plugin-sdk/).
