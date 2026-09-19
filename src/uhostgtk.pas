unit uhostgtk;

{$mode objfpc}{$H+}

{ Linux GTK 2 window. Same TGuideController as macOS; this unit presents
  a GdkPixbuf on a drawing area, a 50 ms timeout, original WAV stings via
  paplay/aplay, keys / clicks, and F11 fullscreen. GTK 2 is the Raspberry
  Pi OS-friendly toolkit the other Pascal apps use. }

interface

procedure HostRun;

implementation

{$IF DEFINED(UNIX) AND NOT DEFINED(DARWIN)}

uses
  SysUtils, ctypes, gtk2, gdk2, gdk2pixbuf, glib2, Unix, uguidemodel, uguideapp, uguideaudio;

const
  WinW = 760;
  WinH = 540;
  MinW = 520;
  MinH = 380;
  TickMs = 50;

  GDK_Escape = $FF1B;
  GDK_F11 = $FFC8;
  GDK_Left = $FF51;
  GDK_Right = $FF53;
  GDK_Up = $FF52;
  GDK_Down = $FF54;
  GDK_space = $20;
  GDK_Return = $FF0D;
  GDK_KP_Enter = $FF8D;
  GDK_1 = $31;
  GDK_KP_1 = $FFB1;

var
  Controller: TGuideController;
  MainWin: PGtkWidget;
  DrawArea: PGtkWidget;
  MenuBar: PGtkWidget;
  Pix: PGdkPixbuf;
  FullScreen: Boolean;
  AreaW, AreaH: Integer;
  SfxWav: array[sfxSearch..sfxType] of TBytes;
  SfxPath: array[sfxSearch..sfxType] of string;

procedure WriteSfxFiles;
var
  Kind: TSfxKind;
  Path: string;
  F: File;
begin
  for Kind := sfxSearch to sfxType do
  begin
    SfxWav[Kind] := BuildSfxWav(Kind);
    Path := IncludeTrailingPathDelimiter(GetTempDir) + 'hhg-' + SfxName(Kind) + '.wav';
    SfxPath[Kind] := Path;
    AssignFile(F, Path);
    Rewrite(F, 1);
    if Length(SfxWav[Kind]) > 0 then
      BlockWrite(F, SfxWav[Kind][0], Length(SfxWav[Kind]));
    CloseFile(F);
  end;
end;

procedure PlaySfx(Kind: TSfxKind);
var
  Cmd: string;
begin
  if (Kind < sfxSearch) or (Kind > sfxType) then
    Exit;
  Cmd := '(paplay ' + SfxPath[Kind] + ' || aplay -q ' + SfxPath[Kind] +
    ') >/dev/null 2>&1 &';
  fpSystem(Cmd);
end;

procedure DrainAudio;
var
  Kind: TSfxKind;
begin
  if Controller = nil then
    Exit;
  while Controller.Model.DrainSfx(Kind) do
    PlaySfx(Kind);
end;

procedure DestroyPix;
begin
  if Pix <> nil then
  begin
    g_object_unref(Pix);
    Pix := nil;
  end;
end;

procedure EnsurePixbuf;
begin
  if (Controller.Canvas.Width < 1) or (Controller.Canvas.Height < 1) then
    Exit;
  if (Pix <> nil) and
     (gdk_pixbuf_get_width(Pix) = Controller.Canvas.Width) and
     (gdk_pixbuf_get_height(Pix) = Controller.Canvas.Height) then
    Exit;
  DestroyPix;
  Pix := gdk_pixbuf_new(GDK_COLORSPACE_RGB, True, 8,
    Controller.Canvas.Width, Controller.Canvas.Height);
end;

procedure PixbufFromBuffer;
var
  Pixels: PByte;
  Row: Integer;
  Src, Dst: PByte;
  BufW: Integer;
begin
  EnsurePixbuf;
  if Pix = nil then
    Exit;
  BufW := Controller.Canvas.Width;
  Pixels := PByte(gdk_pixbuf_get_pixels(Pix));
  for Row := 0 to Controller.Canvas.Height - 1 do
  begin
    Src := Controller.Canvas.Ptr + Row * BufW * 4;
    Dst := Pixels + Row * gdk_pixbuf_get_rowstride(Pix);
    Move(Src^, Dst^, BufW * 4);
  end;
end;

procedure Present;
begin
  Controller.Render;
  PixbufFromBuffer;
  Controller.ConsumePresent;
  if DrawArea <> nil then
    gtk_widget_queue_draw(DrawArea);
end;

function WidgetToCanvas(WX, WY: Double; out CX, CY: Double): Boolean;
begin
  Result := False;
  CX := 0;
  CY := 0;
  if (AreaW < 1) or (AreaH < 1) then
    Exit;
  CX := WX / AreaW * Controller.Canvas.Width;
  CY := WY / AreaH * Controller.Canvas.Height;
  Result := True;
end;

procedure ShowAbout(Parent: PGtkWidget);
var
  Dlg: PGtkWidget;
begin
  Dlg := gtk_message_dialog_new(PGtkWindow(Parent), GTK_DIALOG_MODAL,
    GTK_MESSAGE_INFO, GTK_BUTTONS_OK, PChar(GuideAboutText));
  gtk_window_set_title(PGtkWindow(Dlg), GuideAboutTitle);
  gtk_dialog_run(PGtkDialog(Dlg));
  gtk_widget_destroy(Dlg);
end;

procedure ApplyFullScreen(Enter: Boolean);
begin
  if Enter = FullScreen then
    Exit;
  FullScreen := Enter;
  Controller.SetFullScreen(Enter);
  if Enter then
  begin
    { State change: windowed → gtk_window_fullscreen (hides the menu too). }
    gtk_widget_hide(MenuBar);
    gtk_window_fullscreen(PGtkWindow(MainWin));
  end
  else
  begin
    { State change: fullscreen → titled window. }
    gtk_window_unfullscreen(PGtkWindow(MainWin));
    gtk_widget_show(MenuBar);
  end;
end;

procedure ToggleFullScreen;
begin
  ApplyFullScreen(not FullScreen);
end;

procedure OnQuit(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  gtk_main_quit;
end;

procedure OnAbout(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  ShowAbout(MainWin);
end;

procedure OnFullScreen(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  ToggleFullScreen;
end;

function OnDelete(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  gtk_main_quit;
  Result := False;
end;

function OnTick(Data: gpointer): gboolean; cdecl;
begin
  Controller.Tick;
  DrainAudio;
  if Controller.NeedsPresent then
    Present;
  Result := True; { keep the timeout }
end;

function OnConfigure(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  W, H: Integer;
begin
  W := Event^.configure.width;
  H := Event^.configure.height;
  if W < 1 then
    W := 1;
  if H < 1 then
    H := 1;
  if (W <> AreaW) or (H <> AreaH) then
  begin
    { State change: drawing area size follows the window. }
    AreaW := W;
    AreaH := H;
    Controller.Resize(W, H);
    Present;
  end;
  Result := False;
end;

function OnExpose(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  DestW, DestH: Integer;
begin
  Result := False;
  if (Pix = nil) or (Widget^.window = nil) then
    Exit;
  DestW := gdk_pixbuf_get_width(Pix);
  DestH := gdk_pixbuf_get_height(Pix);
  gdk_pixbuf_render_to_drawable(Pix, Widget^.window,
    Widget^.style^.fg_gc[GTK_WIDGET_STATE(Widget)],
    0, 0, 0, 0, DestW, DestH, GDK_RGB_DITHER_NONE, 0, 0);
end;

function OnButtonPress(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  CX, CY: Double;
begin
  Result := False;
  if Event^.button.button <> 1 then
    Exit;
  if Event^.button._type = GDK_2BUTTON_PRESS then
  begin
    ToggleFullScreen;
    Result := True;
    Exit;
  end;
  gtk_widget_grab_focus(Widget);
  if WidgetToCanvas(Event^.button.x, Event^.button.y, CX, CY) then
    Controller.MouseDown(CX, CY);
  Present;
  Result := True;
end;

function OnButtonRelease(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  CX, CY: Double;
begin
  Result := False;
  if Event^.button.button <> 1 then
    Exit;
  if WidgetToCanvas(Event^.button.x, Event^.button.y, CX, CY) then
    Controller.MouseUp(CX, CY)
  else
    Controller.MouseUp(-1, -1);
  DrainAudio;
  Present;
  Result := True;
end;

function OnMotion(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  CX, CY: Double;
begin
  if WidgetToCanvas(Event^.motion.x, Event^.motion.y, CX, CY) then
    Controller.MouseMove(CX, CY);
  Present;
  Result := True;
end;

function OnLeave(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  Controller.MouseLeave;
  Present;
  Result := False;
end;

function EventToKey(Event: PGdkEvent): TGuideKey;
var
  KV: guint;
begin
  Result := gkNone;
  if Event = nil then
    Exit;
  KV := Event^.key.keyval;
  case KV of
    GDK_Right, GDK_Down, GDK_space, GDK_Return, GDK_KP_Enter:
      Exit(gkNext);
    GDK_Left, GDK_Up:
      Exit(gkPrev);
  end;
  if (KV >= GDK_1) and (KV <= GDK_1 + 8) then
    Exit(GuideKeyFromJump(KV - GDK_1 + 1));
  if (KV >= GDK_KP_1) and (KV <= GDK_KP_1 + 8) then
    Exit(GuideKeyFromJump(KV - GDK_KP_1 + 1));
end;

function OnKey(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  KV: guint;
  Mapped: TGuideKey;
begin
  Result := False;
  KV := Event^.key.keyval;
  if KV = GDK_F11 then
  begin
    ToggleFullScreen;
    Result := True;
    Exit;
  end;
  if KV = GDK_Escape then
  begin
    if FullScreen then
      ApplyFullScreen(False)
    else
      gtk_main_quit;
    Result := True;
    Exit;
  end;
  Mapped := EventToKey(Event);
  if Mapped = gkNone then
    Exit;
  Controller.KeyPress(Mapped);
  DrainAudio;
  Present;
  Result := True;
end;

function OnWindowState(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  NowFull: Boolean;
begin
  NowFull := (Event^.window_state.new_window_state and GDK_WINDOW_STATE_FULLSCREEN) <> 0;
  if NowFull <> FullScreen then
  begin
    { WM may have toggled fullscreen (e.g. a window-manager key) without us. }
    FullScreen := NowFull;
    Controller.SetFullScreen(NowFull);
    if NowFull then
      gtk_widget_hide(MenuBar)
    else
      gtk_widget_show(MenuBar);
  end;
  Result := False;
end;

function BuildMenuBar: PGtkWidget;
var
  Bar, Menu, Item, Root: PGtkWidget;
begin
  Bar := gtk_menu_bar_new;

  Menu := gtk_menu_new;
  Root := gtk_menu_item_new_with_label('Guide');
  gtk_menu_item_set_submenu(PGtkMenuItem(Root), Menu);
  gtk_menu_shell_append(PGtkMenuShell(Bar), Root);
  Item := gtk_menu_item_new_with_label('About Hitch-Hiker''s Guide');
  g_signal_connect(G_OBJECT(Item), 'activate', TG_SIGNAL_FUNC(@OnAbout), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_separator_menu_item_new;
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Quit');
  g_signal_connect(G_OBJECT(Item), 'activate', TG_SIGNAL_FUNC(@OnQuit), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);

  Menu := gtk_menu_new;
  Root := gtk_menu_item_new_with_label('View');
  gtk_menu_item_set_submenu(PGtkMenuItem(Root), Menu);
  gtk_menu_shell_append(PGtkMenuShell(Bar), Root);
  Item := gtk_menu_item_new_with_label('Full Screen');
  g_signal_connect(G_OBJECT(Item), 'activate', TG_SIGNAL_FUNC(@OnFullScreen), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);

  Result := Bar;
end;

procedure HostRun;
var
  Box: PGtkWidget;
  Mask: gint;
begin
  gtk_init(@argc, @argv);
  Controller := TGuideController.Create(WinW, WinH);
  WriteSfxFiles;
  FullScreen := False;
  AreaW := WinW;
  AreaH := WinH;
  Pix := nil;

  MainWin := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(PGtkWindow(MainWin), 'The Hitch-Hiker''s Guide to the Galaxy');
  gtk_window_set_resizable(PGtkWindow(MainWin), True);
  gtk_window_set_default_size(PGtkWindow(MainWin), WinW, WinH);
  gtk_widget_set_size_request(MainWin, MinW, MinH);
  g_signal_connect(G_OBJECT(MainWin), 'delete-event', TG_SIGNAL_FUNC(@OnDelete), nil);
  g_signal_connect(G_OBJECT(MainWin), 'key-press-event', TG_SIGNAL_FUNC(@OnKey), nil);
  g_signal_connect(G_OBJECT(MainWin), 'window-state-event', TG_SIGNAL_FUNC(@OnWindowState), nil);

  Box := gtk_vbox_new(False, 0);
  gtk_container_add(PGtkContainer(MainWin), Box);
  MenuBar := BuildMenuBar;
  gtk_box_pack_start(PGtkBox(Box), MenuBar, False, False, 0);

  DrawArea := gtk_drawing_area_new;
  gtk_widget_set_size_request(DrawArea, MinW, MinH);
  gtk_box_pack_start(PGtkBox(Box), DrawArea, True, True, 0);
  Mask := GDK_BUTTON_PRESS_MASK or GDK_BUTTON_RELEASE_MASK or
    GDK_POINTER_MOTION_MASK or GDK_LEAVE_NOTIFY_MASK or GDK_STRUCTURE_MASK;
  gtk_widget_add_events(DrawArea, Mask);
  gtk_widget_set_can_focus(DrawArea, True);
  g_signal_connect(G_OBJECT(DrawArea), 'configure-event', TG_SIGNAL_FUNC(@OnConfigure), nil);
  g_signal_connect(G_OBJECT(DrawArea), 'expose-event', TG_SIGNAL_FUNC(@OnExpose), nil);
  g_signal_connect(G_OBJECT(DrawArea), 'button-press-event', TG_SIGNAL_FUNC(@OnButtonPress), nil);
  g_signal_connect(G_OBJECT(DrawArea), 'button-release-event', TG_SIGNAL_FUNC(@OnButtonRelease), nil);
  g_signal_connect(G_OBJECT(DrawArea), 'motion-notify-event', TG_SIGNAL_FUNC(@OnMotion), nil);
  g_signal_connect(G_OBJECT(DrawArea), 'leave-notify-event', TG_SIGNAL_FUNC(@OnLeave), nil);

  g_timeout_add(TickMs, TGSourceFunc(@OnTick), nil);
  Present;
  gtk_widget_show_all(MainWin);
  gtk_main;
  DestroyPix;
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
