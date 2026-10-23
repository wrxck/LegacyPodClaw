---
title: "Gateway Server"
description: "Run your iOS 6 device as an OpenClaw-compatible API server"
weight: 4
---

LegacyPodClaw can run as a gateway server. Other devices on your network can then use the device as an OpenClaw-compatible API endpoint.

## Overview

The gateway provides:

- **HTTP API** on port 18789 (change it with `serverPort`)
- **WebSocket** sessions that speak the OpenClaw protocol v3
- **Webhook input** for the webhook chat channel

## Enabling the Gateway

1. Open the LegacyPodClaw app and go to **Settings > Gateway Server**.
2. Turn on the server. It listens on `http://DEVICE_IP:18789`.
3. Tap **Access Token** and copy the token to each client.

The dashboard "Gateway" button opens the app, and the app asks before it starts the server.

## Access Token

Every request needs the access token, except `GET /healthz`.

- The app makes a random 256-bit token the first time the server starts.
- Send it as `Authorization: Bearer <token>`.
- A WebSocket client can also send it in the first `connect` frame. The server closes a client that does not authenticate within 10 seconds.
- **Regenerate** in the token alert makes a new token and disconnects every client.

The server has no password option.

## HTTP Routes

| Route | Purpose |
|---|---|
| `GET /healthz` | Liveness check. Public, returns no data. |
| `GET /health` | Server status |
| `GET /api/sessions` | Session list |
| `GET /api/sessions/<key>/history?limit=N` | The history of one session (default 100 messages) |
| `POST /tools/invoke` | Run a device tool. The user approves risky tools and every file access on the device. |
| `POST /webhook/incoming` | Input for the webhook channel |
| `GET /api/cron` | Cron jobs (not implemented yet) |

## WebSocket

Connect to `ws://DEVICE_IP:18789/` with the token. Chat, session and abort requests go over this connection. The server keeps at most 200 messages of history for each session in memory.

## Security

- The server uses plain HTTP. Use it only on a network you trust.
- Every client with the token can see chat events from every session.
- Plugin and MCP tools cannot be called through the gateway.
