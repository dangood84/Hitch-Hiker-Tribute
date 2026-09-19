unit uguideaudio;

{$mode objfpc}{$H+}

{ Original 8-bit PCM stings for the 1981 Guide CRT. Not the BBC TV
  soundtrack — those cues are still theirs. Search is a stuttering
  computer chirp; Found is a two-note "page ready" beep; Type is a
  short electronic pip per letter, in the spirit of the series readout. }

interface

uses
  SysUtils;

type
  TSfxKind = (sfxNone, sfxSearch, sfxFound, sfxType);

function BuildSfxWav(Kind: TSfxKind): TBytes;
function SfxName(Kind: TSfxKind): string;

implementation

uses
  Math;

const
  Rate = 22050;

procedure WriteWavHeader(var Bytes: TBytes; Samples: Integer);
var
  P: Integer;
begin
  SetLength(Bytes, 44 + Samples * 2);
  FillChar(Bytes[0], Length(Bytes), 0);
  Bytes[0] := Ord('R'); Bytes[1] := Ord('I'); Bytes[2] := Ord('F'); Bytes[3] := Ord('F');
  P := 36 + Samples * 2;
  Bytes[4] := Byte(P); Bytes[5] := Byte(P shr 8);
  Bytes[6] := Byte(P shr 16); Bytes[7] := Byte(P shr 24);
  Bytes[8] := Ord('W'); Bytes[9] := Ord('A'); Bytes[10] := Ord('V'); Bytes[11] := Ord('E');
  Bytes[12] := Ord('f'); Bytes[13] := Ord('m'); Bytes[14] := Ord('t'); Bytes[15] := Ord(' ');
  Bytes[16] := 16;
  Bytes[20] := 1;
  Bytes[22] := 1;
  Bytes[24] := 34; Bytes[25] := 86; { 22050 }
  Bytes[28] := 68; Bytes[29] := 172; { 44100 B/s }
  Bytes[32] := 2;
  Bytes[34] := 16;
  Bytes[36] := Ord('d'); Bytes[37] := Ord('a'); Bytes[38] := Ord('t'); Bytes[39] := Ord('a');
  P := Samples * 2;
  Bytes[40] := Byte(P); Bytes[41] := Byte(P shr 8);
  Bytes[42] := Byte(P shr 16); Bytes[43] := Byte(P shr 24);
end;

procedure PutSample(var Bytes: TBytes; Index: Integer; Amp: Double);
var
  V: SmallInt;
begin
  if Amp > 0.95 then
    Amp := 0.95;
  if Amp < -0.95 then
    Amp := -0.95;
  V := Round(Amp * 32767);
  Bytes[44 + Index * 2] := Byte(V);
  Bytes[45 + Index * 2] := Byte(V shr 8);
end;

function Square(Phase, Duty: Double): Double;
begin
  if Phase < Duty then
    Result := 1
  else
    Result := -1;
end;

function Noise(I: Integer): Double;
begin
  Result := (((I * 1103515245 + 12345) shr 16) and $7FFF) / 16384.0 - 1.0;
end;

function BuildSearchWav: TBytes;
var
  Samples, I: Integer;
  T, Hz, Env, Gate, Acc, Phase: Double;
begin
  { ~0.48 s — sits under RESEARCHING. A rising then falling scan with
    a 18 Hz stutter, the 1981 computer-hunting-the-page chirp. }
  Samples := Round(Rate * 0.48);
  Result := nil;
  WriteWavHeader(Result, Samples);
  Phase := 0;
  for I := 0 to Samples - 1 do
  begin
    T := I / Rate;
    if T < 0.32 then
      Hz := 520 + T * 2800
    else
      Hz := 1400 - (T - 0.32) * 900;
    Gate := 1;
    if Frac(T * 18) > 0.55 then
      Gate := 0;
    Env := 0.52 * Gate;
    if T < 0.02 then
      Env := Env * (T / 0.02);
    if T > 0.40 then
      Env := Env * Max(0, (0.48 - T) / 0.08);
    Phase := Frac(Phase + Hz / Rate);
    Acc := Square(Phase, 0.28) * Env + Noise(I) * Env * 0.12;
    PutSample(Result, I, Acc);
  end;
end;

function BuildFoundWav: TBytes;
var
  Samples, I: Integer;
  T, Hz, Env, Acc, Phase: Double;
begin
  { Two-note "page ready" — G5 then D6, short enough not to fight typing. }
  Samples := Round(Rate * 0.22);
  Result := nil;
  WriteWavHeader(Result, Samples);
  Phase := 0;
  for I := 0 to Samples - 1 do
  begin
    T := I / Rate;
    if T < 0.07 then
    begin
      Hz := 784;
      Env := 0.48;
      if T < 0.01 then
        Env := 0.48 * (T / 0.01);
      if T > 0.05 then
        Env := 0.48 * ((0.07 - T) / 0.02);
    end
    else
    begin
      Hz := 1174.7;
      Env := 0.58;
      if T < 0.08 then
        Env := 0.58 * ((T - 0.07) / 0.01);
      if T > 0.16 then
        Env := 0.58 * Max(0, (0.22 - T) / 0.06);
    end;
    Phase := Frac(Phase + Hz / Rate);
    Acc := Square(Phase, 0.40) * Env;
    PutSample(Result, I, Acc);
  end;
end;

function BuildTypeWav: TBytes;
var
  Samples, I: Integer;
  T, Env, Acc, Phase: Double;
begin
  { ~28 ms clean computer pip — original tribute, not the BBC cue.
    Bright square with a tiny 2nd harmonic, no noise: one per letter. }
  Samples := Round(Rate * 0.028);
  Result := nil;
  WriteWavHeader(Result, Samples);
  Phase := 0;
  for I := 0 to Samples - 1 do
  begin
    T := I / Rate;
    Env := 0.42;
    if T < 0.002 then
      Env := 0.42 * (T / 0.002);
    if T > 0.012 then
      Env := 0.42 * Exp(-(T - 0.012) * 90);
    Phase := Frac(Phase + 1397 / Rate); { F6 — a friendly readout pip }
    Acc := Square(Phase, 0.48) * Env * 0.82 +
           Square(Frac(Phase * 2), 0.48) * Env * 0.18;
    PutSample(Result, I, Acc);
  end;
end;

function BuildSfxWav(Kind: TSfxKind): TBytes;
begin
  case Kind of
    sfxSearch: Result := BuildSearchWav;
    sfxFound: Result := BuildFoundWav;
    sfxType: Result := BuildTypeWav;
    else
      begin
        Result := nil;
        WriteWavHeader(Result, 64);
      end;
  end;
end;

function SfxName(Kind: TSfxKind): string;
begin
  case Kind of
    sfxSearch: Result := 'search';
    sfxFound: Result := 'found';
    sfxType: Result := 'type';
    else
      Result := 'none';
  end;
end;

end.
