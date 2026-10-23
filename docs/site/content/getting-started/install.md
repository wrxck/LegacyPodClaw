---
title: "Installation"
description: "Install LegacyPodClaw on a jailbroken iOS 6 device"
weight: 1
---

## Requirements

- A jailbroken device with iOS 6.0 to 6.1.6
- [MobileSubstrate](http://cydia.saurik.com/package/mobilesubstrate/) (Cydia Substrate)
- [PreferenceLoader](http://cydia.saurik.com/package/preferenceloader/)

Get the latest `.deb` from [GitHub Releases](https://github.com/wrxck/LegacyPodClaw/releases). The file name is `pro.matthesketh.legacypodclaw_0.4.2_iphoneos-arm.deb`.

## SSH over USB (macOS or Linux)

This method is the most reliable. It needs [libimobiledevice](https://libimobiledevice.org/) for the USB tunnel.

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

## SSH over Wi-Fi

Find the device IP address in **Settings > Wi-Fi > (i)**. Then run:

```bash
scp -o HostKeyAlgorithms=ssh-rsa \
  pro.matthesketh.legacypodclaw_0.4.2_iphoneos-arm.deb \
  root@DEVICE_IP:/tmp/legacypodclaw.deb

ssh -o HostKeyAlgorithms=ssh-rsa root@DEVICE_IP \
  'dpkg -i /tmp/legacypodclaw.deb && su mobile -c /usr/bin/uicache && killall SpringBoard'
```

The default SSH password is `alpine`. Change it after you install.

## SSH over USB (Windows)

1. Install [iTunes](https://www.apple.com/itunes/) for the USB drivers.
2. Run [iproxy](https://github.com/libimobiledevice-win32/imobiledevice-net): `iproxy 2222 22`.
3. Connect [WinSCP](https://winscp.net/) to `127.0.0.1:2222` as `root`.
4. Upload the `.deb` to `/tmp/legacypodclaw.deb`.
5. In PuTTY, run `dpkg -i /tmp/legacypodclaw.deb && su mobile -c /usr/bin/uicache && killall SpringBoard`.

## iFile or Filza

1. Copy the `.deb` to the device, for example with a Safari download.
2. Open the file in iFile or Filza.
3. Tap **Install**.
4. Restart SpringBoard.

## What the package installs

The post-install script does these steps:

1. It loads the `clawpodd` daemon.
2. It makes `/var/mobile/Library/LegacyPodClaw` (owner `mobile`, mode 0700).
3. It makes `/Library/LegacyPodClaw/Plugins` (owner `root`, mode 0755).
4. It sets the settings plist to mode 0600.
5. In Cydia, it asks for a SpringBoard restart.

## Remove the package

- A plain remove keeps the settings and the API keys.
- A purge (`dpkg --purge pro.matthesketh.legacypodclaw`) deletes the settings, the shared files and the keys in the keychain.

## SSH errors

iOS 6 uses old SSH algorithms. If you see `no matching host key type found`, add these options to the SSH and SCP commands:

```bash
-o HostKeyAlgorithms=ssh-rsa -o KexAlgorithms=diffie-hellman-group14-sha1
```
