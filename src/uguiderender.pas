unit uguiderender;

{$mode objfpc}{$H+}

{ Software RGBA canvas for the 1981 Guide CRT. Hosts only upload the bytes.
  Layout is derived from the buffer size so a 1× Linux window and a 2×
  retina Mac window share the same hit-testing math. }

interface

uses
  uguidemodel;

type
  TGuideLayout = record
    Scale: Integer;
    FrameX, FrameY, FrameW, FrameH: Integer;
    BannerX, BannerY, BannerW, BannerH: Integer;
    IndexX, IndexY, IndexW, IndexH: Integer;
    IndexRowH: Integer;
    ContentX, ContentY, ContentW, ContentH: Integer;
    ArtX, ArtY, ArtW, ArtH: Integer;
    FooterY: Integer;
  end;

  TPixelBuffer = class
  private
    FWidth, FHeight: Integer;
    FData: array of Byte;
  public
    constructor Create(AWidth, AHeight: Integer);
    procedure Resize(AWidth, AHeight: Integer);
    procedure Clear(R, G, B, A: Byte);
    function Ptr: PByte;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
  end;

function MakeGuideLayout(BufW, BufH: Integer): TGuideLayout;
function HitTestIndex(const Lay: TGuideLayout; PX, PY: Integer): Integer;
procedure RenderGuide(Buf: TPixelBuffer; Model: TGuideModel; HoverIndex: Integer);
procedure CopyBGRA(Buf: TPixelBuffer; Dest: PByte);

implementation

uses
  SysUtils, Math, ubitmapfont;

type
  TColor = record
    R, G, B: Byte;
  end;

  TLineArray = array of string;

function C(R, G, B: Byte): TColor;
begin
  Result.R := R;
  Result.G := G;
  Result.B := B;
end;

constructor TPixelBuffer.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  Resize(AWidth, AHeight);
end;

procedure TPixelBuffer.Resize(AWidth, AHeight: Integer);
begin
  if AWidth < 1 then
    AWidth := 1;
  if AHeight < 1 then
    AHeight := 1;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FData, FWidth * FHeight * 4);
end;

procedure TPixelBuffer.Clear(R, G, B, A: Byte);
var
  I: Integer;
  P: PByte;
begin
  P := @FData[0];
  I := 0;
  while I < Length(FData) do
  begin
    P[I] := R;
    P[I + 1] := G;
    P[I + 2] := B;
    P[I + 3] := A;
    Inc(I, 4);
  end;
end;

function TPixelBuffer.Ptr: PByte;
begin
  Result := @FData[0];
end;

procedure CopyBGRA(Buf: TPixelBuffer; Dest: PByte);
var
  I, N: Integer;
  S, D: PByte;
begin
  S := Buf.Ptr;
  D := Dest;
  N := Buf.Width * Buf.Height;
  for I := 0 to N - 1 do
  begin
    D[0] := S[2]; { B — Windows DIB wants BGRA; the canvas is RGBA }
    D[1] := S[1];
    D[2] := S[0];
    D[3] := S[3];
    Inc(S, 4);
    Inc(D, 4);
  end;
end;

procedure PutPixel(Buf: TPixelBuffer; X, Y: Integer; Col: TColor);
var
  P: PByte;
begin
  if (X < 0) or (Y < 0) or (X >= Buf.Width) or (Y >= Buf.Height) then
    Exit;
  P := Buf.Ptr + (Y * Buf.Width + X) * 4;
  P[0] := Col.R;
  P[1] := Col.G;
  P[2] := Col.B;
  P[3] := 255;
end;

procedure FillRect(Buf: TPixelBuffer; X, Y, W, H: Integer; Col: TColor);
var
  XX, YY, X0, Y0, X1, Y1: Integer;
begin
  X0 := X;
  Y0 := Y;
  if X0 < 0 then
    X0 := 0;
  if Y0 < 0 then
    Y0 := 0;
  X1 := X + W - 1;
  Y1 := Y + H - 1;
  if X1 >= Buf.Width then
    X1 := Buf.Width - 1;
  if Y1 >= Buf.Height then
    Y1 := Buf.Height - 1;
  for YY := Y0 to Y1 do
    for XX := X0 to X1 do
      PutPixel(Buf, XX, YY, Col);
end;

procedure HLine(Buf: TPixelBuffer; X, Y, W: Integer; Col: TColor);
var
  I: Integer;
begin
  for I := 0 to W - 1 do
    PutPixel(Buf, X + I, Y, Col);
end;

procedure VLine(Buf: TPixelBuffer; X, Y, H: Integer; Col: TColor);
var
  I: Integer;
begin
  for I := 0 to H - 1 do
    PutPixel(Buf, X, Y + I, Col);
end;

procedure FrameRect(Buf: TPixelBuffer; X, Y, W, H: Integer; Col: TColor);
begin
  if (W < 1) or (H < 1) then
    Exit;
  HLine(Buf, X, Y, W, Col);
  HLine(Buf, X, Y + H - 1, W, Col);
  VLine(Buf, X, Y, H, Col);
  VLine(Buf, X + W - 1, Y, H, Col);
end;

procedure LineTo(Buf: TPixelBuffer; X0, Y0, X1, Y1: Integer; Col: TColor);
var
  DX, DY, SX, SY, Err, E2: Integer;
begin
  { Bresenham — the TV series was all straight vectors. }
  DX := Abs(X1 - X0);
  DY := Abs(Y1 - Y0);
  if X0 < X1 then
    SX := 1
  else
    SX := -1;
  if Y0 < Y1 then
    SY := 1
  else
    SY := -1;
  Err := DX - DY;
  while True do
  begin
    PutPixel(Buf, X0, Y0, Col);
    if (X0 = X1) and (Y0 = Y1) then
      Break;
    E2 := 2 * Err;
    if E2 > -DY then
    begin
      Dec(Err, DY);
      Inc(X0, SX);
    end;
    if E2 < DX then
    begin
      Inc(Err, DX);
      Inc(Y0, SY);
    end;
  end;
end;

procedure OutlineCircle(Buf: TPixelBuffer; CX, CY, R: Integer; Col: TColor);
var
  X, Y, D: Integer;
begin
  if R < 1 then
    Exit;
  X := 0;
  Y := R;
  D := 3 - 2 * R;
  while X <= Y do
  begin
    PutPixel(Buf, CX + X, CY + Y, Col);
    PutPixel(Buf, CX - X, CY + Y, Col);
    PutPixel(Buf, CX + X, CY - Y, Col);
    PutPixel(Buf, CX - X, CY - Y, Col);
    PutPixel(Buf, CX + Y, CY + X, Col);
    PutPixel(Buf, CX - Y, CY + X, Col);
    PutPixel(Buf, CX + Y, CY - X, Col);
    PutPixel(Buf, CX - Y, CY - X, Col);
    if D < 0 then
      D := D + 4 * X + 6
    else
    begin
      D := D + 4 * (X - Y) + 10;
      Dec(Y);
    end;
    Inc(X);
  end;
end;

procedure FillCircle(Buf: TPixelBuffer; CX, CY, R: Integer; Col: TColor);
var
  X, Y, R2: Integer;
begin
  R2 := R * R;
  for Y := -R to R do
    for X := -R to R do
      if X * X + Y * Y <= R2 then
        PutPixel(Buf, CX + X, CY + Y, Col);
end;

procedure TextAt(Buf: TPixelBuffer; X, Y: Integer; const S: string;
  Col: TColor; Scale: Integer);
begin
  DrawGlyphText(Buf.Ptr, Buf.Width, Buf.Height, X, Y, S, Col.R, Col.G, Col.B, Scale);
end;

function FitChars(MaxW, Scale: Integer): Integer;
begin
  if Scale < 1 then
    Scale := 1;
  Result := MaxW div (8 * Scale);
  if Result < 1 then
    Result := 1;
end;

procedure TextFit(Buf: TPixelBuffer; X, Y: Integer; const S: string;
  Col: TColor; Scale, MaxW: Integer);
var
  T: string;
  N: Integer;
begin
  N := FitChars(MaxW, Scale);
  if Length(S) > N then
    T := Copy(S, 1, N)
  else
    T := S;
  TextAt(Buf, X, Y, T, Col, Scale);
end;

procedure TextGlow(Buf: TPixelBuffer; X, Y: Integer; const S: string;
  Glow, Fg: TColor; Scale: Integer);
begin
  { A cheap phosphor halo: dim copies around the glyph, then the bright ink. }
  TextAt(Buf, X - 1, Y, S, Glow, Scale);
  TextAt(Buf, X + 1, Y, S, Glow, Scale);
  TextAt(Buf, X, Y - 1, S, Glow, Scale);
  TextAt(Buf, X, Y + 1, S, Glow, Scale);
  TextAt(Buf, X, Y, S, Fg, Scale);
end;

function WrapBody(const Text: string; MaxChars: Integer): TLineArray;
var
  Lines: TLineArray;
  Count: Integer;
  I, N: Integer;
  Ch: Char;
  WordStart, LineStart: Integer;

  procedure AddLine(const S: string);
  begin
    Inc(Count);
    SetLength(Lines, Count);
    Lines[Count - 1] := S;
  end;

begin
  Count := 0;
  SetLength(Lines, 0);
  if MaxChars < 8 then
    MaxChars := 8;
  N := Length(Text);
  LineStart := 1;
  WordStart := 1;
  I := 1;
  while I <= N do
  begin
    Ch := Text[I];
    if (Ch = #10) or (Ch = #13) then
    begin
      AddLine(Copy(Text, LineStart, I - LineStart));
      if (Ch = #13) and (I < N) and (Text[I + 1] = #10) then
        Inc(I);
      LineStart := I + 1;
      WordStart := LineStart;
    end
    else if Ch = ' ' then
      WordStart := I + 1
    else if (I - LineStart + 1) > MaxChars then
    begin
      if WordStart > LineStart then
      begin
        AddLine(Copy(Text, LineStart, WordStart - LineStart - 1));
        LineStart := WordStart;
      end
      else
      begin
        AddLine(Copy(Text, LineStart, MaxChars));
        LineStart := LineStart + MaxChars;
        WordStart := LineStart;
      end;
    end;
    Inc(I);
  end;
  if LineStart <= N then
    AddLine(Copy(Text, LineStart, N - LineStart + 1))
  else if Count = 0 then
    AddLine('');
  Result := Lines;
end;

function MakeGuideLayout(BufW, BufH: Integer): TGuideLayout;
var
  S, M: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  { 540-pixel-tall window → Scale 2, so 8×8 glyphs become 16 px on a 1×
    display and 32 px on a retina buffer. }
  S := BufH div 270;
  if S < 1 then
    S := 1;
  Result.Scale := S;
  M := 8 * S;
  Result.FrameX := M;
  Result.FrameY := M;
  Result.FrameW := BufW - 2 * M;
  Result.FrameH := BufH - 2 * M;
  Result.BannerX := Result.FrameX + 4 * S;
  Result.BannerY := Result.FrameY + 4 * S;
  Result.BannerW := Result.FrameW - 8 * S;
  Result.BannerH := 8 * (S * 2) + 12 * S; { series title + DON'T PANIC }
  Result.IndexX := Result.FrameX + 4 * S;
  Result.IndexY := Result.BannerY + Result.BannerH + 4 * S;
  Result.IndexW := (Result.FrameW * 30) div 100;
  Result.FooterY := Result.FrameY + Result.FrameH - 8 * S - 4 * S;
  Result.IndexH := Result.FooterY - Result.IndexY - 4 * S;
  Result.IndexRowH := 8 * S + 4 * S;
  Result.ContentX := Result.IndexX + Result.IndexW + 6 * S;
  Result.ContentY := Result.IndexY;
  Result.ContentW := Result.FrameX + Result.FrameW - 4 * S - Result.ContentX;
  Result.ContentH := Result.IndexH;
  Result.ArtW := 56 * S;
  Result.ArtH := 56 * S;
  if Result.ContentW > Result.ArtW + 24 * S then
  begin
    Result.ArtX := Result.ContentX + Result.ContentW - Result.ArtW;
    { Sit under the title/subtitle so the heading does not run through the doodle. }
    Result.ArtY := Result.ContentY + 8 * S * 3 + 4 * S;
  end
  else
  begin
    Result.ArtW := 0;
    Result.ArtH := 0;
    Result.ArtX := 0;
    Result.ArtY := 0;
  end;
end;

function HitTestIndex(const Lay: TGuideLayout; PX, PY: Integer): Integer;
var
  Row: Integer;
begin
  Result := -1;
  if (PX < Lay.IndexX) or (PX >= Lay.IndexX + Lay.IndexW) then
    Exit;
  if (PY < Lay.IndexY) or (PY >= Lay.IndexY + Lay.IndexH) then
    Exit;
  if Lay.IndexRowH < 1 then
    Exit;
  Row := (PY - Lay.IndexY) div Lay.IndexRowH;
  if (Row >= 0) and (Row < GuideEntryCount) then
    Result := Row;
end;

procedure DarkenScanlines(Buf: TPixelBuffer; Offset: Integer);
var
  Y, X, I: Integer;
  P: PByte;
begin
  { Every fourth row is pulled toward black — a cheap rolling CRT grille. }
  Y := Offset;
  while Y < Buf.Height do
  begin
    P := Buf.Ptr + Y * Buf.Width * 4;
    for X := 0 to Buf.Width - 1 do
    begin
      I := X * 4;
      P[I] := (P[I] * 6) div 10;
      P[I + 1] := (P[I + 1] * 6) div 10;
      P[I + 2] := (P[I + 2] * 6) div 10;
    end;
    Inc(Y, ScanlinePeriod);
  end;
end;

procedure DrawEarth(Buf: TPixelBuffer; CX, CY, R: Integer; Col: TColor);
begin
  OutlineCircle(Buf, CX, CY, R, Col);
  OutlineCircle(Buf, CX, CY, R - 1, Col);
  { Crude continents — enough to read as a planet at 1981 resolution. }
  LineTo(Buf, CX - R div 2, CY - R div 3, CX, CY - R div 5, Col);
  LineTo(Buf, CX, CY - R div 5, CX + R div 3, CY, Col);
  LineTo(Buf, CX - R div 3, CY + R div 6, CX + R div 5, CY + R div 3, Col);
  OutlineCircle(Buf, CX - R div 4, CY, R div 5, Col);
end;

procedure DrawFish(Buf: TPixelBuffer; CX, CY, R: Integer; Col: TColor);
var
  I: Integer;
begin
  OutlineCircle(Buf, CX, CY, R div 2, Col);
  LineTo(Buf, CX + R div 2, CY, CX + R, CY - R div 3, Col);
  LineTo(Buf, CX + R, CY - R div 3, CX + R, CY + R div 3, Col);
  LineTo(Buf, CX + R, CY + R div 3, CX + R div 2, CY, Col);
  PutPixel(Buf, CX - R div 6, CY - R div 8, Col);
  FillCircle(Buf, CX - R div 6, CY - R div 8, Max(1, R div 16), Col);
  for I := 0 to 2 do
    LineTo(Buf, CX - R div 3, CY + I * (R div 8) - R div 8,
      CX - R div 2, CY + I * (R div 8) - R div 8, Col);
end;

procedure DrawTowel(Buf: TPixelBuffer; CX, CY, R: Integer; Col: TColor);
var
  I: Integer;
begin
  FrameRect(Buf, CX - R, CY - R div 2, R * 2, R, Col);
  FrameRect(Buf, CX - R + 2, CY - R div 2 + 2, R * 2 - 4, R - 4, Col);
  for I := 1 to 3 do
    HLine(Buf, CX - R + 6, CY - R div 2 + I * (R div 4), R * 2 - 12, Col);
end;

procedure DrawVogon(Buf: TPixelBuffer; CX, CY, R: Integer; Col: TColor);
begin
  FrameRect(Buf, CX - R div 2, CY - R, R, R * 2, Col);
  FrameRect(Buf, CX - R div 3, CY - R + R div 5, (2 * R) div 3, R div 2, Col);
  HLine(Buf, CX - R div 4, CY + R div 4, R div 2, Col);
  VLine(Buf, CX - R div 6, CY + R div 3, R div 3, Col);
  VLine(Buf, CX + R div 6, CY + R div 3, R div 3, Col);
  OutlineCircle(Buf, CX - R div 6, CY - R div 3, Max(2, R div 10), Col);
  OutlineCircle(Buf, CX + R div 6, CY - R div 3, Max(2, R div 10), Col);
end;

procedure DrawAnswer(Buf: TPixelBuffer; CX, CY, R: Integer; Fg, Glow: TColor; Scale: Integer);
var
  S: string;
  W: Integer;
begin
  S := '42';
  W := GlyphTextWidth(S, Scale * 3);
  TextGlow(Buf, CX - W div 2, CY - GlyphTextHeight(Scale * 3) div 2, S, Glow, Fg, Scale * 3);
  OutlineCircle(Buf, CX, CY, R, Fg);
end;

procedure DrawMagrathea(Buf: TPixelBuffer; CX, CY, R: Integer; Col: TColor);
begin
  OutlineCircle(Buf, CX, CY, R, Col);
  { A flattened ring — the planet-builder's showroom. }
  LineTo(Buf, CX - R - R div 3, CY, CX + R + R div 3, CY, Col);
  LineTo(Buf, CX - R, CY + R div 6, CX + R, CY + R div 6, Col);
  LineTo(Buf, CX - R div 2, CY - R div 2, CX - R div 4, CY - R div 8, Col);
  LineTo(Buf, CX + R div 5, CY - R div 3, CX + R div 2, CY, Col);
end;

procedure DrawBlaster(Buf: TPixelBuffer; CX, CY, R: Integer; Col: TColor);
begin
  LineTo(Buf, CX - R div 2, CY - R, CX + R div 2, CY - R, Col);
  LineTo(Buf, CX - R div 2, CY - R, CX - R div 6, CY, Col);
  LineTo(Buf, CX + R div 2, CY - R, CX + R div 6, CY, Col);
  LineTo(Buf, CX - R div 6, CY, CX + R div 6, CY, Col);
  VLine(Buf, CX, CY, R, Col);
  HLine(Buf, CX - R div 3, CY + R, (2 * R) div 3, Col);
  OutlineCircle(Buf, CX - R div 3, CY - R + R div 4, Max(2, R div 10), Col);
end;

procedure DrawGuideBook(Buf: TPixelBuffer; CX, CY, R: Integer; Col, Yellow: TColor; Scale: Integer);
var
  W: Integer;
begin
  FrameRect(Buf, CX - R, CY - R, R * 2, R * 2, Col);
  FrameRect(Buf, CX - R + 3, CY - R + 3, R * 2 - 6, R * 2 - 6, Col);
  W := GlyphTextWidth('DON''T', Scale);
  TextAt(Buf, CX - W div 2, CY - 8 * Scale, 'DON''T', Yellow, Scale);
  W := GlyphTextWidth('PANIC', Scale);
  TextAt(Buf, CX - W div 2, CY + 2, 'PANIC', Yellow, Scale);
end;

procedure DrawTea(Buf: TPixelBuffer; CX, CY, R: Integer; Col: TColor);
var
  I: Integer;
begin
  FrameRect(Buf, CX - R div 2, CY - R div 3, R, R, Col);
  LineTo(Buf, CX + R div 2, CY - R div 6, CX + R, CY - R div 8, Col);
  LineTo(Buf, CX + R, CY - R div 8, CX + R, CY + R div 3, Col);
  LineTo(Buf, CX + R, CY + R div 3, CX + R div 2, CY + R div 4, Col);
  for I := 0 to 2 do
    LineTo(Buf, CX - R div 6 + I * (R div 6), CY - R div 3 - 2,
      CX - R div 8 + I * (R div 6), CY - R + I, Col);
end;

procedure DrawArt(Buf: TPixelBuffer; const Lay: TGuideLayout; Art: TGuideArt;
  Green, Dim, Yellow, GlowY: TColor);
var
  CX, CY, R: Integer;
begin
  if Lay.ArtW < 8 then
    Exit;
  CX := Lay.ArtX + Lay.ArtW div 2;
  CY := Lay.ArtY + Lay.ArtH div 2;
  R := Lay.ArtW div 3;
  case Art of
    gaEarth: DrawEarth(Buf, CX, CY, R, Green);
    gaFish: DrawFish(Buf, CX, CY, R, Green);
    gaTowel: DrawTowel(Buf, CX, CY, R, Green);
    gaVogon: DrawVogon(Buf, CX, CY, R, Green);
    gaAnswer: DrawAnswer(Buf, CX, CY, R, Yellow, GlowY, Lay.Scale);
    gaMagrathea: DrawMagrathea(Buf, CX, CY, R, Green);
    gaBlaster: DrawBlaster(Buf, CX, CY, R, Green);
    gaGuide: DrawGuideBook(Buf, CX, CY, R, Green, Yellow, Max(1, Lay.Scale));
    gaTea: DrawTea(Buf, CX, CY, R, Green);
  end;
end;

procedure DrawSearch(Buf: TPixelBuffer; const Lay: TGuideLayout;
  Tick: Integer; Green, Dim: TColor);
var
  CX, CY, R, I, Pulse: Integer;
  Dots: string;
  W: Integer;
  S: Integer;
begin
  S := Lay.Scale;
  CX := Lay.ContentX + Lay.ContentW div 2;
  CY := Lay.ContentY + Lay.ContentH div 2;
  Pulse := (Tick mod 8) * (2 * S);
  for I := 0 to 3 do
  begin
    R := 12 * S + I * 10 * S + Pulse;
    FrameRect(Buf, CX - R, CY - R div 2, R * 2, R, Green);
  end;
  Dots := 'RESEARCHING' + StringOfChar('.', (Tick div 3) mod 4);
  W := GlyphTextWidth(Dots, S);
  TextAt(Buf, CX - W div 2, CY - 4 * S, Dots, Green, S);
  TextAt(Buf, CX - GlyphTextWidth('please wait', S) div 2,
    CY + 8 * S, 'please wait', Dim, S);
end;

procedure RenderGuide(Buf: TPixelBuffer; Model: TGuideModel; HoverIndex: Integer);
var
  Lay: TGuideLayout;
  Green, Dim, Yellow, GlowY, Bg, RowBg: TColor;
  Pulse: Integer;
  Banner, TitleLine, SubLine, Footer, LabelN: string;
  I, TX, TY, MaxChars, BodyW: Integer;
  Entry: TGuideEntry;
  Lines: TLineArray;
  Shown: string;
  CursorOn: Boolean;
begin
  Lay := MakeGuideLayout(Buf.Width, Buf.Height);
  Pulse := Model.Flicker;
  { Phosphor green #33FF33 with a tiny pulse so the tube never quite sits still. }
  Green := C(40 + Pulse * 2, 230 + Pulse, 40 + Pulse * 2);
  Dim := C(24, 140, 24);
  Yellow := C(255, 204, 0);
  GlowY := C(80, 50, 0);
  Bg := C(4, 8, 4);
  Buf.Clear(Bg.R, Bg.G, Bg.B, 255);

  FrameRect(Buf, Lay.FrameX, Lay.FrameY, Lay.FrameW, Lay.FrameH, Green);
  FrameRect(Buf, Lay.FrameX + Lay.Scale, Lay.FrameY + Lay.Scale,
    Lay.FrameW - 2 * Lay.Scale, Lay.FrameH - 2 * Lay.Scale, Dim);

  Banner := '*** DON''T PANIC ***';
  TX := Lay.BannerX + (Lay.BannerW - GlyphTextWidth(Banner, Lay.Scale * 2)) div 2;
  if TX < Lay.BannerX then
    TX := Lay.BannerX;
  TextFit(Buf, Lay.BannerX, Lay.BannerY, 'THE HITCH-HIKER''S GUIDE TO THE GALAXY',
    Dim, Lay.Scale, Lay.BannerW);
  TextGlow(Buf, TX, Lay.BannerY + 8 * Lay.Scale + 3 * Lay.Scale, Banner,
    GlowY, Yellow, Lay.Scale * 2);
  HLine(Buf, Lay.FrameX + 4 * Lay.Scale,
    Lay.BannerY + Lay.BannerH - Lay.Scale,
    Lay.FrameW - 8 * Lay.Scale, Dim);

  { Index column — clickable names, current page marked with a caret. }
  for I := 0 to GuideEntryCount - 1 do
  begin
    TY := Lay.IndexY + I * Lay.IndexRowH;
    if I = HoverIndex then
    begin
      RowBg := C(8, 28, 8);
      FillRect(Buf, Lay.IndexX, TY, Lay.IndexW - Lay.Scale, Lay.IndexRowH - Lay.Scale, RowBg);
    end;
    if I = Model.Index then
      LabelN := '>' + IntToStr(I + 1) + ' '
    else
      LabelN := ' ' + IntToStr(I + 1) + ' ';
    LabelN := LabelN + Model.TitleOf(I);
    if I = Model.Index then
      TextFit(Buf, Lay.IndexX + Lay.Scale, TY + Lay.Scale, LabelN, Yellow, Lay.Scale,
        Lay.IndexW - 2 * Lay.Scale)
    else
      TextFit(Buf, Lay.IndexX + Lay.Scale, TY + Lay.Scale, LabelN, Green, Lay.Scale,
        Lay.IndexW - 2 * Lay.Scale);
  end;

  { Wipe any index overflow so the article well is clean, then the divider. }
  FillRect(Buf, Lay.ContentX - 3 * Lay.Scale, Lay.IndexY,
    Lay.ContentW + 3 * Lay.Scale, Lay.IndexH, Bg);
  VLine(Buf, Lay.ContentX - 2 * Lay.Scale, Lay.IndexY, Lay.IndexH, Dim);

  Entry := Model.Current;
  if Model.Phase = gpSearching then
    DrawSearch(Buf, Lay, Model.PhaseTick, Green, Dim)
  else
  begin
    TitleLine := '> ' + Entry.Title;
    TextGlow(Buf, Lay.ContentX, Lay.ContentY, TitleLine, Dim, Green, Lay.Scale * 2);
    SubLine := '[' + Entry.SubTitle + ']';
    TextFit(Buf, Lay.ContentX, Lay.ContentY + 8 * Lay.Scale * 2 + 2 * Lay.Scale,
      SubLine, Dim, Lay.Scale, Lay.ContentW);
    DrawArt(Buf, Lay, Entry.Art, Green, Dim, Yellow, GlowY);

    Shown := Model.VisibleBody;
    BodyW := Lay.ContentW;
    if Lay.ArtW > 0 then
      BodyW := Lay.ArtX - Lay.ContentX - 4 * Lay.Scale;
    MaxChars := BodyW div (8 * Lay.Scale);
    if MaxChars < 8 then
      MaxChars := 8;
    Lines := WrapBody(Shown, MaxChars);
    TY := Lay.ContentY + 8 * Lay.Scale * 3 + 6 * Lay.Scale;
    for I := 0 to High(Lines) do
    begin
      if TY + 8 * Lay.Scale > Lay.ContentY + Lay.ContentH then
        Break;
      TextAt(Buf, Lay.ContentX, TY, Lines[I], Green, Lay.Scale);
      Inc(TY, 8 * Lay.Scale + 2 * Lay.Scale);
    end;
    CursorOn := (Model.Phase = gpTyping) and ((Model.Flicker and 1) = 0);
    if CursorOn then
      FillRect(Buf, Lay.ContentX, TY, 8 * Lay.Scale, 8 * Lay.Scale, Green);
  end;

  Footer := Format('Entry %d/%d  LEFT/RIGHT  1-%d  F11  ESC',
    [Model.Index + 1, GuideEntryCount, GuideEntryCount]);
  TextFit(Buf, Lay.FrameX + 4 * Lay.Scale, Lay.FooterY, Footer, Yellow, Lay.Scale,
    Lay.FrameW - 8 * Lay.Scale);

  DarkenScanlines(Buf, Model.ScanlineOffset);
end;

end.
