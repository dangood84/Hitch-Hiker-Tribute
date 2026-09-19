unit uguideapp;

{$mode objfpc}{$H+}

{ One model, one canvas. Hosts convert OS mouse/keyboard into these calls,
  fire Tick on a ~50 ms timer, and present Canvas when NeedsPresent is set.

  FullScreen is *reported* here; the host is the one that actually asks
  Cocoa / Win32 / GTK to go full screen. }

interface

uses
  uguidemodel, uguiderender;

const
  GuideAboutTitle = 'The Hitch-Hiker''s Guide to the Galaxy';
  GuideAboutText =
    'A tribute to the 1981 BBC TV-series Guide: phosphor-green CRT text, ' +
    'a large friendly DON''T PANIC, and a pocket encyclopedia of the galaxy.' +
    LineEnding + LineEnding +
    'Left / Right or Space turns the page. Keys 1-9 jump. Click an index ' +
    'row. A search chirp plays while RESEARCHING, then a two-note beep, ' +
    'then a small pip for each letter as it types on. F11 (Esc to leave) ' +
    'for fullscreen. Closing the window quits.' +
    LineEnding + LineEnding +
    'Unofficial tribute. Not affiliated with the BBC or the Adams estate.';

type
  TGuideController = class
  private
    FNeedsPresent: Boolean;
    FFullScreen: Boolean;
    FHoverIndex: Integer;
    FPressedIndex: Integer;
  public
    Model: TGuideModel;
    Canvas: TPixelBuffer;
    constructor Create(PixelW, PixelH: Integer);
    destructor Destroy; override;
    procedure Resize(PixelW, PixelH: Integer);
    procedure Tick;
    procedure Render;
    procedure MouseMove(CX, CY: Double);
    procedure MouseDown(CX, CY: Double);
    procedure MouseUp(CX, CY: Double);
    procedure MouseLeave;
    procedure KeyPress(Key: TGuideKey);
    procedure ShowImmediate(NewIndex: Integer);
    procedure SetFullScreen(Value: Boolean);
    function HitAt(CX, CY: Double): Integer;
    property NeedsPresent: Boolean read FNeedsPresent;
    property FullScreen: Boolean read FFullScreen;
    property HoverIndex: Integer read FHoverIndex;
    procedure ConsumePresent;
  end;

implementation

constructor TGuideController.Create(PixelW, PixelH: Integer);
begin
  inherited Create;
  Model := TGuideModel.Create;
  Canvas := TPixelBuffer.Create(PixelW, PixelH);
  FNeedsPresent := True; { first frame before the timer so the window is not blank }
  FFullScreen := False;
  FHoverIndex := -1;
  FPressedIndex := -1;
end;

destructor TGuideController.Destroy;
begin
  Canvas.Free;
  Model.Free;
  inherited Destroy;
end;

procedure TGuideController.Resize(PixelW, PixelH: Integer);
begin
  if (PixelW = Canvas.Width) and (PixelH = Canvas.Height) then
    Exit;
  { State change: backing store follows the window (or the fullscreen
    display). Layout is rebuilt from the new size, so the CRT frame
    stays inset on a widescreen. }
  Canvas.Resize(PixelW, PixelH);
  FNeedsPresent := True;
end;

procedure TGuideController.Tick;
begin
  Model.Tick;
  { Scanlines crawl every tick; page-turns also mutate phase. Always
    dirty — this is a CRT, not a static form. }
  FNeedsPresent := True;
end;

procedure TGuideController.Render;
begin
  RenderGuide(Canvas, Model, FHoverIndex);
  FNeedsPresent := True;
end;

procedure TGuideController.ShowImmediate(NewIndex: Integer);
begin
  Model.ShowImmediate(NewIndex);
  FNeedsPresent := True;
end;

function TGuideController.HitAt(CX, CY: Double): Integer;
var
  Lay: TGuideLayout;
begin
  Lay := MakeGuideLayout(Canvas.Width, Canvas.Height);
  Result := HitTestIndex(Lay, Trunc(CX), Trunc(CY));
end;

procedure TGuideController.MouseMove(CX, CY: Double);
begin
  FHoverIndex := HitAt(CX, CY);
  FNeedsPresent := True;
end;

procedure TGuideController.MouseDown(CX, CY: Double);
begin
  FHoverIndex := HitAt(CX, CY);
  FPressedIndex := FHoverIndex;
  FNeedsPresent := True;
end;

procedure TGuideController.MouseUp(CX, CY: Double);
var
  Hit: Integer;
begin
  FHoverIndex := HitAt(CX, CY);
  Hit := FPressedIndex;
  FPressedIndex := -1; { clear first so a later paint cannot show a stuck row }
  if (Hit >= 0) and (FHoverIndex = Hit) then
    Model.SelectIndex(Hit); { drag off, release — nothing fires }
  FNeedsPresent := True;
end;

procedure TGuideController.MouseLeave;
begin
  FHoverIndex := -1;
  { Leave during a drag: the row stays armed until mouse-up (host capture). }
  FNeedsPresent := True;
end;

procedure TGuideController.KeyPress(Key: TGuideKey);
begin
  if Key = gkNone then
    Exit;
  Model.Press(Key);
  FNeedsPresent := True;
end;

procedure TGuideController.SetFullScreen(Value: Boolean);
begin
  if FFullScreen = Value then
    Exit;
  { State change: windowed ↔ fullscreen. The host has already switched
    presentation; we only remember it. Resize() arrives separately. }
  FFullScreen := Value;
  FNeedsPresent := True;
end;

procedure TGuideController.ConsumePresent;
begin
  FNeedsPresent := False;
end;

end.
