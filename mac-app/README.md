# Current: Phase 1b voice

See [VOICE.md](VOICE.md) for the current voice-enabled project, setup, permissions, and testing. Full voice source is in [VOICE_CODE.md](VOICE_CODE.md). The Phase 0 notes below describe the original hand-tracking baseline.

# Wave — Phase 0

Native Swift/SwiftUI menu-bar prototype for Apple Silicon, macOS 14+, built with Xcode 26.6. No backend, voice, network calls, or frame storage in the app. MediaPipe's local hand model is the only ML component.

## Files

The supplied project is `Wave/Wave.xcodeproj`; its app sources are in `Wave/Wave/`. The installed copy at `~/wave-mac` has `Wave.xcodeproj` at its root and app sources in `Wave/`.

- `WaveApp.swift`: menu-bar scene, Wave hand icon, toggle, permission shortcut, Quit, lifecycle.
- `WaveModel.swift`: permission UI, status, mode coordination, system cursor and click events.
- `HandCamera.swift`: AVFoundation camera, BGRA frames, bundled MediaPipe model and serial inference.
- `GestureEngine.swift`: cursor mapping/smoothing, pinch debounce and palm-pause state machine.
- `Tests/main.swift`: independent gesture behavior checks; not included in the app target.
- `FULL_CODE.md`: complete app source listing, file by file, plus configuration.

## Exact Swift Package Manager setup

The project already contains this dependency and its resolved revision. For a fresh Xcode project:

1. Choose **File > Add Package Dependencies…** and enter `https://github.com/vcamapp/mediapipe.git`.
2. Choose **Commit** as the dependency rule and enter `944568ca9714d5be95b62f6a610582470ba4bae5`.
3. Click **Add Package**; add **MediaPipeTasksVisionHandLandmarker** to the **Wave** target. It includes the framework and `hand_landmarker.task`; no separate model download or additional product is needed.
4. Set the macOS deployment target to **14.0**, Architectures to **arm64**, Swift language version to **5**, and Default Actor Isolation to **nonisolated**. Use Xcode 26.x or newer.
5. Disable **App Sandbox**, retain **Hardened Runtime**, and enable its **Camera** resource access. Add the Info properties below.

This is the **unofficial VCam distribution**, not a Google-supported macOS Swift SDK. It builds native macOS MediaPipe from upstream sources and provides a checksum-verified XCFramework through SPM. Google's documented Apple integration is for iOS via CocoaPods. Sources: https://github.com/vcamapp/mediapipe and https://ai.google.dev/edge/mediapipe/solutions/vision/hand_landmarker/ios .

## Info.plist entries

Xcode generates Info.plist in this project. The following values are configured in target build settings; do not also add an Info.plist to the synchronized source folder.

```xml
<key>LSUIElement</key>
<true/>
<key>NSCameraUsageDescription</key>
<string>Wave uses the camera to track your hand gestures. Frames are processed on-device and never stored or sent anywhere.</string>
```

Corresponding build settings: `INFOPLIST_KEY_LSUIElement = YES` and `INFOPLIST_KEY_NSCameraUsageDescription =` the string above. `ENABLE_RESOURCE_ACCESS_CAMERA = YES` supplies the hardened-runtime camera entitlement when signing. Sandbox is disabled because this prototype posts system-wide input events.

## Run and permissions — five lines

1. Open `~/wave-mac/Wave.xcodeproj` in Xcode 26.x on an Apple Silicon Mac; select Wave > My Mac.
2. Select your signing team if needed, then press Command-R; Wave appears only in the menu bar and starts On.
3. Use the launch alert to open Privacy & Security > Accessibility; enable Wave (use + to add the built Wave.app if absent).
4. Allow the camera prompt; if previously denied, enable Wave in Privacy & Security > Camera and quit/reopen it.
5. Point to move, pinch/release to click, hold an open palm for one second to pause; toggle On or remove your hand for half a second and return to resume.

## Behavior and prototype boundaries

- Controls the primary display. Uses Core Graphics display coordinates, mirrors X once, clamps to screen bounds, and lerps with a factor of 0.25.
- Uses MediaPipe HandLandmarker video mode with monotonic timestamps on the camera's serial queue. AVFoundation drops late frames, and UI processing rejects results older than 300 ms. Video mode retains tracking between frames and is used on the live camera stream.
- Pinch distances are divided by wrist-to-middle-knuckle distance. Press threshold: 0.25; release threshold: 0.45; minimum interval between clicks: 300 ms. A visible release is required before the first click and after hand loss.
- An open palm is a simple landmark-distance heuristic, with one second of continuous detection. Keep fingers extended and palm facing the camera. Lighting, occlusion, hand orientation, and camera framing affect reliability.
- Palm pause keeps the camera running so it can detect departure and reappearance. Manual Off stops the camera and can only be resumed with the menu toggle. A held pinch or a single missed frame cannot resume a pause or produce repeated clicks.
- Permission is rechecked before posting events. Camera/model errors appear in the menu and switch mode Off; toggle On to retry. No screen-recording or microphone permission is used.

## Validation

The Debug arm64 app compiled and linked with the real pinned MediaPipe XCFramework in Xcode 26.6, without Swift compiler errors or warnings. Xcode emits its standard informational App Intents metadata warning because this app has no App Intents dependency. Generated Info.plist has `LSUIElement = true`, the exact camera description, and minimum system version 14.0.

Gesture checks pass for mirrored mapping, smoothing, pinch release/debounce, hand loss, palm timing, reappearance, and manual Off. Run them from the installed project root:

```sh
xcrun swiftc Wave/GestureEngine.swift Tests/main.swift -o /tmp/wave-gesture-tests
/tmp/wave-gesture-tests
```

Real camera accuracy, permission UI, and physical cursor/click behavior require the five-line hands-on run above; they have not been verified by automated input on this Mac.
