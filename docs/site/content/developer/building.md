---
title: "Building from Source"
description: "Set up Theos and build LegacyPodClaw"
weight: 2
---

The build runs on macOS only.

## Prerequisites

1. **Xcode** with the command-line tools.
2. **Theos** at `~/theos`. See [theos.dev](https://theos.dev/docs/installation).

   ```bash
   export THEOS=~/theos
   export PATH="$THEOS/bin:$PATH"
   ```

3. **The iPhoneOS 14.5 SDK** at `$THEOS/sdks/iPhoneOS14.5.sdk`.
4. **ldid** on `PATH`.

The Makefiles use `TARGET = iphone:clang:14.5:6.0`. The SDK is 14.5, but the deployment target is iOS 6.0. The compiler thus accepts APIs that do not exist on iOS 6. Such code builds and then crashes on the device. Check that each API you use exists on iOS 6.

`Vendor/libwolfssl.a` and its headers are in the repository. To build them again, run `THEOS=~/theos Vendor/build-wolfssl.sh`.

## Build

```bash
cd /path/to/LegacyPodClaw
make clean
make package FINALPACKAGE=1
```

The package is `packages/pro.matthesketh.legacypodclaw_0.4.2_iphoneos-arm.deb`. It holds the app, the tweak, the Settings bundle, the Notification Center widget and `clawpodd`.

## Test

The host tests run on macOS with the system SDK, under AddressSanitizer and UBSan:

```bash
make test
```

The tests cover the HTTP response parser, the file guardrails and the tool input checks. They do not need a device or Theos.

## Install on a device

```bash
make package install THEOS_DEVICE_IP=<device-ip>
```

You can also copy the `.deb` to the device and install it. See [Installation](/getting-started/install/).

## Build flags

The app's Makefile uses these flags:

- `-fno-objc-arc`: manual retain and release. Every target uses it.
- `-Os`: optimise for size.
- `-ffast-math`: faster floating-point code.
- `-fvisibility=hidden` and `-fvisibility-inlines-hidden`: fewer exported symbols.
- `-dead_strip`: removes unused code.
- `-Wl,-sectcreate,__RESTRICT,__restrict,/dev/null`: dyld then ignores `DYLD_INSERT_LIBRARIES` for the app. The `clawpodd` caller check relies on this.
- `Vendor/libwolfssl.a`: wolfSSL as a static library.

## Subprojects

The main Makefile builds four subprojects. Each has its own Makefile and `_FILES` list.

| Subproject | Installs to |
|---|---|
| `LegacyPodClawPrefs` | `/Library/PreferenceBundles` |
| `LegacyPodClawTweak` | `/Library/MobileSubstrate/DynamicLibraries` |
| `LegacyPodClawNC` | `/System/Library/WeeAppPlugins` |
| `LegacyPodClawDaemon` | `/usr/bin/clawpodd` |

When you add a `.m` file, add it to the `_FILES` list of the correct Makefile.
