// Window that shows which key combination macOS really receives from the keypad.
// Build: swiftc -O keyview.swift -o keyview
// Close the window to quit. System-wide shortcuts (e.g. screenshots) are taken by macOS first.

import AppKit

let keyNames: [UInt16: String] = [
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
    109: "F10", 103: "F11", 111: "F12", 123: "←", 124: "→", 125: "↓", 126: "↑",
    36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "Esc",
    115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
]

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Keypad key test"
window.delegate = delegate

let current = NSTextField(labelWithString: "Press a key on the keypad")
current.font = .systemFont(ofSize: 34, weight: .medium)
current.alignment = .center
current.frame = NSRect(x: 20, y: 200, width: 480, height: 60)

let history = NSTextField(labelWithString: "")
history.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
history.textColor = .secondaryLabelColor
history.maximumNumberOfLines = 0
history.frame = NSRect(x: 20, y: 20, width: 480, height: 170)

window.contentView?.addSubview(current)
window.contentView?.addSubview(history)
window.center()
window.makeKeyAndOrderFront(nil)
window.level = .floating
app.activate(ignoringOtherApps: true)

var lines: [String] = []
NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
    let flags = event.modifierFlags
    var text = ""
    if flags.contains(.control) { text += "⌃" }
    if flags.contains(.option) { text += "⌥" }
    if flags.contains(.shift) { text += "⇧" }
    if flags.contains(.command) { text += "⌘" }
    let key = keyNames[event.keyCode]
        ?? event.charactersIgnoringModifiers.map { $0.uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
        ?? "?"
    text += key
    current.stringValue = text
    lines.insert("\(text)    (keyCode \(event.keyCode))", at: 0)
    history.stringValue = lines.prefix(9).joined(separator: "\n")
    return nil // swallow the key so nothing else happens in this window
}
app.run()
