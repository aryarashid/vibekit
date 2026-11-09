import Carbon.HIToolbox

/// Finds keys by the letter they type, so ⌘V and the global shortcuts follow Dvorak, AZERTY and other layouts.
@MainActor
enum KeyLayout {
    /// The key that types `letter` while Command is held on the current layout. Command matters: layouts such as
    /// "Dvorak – QWERTY ⌘" switch to QWERTY while it is down. Falls back to the US position.
    static func keyCode(for letter: Character, fallback: Int) -> Int {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let wanted = String(letter).lowercased()
        let command = UInt32((cmdKey >> 8) & 0xFF)

        func types(_ code: Int) -> Bool {
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), command, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            return status == noErr && length > 0 && String(utf16CodeUnits: chars, count: length).lowercased() == wanted
        }
        if types(fallback) { return fallback }
        return (0..<128).first(where: types) ?? fallback
    }
}
