# J7Bridge Final

J7Bridge is an iPhone terminal for an IKOS K7 GSM gateway over BLE.

## UI

- Phone keypad
- Recents
- Contacts / caller-name lookup
- New-contact creation
- Settings
- K7 diagnostics
- CallKit system calling UI

## Real K7 wire path

- Service: `0783B03E-8535-B5A0-7140-A304D2495CB7`
- RX: `...5CB8`
- FLOW: `...5CB9`
- TX: `...5CBA`
- Incoming: `0x0A`
- Answer: `0x05`
- Hangup: `0x04`
- Voice open: `0x0F`
- Voice close: `0x10`
- Audio: channel 3

## First real test

1. Install/build the app and allow Bluetooth.
2. Connect to the J7 running the known-good IKOS K7 gateway.
3. Keep the Phone screen open; the app scans automatically.
4. Place a real GSM call into the J7 SIM.
5. Verify the iPhone receives the system CallKit incoming screen.
6. Answer the call.
7. Verify the BLE log shows `05`, then `0F` and that the microphone prompt is requested only at this stage.
8. End the call and verify Voice returns to `CLOSED` and no microphone capture continues.

Do not use `ANSWER TEST`: the final UI intentionally removes the test shortcut so microphone capture is tied to an actual CallKit call lifecycle.
