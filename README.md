# FastRoute Companion

A macOS companion to [FastRoute](https://github.com/masonasons/FastRoute) for Windows. It speaks
FastRoute's Net Send and Net Receive protocol (and VBAN), so a Mac can send audio to a FastRoute
session on a PC and play what a PC sends back. Built with AppKit and written for keyboard and
VoiceOver use first.

## What it does

Sessions hold blocks, as in FastRoute. Two block kinds so far:

- **Net Send** captures a microphone or other input device, system audio, or any number of
  applications (chosen in the block itself), mixes them, and sends over FastRoute or VBAN:
  waiting for receivers to ask, multicasting to a group, or pushing to one host. PCM 16 bit,
  24 bit, 32 bit float, FLAC and Opus, with FastRoute's Opus settings.
- **Net Receive** lists the FastRoute senders announcing themselves on the network (and VBAN hosts
  that answer a ping), follows one by name or asks a named machine for its audio, buffers it, and
  plays it on the output device chosen in the block.

Keys follow FastRoute: Command N makes a session, Return opens it, Command R runs or stops it.
In a session, Command Shift N adds a block, Return opens its settings, Space turns it on or off,
Command Up/Down moves it, Option Up/Down nudges its volume, F2 names it, Delete removes it.
Every settings sheet has Apply (Command Shift A) to push a change into a running session.

## Protocol

The wire format was worked out from the FastRoute 0.6 build and lives in
`Sources/Core/Net/FastRouteProtocol.swift`:

| Packet | Size | Purpose |
|---|---|---|
| `FRNB` | 96 bytes | Beacon: codec, stream id, group, port, frames per packet, rate, stream and host names. Multicast to 239.255.77.20:6981 twice a second; unicast back to anyone who asks. |
| `FRND` | 32 + payload | Data: codec, rate, stream id, sequence, frame position, frames, length, then PCM, one FLAC frame or one Opus packet. Default group 239.255.77.21, default port 6982. |
| `FRNS` | 48 bytes | Subscribe: a receiver asking a sender for the audio, once a second. The sender keeps the asker for six seconds. |

## Building

Requires macOS 14.2 or later, Xcode 16 or later, [xcodegen](https://github.com/yonaskolb/XcodeGen)
and Homebrew's `opus` and `flac`:

```bash
brew install xcodegen opus flac
xcodegen generate
xcodebuild -scheme FastRouteCompanion -configuration Debug build
```

The build copies the codec libraries into the app bundle, so the app runs on a Mac without
Homebrew. Capturing system audio or applications needs the "System audio recording only"
permission under Privacy & Security, Screen & System Audio Recording; macOS asks the first time.
