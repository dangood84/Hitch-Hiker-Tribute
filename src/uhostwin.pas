unit uhostwin;

{$mode objfpc}{$H+}

{ Windows titled, resizable window on the taskbar. Same TGuideController
  as macOS; this unit presents pixels (BGRA StretchDIBits), a 50 ms
  timer, original WAV stings via PlaySound, keys / clicks, and F11 /
  double-click fullscreen. }

interface

procedure HostRun;

implementation

{$IFDEF WINDOWS}

uses
  Windows, Messages, SysUtils, MMSystem, uguidemodel, uguiderender, uguideapp, uguideaudio;

{ FPC 3.2.2's Win32 Windows unit has no multi-monitor API. user32 does. }
{$if not declared(MonitorFromWindow)}
type
  HMONITOR = type THandle;
  TMonitorInfo = record
    cbSize: DWORD;
    rcMonitor: TRect;
    rcWork: TRect;
    dwFlags: DWORD;
  end;
  PMonitorInfo = ^TMonitorInfo;
{$endif}

const
  AppName = 'HitchHikersGuideWnd';
  CmdAbout = 1001;
  CmdQuit = 1002;
  CmdFullScreen = 1003;
  WinW = 760;
  WinH = 540;
  MinW = 520;
  MinH = 380;
  TickId = 1;
  TickMs = 50;
{$if not declared(MONITOR_DEFAULTTONEAREST)}
  MONITOR_DEFAULTTONEAREST = 2;
{$endif}

var
  Controller: TGuideController;
  MainWnd: HWND;
  Bgra: array of Byte;
  AppMenuBar: HMENU;
  FullScreen: Boolean;
  SavedStyle: LONG;
  SavedRect: TRect;
  SavedMenu: HMENU;
  TrackingLeave: Boolean;
  SfxWav: array[sfxSearch..sfxType] of TBytes;
  SfxHold: array[0..3] of TBytes;
  SfxSlot: Integer;

{$if not declared(MonitorFromWindow)}
function MonitorFromWindow(hwnd: HWND; dwFlags: DWORD): HMONITOR; stdcall;
  external 'user32.dll' name 'MonitorFromWindow';
function GetMonitorInfo(hMonitor: HMONITOR; lpmi: PMonitorInfo): BOOL; stdcall;
  external 'user32.dll' name 'GetMonitorInfoA';
{$endif}

procedure PlaySfx(Kind: TSfxKind);
begin
  if (Kind < sfxSearch) or (Kind > sfxType) then
    Exit;
  if Length(SfxWav[Kind]) < 44 then
    Exit;
  { PlaySound SND_MEMORY needs the buffer to stay alive until it finishes. }
  SfxHold[SfxSlot] := SfxWav[Kind];
  PlaySound(PChar(@SfxHold[SfxSlot][0]), 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT);
  SfxSlot := (SfxSlot + 1) mod Length(SfxHold);
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

function ClientToCanvas(Wnd: HWND; X, Y: Integer; out CX, CY: Double): Boolean;
var
  R: TRect;
  CW, CH: Integer;
begin
  Result := False;
  CX := 0;
  CY := 0;
  if not GetClientRect(Wnd, R) then
    Exit;
  CW := R.Right - R.Left;
  CH := R.Bottom - R.Top;
  if (CW < 1) or (CH < 1) then
    Exit;
  CX := X * Controller.Canvas.Width / CW;
  CY := Y * Controller.Canvas.Height / CH;
  Result := True;
end;

procedure Present(Wnd: HWND);
begin
  Controller.Render;
  SetLength(Bgra, Controller.Canvas.Width * Controller.Canvas.Height * 4);
  CopyBGRA(Controller.Canvas, @Bgra[0]);
  Controller.ConsumePresent;
  InvalidateRect(Wnd, nil, False); { erase=False avoids a grey flash between paints }
end;

procedure PaintGuide(Wnd: HWND);
var
  PS: PAINTSTRUCT;
  DC: HDC;
  Info: BITMAPINFO;
  R: TRect;
begin
  DC := BeginPaint(Wnd, @PS);
  GetClientRect(Wnd, @R);
  if Length(Bgra) = Controller.Canvas.Width * Controller.Canvas.Height * 4 then
  begin
    FillChar(Info, SizeOf(Info), 0);
    Info.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
    Info.bmiHeader.biWidth := Controller.Canvas.Width;
    Info.bmiHeader.biHeight := -Controller.Canvas.Height; { negative = top-down DIB }
    Info.bmiHeader.biPlanes := 1;
    Info.bmiHeader.biBitCount := 32;
    Info.bmiHeader.biCompression := BI_RGB;
    StretchDIBits(DC, 0, 0, R.Right - R.Left, R.Bottom - R.Top,
      0, 0, Controller.Canvas.Width, Controller.Canvas.Height,
      @Bgra[0], Info, DIB_RGB_COLORS, SRCCOPY);
  end;
  EndPaint(Wnd, @PS);
end;

procedure SyncCanvas(Wnd: HWND);
var
  R: TRect;
  CW, CH: Integer;
begin
  if not GetClientRect(Wnd, R) then
    Exit;
  CW := R.Right - R.Left;
  CH := R.Bottom - R.Top;
  if (CW < 1) or (CH < 1) then
    Exit;
  Controller.Resize(CW, CH);
end;

procedure ShowAbout(Wnd: HWND);
begin
  MessageBox(Wnd, PChar(GuideAboutText), GuideAboutTitle, MB_OK or MB_ICONINFORMATION);
end;

procedure EnterFullScreen(Wnd: HWND);
var
  Mi: TMonitorInfo;
  Mon: HMONITOR;
  Style: LONG;
begin
  if FullScreen then
    Exit;
  { State change: overlapped window → monitor-filling popup. }
  GetWindowRect(Wnd, SavedRect);
  SavedStyle := GetWindowLong(Wnd, GWL_STYLE);
  SavedMenu := GetMenu(Wnd);
  SetMenu(Wnd, 0);
  Style := SavedStyle and not (WS_CAPTION or WS_THICKFRAME or WS_BORDER or WS_SYSMENU);
  SetWindowLong(Wnd, GWL_STYLE, Style or WS_POPUP);
  FillChar(Mi, SizeOf(Mi), 0);
  Mi.cbSize := SizeOf(Mi);
  Mon := MonitorFromWindow(Wnd, MONITOR_DEFAULTTONEAREST);
  GetMonitorInfo(Mon, @Mi);
  SetWindowPos(Wnd, HWND_TOP,
    Mi.rcMonitor.Left, Mi.rcMonitor.Top,
    Mi.rcMonitor.Right - Mi.rcMonitor.Left,
    Mi.rcMonitor.Bottom - Mi.rcMonitor.Top,
    SWP_FRAMECHANGED or SWP_SHOWWINDOW);
  FullScreen := True;
  Controller.SetFullScreen(True);
end;

procedure LeaveFullScreen(Wnd: HWND);
begin
  if not FullScreen then
    Exit;
  { State change: popup → titled, resizable window. }
  SetWindowLong(Wnd, GWL_STYLE, SavedStyle);
  SetMenu(Wnd, SavedMenu);
  SetWindowPos(Wnd, HWND_TOP,
    SavedRect.Left, SavedRect.Top,
    SavedRect.Right - SavedRect.Left,
    SavedRect.Bottom - SavedRect.Top,
    SWP_FRAMECHANGED or SWP_SHOWWINDOW);
  FullScreen := False;
  Controller.SetFullScreen(False);
end;

procedure ToggleFullScreen(Wnd: HWND);
begin
  if FullScreen then
    LeaveFullScreen(Wnd)
  else
    EnterFullScreen(Wnd);
end;

procedure EnsureMouseLeaveTrack(Wnd: HWND);
var
  Tme: TTrackMouseEvent;
begin
  if TrackingLeave then
    Exit;
  FillChar(Tme, SizeOf(Tme), 0);
  Tme.cbSize := SizeOf(Tme);
  Tme.dwFlags := TME_LEAVE;
  Tme.hwndTrack := Wnd;
  TrackMouseEvent(Tme);
  TrackingLeave := True;
end;

function WndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var
  MinTrack: PMINMAXINFO;
  CX, CY: Double;
  Key: TGuideKey;
  X, Y: Integer;
begin
  Result := 0;
  case Msg of
    WM_CREATE:
      begin
        SetTimer(Wnd, TickId, TickMs, nil);
        SyncCanvas(Wnd);
        Present(Wnd);
      end;
    WM_TIMER:
      if WParam = TickId then
      begin
        Controller.Tick;
        DrainAudio;
        if Controller.NeedsPresent then
          Present(Wnd);
      end;
    WM_PAINT:
      PaintGuide(Wnd);
    WM_SIZE:
      begin
        SyncCanvas(Wnd);
        Present(Wnd);
      end;
    WM_GETMINMAXINFO:
      begin
        MinTrack := PMINMAXINFO(LParam);
        MinTrack^.ptMinTrackSize.X := MinW + 32;
        MinTrack^.ptMinTrackSize.Y := MinH + 48;
      end;
    WM_LBUTTONDBLCLK:
      ToggleFullScreen(Wnd);
    WM_LBUTTONDOWN:
      begin
        SetCapture(Wnd);
        SetFocus(Wnd);
        X := SmallInt(LOWORD(LParam));
        Y := SmallInt(HIWORD(LParam));
        if ClientToCanvas(Wnd, X, Y, CX, CY) then
          Controller.MouseDown(CX, CY);
        Present(Wnd);
      end;
    WM_MOUSEMOVE:
      begin
        EnsureMouseLeaveTrack(Wnd);
        X := SmallInt(LOWORD(LParam));
        Y := SmallInt(HIWORD(LParam));
        if ClientToCanvas(Wnd, X, Y, CX, CY) then
          Controller.MouseMove(CX, CY);
        Present(Wnd);
      end;
    WM_LBUTTONUP:
      begin
        X := SmallInt(LOWORD(LParam));
        Y := SmallInt(HIWORD(LParam));
        if ClientToCanvas(Wnd, X, Y, CX, CY) then
          Controller.MouseUp(CX, CY)
        else
          Controller.MouseUp(-1, -1);
        if GetCapture = Wnd then
          ReleaseCapture;
        DrainAudio;
        Present(Wnd);
      end;
    WM_MOUSELEAVE:
      begin
        TrackingLeave := False;
        Controller.MouseLeave;
        Present(Wnd);
      end;
    WM_KEYDOWN:
      begin
        Key := gkNone;
        case WParam of
          VK_RIGHT, VK_DOWN, VK_SPACE, VK_RETURN:
            Key := gkNext;
          VK_LEFT, VK_UP:
            Key := gkPrev;
          Ord('1')..Ord('9'):
            Key := GuideKeyFromJump(WParam - Ord('0'));
          VK_NUMPAD1..VK_NUMPAD9:
            Key := GuideKeyFromJump(WParam - VK_NUMPAD1 + 1);
          VK_F11:
            begin
              ToggleFullScreen(Wnd);
              Exit;
            end;
          VK_ESCAPE:
            begin
              if FullScreen then
                LeaveFullScreen(Wnd)
              else
                PostQuitMessage(0);
              Exit;
            end;
        end;
        if Key <> gkNone then
        begin
          Controller.KeyPress(Key);
          DrainAudio;
          Present(Wnd);
        end;
      end;
    WM_COMMAND:
      case LOWORD(WParam) of
        CmdAbout:
          ShowAbout(Wnd);
        CmdFullScreen:
          ToggleFullScreen(Wnd);
        CmdQuit:
          PostQuitMessage(0);
      end;
    WM_DESTROY:
      begin
        KillTimer(Wnd, TickId);
        PostQuitMessage(0);
      end;
    else
      Result := DefWindowProc(Wnd, Msg, WParam, LParam);
  end;
end;

function BuildMenu: HMENU;
var
  Bar, GuideMenu, ViewMenu: HMENU;
begin
  Bar := CreateMenu;
  GuideMenu := CreatePopupMenu;
  AppendMenu(GuideMenu, MF_STRING, CmdAbout, '&About Hitch-Hiker''s Guide...');
  AppendMenu(GuideMenu, MF_SEPARATOR, 0, nil);
  AppendMenu(GuideMenu, MF_STRING, CmdQuit, 'E&xit');
  AppendMenu(Bar, MF_POPUP, GuideMenu, '&Guide');
  ViewMenu := CreatePopupMenu;
  AppendMenu(ViewMenu, MF_STRING, CmdFullScreen, '&Full Screen'#9'F11');
  AppendMenu(Bar, MF_POPUP, ViewMenu, '&View');
  Result := Bar;
end;

procedure HostRun;
var
  WC: WNDCLASS;
  Msg: TMsg;
  Wr: TRect;
  Style: DWORD;
  Kind: TSfxKind;
begin
  Controller := TGuideController.Create(WinW, WinH);
  FullScreen := False;
  TrackingLeave := False;
  SfxSlot := 0;
  for Kind := sfxSearch to sfxType do
    SfxWav[Kind] := BuildSfxWav(Kind);
  AppMenuBar := BuildMenu;

  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @WndProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursor(0, IDC_ARROW);
  WC.hbrBackground := GetStockObject(BLACK_BRUSH);
  WC.lpszClassName := AppName;
  WC.style := CS_DBLCLKS or CS_HREDRAW or CS_VREDRAW;
  RegisterClass(WC);

  Style := WS_OVERLAPPEDWINDOW;
  Wr.Left := 0;
  Wr.Top := 0;
  Wr.Right := WinW;
  Wr.Bottom := WinH;
  AdjustWindowRect(Wr, Style, True);

  MainWnd := CreateWindowEx(WS_EX_APPWINDOW, AppName,
    'The Hitch-Hiker''s Guide to the Galaxy',
    Style,
    CW_USEDEFAULT, CW_USEDEFAULT, Wr.Right - Wr.Left, Wr.Bottom - Wr.Top,
    0, AppMenuBar, HInstance, nil);

  ShowWindow(MainWnd, SW_SHOW);
  UpdateWindow(MainWnd);

  while GetMessage(Msg, 0, 0, 0) do
  begin
    TranslateMessage(Msg);
    DispatchMessage(Msg);
  end;
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
