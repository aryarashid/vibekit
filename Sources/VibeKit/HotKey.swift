import Carbon.HIToolbox

/// System-wide shortcuts through Carbon, which need no Accessibility permission.
@MainActor
final class HotKey {
    enum Key: UInt32, CaseIterable {
        /// Control-Option-Command-V: the panel.
        case panel = 1
        /// Control-Option-Command-P: the panel, on Prompts.
        case prompts = 2

        var code: Int {
            switch self {
            case .panel: kVK_ANSI_V
            case .prompts: kVK_ANSI_P
            }
        }
    }

    private var refs: [Key: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private static var actions: [Key: () -> Void] = [:]

    func set(_ key: Key, enabled: Bool, action: @escaping () -> Void) {
        if let ref = refs.removeValue(forKey: key) { UnregisterEventHotKey(ref) }
        Self.actions[key] = enabled ? action : nil
        guard enabled else { return }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x564B_4954), id: key.rawValue) // "VKIT"
        RegisterEventHotKey(UInt32(key.code), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[key] = ref }
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let raw = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let key = HotKey.Key(rawValue: raw) { HotKey.actions[key]?() }
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
