# FXRouter

Run your AU / VST3 plugins on **everything your Mac plays**.

FXRouter installs a virtual output device, captures whatever macOS sends to
it, runs that audio through a chain of your own plugins in real time, and
sends the result to your speakers or interface.

```
Any app ──▶ FXRouter device ──▶ plugin 1 → plugin 2 → … ──▶ your output 🔊
```

## Requirements

- Apple Silicon Mac, macOS 13 or later
- [Xcode](https://apps.apple.com/app/xcode/id497799835) (free)
- [Homebrew](https://brew.sh), then `brew install cmake xcodegen`

## Install

```sh
git clone [repo]
cd FXRouter
./installer/install.sh
```

That builds everything, installs the audio driver (asks for your password —
it lives in a system folder), installs the app to `/Applications`, and
launches it.

## First run

1. If **System Settings → Privacy & Security** shows an **Allow** prompt for
   the driver, approve it, then run `sudo killall coreaudiod`. One time only.
2. Allow **microphone access** when asked — that is how macOS gates reading
   FXRouter's own device. No real microphone is captured.
3. Set **System Settings → Sound → Output** to **FXRouter** (the app offers
   to do this for you).
4. Click the menu-bar icon, pick your real **Output Device**, and add plugins.

While output is set to FXRouter, sound only plays while the app is running —
turn on **Launch at Login** in the app's Settings menu.

## Uninstall

```sh
./installer/uninstall.sh           # app + driver
./installer/uninstall.sh --purge   # …and settings, catalog, presets
```

It restores a real output device first, so you are never left in silence.

## Good to know

- Plugin **scanning** runs in a throwaway process, so a plugin that crashes
  while being probed gets blacklisted instead of taking the app down. Plugins
  run **in-process** during playback, though — one that crashes there will
  stop FXRouter and your audio.
- The chain is stereo; mono-only plugins are rejected.
- Builds are ad-hoc signed for local use. There is no notarized download —
  build from source.

## License

GPLv3 — see [`LICENSE`](LICENSE). Built on
[BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPLv3; the virtual
driver is a rebranded fork) and [JUCE](https://juce.com) 8 (AGPLv3), combined
as GPLv3 section 13 permits. Full notices in
[`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md).
