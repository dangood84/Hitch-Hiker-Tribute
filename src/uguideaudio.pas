unit uguideaudio;

{$mode objfpc}{$H+}

{ Original 8-bit PCM stings for the 1981 Guide CRT. Not the BBC TV
  soundtrack — those cues are still theirs. Search is a stuttering
  computer chirp; Found is a two-note "page ready" beep; Type is a
  short electronic pip per letter, in the spirit of the series readout. }

interface

uses
  SysUtils, SyncObjs;

const
  GuideSfxRate = 22050; { 16-bit mono. Hosts keep one stream open at this rate. }

type
  TSfxKind = (sfxNone, sfxSearch, sfxFound, sfxType);

  { Mixes the three cues into a live 22050 Hz stream. Trigger starts a
    voice at the next slice the host asks for — there is no backlog, so
    a pip cannot sit behind earlier audio and drift away from its letter. }
  TGuideMixer = class
  private
    FLock: TCriticalSection;
    FPcm: array[sfxSearch..sfxType] of array of SmallInt;
    FKind: array[0..7] of TSfxKind;
    FPos: array[0..7] of Integer;
    FOn: array[0..7] of Boolean;
    FRelease: array[0..7] of Integer; { -1 sustains; else samples left in the fade }
    procedure LoadKind(Kind: TSfxKind);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Trigger(Kind: TSfxKind);
    procedure Render(Dest: PSmallInt; Frames: Integer);
    function ActiveVoices: Integer;
  end;

function BuildSfxWav(Kind: TSfxKind): TBytes;
function SfxName(Kind: TSfxKind): string;

implementation

uses
  Math;

const
  Rate = GuideSfxRate;

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
const
  Dur = 1.50; { longer than RESEARCHING; the found beep cuts it }
var
  Samples, I: Integer;
  T, Hz, Env, Gate, Acc, Phase: Double;
begin
  { Rising 18 Hz stutter for the whole hunt. Pitch keeps climbing.
    The found beep is the landing: the mixer fades this voice into it,
    instead of the sweep turning around and stopping short. }
  Samples := Round(Rate * Dur);
  Result := nil;
  WriteWavHeader(Result, Samples);
  Phase := 0;
  for I := 0 to Samples - 1 do
  begin
    T := I / Rate;
    Hz := 480 + T * 900; { still rising when the gong arrives, up near D6 }
    Gate := 1;
    if Frac(T * 18) > 0.55 then
      Gate := 0;
    Env := 0.52 * Gate;
    if T < 0.02 then
      Env := Env * (T / 0.02);
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

procedure TGuideMixer.LoadKind(Kind: TSfxKind);
var
  Wav: TBytes;
  Samples, I: Integer;
begin
  Wav := BuildSfxWav(Kind);
  Samples := (Length(Wav) - 44) div 2;
  if Samples < 1 then
  begin
    SetLength(FPcm[Kind], 0);
    Exit;
  end;
  SetLength(FPcm[Kind], Samples);
  for I := 0 to Samples - 1 do
    FPcm[Kind][I] := SmallInt(Word(Wav[44 + I * 2]) or (Word(Wav[45 + I * 2]) shl 8));
end;

constructor TGuideMixer.Create;
var
  Kind: TSfxKind;
  V: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  for Kind := sfxSearch to sfxType do
    LoadKind(Kind);
  for V := 0 to High(FOn) do
  begin
    FOn[V] := False;
    FRelease[V] := -1;
  end;
end;

destructor TGuideMixer.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TGuideMixer.Trigger(Kind: TSfxKind);
var
  V, Slot, Oldest: Integer;
begin
  if (Kind < sfxSearch) or (Kind > sfxType) then
    Exit;
  if Length(FPcm[Kind]) < 1 then
    Exit;
  FLock.Enter;
  try
    Slot := -1;
    Oldest := 0;
    for V := 0 to High(FOn) do
      if not FOn[V] then
      begin
        Slot := V;
        Break;
      end
      else if FPos[V] > FPos[Oldest] then
        Oldest := V;
    if Slot < 0 then
      Slot := Oldest; { every voice busy: the one furthest along yields }
    if Kind = sfxFound then
      for V := 0 to High(FOn) do
        if FOn[V] and (FKind[V] = sfxSearch) and (FRelease[V] < 0) then
          FRelease[V] := Round(Rate * 0.05); { State change: hunt yields to the gong. }
    { State change: this cue starts at the next rendered slice.
      It is mixed into the open channel, not parked behind it. }
    FKind[Slot] := Kind;
    FPos[Slot] := 0;
    FOn[Slot] := True;
    FRelease[Slot] := -1;
  finally
    FLock.Leave;
  end;
end;

procedure TGuideMixer.Render(Dest: PSmallInt; Frames: Integer);
var
  V, I, N, P, S: Integer;
  Kind: TSfxKind;
begin
  if (Dest = nil) or (Frames < 1) then
    Exit;
  FillChar(Dest^, Frames * SizeOf(SmallInt), 0);
  FLock.Enter;
  try
    for V := 0 to High(FOn) do
    begin
      if not FOn[V] then
        Continue;
      Kind := FKind[V];
      P := FPos[V];
      N := Frames;
      if P >= Length(FPcm[Kind]) then
        N := 0
      else if P + N > Length(FPcm[Kind]) then
        N := Length(FPcm[Kind]) - P;
      for I := 0 to N - 1 do
      begin
        if FRelease[V] = 0 then
        begin
          N := I; { fade finished inside this slice }
          Break;
        end;
        S := FPcm[Kind][P + I];
        if FRelease[V] > 0 then
        begin
          S := S * FRelease[V] div Round(Rate * 0.05);
          Dec(FRelease[V]);
        end;
        S := Integer(Dest[I]) + S;
        if S > 32767 then
          S := 32767
        else if S < -32768 then
          S := -32768;
        Dest[I] := SmallInt(S);
      end;
      FPos[V] := P + N;
      if (FRelease[V] = 0) or (FPos[V] >= Length(FPcm[Kind])) then
        FOn[V] := False; { State change: this cue has left the channel. }
    end;
  finally
    FLock.Leave;
  end;
end;

function TGuideMixer.ActiveVoices: Integer;
var
  V: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for V := 0 to High(FOn) do
      if FOn[V] then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

end.
