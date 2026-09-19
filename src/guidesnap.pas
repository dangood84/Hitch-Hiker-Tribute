program guidesnap;

{$mode objfpc}{$H+}

{ Writes PPM frames of the software canvas (no window, no speaker).
  ShowImmediate clears the sfx queue. Usage: guidesnap out-dir }

uses
  SysUtils, uguidemodel, uguideapp;

procedure WritePPM(const Path: string; C: TGuideController);
var
  F: File;
  X, Y: Integer;
  P: PByte;
  RGB: array[0..2] of Byte;
  Header: string;
begin
  C.Render;
  Header := Format('P6'#10'%d %d'#10'255'#10, [C.Canvas.Width, C.Canvas.Height]);
  AssignFile(F, Path);
  Rewrite(F, 1);
  BlockWrite(F, Header[1], Length(Header));
  for Y := 0 to C.Canvas.Height - 1 do
  begin
    P := C.Canvas.Ptr + Y * C.Canvas.Width * 4;
    for X := 0 to C.Canvas.Width - 1 do
    begin
      RGB[0] := P[0];
      RGB[1] := P[1];
      RGB[2] := P[2]; { drop alpha — PPM is RGB only }
      BlockWrite(F, RGB[0], 3);
      Inc(P, 4);
    end;
  end;
  CloseFile(F);
end;

var
  Dir: string;
  C: TGuideController;
  I: Integer;
begin
  if ParamCount >= 1 then
    Dir := ParamStr(1)
  else
    Dir := 'build';
  ForceDirectories(Dir);
  C := TGuideController.Create(1520, 1080); { 2× of the 760×540 point window }
  try
    C.ShowImmediate(0);
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-earth.ppm', C);

    C.KeyPress(gkJump5);
    { Mid-search: concentric RESEARCHING frame, The Answer already selected. }
    for I := 1 to 8 do
      C.Tick;
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-search.ppm', C);

    C.ShowImmediate(4);
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-42.ppm', C);

    C.Resize(1920, 800);
    C.ShowImmediate(2);
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-wide.ppm', C);
  finally
    C.Free;
  end;
end.
