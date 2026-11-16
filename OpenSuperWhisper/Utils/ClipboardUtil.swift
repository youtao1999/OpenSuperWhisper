import Cocoa
import ApplicationServices
import Carbon

class ClipboardUtil {

    typealias PasteboardContents = ([NSPasteboard.PasteboardType: Any], [NSPasteboard.PasteboardType])

    /// Slow consumers (browsers, Electron apps) can service the synthesized
    /// Cmd+V long after the event is posted. Restoring the original clipboard
    /// earlier makes them paste the old contents instead of the transcription.
    static let clipboardRestoreDelay: TimeInterval = 1.5

    /// Copies text to clipboard without pasting or restoring
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    /// Pastes text and keeps it in clipboard (does not restore original clipboard)
    static func insertTextAndKeepInClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        simulatePaste()
    }

    /// Pastes text and restores original clipboard (legacy behavior)
    static func insertText(_ text: String) {
        insertText(text, postEvent: { $0.post(tap: .cghidEventTap) })
    }

    static func insertText(_ text: String, postEvent: (CGEvent) -> Void) {
        let pasteboard = NSPasteboard.general

        // Save current pasteboard contents
        let savedContents = saveCurrentPasteboardContents(from: pasteboard)

        // Set new text to pasteboard
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        let changeCountAfterCopy = pasteboard.changeCount

        // Simulate Cmd+V using layout-aware keycode resolution
        sendCmdV(postEvent: postEvent)

        // Restore original contents only after the target app had a chance to
        // process the paste, and only if the pasteboard still holds our text:
        // a different changeCount means the user (or another app) took over
        // the clipboard and restoring would clobber their data.
        if let contents = savedContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
                restoreIfUnchanged(contents, expectedChangeCount: changeCountAfterCopy, pasteboard: pasteboard)
            }
        }
    }

    @discardableResult
    static func restoreIfUnchanged(_ contents: PasteboardContents,
                                   expectedChangeCount: Int,
                                   pasteboard: NSPasteboard = .general) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        restorePasteboardContents(contents, to: pasteboard)
        return true
    }
    
    private static func simulatePaste() {
        sendCmdV(postEvent: { $0.post(tap: .cghidEventTap) })
    }
    
    private static func sendCmdV(postEvent: (CGEvent) -> Void) {
        // QWERTY keycode for V
        let qwertyKeyCodeV: CGKeyCode = 9
        
        // Determine the correct keycode for Cmd+V
        let keyCodeV: CGKeyCode
        
        if isQwertyCommandLayout() {
            // For layouts like "Dvorak - QWERTY ⌘" that use QWERTY for Command shortcuts
            keyCodeV = qwertyKeyCodeV
        } else if let foundKeycode = findKeycodeForCharacter("v") {
            // For layouts where shortcuts follow the layout (Dvorak Left/Right Hand)
            keyCodeV = foundKeycode
        } else {
            // Fallback for non-Latin layouts (Russian, etc.) - use QWERTY keycode
            keyCodeV = qwertyKeyCodeV
        }
        
        // Real Left Command press/release around V: remote-desktop clients
        // (Chrome Remote Desktop) forward only keys they see pressed, so a
        // V carrying just the Cmd flag arrives on the remote side as plain "v".
        let leftCommandKeyCode: CGKeyCode = 55

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: leftCommandKeyCode, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: leftCommandKeyCode, keyDown: false)
        else { return }

        cmdDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        cmdUp.flags = []

        postEvent(cmdDown)
        postEvent(keyDown)
        postEvent(keyUp)
        postEvent(cmdUp)
    }
    
    /// Chrome Remote Desktop runs in Chrome (or as a Chrome app).
    static func frontmostIsChrome() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.google.Chrome") ?? false
    }

    private static let typingQueue = DispatchQueue(label: "ClipboardUtil.typing")
    private static let typingEventDelay: useconds_t = 2000

    /// Types text as real key presses, Shift pressed as its own key.
    /// Chrome Remote Desktop forwards keystrokes at once but syncs the clipboard
    /// lazily, so a paste there inserts stale clipboard text.
    /// shortcut: characters the layout cannot type without Option are skipped; fine for English dictation.
    static func typeText(_ text: String) {
        let keys = keyMapForCurrentLayout()
        let shiftKeyCode: CGKeyCode = 56
        typingQueue.async {
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
            func post(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
                event.flags = flags
                event.post(tap: .cghidEventTap)
                usleep(typingEventDelay)
            }
            for ch in text {
                guard let key = keys[ch] else { continue }
                let flags: CGEventFlags = key.shift ? .maskShift : []
                if key.shift { post(shiftKeyCode, true, .maskShift) }
                post(key.code, true, flags)
                post(key.code, false, flags)
                if key.shift { post(shiftKeyCode, false, []) }
            }
        }
    }

    /// Character to (keycode, needs Shift) for the main key block of the current layout.
    static func keyMapForCurrentLayout() -> [Character: (code: CGKeyCode, shift: Bool)] {
        var map: [Character: (code: CGKeyCode, shift: Bool)] = ["\n": (36, false), "\t": (48, false)]
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return map }
        let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

        // Unshifted pass first so it wins; 0...50 skips the keypad (Windows reads it as navigation keys with NumLock off).
        for shift in [false, true] {
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            for keycode: UInt16 in 0...50 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(keyboardLayout, keycode, UInt16(kUCKeyActionDown), modifiers,
                                            UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, 4, &length, &chars)
                guard status == noErr, length == 1, let scalar = UnicodeScalar(chars[0]) else { continue }
                let ch = Character(scalar)
                if map[ch] == nil { map[ch] = (CGKeyCode(keycode), shift) }
            }
        }
        return map
    }

    static func isQwertyCommandLayout() -> Bool {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return false }
        
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        
        // "Dvorak - QWERTY ⌘" uses QWERTY positions for Command shortcuts
        // Its ID contains "DVORAK-QWERTY" or similar patterns
        // Also standard QWERTY, ABC, US layouts use keycode 9 for V
        let qwertyCommandLayouts = [
            "DVORAK-QWERTY",  // Dvorak - QWERTY ⌘
            "US",             // US QWERTY
            "ABC",            // ABC
            "Australian",     // Australian
            "British",        // British
            "Canadian",       // Canadian
            "USInternational" // US International
        ]
        
        let upperID = sourceID.uppercased()
        return qwertyCommandLayouts.contains { upperID.contains($0.uppercased()) }
    }
    
    static func findKeycodeForCharacter(_ char: Character) -> CGKeyCode? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        
        let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )
        
        let targetLower = char.lowercased()
        
        // Iterate through common keycodes (0-50 covers all letter keys)
        for keycode: UInt16 in 0...50 {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            
            let status = UCKeyTranslate(
                keyboardLayout,
                keycode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
            
            if status == noErr && length > 0 {
                let resultChar = Character(UnicodeScalar(chars[0])!)
                if resultChar.lowercased() == targetLower {
                    return CGKeyCode(keycode)
                }
            }
        }
        return nil
    }
    
    static func saveCurrentPasteboardContents(from pasteboard: NSPasteboard = .general) -> PasteboardContents? {
        let types = pasteboard.types ?? []
        
        guard !types.isEmpty else { return nil }
        
        var savedContents: [NSPasteboard.PasteboardType: Any] = [:]
        
        for type in types {
            if let data = pasteboard.data(forType: type) {
                savedContents[type] = data
            } else if let string = pasteboard.string(forType: type) {
                savedContents[type] = string
            } else if let urls = pasteboard.propertyList(forType: type) as? [String] {
                savedContents[type] = urls
            }
        }
        
        return (!savedContents.isEmpty) ? (savedContents, types) : nil
    }
    
    static func restorePasteboardContents(_ contents: PasteboardContents, to pasteboard: NSPasteboard = .general) {
        let (savedContents, types) = contents
        
        pasteboard.declareTypes(types, owner: nil)
        
        for (type, content) in savedContents {
            if let data = content as? Data {
                pasteboard.setData(data, forType: type)
            } else if let string = content as? String {
                pasteboard.setString(string, forType: type)
            } else if let urls = content as? [String] {
                pasteboard.setPropertyList(urls, forType: type)
            }
        }
    }
    
    @available(*, deprecated, renamed: "insertText")
    static func insertTextUsingPasteboard(_ text: String) {
        insertText(text)
    }
    
    // MARK: - Testing Helpers
    
    static func getCurrentInputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }
    
    static func switchToInputSource(withID targetID: String) -> Bool {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            
            if sourceID.contains(targetID) || targetID.contains(sourceID) || sourceID == targetID {
                let result = TISSelectInputSource(source)
                usleep(100000) // 100ms delay for layout switch
                return result == noErr
            }
        }
        return false
    }
    
    static func getAvailableInputSources() -> [String] {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        
        var result: [String] = []
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let selectablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            else { continue }
            
            let isSelectable = unsafeBitCast(selectablePtr, to: CFBoolean.self) == kCFBooleanTrue
            if isSelectable {
                let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                result.append(sourceID)
            }
        }
        return result
    }
}
