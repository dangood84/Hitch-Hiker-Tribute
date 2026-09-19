unit uhostcocoa;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}

{ macOS titled, resizable window. Regular activation policy so there is a
  Dock icon. Same TGuideController as Windows/Linux; this unit presents
  pixels, runs the 50 ms CRT timer, plays original WAV stings, and
  forwards keys / clicks / fullscreen. }

interface

procedure HostRun;

implementation

uses
  SysUtils, Math, CocoaAll, uguidemodel, uguideapp, uguideaudio;

const
  WinPointsW = 760;
  WinPointsH = 540;
  MinPointsW = 520;
  MinPointsH = 380;
  TickInterval = 0.05; { 20 Hz: scanlines crawl, typing ticks, search pulses }

type
  TGuideView = objcclass;
  TGuideWindow = objcclass;

  NSBitmapImageRepGuide = objccategory external (NSBitmapImageRep)
    { FPC truncates the real method name past 127 chars; this category keeps
      a short Pascal identifier and the full ObjC selector. }
    function initRGBA(planes: Pointer; aWidth: NSInteger; aHeight: NSInteger;
      aBits: NSInteger; aSamples: NSInteger; aAlpha: ObjCBOOL;
      aPlanar: ObjCBOOL; aSpace: NSString; aBpr: NSInteger;
      aBpp: NSInteger): id; message 'initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:';
  end;

  TAppDelegate = objcclass(NSObject, NSApplicationDelegateProtocol, NSWindowDelegateProtocol)
  public
    controller: TGuideController;
    window: TGuideWindow;
    view: TGuideView;
    frameImage: NSImage;
    animTimer: NSTimer;
    scale: Double;
    sfxSlot: Integer;
    ready: ObjCBOOL;
    procedure applicationDidFinishLaunching(notification: NSNotification); message 'applicationDidFinishLaunching:';
    function applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication): ObjCBOOL; message 'applicationShouldTerminateAfterLastWindowClosed:';
    procedure quitAction(sender: id); message 'quitAction:';
    procedure aboutAction(sender: id); message 'aboutAction:';
    procedure fullscreenAction(sender: id); message 'fullscreenAction:';
    procedure windowDidResize(notification: NSNotification); message 'windowDidResize:';
    procedure windowDidEnterFullScreen(notification: NSNotification); message 'windowDidEnterFullScreen:';
    procedure windowDidExitFullScreen(notification: NSNotification); message 'windowDidExitFullScreen:';
    procedure tick(timer: NSTimer); message 'tick:';
    procedure drainAudio; message 'drainAudio';
    procedure redraw; message 'redraw';
    procedure syncCanvasSize; message 'syncCanvasSize';
    procedure setup; message 'setup';
  end;

  TGuideWindow = objcclass(NSWindow)
  public
    app: TAppDelegate;
    function canBecomeKeyWindow: ObjCBOOL; override;
  end;

  TGuideView = objcclass(NSView)
  public
    app: TAppDelegate;
    procedure drawRect(dirtyRect: NSRect); override;
    function acceptsFirstResponder: ObjCBOOL; override;
    function acceptsFirstMouse(theEvent: NSEvent): ObjCBOOL; override;
    procedure mouseDown(event: NSEvent); override;
    procedure mouseUp(event: NSEvent); override;
    procedure mouseMoved(event: NSEvent); override;
    procedure mouseDragged(event: NSEvent); override;
    procedure mouseExited(event: NSEvent); override;
    procedure keyDown(event: NSEvent); override;
    procedure updateTrackingAreas; override;
  end;

var
  SharedApp: TAppDelegate;
  SfxWav: array[sfxSearch..sfxType] of TBytes;
  SfxRing: array[0..5] of NSSound;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

function MakeImage(Pixels: PByte; PixelW, PixelH: Integer; PointW, PointH: Double): NSImage;
var
  Rep: NSBitmapImageRep;
  Dest: PByte;
  Bytes: Integer;
begin
  Rep := NSBitmapImageRep(NSBitmapImageRep.alloc.initRGBA(nil, PixelW, PixelH, 8, 4,
    True, False, NSCalibratedRGBColorSpace, PixelW * 4, 32));
  { nil planes: AppKit owns a snapshot. Aliasing Canvas.Ptr would freeze the CRT. }
  Result := NSImage.alloc.initWithSize(NSMakeSize(PointW, PointH));
  if Rep <> nil then
  begin
    Dest := PByte(Rep.bitmapData);
    Bytes := PixelW * PixelH * 4;
    if (Dest <> nil) and (Pixels <> nil) and (Bytes > 0) then
      Move(Pixels^, Dest^, Bytes);
    Result.addRepresentation(Rep);
    Rep.release;
  end;
  Result.setCacheMode(NSImageCacheNever);
end;

function ViewToCanvas(View: NSView; Event: NSEvent; BufW, BufH: Integer; out CX, CY: Double): Boolean;
var
  Pt: NSPoint;
  B: NSRect;
begin
  Result := False;
  CX := 0;
  CY := 0;
  if (View = nil) or (Event = nil) then
    Exit;
  Pt := View.convertPoint_fromView(Event.locationInWindow, nil);
  B := View.bounds;
  if (B.size.width < 0.5) or (B.size.height < 0.5) then
    Exit;
  { Unflipped view: Cocoa y-up vs the y-down pixel buffer. }
  CX := Pt.x / B.size.width * BufW;
  CY := (B.size.height - Pt.y) / B.size.height * BufH;
  Result := True;
end;

function EventToKey(Event: NSEvent): TGuideKey;
var
  Code: Word;
  Chars: NSString;
  Ch: unichar;
begin
  Result := gkNone;
  if Event = nil then
    Exit;
  if Event.modifierFlags and NSCommandKeyMask <> 0 then
    Exit; { ⌘Q must stay the menu item }
  Code := Event.keyCode;
  case Code of
    123, 126: { Left / Up }
      Exit(gkPrev);
    124, 125, 49, 36, 76: { Right / Down / Space / Return / keypad Enter }
      Exit(gkNext);
  end;
  Chars := Event.charactersIgnoringModifiers;
  if (Chars = nil) or (Chars.length < 1) then
    Exit;
  Ch := Chars.characterAtIndex(0);
  if (Ch >= Ord('1')) and (Ch <= Ord('9')) then
    Result := GuideKeyFromJump(Ch - Ord('0'));
end;

procedure TAppDelegate.redraw;
var
  B: NSRect;
begin
  if (controller = nil) or (view = nil) then
    Exit;
  controller.Render;
  B := view.bounds;
  if frameImage <> nil then
    frameImage.release;
  frameImage := MakeImage(controller.Canvas.Ptr, controller.Canvas.Width,
    controller.Canvas.Height, B.size.width, B.size.height);
  controller.ConsumePresent;
  view.setNeedsDisplay_(True);
end;

procedure TAppDelegate.syncCanvasSize;
var
  B: NSRect;
  PW, PH: Integer;
begin
  if (view = nil) or (controller = nil) then
    Exit;
  B := view.bounds;
  PW := Max(1, Round(B.size.width * scale));
  PH := Max(1, Round(B.size.height * scale));
  controller.Resize(PW, PH);
end;

procedure PlaySfx(Kind: TSfxKind);
var
  Data: NSData;
  Bytes: TBytes;
begin
  if (Kind < sfxSearch) or (Kind > sfxType) then
    Exit;
  Bytes := SfxWav[Kind];
  if Length(Bytes) < 44 then
    Exit;
  Data := NSData.dataWithBytes_length(@Bytes[0], Length(Bytes));
  if SfxRing[SharedApp.sfxSlot] <> nil then
  begin
    SfxRing[SharedApp.sfxSlot].stop;
    SfxRing[SharedApp.sfxSlot].release;
    SfxRing[SharedApp.sfxSlot] := nil;
  end;
  SfxRing[SharedApp.sfxSlot] := NSSound.alloc.initWithData(Data);
  if SfxRing[SharedApp.sfxSlot] <> nil then
    SfxRing[SharedApp.sfxSlot].play;
  SharedApp.sfxSlot := (SharedApp.sfxSlot + 1) mod Length(SfxRing);
end;

procedure TAppDelegate.drainAudio;
var
  Kind: TSfxKind;
begin
  if controller = nil then
    Exit;
  while controller.Model.DrainSfx(Kind) do
    PlaySfx(Kind);
end;

procedure TAppDelegate.tick(timer: NSTimer);
var
  Pool: NSAutoreleasePool;
begin
  Pool := NSAutoreleasePool.alloc.init;
  if controller <> nil then
  begin
    controller.Tick;
    drainAudio;
    if controller.NeedsPresent then
      redraw;
  end;
  Pool.release;
end;

procedure SetupMenu(Del: TAppDelegate);
var
  MainMenu, AppMenu, ViewMenu: NSMenu;
  AppItem, ViewItem, Item: NSMenuItem;
begin
  MainMenu := NSMenu.alloc.init;

  AppItem := NSMenuItem.alloc.init;
  AppMenu := NSMenu.alloc.initWithTitle(NSStr('Guide'));
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('About Hitch-Hiker''s Guide'), objcselector('aboutAction:'), NSStr(''));
  Item.setTarget(Del);
  AppMenu.addItem(Item);
  Item.release;
  AppMenu.addItem(NSMenuItem.separatorItem);
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Quit Hitch-Hiker''s Guide'), objcselector('quitAction:'), NSStr('q'));
  Item.setTarget(Del);
  AppMenu.addItem(Item);
  Item.release;
  AppItem.setSubmenu(AppMenu);
  MainMenu.addItem(AppItem);

  ViewItem := NSMenuItem.alloc.init;
  ViewMenu := NSMenu.alloc.initWithTitle(NSStr('View'));
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Full Screen'), objcselector('fullscreenAction:'), NSStr('f'));
  { Ctrl+Cmd+F — the same chord macOS uses for native fullscreen. }
  Item.setKeyEquivalentModifierMask(NSCommandKeyMask or NSControlKeyMask);
  Item.setTarget(Del);
  ViewMenu.addItem(Item);
  Item.release;
  ViewItem.setSubmenu(ViewMenu);
  MainMenu.addItem(ViewItem);

  NSApplication.sharedApplication.setMainMenu(MainMenu);
  ViewMenu.release;
  ViewItem.release;
  AppMenu.release;
  AppItem.release;
  MainMenu.release;
end;

procedure TAppDelegate.setup;
var
  PixelScale: Double;
  Style: NSUInteger;
  Rect, Vis: NSRect;
  Kind: TSfxKind;
  I: Integer;
begin
  if ready then
    Exit;
  ready := True;

  PixelScale := 2;
  if NSScreen.mainScreen <> nil then
    PixelScale := NSScreen.mainScreen.backingScaleFactor;
  if PixelScale < 1 then
    PixelScale := 1;
  scale := PixelScale;
  sfxSlot := 0;
  for Kind := sfxSearch to sfxType do
    SfxWav[Kind] := BuildSfxWav(Kind);
  for I := 0 to High(SfxRing) do
    SfxRing[I] := nil;

  controller := TGuideController.Create(
    Round(WinPointsW * scale), Round(WinPointsH * scale));

  SetupMenu(self);

  Style := NSTitledWindowMask or NSClosableWindowMask or
    NSMiniaturizableWindowMask or NSResizableWindowMask;
  Rect := NSMakeRect(80, 60, WinPointsW, WinPointsH);
  if NSScreen.mainScreen <> nil then
  begin
    Vis := NSScreen.mainScreen.visibleFrame;
    Rect := NSMakeRect(
      Vis.origin.x + Trunc((Vis.size.width - WinPointsW) / 2),
      Vis.origin.y + Trunc((Vis.size.height - WinPointsH) / 2),
      WinPointsW, WinPointsH);
  end;
  window := TGuideWindow.alloc.initWithContentRect_styleMask_backing_defer(
    Rect, Style, NSBackingStoreBuffered, False);
  window.app := self;
  window.setTitle(NSStr('The Hitch-Hiker''s Guide to the Galaxy'));
  window.setReleasedWhenClosed(False);
  window.setOpaque(True);
  window.setBackgroundColor(NSColor.colorWithCalibratedRed_green_blue_alpha(0.02, 0.03, 0.02, 1.0));
  window.setContentMinSize(NSMakeSize(MinPointsW, MinPointsH));
  { Sonoma green-button fullscreen, not just zoom-to-fit. }
  window.setCollectionBehavior(NSWindowCollectionBehaviorFullScreenPrimary);
  window.setDelegate(self);

  view := TGuideView.alloc.initWithFrame(NSMakeRect(0, 0, WinPointsW, WinPointsH));
  view.app := self;
  window.setContentView(view);
  window.makeFirstResponder(view);

  syncCanvasSize;
  redraw;

  animTimer := NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
    TickInterval, self, objcselector('tick:'), nil, True);
  animTimer.retain;
  NSRunLoop.currentRunLoop.addTimer_forMode(animTimer, NSRunLoopCommonModes);

  NSApplication.sharedApplication.activateIgnoringOtherApps(True);
  window.makeKeyAndOrderFront(nil);
end;

procedure TAppDelegate.applicationDidFinishLaunching(notification: NSNotification);
begin
  setup;
end;

function TAppDelegate.applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication): ObjCBOOL;
begin
  Result := True; { close box quits — a desk Guide, not a menu extra }
end;

procedure TAppDelegate.quitAction(sender: id);
var
  I: Integer;
begin
  for I := 0 to High(SfxRing) do
    if SfxRing[I] <> nil then
    begin
      SfxRing[I].stop;
      SfxRing[I].release;
      SfxRing[I] := nil;
    end;
  NSApplication.sharedApplication.terminate(nil);
end;

procedure TAppDelegate.aboutAction(sender: id);
var
  Alert: NSAlert;
begin
  Alert := NSAlert.alloc.init;
  Alert.setMessageText(NSStr(GuideAboutTitle));
  Alert.setInformativeText(NSStr(GuideAboutText));
  Alert.runModal;
  Alert.release;
end;

procedure TAppDelegate.fullscreenAction(sender: id);
begin
  if window <> nil then
    window.toggleFullScreen(nil); { AppKit animates; DidEnter/DidExit update the model }
end;

procedure TAppDelegate.windowDidResize(notification: NSNotification);
begin
  syncCanvasSize;
  redraw;
end;

procedure TAppDelegate.windowDidEnterFullScreen(notification: NSNotification);
begin
  { State change: windowed → macOS fullscreen Space. }
  if controller <> nil then
    controller.SetFullScreen(True);
  syncCanvasSize;
  redraw;
end;

procedure TAppDelegate.windowDidExitFullScreen(notification: NSNotification);
begin
  { State change: fullscreen Space → titled window. }
  if controller <> nil then
    controller.SetFullScreen(False);
  syncCanvasSize;
  redraw;
end;

procedure TGuideView.drawRect(dirtyRect: NSRect);
begin
  NSColor.colorWithCalibratedRed_green_blue_alpha(0.02, 0.03, 0.02, 1.0).set_;
  NSRectFill(self.bounds);
  if (app = nil) or (app.frameImage = nil) then
    Exit;
  app.frameImage.drawInRect_fromRect_operation_fraction(self.bounds, NSZeroRect,
    NSCompositeSourceOver, 1.0); { unflipped view + y-down buffer; isFlipped would invert it }
end;

function TGuideView.acceptsFirstResponder: ObjCBOOL;
begin
  Result := True; { otherwise keyDown never fires }
end;

function TGuideView.acceptsFirstMouse(theEvent: NSEvent): ObjCBOOL;
begin
  Result := True;
end;

procedure TGuideView.updateTrackingAreas;
var
  Track: NSTrackingArea;
  Areas: NSArray;
  Options: NSTrackingAreaOptions;
  I: Integer;
begin
  Areas := self.trackingAreas;
  if Areas <> nil then
    for I := Integer(Areas.count) - 1 downto 0 do
      self.removeTrackingArea(Areas.objectAtIndex(I));
  inherited updateTrackingAreas;
  Options := NSTrackingMouseMoved or NSTrackingMouseEnteredAndExited or
    NSTrackingActiveInKeyWindow or NSTrackingInVisibleRect or
    NSTrackingEnabledDuringMouseDrag;
  Track := NSTrackingArea.alloc.initWithRect_options_owner_userInfo(
    self.bounds, Options, self, nil);
  self.addTrackingArea(Track);
  Track.release;
end;

procedure TGuideView.mouseDown(event: NSEvent);
var
  CX, CY: Double;
begin
  if app = nil then
    Exit;
  self.window.makeFirstResponder(self);
  if (event <> nil) and (event.clickCount >= 2) then
  begin
    app.fullscreenAction(nil); { double-click the CRT to toggle fullscreen }
    Exit;
  end;
  if ViewToCanvas(self, event, app.controller.Canvas.Width, app.controller.Canvas.Height, CX, CY) then
    app.controller.MouseDown(CX, CY);
  app.redraw;
end;

procedure TGuideView.mouseUp(event: NSEvent);
var
  CX, CY: Double;
begin
  if app = nil then
    Exit;
  if ViewToCanvas(self, event, app.controller.Canvas.Width, app.controller.Canvas.Height, CX, CY) then
    app.controller.MouseUp(CX, CY)
  else
    app.controller.MouseUp(-1, -1);
  app.drainAudio;
  app.redraw;
end;

procedure TGuideView.mouseMoved(event: NSEvent);
var
  CX, CY: Double;
begin
  if app = nil then
    Exit;
  if ViewToCanvas(self, event, app.controller.Canvas.Width, app.controller.Canvas.Height, CX, CY) then
    app.controller.MouseMove(CX, CY);
  { The timer already redraws; still paint on hover so the row lights at once. }
  app.redraw;
end;

procedure TGuideView.mouseDragged(event: NSEvent);
var
  CX, CY: Double;
begin
  if app = nil then
    Exit;
  if ViewToCanvas(self, event, app.controller.Canvas.Width, app.controller.Canvas.Height, CX, CY) then
    app.controller.MouseMove(CX, CY);
  app.redraw;
end;

procedure TGuideView.mouseExited(event: NSEvent);
begin
  if app = nil then
    Exit;
  app.controller.MouseLeave;
  app.redraw;
end;

procedure TGuideView.keyDown(event: NSEvent);
var
  Code: Word;
  Mapped: TGuideKey;
begin
  if (app = nil) or (event = nil) then
  begin
    inherited keyDown(event);
    Exit;
  end;
  Code := event.keyCode;
  case Code of
    53: { Escape }
      if app.controller.FullScreen then
        app.fullscreenAction(nil)
      else
        app.quitAction(nil);
    103: { F11 }
      app.fullscreenAction(nil);
    else
      begin
        Mapped := EventToKey(event);
        if Mapped = gkNone then
        begin
          inherited keyDown(event);
          Exit;
        end;
        app.controller.KeyPress(Mapped);
        app.drainAudio;
        app.redraw;
      end;
  end;
end;

function TGuideWindow.canBecomeKeyWindow: ObjCBOOL;
begin
  Result := True;
end;

procedure HostRun;
var
  Pool: NSAutoreleasePool;
  App: NSApplication;
begin
  Pool := NSAutoreleasePool.alloc.init;
  App := NSApplication.sharedApplication;
  App.setActivationPolicy(NSApplicationActivationPolicyRegular); { Dock icon }
  SharedApp := TAppDelegate.alloc.init;
  App.setDelegate(SharedApp);
  SharedApp.setup; { do not wait for didFinishLaunching; first paint before App.run }
  App.run;
  Pool.release;
end;

end.
