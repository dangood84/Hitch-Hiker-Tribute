# Execution flow: from `begin` to a drawn page

A step-by-step trace of what happens from `program HitchHikersGuide` through host initialisation, down to how a press of **Right** turns Earth into Babel Fish.

Default launch (`make run`) opens the **macOS window**. `make windows` / `make linux` use the same model and renderer; only the present step changes. This trace is **macOS** (`uhostcocoa`) unless a step says otherwise.

One thread does everything after startup:

- **main (Pascal, then Cocoa run loop)** — `HostRun`, `setup`, timer, mouse/key handlers, AppKit drawing

There is no Swing EDT. `NSView.keyDown` and `NSImage.drawInRect` run on the same thread that called `NSApplication.run`.

---

## Phase A — process entry

**1.** The OS loads `HitchHikersGuide.app/Contents/MacOS/HitchHikersGuide` (or `./build/HitchHikersGuide`). FPC unit initialisation runs (`TGuideModel` is not constructed yet).

**2.** `program HitchHikersGuide` executes `HostRun`.

```pascal
{ src/guide.pas }
begin
  HostRun;
end.
```

**3.** `HostRun` (Cocoa):

```pascal
procedure HostRun;
var
  Pool: NSAutoreleasePool;
  App: NSApplication;
begin
  Pool := NSAutoreleasePool.alloc.init;
  App := NSApplication.sharedApplication;
  App.setActivationPolicy(NSApplicationActivationPolicyRegular);
  SharedApp := TAppDelegate.alloc.init;
  App.setDelegate(SharedApp);
  SharedApp.setup;
  App.run;
  Pool.release;
end.
```

Regular policy (and **no** `LSUIElement` in `bundle/Info.plist`) means: **Dock icon**, Cmd-Tab, a real app. `App.run` does not return until Quit.

Windows: `HostRun` registers a window class, `CreateWindowEx`, menu, then `GetMessage`.
Linux: `gtk_init`, `gtk_window_new`, drawing area, `gtk_main`.

---

## Phase B — window initialisation (`setup`)

**4.** `TAppDelegate.setup` is idempotent (`if ready then Exit`). `applicationDidFinishLaunching` calls it again after `App.run` has started; the second call is a no-op.

**5.** Pixel scale: `NSScreen.mainScreen.backingScaleFactor` (typically `2`). Controller buffer is in **pixels**, window size in **points** (760×540).

**6.** `controller := TGuideController.Create(pixelW, pixelH)`:

- `TGuideModel.Create` — Earth selected, `gpIdle`, body fully visible, scanline 0
- `Canvas` `TPixelBuffer` allocated (RGBA)
- `HoverIndex` / `PressedIndex` = `-1`
- `NeedsPresent` = True so the first frame is not blank

**7.** Application menu targets the delegate: `aboutAction:`, `quitAction:` with **⌘Q**. View menu: Full Screen with **Ctrl+Cmd+F**.

**8.** Window: titled, closable, miniaturizable, **resizable**, centred on `visibleFrame`. Content view is `TGuideView` (unflipped). `applicationShouldTerminateAfterLastWindowClosed` is true, so the close box **quits**.

**9.** First `redraw` **before** `App.run` so the tube is not blank for a frame.

```pascal
controller.Render;
frameImage := MakeImage(...);   { copy RGBA into a new NSImage }
window.makeKeyAndOrderFront(nil);
```

**10.** `NSTimer` at 50 ms, added to `NSRunLoopCommonModes` so it keeps firing during a resize.

Windows: `SetTimer(..., 50, ...)`.
Linux: `g_timeout_add(50, ...)`.

**11.** `App.run` starts. Cocoa may also send `applicationDidFinishLaunching` → `setup` (already `ready`).

---

## Phase C — one CRT tick (idle)

**12.** The timer fires `tick:`.

```pascal
controller.Tick;          { Model.Tick: scanline 0→1→2→3→0, flicker 0..7 }
if controller.NeedsPresent then
  redraw;
```

On idle, `Tick` does **not** change the entry. It always sets `NeedsPresent`, because the grille has moved.

**13.** `redraw` calls `RenderGuide`:

1. Clear phosphor black `(4,8,4)`
2. Double green frame
3. Dim series title, glowing yellow `*** DON'T PANIC ***`
4. Index column; Earth marked `>1 EARTH`
5. Content: `> EARTH`, subtitle, wrapped body, planet doodle
6. Footer `Entry 1 of 9 | ...`
7. Darken every fourth scanline, offset by `ScanlineOffset`

**14.** `MakeImage` copies the RGBA bytes into a fresh `NSBitmapImageRep` (AppKit owns that snapshot; aliasing `Canvas.Ptr` would freeze the tube). `setNeedsDisplay_` makes AppKit call `drawRect`, which draws the `NSImage` into the unflipped view.

Windows: `CopyBGRA` then `StretchDIBits`.
Linux: copy into a `GdkPixbuf`, `gdk_pixbuf_render_to_drawable`.

---

## Phase D — Right Arrow: Earth → Babel Fish

**15.** `TGuideView.keyDown` sees keyCode 124 (Right). `EventToKey` returns `gkNext`. (Escape and F11 are handled before that mapping.)

**16.** `controller.KeyPress(gkNext)` → `Model.Press(gkNext)`:

```
Index 0 → 1
Phase  idle → searching     { State change: fetch Babel Fish }
VisibleChars := 0
PhaseTick := 0
```

**17.** The next paints show the index caret on `>2 BABEL FISH` and, in the content well, concentric frames plus `RESEARCHING...`. The body is empty (`VisibleBody = ''`). `BeginSearch` also queued `sfxSearch`; `drainAudio` plays the chirp (`NSSound` on macOS).

**18.** For ~18 ticks (about 0.9 s) `PhaseTick` climbs. On the tick where it reaches `SearchTicks`:

```
Phase  searching → typing   { State change: the page was found }
VisibleChars := 0
PushSfx(sfxFound)            { two-note beep; letters start on the next tick }
```

**19.** Each following tick adds one character and queues `sfxType` (the readout pip). `WrapBody` reflows the visible prefix. A block cursor blinks on the flicker bit.

**20.** When `VisibleChars >= Length(Body)`:

```
Phase  typing → idle        { State change: the page sits on the phosphor }
```

Babel Fish is now fully typed. Scanlines keep crawling.

Windows: `WM_KEYDOWN` with `VK_RIGHT` is the same `gkNext`.
Linux: `GDK_Right` likewise.

Clicking index row 2 is the same model call (`SelectIndex(1)`), after the classic press/release rule: mouse-up must land on the same row mouse-down started on.

---

## Phase E — wrap, jump, fullscreen, quit

**21.** From Tea (index 8), `gkNext` wraps to Earth (0). From Earth, `gkPrev` wraps to Tea. `BeginSearch` still runs — wrap is a page turn, not a no-op.

**22.** Key `5` becomes `gkJump5` (`GuideKeyFromJump(5)`). Index becomes 4, **THE ANSWER**, same search → type → idle fanfare. Selecting the page you are already idle on is ignored.

**23.** Fullscreen: `fullscreenAction` calls `window.toggleFullScreen`. `windowDidEnterFullScreen` sets `controller.SetFullScreen(True)` and `syncCanvasSize` rebuilds the buffer to the Space. **Esc** toggles back. In a windowed tube, **Esc** is `quitAction` (process exit).

**24.** Quit: close box, ⌘Q, or **Guide → Quit**. `applicationShouldTerminateAfterLastWindowClosed` is true, so the last window ending the process is the point.

---

## Headless paths

`make test` compiles `guidetest.pas` against `uguidemodel` and `uguideaudio`. No host, no canvas. It checks wrap, jump, the three phases, the sfx queue, freeze, and that Earth still says harmless.

`make snap` constructs a `TGuideController` at 1520×1080, writes four PPM files, and exits. Useful when you want to see the CRT without opening a window.
