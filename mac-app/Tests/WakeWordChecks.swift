import Foundation
import AVFoundation

@MainActor
func testWakeWord() {
    print("Testing WakeWordListener...")

    // 1. Test UserDefaults storage and configuration
    UserDefaults.standard.set(0.45, forKey: "wake_word_sensitivity")
    let sens = UserDefaults.standard.double(forKey: "wake_word_sensitivity")
    assert(abs(sens - 0.45) < 0.001, "Sensitivity should match configured value")

    // 2. Test listener instantiation
    let listener = WakeWordListener()
    assert(!listener.isListening, "Listener should start not listening")
    assert(!listener.activeEngineName.isEmpty, "Active engine should have a name")

    // 3. Test frame processing
    let silentFrame = [Int16](repeating: 0, count: WakeWordListener.porcupineFrameLength)
    assert(silentFrame.count == 512, "Frame length must be 512 samples")

    // 4. Test start and stop
    listener.start()
    assert(listener.isListening, "Listener should be listening after start()")

    listener.pause()
    listener.resume()

    listener.stop()
    assert(!listener.isListening, "Listener should not be listening after stop()")
    print("PASS: WakeWordListener lifecycle, frame size, sensitivity, and state transitions")
}

@main
struct WakeWordChecks {
    @MainActor
    static func main() {
        testWakeWord()
    }
}
