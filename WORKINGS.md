# How the Hitch-Hiker's Guide works

This note is for someone who wants to **build and run** the tribute on each OS, and to see how a small Free Pascal desktop app is structured: where it starts, who owns the encyclopedia, who paints pixels, and how a keypress becomes a page turn.

You do not need to be a Cocoa, Win32, or GTK expert. The same ideas show up in Goody's Calculator, the RISC OS Clock, Eyes, the Grouch, and Moiré: an entry point, a model, a software canvas, and a native host that only presents bytes.

There is **no Lazarus form**, **no SDL2**, and **no HTML**. Each index row is a rectangle in a layout. A click that lands inside a rectangle becomes an entry index. The model mutates a phase (`idle` / `searching` / `typing`) and a visible-character count. The renderer turns that into an RGBA buffer. The host only uploads the buffer.

This is a **timer-driven CRT**, not a static form like the calculator. Scanlines crawl at ~20 Hz even while you read. A page turn is a short state machine on top of that pulse.

## Build / run workflows

Work from the project root. `fpc` must be on `PATH`. Output always lands in `build/` (gitignored).

| What you want | Command | What you get |
|---------------|---------|--------------|
| macOS app | `make` then `make run` | `build/HitchHikersGuide.app`, opened |
| Linux / Raspberry Pi OS | `sudo apt install fpc libgtk2.0-dev` then `make linux` then `./build/hitchhikersguide` | GTK 2 window |
| Windows 10+ | from a native FPC prompt: `make windows` then `build\HitchHikersGuide.exe` | taskbar window |
| Headless encyclopedia checks | `make test` | prints `ok` lines; non-zero if a phase is wrong |
| Frozen canvas frames | `make snap` | `build/snap-earth.ppm`, `snap-search.ppm`, `snap-42.ppm`, `snap-wide.ppm` |
| Start over | `make clean` | deletes `build/` |

macOS (Homebrew, Sonoma+):

```bash
brew install fpc
make
make run
```

Debian / Raspberry Pi OS:

```bash
sudo apt install fpc libgtk2.0-dev
make linux
./build/hitchhikersguide
```

Windows: install FPC, open its command prompt so `fpc` is on `PATH`, then `make windows`. The `Windows` unit ships with FPC; no extra SDK is required for this app.

Only **one** host unit is compiled. `{$IFDEF DARWIN}` / `WINDOWS` / else picks `uhostcocoa`, `uhostwin`, or `uhostgtk`. Cross-compiling the GUI hosts is not a supported workflow — build on the OS you want to run on.

## Fullscreen workflow (all three hosts)

| Action | macOS | Windows | Linux |
|--------|-------|---------|-------|
| Menu | **View → Full Screen** | **View → Full Screen** | **View → Full Screen** |
| Key | **Ctrl+Cmd+F**, **F11** | **F11** | **F11** |
| Mouse | double-click the tube | double-click the tube | double-click the tube |
| Leave | **Esc**, or the same toggle | **Esc** or **F11** | **Esc** or **F11** |
| What the OS does | native fullscreen Space (`toggleFullScreen`) | popup covering the current monitor | `gtk_window_fullscreen` |

Resize (drag a corner, maximise, or enter fullscreen) always **rebuilds** the pixel buffer to the new client size. Glyph scale is `height / 270`, so a widescreen fullscreen is a bigger terminal, not a stretched one.

## Mental model

```
guide.pas begin
  → HostRun                    # uhostcocoa / uhostwin / uhostgtk
      → create TGuideController (model + pixel buffer)
      → create titled, resizable window
      → timer (~20 Hz)
           → Model.Tick (scanlines, search, typing)
           → drain sfx queue → NSSound / PlaySound / paplay
           → RenderGuide (RGBA pixels)
           → host shows the buffer
      → key / click
           → Model.Press / SelectIndex
           → idle → searching → typing → idle
```

| Layer | Unit | Tester-friendly analogy |
|-------|------|-------------------------|
| Entry / routing | `guide.pas` | Test runner that picks the OS host at compile time |
| State | `uguidemodel` | Fixture: nine entries, current index, phase, visible chars |
| Composer | `uguideapp` | Holds the model and the canvas; `NeedsPresent` is the dirty flag |
| View | `uguiderender` | The thing that actually paints the CRT frame, glyphs, and art |
| Chip sounds | `uguideaudio` | In-memory WAVs: search chirp, two-note found beep |
| Window shell | `uhostcocoa` / `uhostwin` / `uhostgtk` | Window, timer, fullscreen, About / Quit, sfx playback |

The hosts are **event-driven**. Almost everything after `HostRun` runs on the GUI thread. That is why the tube uses `NSTimer` / `SetTimer` / `g_timeout_add` instead of a raw `while true` loop.

## Unit responsibilities

### `guide.pas` — composition root

- Picks the host with `{$IFDEF}`
- Calls `HostRun`
- Does **not** draw glyphs or store the current entry

### `uguidemodel` — state management

Holds *behaviour*, not pixels:

- `FEntries[0..8]` — title, subtitle, body, art kind
- `FIndex` — which page is selected
- `FPhase` — `gpIdle`, `gpSearching`, `gpTyping`
- `FVisibleChars` — how much of the body has typed on
- `FScanlineOffset` — 0..3, crawls every tick
- `FFlicker` — 0..7, a cheap phosphor pulse

`Press` and `SelectIndex` never paint. They call `BeginSearch`, which is the state change from “this page” to “fetching that page”, and queue `sfxSearch`. `Tick` is the only place `searching` becomes `typing` (and queues `sfxFound`) and `typing` becomes `idle`.

`ShowImmediate` skips the fanfare (first paint, snaps, tests) and clears any queued sfx. `Freeze` stops time so a snapshot does not drift.

### `uguideapp` — composer

- Owns one `TGuideModel` and one `TPixelBuffer`
- Hit-tests index rows (classic press/release: mouse-up must land on the same row)
- `Tick` always dirties the canvas — scanlines never sit still
- Remembers hover and fullscreen; does not talk to Cocoa / Win32 / GTK

### `uguiderender` — view

- `MakeGuideLayout` derives every rectangle from the buffer size
- `RenderGuide` clears phosphor-black, draws the double green frame, the yellow **DON'T PANIC**, the index, the body (or the RESEARCHING graphic), then darkens every fourth scanline
- Vector doodles (`DrawEarth`, `DrawFish`, …) sit in the art well when the window is wide enough
- `CopyBGRA` is for the Windows DIB; macOS and GTK read RGBA directly

### `uguideaudio` — original bytes

`BuildSfxWav` writes in-memory WAVs (22050 Hz, 16-bit mono). Search is a stuttering rising/falling square-wave chirp. Found is a short G5–D6 beep. Type is a short F6 pip, one per letter. Original tribute tones, not the BBC TV soundtrack.

Hosts drain `Model.DrainSfx` on the timer and after keys/clicks, then play with `NSSound` / `PlaySound` / `paplay`.

### Hosts — window shell

Each host:

1. Creates the controller at the native pixel size (retina-scaled on macOS)
2. Builds a titled window, About / Quit, View → Full Screen
3. Starts a 50 ms timer
4. Forwards keys (`TGuideKey`) and mouse (canvas coordinates)
5. Uploads `Canvas.Ptr` (`NSImage` / `StretchDIBits` / `GdkPixbuf`)

They do not know what Forty-two means.

## Page-turn state machine

```
          Press next / prev / 1-9 / click
                      │
                      ▼
                 gpSearching
            (RESEARCHING..., ~0.9 s)
            + sfxSearch chirp
                      │
                      ▼
                  gpTyping
           (one glyph / 50 ms, pip per letter)
            + sfxType after the found beep
                      │
                      ▼
                   gpIdle
              (scanlines still crawl)
```

Selecting the page you are already idle on is a no-op. Selecting a page during search or typing **restarts** search on the new index — the tube does not queue.

## Why testers care

- **Compile-time host is the feature flag.** Automating “Mac window” vs “Windows window” is `make` vs `make windows`, not a CLI switch.
- **There is no preferences file.** The nine entries are constants in `uguidemodel`. A test that wants Babel Fish should press `gkJump2` (or `gkNext` from Earth), not edit a config.
- **Exit is process-level** (`terminate` / `PostQuitMessage` / `gtk_main_quit`). Closing the window **quits**, unlike Eyes where close hid the desktop pair and left the extra running. **Esc** in a windowed tube also quits; in fullscreen it only leaves fullscreen.
- **The painted index rows are the real hit targets.** If a click misses a row, `HitTestIndex` returns `-1` and the model does not change. You are not testing a native `NSButton`.
- **`make test`** exercises the engine without a GUI. Use that for wrap-around and phases; use the window for hit-testing, hover, and keyboard mapping.
