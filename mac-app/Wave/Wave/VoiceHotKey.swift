import AppKit
import ApplicationServices

/// An active event tap consumes Control–Option–Space, even outside Wave.
@MainActor
final class VoiceHotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private var swallowedSpace = false
    private var permissionTimer: Timer?
    var onAvailability: ((Bool) -> Void)?

    func start() {
        installIfPermitted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.installIfPermitted() }
        }
    }

    private func installIfPermitted() {
        guard AXIsProcessTrusted() else {
            if held { held = false; enqueue(onCancel) }
            onAvailability?(false)
            return
        }
        guard tap == nil else { onAvailability?(true); return }
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // This tap's source is attached only to the main run loop.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<VoiceHotKey>.fromOpaque(context).takeUnretainedValue()
                return owner.handle(type, event: event)
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                         callback: callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            onAvailability?(false)
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onAvailability?(true)
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if held { held = false; enqueue(onCancel) }
            swallowedSpace = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let chord = event.flags.contains([.maskControl, .maskAlternate]) &&
                    !event.flags.contains(.maskCommand) && !event.flags.contains(.maskShift)
        let space = event.getIntegerValueField(.keyboardEventKeycode) == 49
        if type == .keyDown && space && (chord || swallowedSpace) {
            if !swallowedSpace && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                swallowedSpace = true
                held = true
                enqueue(onPress)
            }
            return nil
        }
        if type == .keyUp && space && swallowedSpace {
            swallowedSpace = false
            if held { held = false; enqueue(onRelease) }
            return nil
        }
        if type == .flagsChanged && held && !chord {
            held = false
            enqueue(onRelease)
        }
        return Unmanaged.passUnretained(event)
    }

    private func enqueue(_ action: (() -> Void)?) {
        // Keep the event-tap callback short; audio shutdown happens after it returns.
        DispatchQueue.main.async { action?() }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if held { enqueue(onCancel) }
        held = false
        swallowedSpace = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }
}
