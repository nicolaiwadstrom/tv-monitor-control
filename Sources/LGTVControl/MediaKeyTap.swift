import AppKit

enum MediaKey {
    case volumeUp, volumeDown, mute
}

/// Intercepts the keyboard's volume keys (system-defined media key events) with a CGEventTap.
/// Needs the Accessibility permission. All callbacks happen on the main run loop.
final class MediaKeyTap {
    /// Return true to swallow the event so macOS doesn't also act on it.
    var handler: @MainActor (_ key: MediaKey, _ isDown: Bool, _ isRepeat: Bool, _ modifiers: NSEvent.ModifierFlags) -> Bool
        = { _, _, _, _ in false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.process(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        return true
    }

    func stop() {
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        tap = nil
        source = nil
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14,
              let ns = NSEvent(cgEvent: event),
              Int(ns.subtype.rawValue) == 8 else { return Unmanaged.passUnretained(event) }

        let data = ns.data1
        let keyCode = (data & 0xFFFF_0000) >> 16
        let flags = data & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        let isRepeat = (flags & 0x1) != 0

        let key: MediaKey
        switch keyCode {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 7: key = .mute
        default: return Unmanaged.passUnretained(event)
        }

        let swallow = MainActor.assumeIsolated {
            handler(key, isDown, isRepeat, ns.modifierFlags)
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
