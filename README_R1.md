# J7Bridge iOS R1

This is the first native iOS counterpart for the supplied J7/K7 Android GATT source.

## Implemented

- CoreBluetooth central
- Service discovery
- 5CB8 notification subscription
- 5CB9 notification subscription
- 5CBA write path
- Control channel 2 framing
- Audio channel 3 framing
- Incoming-call event `0x0A`
- ANSWER command `0x05`
- HANGUP command `0x04`
- VOICE_OPEN `0x0F`
- VOICE_CLOSE `0x10`
- CallKit incoming-call reporting
- CallKit answer/end callbacks
- AVAudioEngine microphone capture hook

## Important R1 limitation

The supplied Android project uses an Android `libamr-codec.so` for AMR-NB. That `.so` cannot be linked into an iOS application.

The iOS `VoiceEngine` therefore has an explicit codec adapter boundary. R1 is intended to prove:

BLE -> incoming event -> CallKit -> ANSWER -> BLE

and to establish the audio session/capture path.

The next milestone is an iOS arm64 AMR-NB implementation that produces the same AMR-NB frames as the Android implementation.

## Source-derived protocol

Service:
`0783B03E-8535-B5A0-7140-A304D2495CB7`

RX:
`0783B03E-8535-B5A0-7140-A304D2495CB8`

FLOW:
`0783B03E-8535-B5A0-7140-A304D2495CB9`

TX:
`0783B03E-8535-B5A0-7140-A304D2495CBA`

The control and audio framing in `K7Protocol.swift` are translated from the supplied Java `Frame.java`.

## Build

Open the generated Xcode project on macOS/Xcode. The source is intentionally small and uses only Apple system frameworks for R1:

- SwiftUI
- CoreBluetooth
- CallKit
- AVFoundation
