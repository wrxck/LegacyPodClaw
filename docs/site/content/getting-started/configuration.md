---
title: "Configuration"
description: "Set up an AI provider and connect to a gateway"
weight: 2
---

After installation, open **Settings > LegacyPodClaw** on your device.

## Local Agent (Recommended Start)

The simplest setup — the AI runs directly through an API provider:

1. Go to **Settings > LegacyPodClaw > Local Agent**
2. Enter your API key (Anthropic, OpenAI, Google, or any supported provider)
3. Choose a model (defaults to a sensible option for each provider)

That's it. Hold the home button and start chatting.

## Gateway Connection

If you're running an [OpenClaw](https://openclaw.ai) gateway on your network:

1. Go to **Settings > LegacyPodClaw > Gateway**
2. Enter the gateway host and port
3. Enter the gateway's auth token or password
4. Tap **Connect**

If the gateway uses a self-signed certificate, turn on **Self-Signed Certs** and enter the certificate's SHA-256 fingerprint in **Cert SHA-256**. Get it on the gateway host:

```
openssl x509 -noout -fingerprint -sha256 -in cert.pem
```

Without the fingerprint, the app refuses the connection.

## Bonjour Auto-Discovery

LegacyPodClaw auto-discovers gateways broadcasting `_openclaw-gw._tcp` on the local network. If a gateway is found, it appears in the Settings screen automatically.

## Supported Providers

LegacyPodClaw supports 10 AI providers. Each needs only an API key (or base URL for self-hosted):

| Provider | Config Field |
|----------|-------------|
| Anthropic | API Key |
| OpenAI | API Key |
| Google / Gemini | API Key |
| Ollama | Base URL (e.g. `http://192.168.1.x:11434`) |
| Groq | API Key |
| Together AI | API Key |
| OpenRouter | API Key |
| Mistral | API Key |
| Deepseek | API Key |
| Custom | Base URL + API Key |

Configure providers in **Settings > LegacyPodClaw > Local Agent**. There is no automatic failover between providers.
