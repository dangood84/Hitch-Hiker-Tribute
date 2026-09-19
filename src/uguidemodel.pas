unit uguidemodel;

{$mode objfpc}{$H+}

{ Encyclopedia state. No pixels, no Cocoa/Win32/GTK.

  The Guide is a small array of entries plus a three-phase page turn:
    idle       — the current article sits on the phosphor
    searching  — "RESEARCHING" while the new page is fetched
    typing     — the body ticks onto the screen, 1981 TV-series style

  Tick() advances scanlines always, and the phase timers when a page
  turn is in flight. Hosts never mutate FIndex themselves.

  Audio is queued here (search chirp, page-found beep) so the renderer
  never starts a sound. Hosts DrainSfx and play the in-memory WAVs. }

interface

uses
  SysUtils, uguideaudio;

const
  GuideEntryCount = 9;
  SearchTicks = 18;     { ~0.9 s at a 50 ms host timer }
  CharsPerTick = 1;     { one glyph, one pip — 1981 readout cadence }
  ScanlinePeriod = 4;

type
  TGuidePhase = (gpIdle, gpSearching, gpTyping);

  TGuideArt = (
    gaEarth, gaFish, gaTowel, gaVogon, gaAnswer,
    gaMagrathea, gaBlaster, gaGuide, gaTea
  );

  TGuideEntry = record
    Title: string;
    ShortTitle: string;
    SubTitle: string;
    Body: string;
    Art: TGuideArt;
  end;

  TGuideKey = (
    gkNone, gkNext, gkPrev, gkJump1, gkJump2, gkJump3,
    gkJump4, gkJump5, gkJump6, gkJump7, gkJump8, gkJump9
  );

  TGuideModel = class
  private
    FEntries: array[0..GuideEntryCount - 1] of TGuideEntry;
    FIndex: Integer;
    FPhase: TGuidePhase;
    FPhaseTick: Integer;
    FVisibleChars: Integer;
    FScanlineOffset: Integer;
    FFlicker: Integer;
    FFrozen: Boolean;
    FSfx: array[0..7] of TSfxKind;
    FSfxCount: Integer;
    procedure LoadEntries;
    procedure BeginSearch(NewIndex: Integer);
    procedure PushSfx(Kind: TSfxKind);
  public
    constructor Create;
    procedure Tick;
    procedure Press(Key: TGuideKey);
    procedure SelectIndex(NewIndex: Integer);
    procedure ShowImmediate(NewIndex: Integer);
    procedure Freeze;
    function Current: TGuideEntry;
    function TitleOf(AIndex: Integer): string;
    function VisibleBody: string;
    function JumpKeyIndex(Key: TGuideKey): Integer;
    function DrainSfx(out Kind: TSfxKind): Boolean;
    property Index: Integer read FIndex;
    property Phase: TGuidePhase read FPhase;
    property PhaseTick: Integer read FPhaseTick;
    property VisibleChars: Integer read FVisibleChars;
    property ScanlineOffset: Integer read FScanlineOffset;
    property Flicker: Integer read FFlicker;
    property Frozen: Boolean read FFrozen;
  end;

function GuideEntryCountValue: Integer;
function GuideKeyFromJump(N: Integer): TGuideKey;

implementation

function GuideEntryCountValue: Integer;
begin
  Result := GuideEntryCount;
end;

function GuideKeyFromJump(N: Integer): TGuideKey;
begin
  { 1-based entry number from a keyboard digit. Out of range → gkNone. }
  case N of
    1: Result := gkJump1;
    2: Result := gkJump2;
    3: Result := gkJump3;
    4: Result := gkJump4;
    5: Result := gkJump5;
    6: Result := gkJump6;
    7: Result := gkJump7;
    8: Result := gkJump8;
    9: Result := gkJump9;
    else
      Result := gkNone;
  end;
end;

constructor TGuideModel.Create;
begin
  inherited Create;
  LoadEntries;
  FIndex := 0;
  FPhase := gpIdle;
  FPhaseTick := 0;
  FVisibleChars := Length(FEntries[0].Body);
  FScanlineOffset := 0;
  FFlicker := 0;
  FFrozen := False;
  FSfxCount := 0;
end;

procedure TGuideModel.LoadEntries;
begin
  { Tribute paraphrases, not book text. Short famous labels stay because
    they *are* the 1981 cover: DON'T PANIC, Mostly harmless, Forty-two. }

  FEntries[0].Title := 'EARTH';
  FEntries[0].ShortTitle := '';
  FEntries[0].SubTitle := 'Sector ZZ9 Plural Z Alpha';
  FEntries[0].Art := gaEarth;
  FEntries[0].Body :=
    'A small, unregarded world. An early edition of the Guide listed it ' +
    'in a single word: Harmless. A later field researcher, after a much ' +
    'longer stay, filed the revised entry that stuck: Mostly harmless.';

  FEntries[1].Title := 'BABEL FISH';
  FEntries[1].ShortTitle := '';
  FEntries[1].SubTitle := 'Small, yellow, leech-like';
  FEntries[1].Art := gaFish;
  FEntries[1].Body :=
    'Place one in your ear. Brainwave energy goes in; a telepathic ' +
    'matrix comes out. The practical upshot is instant translation of ' +
    'any spoken language. Evolution''s least probable coincidence, and ' +
    'a favourite argument of certain theologians.';

  FEntries[2].Title := 'TOWEL';
  FEntries[2].ShortTitle := '';
  FEntries[2].SubTitle := 'Most massively useful';
  FEntries[2].Art := gaTowel;
  FEntries[2].Body :=
    'Dry, damp, or worn as a cape, a towel is the hitchhiker''s badge ' +
    'of competence. Anyone who can be seen to know where their towel ' +
    'is, is a hitchhiker to be reckoned with. Keep it. Never lend it ' +
    'to a Vogon.';

  FEntries[3].Title := 'VOGON POETRY';
  FEntries[3].ShortTitle := 'VOGON POEM';
  FEntries[3].SubTitle := 'Third worst in the Universe';
  FEntries[3].Art := gaVogon;
  FEntries[3].Body :=
    'Readings are a recognised form of interstellar torture. Do not ' +
    'make eye contact with the reader. Do not applaud. Do not, under ' +
    'any circumstances, stay for an encore. The second worst poetry is ' +
    'that of the Azgoths of Kria. The very worst has never been published.';

  FEntries[4].Title := 'THE ANSWER';
  FEntries[4].ShortTitle := 'ANSWER';
  FEntries[4].SubTitle := 'Deep Thought Supercomputer';
  FEntries[4].Art := gaAnswer;
  FEntries[4].Body :=
    'After seven and a half million years of thought, Deep Thought ' +
    'produced the Answer to the Ultimate Question of Life, the Universe, ' +
    'and Everything.' + LineEnding + LineEnding +
    'Forty-two.' + LineEnding + LineEnding +
    'The Question, unfortunately, was never properly known.';

  FEntries[5].Title := 'MAGRATHEA';
  FEntries[5].ShortTitle := '';
  FEntries[5].SubTitle := 'Planet of planet-builders';
  FEntries[5].Art := gaMagrathea;
  FEntries[5].Body :=
    'A legendary workshop world, long rumoured closed, where custom ' +
    'planets were designed for the very rich. Fjords extra. The Guide''s ' +
    'own maps still mark it as a myth, which is usually a hint that it ' +
    'is both real and expensive.';

  FEntries[6].Title := 'GARGLE BLASTER';
  FEntries[6].ShortTitle := 'BLASTER';
  FEntries[6].SubTitle := 'Pan Galactic, well shaken';
  FEntries[6].Art := gaBlaster;
  FEntries[6].Body :=
    'The best drink in existence, according to the Guide. The effect ' +
    'has been compared to a citrus-scented brick meeting the inside of ' +
    'the skull at speed. Sip. Do not operate heavy spacecraft afterwards.';

  FEntries[7].Title := 'THE GUIDE';
  FEntries[7].ShortTitle := 'GUIDE';
  FEntries[7].SubTitle := 'Standard repository of knowledge';
  FEntries[7].Art := gaGuide;
  FEntries[7].Body :=
    'Slightly cheaper than the Encyclopedia Galactica, and a good deal ' +
    'more entertaining. On the cover, in large friendly letters, are ' +
    'the words DON''T PANIC. That is the whole of the law, as far as ' +
    'this edition is concerned.';

  FEntries[8].Title := 'TEA';
  FEntries[8].ShortTitle := '';
  FEntries[8].SubTitle := 'Nutri-Matic assignment, pending';
  FEntries[8].Art := gaTea;
  FEntries[8].Body :=
    'A beverage of extraordinary importance to certain carbon-based ' +
    'life forms. The Nutri-Matic Drink Synthesizer has never quite ' +
    'understood the assignment, and will cheerfully offer almost ' +
    'anything else. Sit. Breathe. The kettle, at least, is honest.';
end;

procedure TGuideModel.BeginSearch(NewIndex: Integer);
begin
  if (NewIndex < 0) or (NewIndex > High(FEntries)) then
    Exit;
  if (NewIndex = FIndex) and (FPhase = gpIdle) then
    Exit; { already looking at this page; do not restart the fanfare }
  { State change: idle/typing/searching → researching a (possibly new) page. }
  FIndex := NewIndex;
  FPhase := gpSearching;
  FPhaseTick := 0;
  FVisibleChars := 0;
  PushSfx(sfxSearch); { computer-hunting-the-page chirp }
end;

procedure TGuideModel.SelectIndex(NewIndex: Integer);
begin
  BeginSearch(NewIndex);
end;

procedure TGuideModel.ShowImmediate(NewIndex: Integer);
begin
  if (NewIndex < 0) or (NewIndex > High(FEntries)) then
    Exit;
  { State change: skip the page-turn animation (snaps, tests, first paint). }
  FIndex := NewIndex;
  FPhase := gpIdle;
  FPhaseTick := 0;
  FVisibleChars := Length(FEntries[FIndex].Body);
  FSfxCount := 0; { snaps must not leave a chirp queued }
end;

procedure TGuideModel.Freeze;
begin
  { State change: live CRT → frozen pose. Tick will still be called by
    snaps that want a particular scanline, but time will not advance. }
  FFrozen := True;
end;

procedure TGuideModel.Tick;
var
  BodyLen: Integer;
begin
  if FFrozen then
    Exit;
  Inc(FScanlineOffset);
  if FScanlineOffset >= ScanlinePeriod then
    FScanlineOffset := 0;
  FFlicker := (FFlicker + 1) mod 8;

  case FPhase of
    gpSearching:
      begin
        Inc(FPhaseTick);
        if FPhaseTick >= SearchTicks then
        begin
          { State change: researching → typing the found entry.
            Body stays empty this tick so the found beep is not
            mixed with the first letter's pip. }
          FPhase := gpTyping;
          FPhaseTick := 0;
          FVisibleChars := 0;
          PushSfx(sfxFound); { two-note "page ready" before the letters }
        end;
      end;
    gpTyping:
      begin
        BodyLen := Length(FEntries[FIndex].Body);
        Inc(FVisibleChars, CharsPerTick);
        { State change: one more glyph lands — a series-style pip. }
        PushSfx(sfxType);
        if FVisibleChars >= BodyLen then
        begin
          { State change: typing finished → idle phosphor page. }
          FVisibleChars := BodyLen;
          FPhase := gpIdle;
        end;
      end;
    gpIdle:
      ; { scanlines and flicker still move; the text does not }
  end;
end;

procedure TGuideModel.Press(Key: TGuideKey);
var
  Jump: Integer;
begin
  case Key of
    gkNone:
      Exit;
    gkNext:
      begin
        Jump := FIndex + 1;
        if Jump > High(FEntries) then
          Jump := 0; { wrap: last page → Earth again }
        BeginSearch(Jump);
      end;
    gkPrev:
      begin
        Jump := FIndex - 1;
        if Jump < 0 then
          Jump := High(FEntries);
        BeginSearch(Jump);
      end;
    gkJump1..gkJump9:
      begin
        Jump := Ord(Key) - Ord(gkJump1);
        if Jump <= High(FEntries) then
          BeginSearch(Jump);
      end;
  end;
end;

function TGuideModel.Current: TGuideEntry;
begin
  Result := FEntries[FIndex];
end;

function TGuideModel.TitleOf(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex > High(FEntries)) then
    Exit('');
  if FEntries[AIndex].ShortTitle <> '' then
    Result := FEntries[AIndex].ShortTitle
  else
    Result := FEntries[AIndex].Title;
end;

function TGuideModel.VisibleBody: string;
var
  N: Integer;
  Body: string;
begin
  Body := FEntries[FIndex].Body;
  if FPhase = gpSearching then
    Exit('');
  N := FVisibleChars;
  if N < 0 then
    N := 0;
  if N > Length(Body) then
    N := Length(Body);
  Result := Copy(Body, 1, N);
end;

function TGuideModel.JumpKeyIndex(Key: TGuideKey): Integer;
begin
  if (Key >= gkJump1) and (Key <= gkJump9) then
    Result := Ord(Key) - Ord(gkJump1)
  else
    Result := -1;
end;

procedure TGuideModel.PushSfx(Kind: TSfxKind);
begin
  if Kind = sfxNone then
    Exit;
  if FSfxCount >= Length(FSfx) then
    Exit;
  FSfx[FSfxCount] := Kind;
  Inc(FSfxCount);
end;

function TGuideModel.DrainSfx(out Kind: TSfxKind): Boolean;
var
  I: Integer;
begin
  Result := FSfxCount > 0;
  if not Result then
  begin
    Kind := sfxNone;
    Exit;
  end;
  Kind := FSfx[0];
  for I := 1 to FSfxCount - 1 do
    FSfx[I - 1] := FSfx[I];
  Dec(FSfxCount);
end;

end.
