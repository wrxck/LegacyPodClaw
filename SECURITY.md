# LegacyPodClaw Security Model

This file says what LegacyPodClaw protects and what it cannot protect. It
replaces the earlier `SECURITY_ENHANCEMENTS.md`, which described features
that do not exist.

## Limits of a jailbroken device

A jailbroken device has no strong process isolation. Any process that runs as
`mobile` can read files that `mobile` owns. A MobileSubstrate tweak inside
SpringBoard runs with SpringBoard's rights. The measures below raise the cost
of an attack. They do not stop code that already runs as `mobile` or root.

## Network

- All HTTPS goes through `CPTLSClient` on wolfSSL 5.9.4: TLS 1.2 minimum,
  certificate verification against the bundled Mozilla CA list
  (`Resources/cacert.pem`), host-name check and SNI.
- Optional key pinning checks only the server's leaf key.
- `CPFetch` refuses every scheme except `http` and `https`. Plain HTTP is
  for LAN services such as Ollama or the music proxy.

## Secrets

- API keys and tokens live in the keychain, in an access group that only
  `clawpodd` has. They are never written to the settings plist.
- `clawpodd` serves them over a mach service. It reads the caller's pid and
  uid from the mach audit trailer and checks the executable path:
  SpringBoard may read; the app and Settings may read and write; all other
  callers are refused.
- The app binary has a `__RESTRICT` segment, so dyld ignores
  `DYLD_INSERT_LIBRARIES` for it.
- `dpkg --purge` deletes the secrets from the keychain. A plain remove
  keeps them, like the other settings.
- Known gaps: a tweak inside SpringBoard can read every secret, and a
  process that sends a request and then execs an allowed binary can pass
  the path check.

## clawpodd

- It answers only fixed read-only questions: ping, status, battery,
  processes, crash list and an allow-listed sysctl. It has no command or
  file-read operation.
- It registers its mach services as root, then drops to `mobile`.

## Tools

- Every tool call goes through `OCToolDispatcher`. It checks the input
  against the schema, applies the path guardrails, enforces a timeout and
  asks the user before a risky tool runs.
- The approval alert shows the command, path and URL in full, with runs of
  spaces and control characters made visible. A field too long to show is
  refused.
- Calls from chat channels and from MCP or plugin tools always need
  approval. Calls through the gateway need approval for risky tools and
  for every file access.
- `bash` runs as `mobile` through `posix_spawn`, with no app descriptors,
  in its own process group, with a CPU and time limit. There is no command
  denylist; the user approves each call.
- The guardrails block writes to system paths and reads of the keychain,
  Mail, Accounts, SMS, AddressBook, Cookies, Safari and CallHistory data.

## Gateway server

- Every HTTP request and WebSocket session needs the 256-bit access token.
  Only `GET /healthz` is public, and it returns no data.
- Request size, header size and time are bounded.

## Gateway client

- The connection to a remote gateway uses the system TLS stack. With
  "Self-Signed Certs" on, the app does not check the chain. It then
  connects only when the leaf certificate's SHA-256 matches the pinned
  fingerprint, and refuses when no fingerprint is set.

## Chat channels

- Each channel ignores senders that are not on its allow list.
- Channel messages are untrusted. Tools are off for channel sessions unless
  the user turns them on, and then each call needs approval.

## Plugins

- Plugins load only from `/Library/LegacyPodClaw/Plugins`. The directory,
  every file in a bundle and the parent directories must be owned by root
  and must not be writable by others. Symlinks are refused.

## SpringBoard tweak

- The overlay never shows while the device is locked, and it hides when
  the device locks.
- The Notification Center widget does not run while the device is locked
  with a passcode. It sends HTTPS through the tweak's wolfSSL client.
- With a passcode set, the lock screen camera keeps Apple's behaviour.
- Files that the app passes to SpringBoard live in a 0700 directory, not
  in `/tmp`.

## Reporting

Report a security problem to the maintainer by email, not in a public issue.
