// Small macOS tool for the Vaydeer JP-1011 keypad.
// Build: swiftc -O vaydeer.swift -o vaydeer
//
//   vaydeer info                     show firmware and layers
//   vaydeer dump                     show all keys
//   vaydeer backup <file.json>       save all keys to a file
//   vaydeer set [layer=N] 0=F13 1=ctrl+f16 ...  write keys (default: active layer)
//   vaydeer restore <file.json> [layer]         write keys back from a backup
//   vaydeer layer N                  make layer N the active layer (stays after unplugging)
//
// Key index is row by row: 0 1 2 / 3 4 5 / 6 7 8.
// Protocol notes come from the Vaydeer Studio project (docs/research/hid-protocol.md).

import Foundation
import IOKit.hid

let vendorID = 0x0483
let productID = 0x5752
let cmdWriteKey: UInt8 = 0x61
let cmdReadKey: UInt8 = 0x62
let cmdInfo: UInt8 = 0x60
let cmdLayerInfo: UInt8 = 0x63
let cmdWriteLayerName: UInt8 = 0x65
let cmdCommit: UInt8 = 0x66
let cmdReadLayerName: UInt8 = 0x67
let cmdSetLayer: UInt8 = 0x64 // make a stored layer the active one
let cmdInit: UInt8 = 0xFD // sent before writing, as the vendor app and ninekeypad do
// Only these commands can leave this program. Firmware command 0xFC is not here on purpose.
let allowedCommands: Set<UInt8> = [cmdInfo, cmdWriteKey, cmdReadKey, cmdLayerInfo, cmdWriteLayerName, cmdCommit, cmdReadLayerName, cmdSetLayer, cmdInit]
// Vaydeer Studio validated writes on 1.0.2. Firmware 1.1.1 was added after a test on a real keypad.
let writeFirmwares: [[UInt8]] = [[1, 0, 2], [1, 1, 1]]
let writeBootloader: [UInt8] = [0, 2, 1]

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

func xor(_ bytes: [UInt8]) -> UInt8 { bytes.reduce(0, ^) }
func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

func utf16be(_ text: String) -> [UInt8] {
    text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
}

func fromUtf16be(_ bytes: [UInt8]) -> String {
    var units: [UInt16] = []
    var index = 0
    while index + 1 < bytes.count {
        units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        index += 2
    }
    return String(decoding: units, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
}

final class Keypad {
    private let manager: IOHIDManager // must stay alive, or the device closes
    private let device: IOHIDDevice
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    fileprivate var received: [[UInt8]] = []

    init() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: 0xFF00,
            kIOHIDPrimaryUsageKey: 1,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, set.count == 1, let found = set.first else {
            throw ToolError("Keypad command interface not found (need exactly one). Is the keypad connected?")
        }
        device = found
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            throw ToolError(String(format: "Cannot open keypad: 0x%08X", status))
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            let keypad = Unmanaged<Keypad>.fromOpaque(context!).takeUnretainedValue()
            keypad.received.append(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        pump(0.05) // drop old replies
        received.removeAll()
    }

    private func pump(_ seconds: Double) {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, true)
    }

    private func parse(_ raw: [UInt8], expected: UInt8) -> [UInt8]? {
        for frame in [raw, Array(raw.dropFirst())] where frame.count >= 3 {
            let total = Int(frame[1]) + 3
            guard frame.count >= total, frame[0] == expected else { continue }
            guard xor(Array(frame[..<(total - 1)])) == frame[total - 1] else { continue }
            return Array(frame[2..<(total - 1)])
        }
        return nil
    }

    /// Sends one command. Returns the reply data after the status byte.
    func request(_ command: UInt8, _ payload: [UInt8] = []) throws -> [UInt8] {
        guard allowedCommands.contains(command) else {
            throw ToolError(String(format: "Command 0x%02X is not allowed", command))
        }
        guard payload.count <= 61 else { throw ToolError("Payload is too long") }
        let body = [command, UInt8(payload.count)] + payload
        var frame = body + [xor(body)]
        frame += [UInt8](repeating: 0, count: 64 - frame.count)
        received.removeAll()
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, frame, frame.count)
        guard status == kIOReturnSuccess else {
            throw ToolError(String(format: "Write to keypad failed: 0x%08X", status))
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            pump(0.01)
            for raw in received {
                if let data = parse(raw, expected: command) {
                    guard let first = data.first else { throw ToolError("Empty reply") }
                    guard first == 0 else {
                        throw ToolError(String(format: "Keypad refused command 0x%02X, status %d", command, first))
                    }
                    return Array(data.dropFirst())
                }
            }
        }
        throw ToolError(String(format: "No reply to command 0x%02X", command))
    }
}

struct Info {
    let type, keys: UInt8
    let firmware, bootloader: [UInt8]
    let activeLayer, layerCount, maxLayers: UInt8
}

struct Key: Codable, Equatable {
    var layer: Int
    var index: Int
    var keyType: Int
    var subtype: Int
    var encoding: Int
    var label: String
    var data: [Int]
}

struct Backup: Codable {
    var firmware: [Int]
    var bootloader: [Int]
    var activeLayer: Int
    var layerNames: [String]
    var keys: [Key]
}

func readInfo(_ pad: Keypad) throws -> Info {
    let data = try pad.request(cmdInfo)
    guard data.count >= 11 else { throw ToolError("Short info reply: \(hex(data))") }
    return Info(type: data[0], keys: data[1], firmware: Array(data[2...4]), bootloader: Array(data[5...7]),
                activeLayer: data[8], layerCount: data[9], maxLayers: data[10])
}

func readKey(_ pad: Keypad, layer: UInt8, index: UInt8) throws -> Key {
    let head = try pad.request(cmdReadKey, [0xFF, layer, index])
    guard head.count >= 4 else { throw ToolError("Short key header: \(hex(head))") }
    var data: [UInt8] = []
    var finished = false
    for sequence in 0..<16 {
        let chunk = try pad.request(cmdReadKey, [UInt8(sequence), layer, index])
        guard let first = chunk.first else { throw ToolError("Empty key data") }
        if first == 0xFE { finished = true; break }
        data += chunk.dropFirst()
    }
    guard finished else { throw ToolError("Key data has no end marker") }
    return Key(layer: Int(layer), index: Int(index), keyType: Int(head[1]), subtype: Int(head[2]),
               encoding: Int(head[3]), label: fromUtf16be(Array(head[4...])), data: data.map(Int.init))
}

func snapshot(_ pad: Keypad) throws -> Backup {
    let info = try readInfo(pad)
    var names: [String] = []
    var keys: [Key] = []
    for layer in 0..<info.layerCount {
        names.append(fromUtf16be(try pad.request(cmdReadLayerName, [layer])))
        for index in 0..<info.keys {
            keys.append(try readKey(pad, layer: layer, index: index))
        }
    }
    return Backup(firmware: info.firmware.map(Int.init), bootloader: info.bootloader.map(Int.init),
                  activeLayer: Int(info.activeLayer), layerNames: names, keys: keys)
}

func saveBackup(_ backup: Backup, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(backup).write(to: URL(fileURLWithPath: path))
}

// Named keys (Windows virtual-key codes, which the keypad stores). The first name of a code is used for display.
let namedKeys: [(String, UInt8)] = [
    ("Ctrl", 17), ("Shift", 16), ("Opt", 18), ("Alt", 18), ("Option", 18), ("Cmd", 91), ("Meta", 91),
    ("Left", 37), ("Up", 38), ("Right", 39), ("Down", 40),
    ("Space", 32), ("Enter", 13), ("Return", 13), ("Tab", 9), ("Esc", 27), ("Backspace", 8),
    ("Delete", 46), ("Del", 46), ("Home", 36), ("End", 35), ("PgUp", 33), ("PgDn", 34),
    // Keys labelled + and - on a German keyboard (US ] and /). Verified on firmware 1.1.1: macOS keyCode 30 and 44.
    ("Plus", 0xDD), ("Minus", 0xBF),
    // Keys labelled = and - on a US keyboard (German ´ and ß).
    ("Equal", 0xBB), ("Hyphen", 0xBD),
    ("VolUp", 0xAF), ("VolDown", 0xAE), ("Mute", 0xAD), ("Play", 0xB3), ("Next", 0xB0), ("Prev", 0xB1),
]
let modifierSymbols: [UInt8: String] = [17: "⌃", 18: "⌥", 16: "⇧", 91: "⌘"]

func parseCodes(_ text: String) throws -> [UInt8] {
    var codes: [UInt8] = []
    for part in text.uppercased().split(separator: "+").map(String.init) {
        if let named = namedKeys.first(where: { $0.0.uppercased() == part }) {
            codes.append(named.1)
        } else if part.count == 1, let scalar = part.unicodeScalars.first,
                  ("A"..."Z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)) {
            codes.append(UInt8(scalar.value)) // VK codes for A-Z and 0-9 equal their ASCII codes
        } else if part.hasPrefix("F"), let number = Int(part.dropFirst()), (1...24).contains(number) {
            codes.append(UInt8(111 + number))
        } else if part.hasPrefix("NUM"), let number = Int(part.dropFirst(3)), (0...9).contains(number) {
            codes.append(UInt8(96 + number))
        } else if part.hasPrefix("0X"), let value = UInt8(part.dropFirst(2), radix: 16) {
            codes.append(value)
        } else {
            throw ToolError("Unknown key name: \(part). See: vaydeer keys")
        }
    }
    guard !codes.isEmpty else { throw ToolError("Empty key") }
    return codes
}

func keyName(_ code: Int) -> String {
    if let named = namedKeys.first(where: { Int($0.1) == code }) { return named.0 }
    switch code {
    case 48...57, 65...90: return String(UnicodeScalar(UInt8(code)))
    case 96...105: return "Num\(code - 96)"
    case 112...135: return "F\(code - 111)"
    default: return String(format: "0x%02X", code)
    }
}

/// Short Mac-style form, e.g. ⌘⇧4.
func shortcut(_ key: Key) -> String {
    switch key.keyType {
    case 0, 1:
        if key.data.allSatisfy({ $0 == 0 }) { return "—" }
        return key.data.map { modifierSymbols[UInt8($0)] ?? keyName($0) }.joined()
    case 2: return "(Text)"
    case 3: return "(program/URL)"
    case 4: return "(mouse)"
    case 5: return "(macro)"
    default: return "(type \(key.keyType))"
    }
}

func describe(_ key: Key) -> String {
    let names = key.data.map(keyName)
    return "key \(key.index): type=\(key.keyType) subtype=\(key.subtype) enc=\(key.encoding) "
        + "label=\"\(key.label)\" -> \(names.joined(separator: "+"))"
}

/// Prints the keys of one layer as the 3×3 grid of the keypad.
func printGrid(_ backup: Backup, layer: Int) {
    let width = 15
    func cell(_ text: String) -> String {
        let cut = String(text.prefix(width))
        return " " + cut + String(repeating: " ", count: width - cut.count) + " "
    }
    let line = "+" + Array(repeating: String(repeating: "-", count: width + 2), count: 3).joined(separator: "+") + "+"
    let name = layer < backup.layerNames.count ? backup.layerNames[layer] : ""
    print("Layer \(layer) \"\(name)\"\(layer == backup.activeLayer ? "  ← active" : "")")
    print(line)
    for row in 0..<3 {
        let keys = (0..<3).map { column in backup.keys.first { $0.layer == layer && $0.index == row * 3 + column } }
        print("|" + keys.map { cell($0.map { "\($0.index) \($0.label)" } ?? "") }.joined(separator: "|") + "|")
        print("|" + keys.map { cell($0.map { "  " + shortcut($0) } ?? "") }.joined(separator: "|") + "|")
        print(line)
    }
}

func writeKey(_ pad: Keypad, _ key: Key) throws {
    guard key.keyType == 0 || key.keyType == 1 else {
        throw ToolError("Key \(key.index) has type \(key.keyType). Only single keys and combinations can be written.")
    }
    let layer = UInt8(key.layer), index = UInt8(key.index)
    _ = try pad.request(cmdWriteKey, [0xFF, layer, index, UInt8(key.keyType), UInt8(key.subtype), 0] + utf16be(key.label))
    _ = try pad.request(cmdWriteKey, [0] + key.data.map { UInt8($0) })
    _ = try pad.request(cmdWriteKey, [0xFE])
}

func writeAll(_ pad: Keypad, keys: [Key], names: [String], info: Info) throws {
    guard writeFirmwares.contains(info.firmware), info.bootloader == writeBootloader, info.type == 1, info.keys == 9 else {
        throw ToolError("Firmware \(info.firmware) / bootloader \(info.bootloader) is not validated for writing. Nothing was written.")
    }
    for layer in Set(keys.map(\.layer)) {
        guard keys.filter({ $0.layer == layer }).map(\.index) == Array(0..<Int(info.keys)) else {
            throw ToolError("Layer \(layer) must be written with all keys in order. Nothing was written.")
        }
    }
    // Check every key before the first write: a failure mid-layer would leave the layer half written.
    for key in keys where key.keyType != 0 && key.keyType != 1 {
        throw ToolError("Layer \(key.layer) key \(key.index) has type \(key.keyType), which this tool cannot write. Nothing was written.")
    }
    // Highest layer index in use, as the vendor app sends it (ninekeypad, tested on 1.1.5).
    // The original tool sent maxLayers - 1 (5); with that, a new layer name did not survive unplugging.
    let maxIndex = UInt8(max(0, Int(info.layerCount) - 1))
    _ = try pad.request(cmdInit)
    for layer in Set(keys.map(\.layer)).sorted() {
        let value = UInt8(layer)
        _ = try pad.request(cmdWriteLayerName, [value, maxIndex] + utf16be(names[layer]))
        for key in keys where key.layer == layer { try writeKey(pad, key) }
        _ = try pad.request(cmdCommit, [value, maxIndex])
    }
    let after = try snapshot(pad)
    for key in keys {
        guard let actual = after.keys.first(where: { $0.layer == key.layer && $0.index == key.index }),
              actual.keyType == key.keyType, actual.data == key.data else {
            throw ToolError("Read-back differs on key \(key.index). Restore from the backup.")
        }
    }
    for layer in Set(keys.map(\.layer)) where layer < after.layerNames.count && after.layerNames[layer] != names[layer] {
        print("Warning: layer \(layer) name reads back as \"\(after.layerNames[layer])\", not \"\(names[layer])\". Keys are fine.")
    }
    print("Written and verified by read-back: \(keys.count) keys.")
}

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw ToolError("Use: info | show [layer] | layers | dump | backup <file> | set [layer=N] 0=cmd+c[:Label] ... | rename N \"Name\" | restore <file> | layer N | keys")
    }
    if command == "keys" {
        print("Modifier: ctrl shift opt cmd")
        print("Named:    " + namedKeys.map { $0.0.lowercased() }.filter { !["ctrl", "shift", "opt", "cmd", "alt", "option", "meta"].contains($0) }.joined(separator: " "))
        print("Also:     a-z, 0-9, f1-f12, num0-num9, 0xNN (raw virtual-key code)")
        print("Join with +, e.g. cmd+shift+4. plus/minus = the + and - keys of a German keyboard.")
        print("F13-F24 are not stored by firmware 1.1.1.")
        return
    }
    let pad = try Keypad()
    let info = try readInfo(pad)
    switch command {
    case "info":
        print("type=\(info.type) keys=\(info.keys) firmware=\(info.firmware) bootloader=\(info.bootloader)")
        print("activeLayer=\(info.activeLayer) layerCount=\(info.layerCount) maxLayers=\(info.maxLayers)")
    case "show":
        let all = try snapshot(pad)
        let layers = arguments.count > 1 ? [Int(arguments[1]) ?? all.activeLayer] : Array(0..<all.layerNames.count)
        for layer in layers {
            printGrid(all, layer: layer)
            print("")
        }
    case "dump":
        let all = try snapshot(pad)
        for (layer, name) in all.layerNames.enumerated() {
            print("Layer \(layer) \"\(name)\"\(layer == all.activeLayer ? " (active)" : "")")
            for key in all.keys where key.layer == layer { print("  " + describe(key)) }
        }
    case "backup":
        guard arguments.count == 2 else { throw ToolError("Use: backup <file>") }
        try saveBackup(try snapshot(pad), to: arguments[1])
        print("Saved \(arguments[1])")
    case "set":
        let all = try snapshot(pad)
        let stamp = Int(Date().timeIntervalSince1970)
        let path = "vaydeer-backup-\(stamp).json"
        try saveBackup(all, to: path)
        print("Backup: \(path)")
        var keys: [Key] = []
        var layer = all.activeLayer
        for item in arguments.dropFirst() {
            if item.hasPrefix("layer=") {
                guard let value = Int(item.dropFirst(6)), value < all.layerNames.count else {
                    throw ToolError("Bad layer: \(item)")
                }
                layer = value
                continue
            }
            // Form: index=keys[:label], e.g. 0=cmd+c:Kopieren
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let index = Int(parts[0]), (0..<Int(info.keys)).contains(index) else {
                throw ToolError("Bad item: \(item)")
            }
            let value = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let codes = value[0].lowercased() == "none" ? [UInt8(0)] : try parseCodes(value[0])
            guard var key = all.keys.first(where: { $0.layer == layer && $0.index == index }) else {
                throw ToolError("Key \(index) not found")
            }
            key.keyType = codes.count > 1 ? 1 : 0
            key.subtype = 255
            let label = value.count > 1 ? value[1] : (codes == [0] ? "" : value[0].uppercased())
            key.label = String(label.prefix(12)) // long labels are not stored
            key.data = codes.map(Int.init)
            keys.append(key)
        }
        // The keypad erases a layer when it is written, so always send all keys of the layer.
        let changed = keys
        let full = all.keys.filter { $0.layer == layer }.map { old in
            changed.first { $0.index == old.index } ?? old
        }
        try writeAll(pad, keys: full, names: all.layerNames, info: info)
        printGrid(try snapshot(pad), layer: layer)
    case "restore":
        guard (2...3).contains(arguments.count) else { throw ToolError("Use: restore <file> [layer]") }
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let only = arguments.count == 3 ? Int(arguments[2]) : nil
        let keys = backup.keys.filter { only == nil || $0.layer == only }
        try writeAll(pad, keys: keys, names: backup.layerNames, info: info)
    case "layers":
        for (layer, name) in try snapshot(pad).layerNames.enumerated() {
            print("\(layer)  \(name)\(layer == Int(info.activeLayer) ? "  ← active" : "")")
        }
        print("(\(info.layerCount) of at most \(info.maxLayers) layers in use)")
    case "rename":
        // The keypad only takes a layer name together with all keys of that layer, so the whole layer is rewritten.
        guard arguments.count == 3, let layer = Int(arguments[1]), (0..<Int(info.layerCount)).contains(layer) else {
            throw ToolError("Use: rename N \"Name\"")
        }
        let all = try snapshot(pad)
        let path = "vaydeer-backup-\(Int(Date().timeIntervalSince1970)).json"
        try saveBackup(all, to: path)
        print("Backup: \(path)")
        // Firmware 1.1.1 keeps only the first 8 characters of a layer name (seen: a 14-character name came back as its first 8).
        guard arguments[2].count <= 8 else {
            throw ToolError("Layer names can have at most 8 characters (\"\(arguments[2])\" has \(arguments[2].count)). Nothing was written.")
        }
        var names = all.layerNames
        names[layer] = arguments[2]
        try writeAll(pad, keys: all.keys.filter { $0.layer == layer }, names: names, info: info)
        printGrid(try snapshot(pad), layer: layer)
    case "layer":
        guard arguments.count == 2, let value = Int(arguments[1]), (0..<Int(info.layerCount)).contains(value) else {
            throw ToolError("Use: layer N (0 to \(Int(info.layerCount) - 1))")
        }
        _ = try pad.request(cmdSetLayer, [UInt8(value)])
        let after = try readInfo(pad)
        guard Int(after.activeLayer) == value else {
            throw ToolError("Keypad still reports layer \(after.activeLayer) as active.")
        }
        print("Active layer is now \(value).")
    default:
        throw ToolError("Unknown command: \(command)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
