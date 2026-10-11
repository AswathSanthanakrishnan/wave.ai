# Wave Phase 1b: local push-to-talk

Open `Wave/Wave.xcodeproj` in this checkout (`~/Downloads/wave-mac`). This is the updated copy; the separate `~/wave-mac` copy from Phase 0 is not updated.

## Test it

1. Build and run Wave in Xcode 26.x on an Apple Silicon Mac. Wait for **Voice ready — hold ⌃⌥Space** in the menu; the first Core ML load can take longer.
2. Set **Gesture mode: Off**. Voice uses no camera or gesture state.
3. Focus another app, hold **Control–Option–Space**, and grant microphone access if asked. If you released the keys while granting permission, press and hold them again.
4. Say **“hello wave”**, then release Space (or either modifier). Wave shows **Listening...**, then **Transcribing…**, **Asking Wave…**, and **Speaking…**; the reply is spoken using the local system voice.
5. Alternatively choose **Test voice**, speak during its five-second recording, and wait for the reply. The backend and Ollama must be running locally. A connection failure shows **Backend not reachable**.

The global shortcut uses an active Core Graphics event tap and the existing Accessibility grant. The chord is consumed so it does not type spaces into the focused app. Key repeats do not start additional recordings. Secure-input fields or another app's shortcut interception can prevent global key delivery; test in an ordinary text editor or browser page.

## Swift Package Manager

The dependency is already added and pinned in the project.

1. In Xcode choose **File → Add Package Dependencies…**.
2. Enter `https://github.com/argmaxinc/argmax-oss-swift.git`.
3. Choose **Exact Version: 1.1.0**.
4. Add only the **WhisperKit** product to the **Wave** target. Keep the existing MediaPipe product.
5. Leave the target at macOS 14.0, arm64, Swift 5, and nonisolated default actor isolation.

Package choice: **Argmax WhisperKit**, the native Swift/Core ML Whisper implementation maintained in Argmax OSS. Its stable 1.1.0 release has Apple Silicon support and a native in-memory transcription API. Wave links WhisperKit and its internal ArgmaxCore target. The package manifest also resolves Apple's `swift-argument-parser` for Argmax's CLI; that product is not linked into Wave. No additional application dependencies were added.

Sources: [Argmax OSS](https://github.com/argmaxinc/argmax-oss-swift), [1.1.0 release](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0).

## Offline model assets

`Wave/VoiceModels/` is already populated and copied into Wave.app as a folder resource. It contains the English `openai_whisper-base.en` Core ML model and local tokenizer, approximately 155 MB. Model preparation/downloads happen during development, not in the running app. Audio and transcription never go to a cloud API.

To reconstruct the assets from their pinned upstream revisions, run this from the checkout root, then rebuild:

```sh
bash Scripts/prepare-voice-model.sh
```

The script downloads static model/tokenizer files from Hugging Face. It never accesses the microphone. Do not move the model files into the Swift source group: keep the existing `VoiceModels` folder reference in Copy Bundle Resources. The app checks for local assets, validates the tokenizer, and sets WhisperKit `download: false`; missing or corrupt assets produce a menu error instead of starting a recording.

## Files

All Swift files below belong to the Wave app target and live in `Wave/Wave/`:

- `WaveApp.swift`: existing menu and lifecycle with independent voice state, microphone icon, Test voice, Cancel voice, and permission/retry actions.
- `VoiceHotKey.swift`: global Control–Option–Space event tap, repeat suppression, modifier release handling, and recovery after tap disablement.
- `VoiceRecorder.swift`: AVAudioEngine capture, mono 16 kHz conversion, lock-protected in-memory PCM, and bounded recording length.
- `LocalTranscriber.swift`: actor-isolated WhisperKit model loading and transcription of the PCM array.
- `VoiceBackend.swift`: ephemeral URLSession POST to `127.0.0.1:4000/ask`, JSON decoding, timeout/errors, and redirect rejection.
- `VoiceModel.swift`: microphone permission, recording/transcription/request/speech lifecycle, five-second menu test, cancellation, and AVSpeechSynthesizer.

Other files:

- `Wave/VoiceInfo.plist`: microphone description and local-network transport setting; Xcode merges it with the existing generated Info.plist values.
- `Wave/Wave.xcodeproj/project.pbxproj`: WhisperKit dependency, model resource, microphone entitlement build setting, and plist path.
- `Scripts/prepare-voice-model.sh`: reproducible developer-only asset download.
- `Tests/VoiceBackendChecks.swift`: dependency-free checks for backend success and failure handling.
- `Tests/VoiceTranscriptionSmoke.swift`: generated-audio transcription and local backend smoke test.
- `VOICE_CODE.md`: complete new/updated Swift source, file by file, with plist and model preparation script.

The Phase 0 `HandCamera.swift`, `GestureEngine.swift`, and `WaveModel.swift` are unchanged.

## Info.plist and capabilities

`Wave/VoiceInfo.plist` contains:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Wave uses the microphone for push-to-talk voice commands. Audio is transcribed on-device and never stored.</string>
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

Existing `LSUIElement = true` and `NSCameraUsageDescription` stay configured in target build settings. Hardened Runtime has **Audio Input** enabled (`ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES`), alongside the existing Camera resource access. App Sandbox remains disabled for global cursor/hotkey handling. Apple Speech Recognition permission is not requested: WhisperKit does transcription locally.

## Behavior

- The microphone opens only for a held shortcut or the menu test. Audio is held in RAM, passed directly to WhisperKit, then released; no recording file is written. Model weights/tokenizer remain on disk.
- Releasing during the permission prompt cancels that round. It cannot start recording unexpectedly after permission is granted.
- Only one round runs at a time. Recording stops after at most 30 seconds, on cancellation, on sleep, or on microphone reconfiguration. Test voice stops after five seconds.
- New recording interrupts a spoken reply. Key presses during transcription or the backend request are ignored. Cancel voice discards the round and prevents a late reply from speaking.
- Silence/very short input is rejected. Whisper is probabilistic; noisy audio can still produce mistaken text.
- Only `{ "text": "…" }` reaches the localhost backend. Network sessions are ephemeral, and HTTP redirects are rejected. Backend timeout is 90 seconds per request / 95 seconds overall because the current local model can take roughly 40 seconds.
- Permission denial appears in the menu with an **Open Microphone Settings…** action. Enable Wave in Privacy & Security → Microphone; quit/reopen if macOS requests it.

## Verified results

- Xcode 26.6 Debug arm64 build: **BUILD SUCCEEDED**, with no Swift compiler errors or warnings. Xcode emits its standard App Intents metadata notice because this app has no App Intents dependency.
- Phase 0 gesture regression checks: passed.
- Voice backend checks: successful decoding, invalid JSON, empty response, HTTP failure, and connection failure passed.
- Local WhisperKit test on generated system-voice audio: `TRANSCRIPT: Hello Wave`.
- That transcript sent to the real local backend returned: `REPLY: Hello! I'm Wave. How can I help you today?`.
- Live microphone capture, global shortcut interaction, and audible AVSpeechSynthesizer output still require the hands-on steps above. The automated test used generated speech and did not access the camera or microphone.

Run the dependency-free backend and gesture checks from the checkout root:

```sh
xcrun swiftc Wave/Wave/VoiceBackend.swift Wave/Wave/VoiceRecorder.swift Tests/VoiceBackendChecks.swift -o /tmp/wave-backend-checks
/tmp/wave-backend-checks
xcrun swiftc Wave/Wave/GestureEngine.swift Tests/main.swift -o /tmp/wave-gesture-tests
/tmp/wave-gesture-tests
```
