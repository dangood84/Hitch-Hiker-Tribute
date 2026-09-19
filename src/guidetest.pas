program guidetest;

{$mode objfpc}{$H+}

{ Headless checks for uguidemodel. No GUI. Run with: make test }

uses
  SysUtils, uguidemodel, uguideaudio;

var
  Failed: Integer;

procedure ExpectEq(const Name: string; Got, Want: Integer);
begin
  if Got <> Want then
  begin
    Inc(Failed);
    WriteLn('FAIL  ', Name, ': got ', Got, ' want ', Want);
  end
  else
    WriteLn('ok    ', Name);
end;

procedure ExpectStr(const Name, Got, Want: string);
begin
  if Got <> Want then
  begin
    Inc(Failed);
    WriteLn('FAIL  ', Name, ': got "', Got, '" want "', Want, '"');
  end
  else
    WriteLn('ok    ', Name);
end;

procedure ExpectTrue(const Name: string; Cond: Boolean);
begin
  if Cond then
    WriteLn('ok    ', Name)
  else
  begin
    Inc(Failed);
    WriteLn('FAIL  ', Name);
  end;
end;

procedure ExpectPhase(const Name: string; Got, Want: TGuidePhase);
begin
  if Got <> Want then
  begin
    Inc(Failed);
    WriteLn('FAIL  ', Name);
  end
  else
    WriteLn('ok    ', Name);
end;

procedure Run;
var
  M: TGuideModel;
  I, TypeCount: Integer;
  Kind: TSfxKind;
  Wav: TBytes;
  SawSearch, SawFound: Boolean;
begin
  Failed := 0;
  M := TGuideModel.Create;
  try
    ExpectEq('entry count', GuideEntryCountValue, 9);
    ExpectEq('starts on Earth', M.Index, 0);
    ExpectStr('Earth title', M.Current.Title, 'EARTH');
    ExpectPhase('starts idle', M.Phase, gpIdle);
    ExpectTrue('Earth body fully visible', M.VisibleChars = Length(M.Current.Body));
    ExpectTrue('Earth mentions harmless', Pos('harmless', LowerCase(M.Current.Body)) > 0);
    ExpectTrue('no sfx at boot', not M.DrainSfx(Kind));

    ExpectTrue('sfx search name', SfxName(sfxSearch) = 'search');
    ExpectTrue('sfx found name', SfxName(sfxFound) = 'found');
    ExpectTrue('sfx type name', SfxName(sfxType) = 'type');
    Wav := BuildSfxWav(sfxSearch);
    ExpectTrue('search wav header', (Length(Wav) > 44) and (Chr(Wav[0]) = 'R'));
    Wav := BuildSfxWav(sfxFound);
    ExpectTrue('found wav size', Length(Wav) > 1000);
    Wav := BuildSfxWav(sfxType);
    ExpectTrue('type wav is a pip', Length(Wav) > 44);

    M.Press(gkNext);
    ExpectEq('next is Babel Fish', M.Index, 1);
    ExpectPhase('next starts search', M.Phase, gpSearching);
    ExpectEq('search hides body', Length(M.VisibleBody), 0);
    ExpectTrue('search queues chirp', M.DrainSfx(Kind) and (Kind = sfxSearch));
    ExpectTrue('search does not also queue found', not M.DrainSfx(Kind));

    for I := 1 to SearchTicks do
      M.Tick;
    ExpectPhase('search becomes typing', M.Phase, gpTyping);
    ExpectEq('found beep before first letter', M.VisibleChars, 0);
    ExpectTrue('typing queues found beep', M.DrainSfx(Kind) and (Kind = sfxFound));

    M.Tick;
    ExpectEq('first letter', M.VisibleChars, 1);
    ExpectTrue('first letter pips', M.DrainSfx(Kind) and (Kind = sfxType));

    TypeCount := 0;
    while M.Phase = gpTyping do
    begin
      M.Tick;
      while M.DrainSfx(Kind) do
        if Kind = sfxType then
          Inc(TypeCount);
    end;
    ExpectPhase('typing becomes idle', M.Phase, gpIdle);
    ExpectStr('Babel title', M.Current.Title, 'BABEL FISH');
    ExpectTrue('Babel body complete', M.VisibleChars = Length(M.Current.Body));
    ExpectTrue('more letter pips', TypeCount > 8);
    ExpectTrue('idle types no extra sfx', not M.DrainSfx(Kind));

    M.ShowImmediate(0);
    ExpectEq('immediate Earth', M.Index, 0);
    ExpectPhase('immediate is idle', M.Phase, gpIdle);
    ExpectTrue('immediate clears sfx', not M.DrainSfx(Kind));

    M.Press(gkPrev);
    ExpectEq('prev wraps to Tea', M.Index, GuideEntryCount - 1);
    ExpectStr('Tea title', M.Current.Title, 'TEA');
    while M.DrainSfx(Kind) do
      ;

    M.ShowImmediate(GuideEntryCount - 1);
    M.Press(gkNext);
    ExpectEq('next wraps to Earth', M.Index, 0);
    while M.DrainSfx(Kind) do
      ;

    M.Press(gkJump5);
    ExpectEq('key 5 is The Answer', M.Index, 4);
    ExpectStr('Answer title', M.Current.Title, 'THE ANSWER');
    ExpectTrue('Answer mentions forty-two',
      Pos('Forty-two', M.Current.Body) > 0);
    SawSearch := False;
    SawFound := False;
    while M.DrainSfx(Kind) do
      if Kind = sfxSearch then
        SawSearch := True
      else if Kind = sfxFound then
        SawFound := True;
    ExpectTrue('jump queues search', SawSearch);
    ExpectTrue('jump does not found yet', not SawFound);

    M.ShowImmediate(4);
    M.Press(gkJump5);
    ExpectPhase('reselect same idle page is ignored', M.Phase, gpIdle);
    ExpectTrue('reselect queues no sfx', not M.DrainSfx(Kind));

    ExpectEq('jump key 1', M.JumpKeyIndex(gkJump1), 0);
    ExpectEq('jump key 9', M.JumpKeyIndex(gkJump9), 8);
    ExpectEq('next is not a jump', M.JumpKeyIndex(gkNext), -1);
    ExpectTrue('GuideKeyFromJump 0 is none', GuideKeyFromJump(0) = gkNone);
    ExpectTrue('GuideKeyFromJump 10 is none', GuideKeyFromJump(10) = gkNone);

    M.Freeze;
    I := M.ScanlineOffset;
    M.Tick;
    ExpectEq('frozen tick does not crawl', M.ScanlineOffset, I);
    ExpectTrue('frozen flag', M.Frozen);
    ExpectTrue('frozen tick queues no sfx', not M.DrainSfx(Kind));

    ExpectStr('title of 7', M.TitleOf(7), 'GUIDE');
    ExpectStr('title of -1', M.TitleOf(-1), '');
  finally
    M.Free;
  end;
end;

begin
  Run;
  if Failed > 0 then
  begin
    WriteLn(Failed, ' test(s) failed.');
    Halt(1);
  end;
  WriteLn('All guide tests passed.');
end.
