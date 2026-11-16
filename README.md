# Vaydeer JP-1011 for macOS

A small Swift tool that reads and changes the keys of the Vaydeer JP-1011 keypad
(9 keys, shown by the system as `9-key Smart Keypad`) without the official app.
The layout is stored in the keypad itself, so you do not need this tool after writing.

This is an unofficial project. It was tested on one keypad: firmware 1.1.1,
bootloader 0.2.1, on a Mac with Apple silicon. Use it at your own risk.

This fork adds an interactive helper (`keypad`), more key names, labels,
layer switching and renaming, a key test window, and a fix that makes layer
names survive unplugging. See [Changes in this fork](#changes-in-this-fork).

## Quick start

You only need Xcode or the Command Line Tools. There are no other dependencies.

```bash
git clone https://github.com/mfabich-a11y/vaydeer-jp1011-macos.git
```

```bash
cd vaydeer-jp1011-macos
```

```bash
./keypad
```

`keypad` builds the tools on first use (and again whenever the source changes)
and opens a menu. Backups go to `my-backups/` next to the script.

To call it from anywhere:

```bash
echo "alias keypad=$PWD/keypad" >> ~/.zshrc
```

## The helper

`keypad` without arguments opens a menu:

| Item | What it does |
|---|---|
| 1 | Show all layers as a 3×3 grid |
| 2 | Change one key (asks for layer, key, shortcut, label, then confirms) |
| 3 | Switch the active layer (number, or Enter for the next one) |
| 4 | Rename a layer (8 characters at most) |
| 5 | Key test window: shows what macOS really receives |
| 6 | Make a backup |
| 7 | Restore from a backup |
| 8 | List key names |

With arguments it runs a command directly:

| Command | What it does |
|---|---|
| `keypad show [layer]` | Shows the keys as a grid |
| `keypad layers` | Lists the layers, marks the active one |
| `keypad next` | Switches to the next layer (wraps to 0) |
| `keypad layer N` | Makes layer N active |
| `keypad set layer=1 0=cmd+c:Copy 1=cmd+v` | Changes keys; the text after `:` is the label |
| `keypad rename N "Name"` | Renames a layer |
| `keypad test` | Opens the key test window |
| `keypad backup file.json` | Saves all keys |
| `keypad restore file.json [layer]` | Writes keys back from a backup |
| `keypad info` | Firmware, active layer, layer count |
| `keypad keys` | Key names |

The same commands work with the bare tool: `./vaydeer show`, `./vaydeer set …`.

Keys are numbered row by row, from top to bottom:

```text
0 1 2
3 4 5
6 7 8
```

Layers count from zero: `layer=0` is the first layer, `layer=1` is the second.

### Key names

Join parts with `+`, for example `cmd+shift+4` or `ctrl+opt+left`.

| Names | Meaning |
|---|---|
| `cmd` `ctrl` `opt` `shift` | Modifiers |
| `a`–`z`, `0`–`9` | Letters and digits |
| `f1`–`f12` | Function keys |
| `left` `right` `up` `down` | Arrow keys |
| `space` `enter` `tab` `esc` `backspace` `delete` | Special keys |
| `home` `end` `pgup` `pgdn` | Navigation |
| `plus` `minus` | The `+` and `-` keys of a **German** keyboard (US `]` and `/`) |
| `equal` `hyphen` | The `=` and `-` keys of a **US** keyboard |
| `volup` `voldown` `mute` `play` `next` `prev` | Media keys |
| `num0`–`num9` | Number pad |
| `none` | Empty key |
| `0xNN` | Raw Windows virtual-key code |

The keypad sends key positions, and macOS reads them with the active keyboard
layout. Use `keypad test` after writing to see what arrives.

## Example layout

A Mac layout with copy, paste, screenshot, zoom and window tiling:

```bash
keypad set layer=1 0=cmd+c:Copy 1=cmd+v:Paste 2=cmd+ctrl+shift+4:Screenshot 3=cmd+minus:"Zoom -" 4=cmd+0:"Zoom 100%" 5=cmd+plus:"Zoom +" 6=ctrl+opt+shift+f1:"Window left" 7=ctrl+opt+shift+f2:Fill 8=ctrl+opt+shift+f3:"Window right"
```

```bash
keypad layer 1
```

The built-in macOS window shortcuts use the Globe key, which the keypad cannot
send. Assign the neutral shortcuts of keys 6–8 in System Settings → Keyboard →
Keyboard Shortcuts → Windows instead.

## Good to know

- **Write order.** The tool writes like the vendor app: `0xFD` (init), then per
  layer the name (`0x65`), all keys (`0x61`) and commit (`0x66`), each with the
  highest layer index *in use*. The original tool sent `maxLayers - 1` and no init;
  keys survived that, but a new layer name was lost after unplugging.
- **A layer can only be written as a whole.** If you write one key, the other
  keys on that layer are erased. The tool always sends all 9 keys.
- **Only single keys and combinations can be written** (types 0 and 1). If a
  layer holds a text, program, mouse or macro key, the tool stops before writing
  anything to that layer.
- **Layer names: 8 characters.** Longer names are cut by the firmware; the tool refuses them.
- **Labels: 12 characters.** An 18-character label came back empty.
- **F13–F24 do not work** on firmware 1.1.1. The keypad accepts the code but stores `0x00`.
- **The keypad does not switch layers by itself.** Use `keypad layer N` or `keypad next`.
  The active layer, keys and names survive unplugging (tested).
- **Firmware.** Writing is allowed only for 1.0.2 and 1.1.1 with bootloader 0.2.1.
- **The firmware command `0xFC` is blocked.** The tool only sends commands from
  the short list at the top of `vaydeer.swift`.
- **Backups can hold private data** (program paths, URLs, text). `my-backups/`
  and `vaydeer-backup-*.json` are in `.gitignore`.
- Device: VID `0x0483`, PID `0x5752`, configuration interface with usage page
  `0xFF00` and usage `1`.

## Restore the original keys

`backups/original.json` holds the settings of the original author's keypad from
before any changes: Num1–Num9 on layer 1, and arrows, Home, End, Page Up,
Page Down and Space on layer 2. Make your own backup first (`keypad backup`),
because the factory layout of your keypad may differ.

## Changes in this fork

- `keypad`: interactive helper with menu, auto-build and backups in `my-backups/`.
- `keyview.swift`: key test window that shows any key combination macOS receives.
- `vaydeer.swift`:
  - write order of the vendor app (`0xFD` init, highest layer index in use), so names persist;
  - new commands `show`, `layers`, `layer N`, `rename`, `keys`;
  - key names for letters, digits, arrows, special, media and German `+`/`-` keys, raw `0xNN`;
  - labels with `index=keys:label` and empty keys with `none`;
  - all keys of a layer are checked before the first write, so a layer is never half written;
  - layer names longer than 8 characters are refused.

## Credits

The protocol description comes from the
[Vaydeer Studio](https://github.com/callum-baillie/vaydeer-studio-linux)
project (MIT license). Its code is not used here.
The write order follows the notes of [ninekeypad](https://github.com/pienzo/ninekeypad).
Original tool by [SergiySev](https://github.com/SergiySev/vaydeer-jp1011-macos).

## License

MIT
