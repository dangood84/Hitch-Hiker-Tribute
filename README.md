# The Hitch-Hiker's Guide to the Galaxy (1981)

A tribute to the **1981 BBC television series**: phosphor-green CRT text on a deep black tube, a large friendly **DON'T PANIC**, rolling scanlines, and a pocket encyclopedia you can page through.

Written in **Free Pascal**. Lazarus and Delphi are not required — `fpc` plus the platform GUI libraries already on the machine are enough. There is no SDL2, no JVM, and no widget-toolkit theme to fight. The whole tube is a software RGBA canvas; each host only uploads those bytes into a native window.

Pascal is a better fit here than Java for the same reason it was for the calculator and the RISC OS clock: one compile-time host (`{$IFDEF}`) gives a small native binary on macOS, Windows, and Linux, with mouse and key events coming from Cocoa / Win32 / GTK.

The Guide:

- opens on **Earth** (Mostly harmless)
- **researches** the next page with a pulsing vector frame, then **types** the body onto the phosphor
- keeps a clickable **index** down the left
- crawls **CRT scanlines** and a tiny green flicker even while idle
- plays original **8-bit chirps** on a page turn (search, then a two-note "found")
- stays a **4:3-ish terminal** when you stretch the window or go fullscreen

How the pieces fit together (same style as the calculator, the RISC OS clock, Eyes, the Grouch, and Moiré): `WORKINGS.md` for responsibilities and the page-turn state machine, `EXECUTION_FLOW.md` for a tick-by-tick trace.

Unofficial tribute. Not affiliated with the BBC or the Adams estate.

## Requirements

- **Free Pascal** 3.2+ (`fpc` on your `PATH`)

macOS (Homebrew), Sonoma-compatible:

```bash
brew install fpc
```

Debian / Raspberry Pi OS:

```bash
sudo apt install fpc libgtk2.0-dev
```

Windows 10+: a native Free Pascal install (the `Windows` unit ships with FPC).

## Run

From the project root:

```bash
make
make run
```

That compiles to `build/` and opens `HitchHikersGuide.app` on macOS. The window is a real app with a Dock icon.

Or with Make on other OSes:

```bash
make linux      # Linux / Raspberry Pi OS window
make windows    # HitchHikersGuide.exe
make test       # headless encyclopedia / state-machine checks (no GUI)
make snap       # PPM frames of the canvas (Earth, researching, 42, wide)
make clean      # remove build/
```

Manual compile on macOS (Make still has to wrap the binary in the `.app` bundle):

```bash
fpc -Mobjfpc -Scgi -O2 -Fusrc -FUbuild -FEbuild -obuild/HitchHikersGuide src/guide.pas
make app
open build/HitchHikersGuide.app
```

## Using it

1. The tube boots on **Earth**. Scanlines keep crawling.
2. **Right** / **Down** / **Space** / **Return** fetches the next entry. **Left** / **Up** goes back. The pages wrap.
3. Keys **1**–**9** jump straight to an index row. Click a row to do the same.
4. While it researches, concentric frames pulse, `RESEARCHING...` ticks, and a computer chirp plays. Then a two-note beep, then **one pip per letter** as the body types on.
5. **F11** (or **View → Full Screen**, or **double-click** the tube) goes fullscreen. **Esc** leaves it. On macOS the green traffic-light button and **Ctrl+Cmd+F** do the same native fullscreen. **Esc** in a windowed tube **quits**.
6. **Guide → About** describes the tribute. Closing the window quits.

## Keyboard

| Key | Action |
|-----|--------|
| `→` `↓` `Space` `Return` | Next entry (wraps) |
| `←` `↑` | Previous entry (wraps) |
| `1`–`9` | Jump to that index row |
| `F11` | Toggle fullscreen |
| `Esc` | Leave fullscreen, or quit if windowed |

## Where it appears

| OS | Presence |
|----|----------|
| **macOS** | Titled, resizable window, Dock icon, native fullscreen Space. |
| **Windows** | Titled, resizable window on the taskbar, F11 monitor-filling popup. |
| **Linux** | GTK 2 window (Raspberry Pi OS friendly), F11 `gtk_window_fullscreen`. |

Closing the window **quits** the process. This is a desk Guide, not a menu extra.

## Project layout

```
src/
  guide.pas          # program; picks the host with {$IFDEF}
  uguidemodel.pas    # entries, page-turn phases, scanline offset, sfx queue
  uguiderender.pas   # software RGBA canvas (CRT frame, glyphs, art)
  uguideapp.pas      # TGuideController: hit-test, tick, present flag
  uguideaudio.pas    # original WAV search chirp + found beep
  ubitmapfont.pas    # 8×8 glyphs (no native text APIs)
  uhostcocoa.pas     # macOS NSWindow
  uhostwin.pas       # Windows HWND
  uhostgtk.pas       # Linux GtkWindow
  guidetest.pas      # headless encyclopedia / state checks
  guidesnap.pas      # paints PPM frames without a window
bundle/
  Info.plist         # retina-capable app bundle
Makefile
```
