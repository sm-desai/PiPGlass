import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    static let controlOption = UInt32(controlKey | optionKey)

    func register(keyCode: Int, modifiers: UInt32, name: String, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5047_4C53), id: id) // 'PGLS'
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
        } else {
            Log.info("hotkey: failed to register \(name) (status \(status)); another app may own it")
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr {
                let id = hotKeyID.id
                Log.info("hotkey: pressed id \(id)")
                DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
