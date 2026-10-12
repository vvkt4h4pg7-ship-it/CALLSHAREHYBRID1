# J7Bridge iOS R2

R2 hardens the R1 prototype using the supplied Android K7 source as the protocol authority.

## R2 changes

- Added `CoreBluetooth` import to `K7Protocol.swift`.
- Corrected remote/J7 call termination: the iOS side now reports a remote CallKit end instead of submitting a second `CXEndCallAction` transaction.
- Kept CallKit ANSWER action pending until the J7 `0x05` answer event is received.
- Preserved exact control framing and audio channel-3 framing.
- Added 8 kHz AVAudioConverter path and a 160-sample accumulator so the audio pipeline now reaches the exact AMR-NB frame boundary expected by the Android source.
- Kept AMR codec implementation isolated because the supplied Android `libamr-codec.so` is not an iOS binary.

## Current milestone

A macOS/Xcode build should validate the native iOS project and the following wire sequence can then be tested against the J7 Android gateway:

1. Scan service `0783B03E-8535-B5A0-7140-A304D2495CB7`.
2. Subscribe RX `5CB8` and FLOW `5CB9`.
3. Receive `0x0A` incoming event and report CallKit incoming call.
4. iPhone ANSWER -> control payload `05`.
5. J7 responds with control payload `05` after the GSM answer request.
6. iOS fulfills CallKit answer and sends control payload `0F`.
7. J7 opens audio and returns `0F`.
8. Audio uses channel 3; Android source encodes 8 kHz mono PCM in 160-sample frames to AMR-NB.

## Not yet complete

AMR-NB encode/decode is still a deliberate adapter boundary. The next engineering step is to add an iOS arm64-compatible AMR-NB implementation and compare it against known Android codec output before attempting live two-way speech.
