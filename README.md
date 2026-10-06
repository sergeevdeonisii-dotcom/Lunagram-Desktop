# Lunagram Desktop

Independent native Telegram API client for Windows, based on Telegram Desktop
**7.2.9**, pinned at `fb2e33209517e1a34637d837bfadb3783f2fd59c`.
Lunagram is not the official Telegram application. This is a native Qt/C++
client, not a browser wrapper.

[![Windows Debug](https://github.com/sergeevdeonisii-dotcom/Lunagram-Desktop/actions/workflows/lunagram-windows-debug.yml/badge.svg)](https://github.com/sergeevdeonisii-dotcom/Lunagram-Desktop/actions/workflows/lunagram-windows-debug.yml)

## Development status

The Windows port is under development. A successful source check is not proof
that a feature compiles or works on a real account. Only a successful native
build and startup check produce an artifact; runtime account/UI verification
is still required before a production release. Interim packages are clearly
marked **Windows x64 Debug** and use `%APPDATA%\Lunagram`, independent from
ordinary Telegram. Existing Telegram profiles are not imported automatically.
Initial Windows test executables are unsigned, not production releases.

Implemented source covers grouped Lunagram settings, three built-in palettes,
rounded translucent composer styling, local typing pulses, automatic text
formatting, reduced automatic media traffic and an optional 400–5000 ms
undo-send window for ordinary text.
The undo window is local, does not schedule messages on Telegram, and keeps
the draft when canceled. Attachments, paid, disappearing and explicitly
scheduled messages keep their existing send path.

Additional modules cover observed edit history, retained observed deleted
messages, unlimited local gift pinning, paged hide/show-all gift visibility,
local profile previews, per-account settings profiles, notes, a notification
journal and a selected-chat UI vault. These modules still require native
runtime testing. Visibility changes for gifts use Telegram's actual API;
local pins, rating, number and verification previews do not change server
ownership or account status. **Ghost mode is intentionally absent on Windows**:
normal Telegram online, typing and read behavior is preserved.

## Privacy limits

- Private local records use Windows user-bound DPAPI and atomic file writes.
  This is not protection from another process running as the same Windows user.
- Only messages/edits this client actually observed can be retained. Protected
  and disappearing content is excluded; media is available only from cache.
  Unseen deletions, edits and missing push notifications cannot be recovered.
  Storage is bounded to 3,000 observed records, 1,000 retained deletions and
  300 edited messages with up to 20 text/caption versions each (4,096 text
  units per version). Old records can be evicted. Saved TL snapshots are
  tied to the current schema; incompatible storage fails closed and needs a
  migration before a future schema upgrade.
- The notification journal is off by default, bounded to 200 previews/30 days,
  and excludes protected, disappearing, login-code and vault-chat content.
- The vault is a **UI lock**, not encryption of Telegram's message database.
  Its metadata is DPAPI-protected; PIN verification uses salted
  PBKDF2-HMAC-SHA256 with 600,000 iterations. It locks on background/account
  changes. Suggestions, global media/downloads, stories, communities and
  auxiliary sections are unavailable while locked.
  Forgetting the PIN does not reveal the chats; do not rely on this experimental
  UI vault as your only protection.
- Settings export excludes messages, notes, PINs and notification previews.
- Stock Telegram automatic updates and crash submissions are disabled in the
  Lunagram workflow. Windows updates currently open this fork's releases page;
  no automatic Windows updater has been implemented.

## Android parity still pending

Windows uses a native opacity pulse rather than Android's exact letter/word
sliding, blur, height and swipe controls. The reduced-media setting is not
Android's selected emergency-chat/text-only mode: it stops new automatic
media-download/autoplay decisions, but does not cancel manual downloads,
thumbnails or running transfers. Dynamic alternate app icons, the custom
PDF/account ZIP export skins and the compact scheduled bot-draft view have
not been ported. Native Telegram HTML/JSON export remains available. Local
settings formats and private records are not cross-platform imports.

## Windows Debug build

The manual `Lunagram Windows Debug` workflow uses a standard GitHub-hosted
Windows runner, pinned actions/submodules, MSVC 14.44, Windows SDK 26100 and Qt 6.
It does not use the upstream paid Depot configuration. Set app-owned
`TDESKTOP_API_ID` and `TDESKTOP_API_HASH` repository secrets; credentials are
never stored in source. `prepare_only` warms dependency caches without
compiling the client. Full runs compile Debug only and start the native
executable for 15 seconds with an isolated test profile, without signing in.
Artifacts include preserved license notices and a pinned build manifest.

Source checks live in `Telegram/build/lunagram/features.tests.ps1` and
`windows-debug.tests.ps1`. Theme assets are reproducibly generated from the
preserved upstream palettes by `generate-themes.ps1`. The original icon image
is `Telegram/Resources/art/lunagram-logo-source.png`.
After dependency preparation, `private_codec.tests.ps1` compiles and executes
the exact production Windows DPAPI codec against tampering, entropy mismatch,
empty-data and size-boundary cases. This does not test message retention or
the interactive vault UI.

The Android companion remains at
[LumaGram-Android](https://github.com/sergeevdeonisii-dotcom/LumaGram-Android),
with its display name changed to Lunagram. Android account/package identifiers
and its established update feed remain unchanged for in-place upgrades.

## Upstream credits and documentation

The preserved source and platform instructions below come from
[Telegram Desktop][telegram_desktop], based on the [Telegram API][telegram_api]
and the [MTProto][telegram_proto] secure protocol. Upstream download links are
ordinary Telegram downloads, not Lunagram packages.

The source code is published under GPLv3 with OpenSSL exception, the license is available [here][license].

## Upstream supported systems

Upstream Telegram provides downloads for

* [Windows 7 and above (64 bit)](https://telegram.org/dl/desktop/win64) ([portable](https://telegram.org/dl/desktop/win64_portable))
* [Windows 7 and above (32 bit)](https://telegram.org/dl/desktop/win) ([portable](https://telegram.org/dl/desktop/win_portable))
* [macOS 10.13 and above](https://telegram.org/dl/desktop/mac)
* [Linux static build for 64 bit](https://telegram.org/dl/desktop/linux)
* [Snap](https://snapcraft.io/telegram-desktop)
* [Flatpak](https://flathub.org/apps/details/org.telegram.desktop)

## Old system versions

Version **4.9.9** was the last that supports older systems

* [macOS 10.12](https://updates.tdesktop.com/tmac/tsetup.4.9.9.dmg)
* [Linux with glibc < 2.28 static build](https://updates.tdesktop.com/tlinux/tsetup.4.9.9.tar.xz)

Version **2.4.4** was the last that supports older systems

* [OS X 10.10 and 10.11](https://updates.tdesktop.com/tosx/tsetup-osx.2.4.4.dmg)
* [Linux static build for 32 bit](https://updates.tdesktop.com/tlinux32/tsetup32.2.4.4.tar.xz)

Version **1.8.15** was the last that supports older systems

* [Windows XP and Vista](https://updates.tdesktop.com/tsetup/tsetup.1.8.15.exe) ([portable](https://updates.tdesktop.com/tsetup/tportable.1.8.15.zip))
* [OS X 10.8 and 10.9](https://updates.tdesktop.com/tmac/tsetup.1.8.15.dmg)
* [OS X 10.6 and 10.7](https://updates.tdesktop.com/tmac32/tsetup32.1.8.15.dmg)

## Third-party

* Qt 6 ([LGPL](http://doc.qt.io/qt-6/lgpl.html)) and Qt 5.15 ([LGPL](http://doc.qt.io/qt-5/lgpl.html)) slightly patched
* OpenSSL 3.2.1 ([Apache License 2.0](https://openssl-library.org/source/license/apache-license-2.0.txt))
* WebRTC ([New BSD License](https://github.com/desktop-app/tg_owt/blob/master/LICENSE))
* zlib ([zlib License](http://www.zlib.net/zlib_license.html))
* LZMA SDK 9.20 ([public domain](http://www.7-zip.org/sdk.html))
* liblzma ([public domain](http://tukaani.org/xz/))
* Google Breakpad ([License](https://chromium.googlesource.com/breakpad/breakpad/+/master/LICENSE))
* Google Crashpad ([Apache License 2.0](https://chromium.googlesource.com/crashpad/crashpad/+/master/LICENSE))
* GYP ([BSD License](https://github.com/bnoordhuis/gyp/blob/master/LICENSE))
* Ninja ([Apache License 2.0](https://github.com/ninja-build/ninja/blob/master/COPYING))
* OpenAL Soft ([LGPL](https://github.com/kcat/openal-soft/blob/master/COPYING))
* Opus codec ([BSD License](http://www.opus-codec.org/license/))
* FFmpeg ([LGPL](https://www.ffmpeg.org/legal.html))
* Guideline Support Library ([MIT License](https://github.com/Microsoft/GSL/blob/master/LICENSE))
* Range-v3 ([Boost License](https://github.com/ericniebler/range-v3/blob/master/LICENSE.txt))
* Open Sans font ([Apache License 2.0](http://www.apache.org/licenses/LICENSE-2.0.html))
* Vazirmatn font ([SIL Open Font License 1.1](https://github.com/rastikerdar/vazirmatn/blob/master/OFL.txt))
* Emoji alpha codes ([MIT License](https://github.com/emojione/emojione/blob/master/extras/alpha-codes/LICENSE.md))
* xxHash ([BSD License](https://github.com/Cyan4973/xxHash/blob/dev/LICENSE))
* QR Code generator ([MIT License](https://github.com/nayuki/QR-Code-generator#license))
* CMake ([New BSD License](https://github.com/Kitware/CMake/blob/master/Copyright.txt))
* Hunspell ([LGPL](https://github.com/hunspell/hunspell/blob/master/COPYING.LESSER))
* Ada ([Apache License 2.0](https://github.com/ada-url/ada/blob/main/LICENSE-APACHE))

## Build instructions

* [Windows (32-bit and 64-bit)][win]
* [macOS][mac]
* [GNU/Linux using Docker][linux]

[//]: # (LINKS)
[telegram]: https://telegram.org
[telegram_desktop]: https://desktop.telegram.org
[telegram_api]: https://core.telegram.org
[telegram_proto]: https://core.telegram.org/mtproto
[license]: LICENSE
[win]: docs/building-win.md
[mac]: docs/building-mac.md
[linux]: docs/building-linux.md
[preview_image]: https://github.com/telegramdesktop/tdesktop/blob/dev/docs/assets/preview.png "Preview of Telegram Desktop"
[preview_image_url]: https://raw.githubusercontent.com/telegramdesktop/tdesktop/dev/docs/assets/preview.png

## Thanks to

<a href="https://depot.dev">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://depot.dev/assets/brand/1693758816/depot-logo-horizontal-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://depot.dev/assets/brand/1693758816/depot-logo-horizontal-on-light.svg">
    <img alt="Depot" src="https://depot.dev/assets/brand/1693758816/depot-logo-horizontal-on-light.svg" width="150">
  </picture>
</a>

Upstream Telegram CI infrastructure is sponsored by [Depot](https://depot.dev).
Lunagram's active workflow does not use those runners.

