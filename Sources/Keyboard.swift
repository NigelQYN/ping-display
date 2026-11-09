import AppKit
import Carbon
import CoreGraphics

final class Keyboard {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onCancel: (() -> Void)?
    var onBrightness: ((Int) -> Bool)?

    func startRecovery() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x50494E47, id.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<Keyboard>.fromOpaque(context).takeUnretainedValue().onCancel?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return }
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: 0x50494E47, id: 1),
                            GetApplicationEventTarget(), 0, &hotkey)
    }

    var recoveryAvailable: Bool { hotkey != nil }

    @discardableResult
    func setBrightnessKeys(_ enabled: Bool, requestPermission: Bool = false) -> Bool {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        guard enabled else { return true }
        if requestPermission && !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        let type = CGEventType(rawValue: 14)!
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: 1 << type.rawValue,
                                           callback: { _, type, event, context in
            let keyboard = Unmanaged<Keyboard>.fromOpaque(context!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = keyboard.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let native = NSEvent(cgEvent: event), native.type == .systemDefined, native.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            let key = (native.data1 >> 16) & 0xffff
            guard key == 2 || key == 3 else { return Unmanaged.passUnretained(event) }
            let flags = native.data1 & 0xffff
            let down = ((flags >> 8) & 0xff) == 0x0a
            if keyboard.onBrightness?(down ? (key == 2 ? 1 : -1) : 0) == true { return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0) else { return false }
        tap = port
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        setBrightnessKeys(false)
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
