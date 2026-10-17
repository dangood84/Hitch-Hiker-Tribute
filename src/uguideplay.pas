unit uguideplay;

{$mode objfpc}{$H+}

{ One open playback stream for the life of the tube.

  The NoBugs ladybird on a Panasonic television taught this: a fresh
  player for every line lets the HDMI port fall asleep, so the first
  shout is late or missing, and later ones queue up behind that wake.
  The Guide had the same shape — a new NSSound, PlaySound, or paplay
  for every chirp and every letter — so the first index cue stumbled
  and the pips walked away from the scrolling text.

  Here the stream starts while Earth is still on the phosphor, full of
  silence, and stays open. A cue is mixed into the next short slice.
  The slice is small on purpose: a pip has nowhere to queue up, so it
  stays with the letter that asked for it. }

interface

uses
  uguideaudio;

procedure GuidePlayStart;
procedure GuidePlayStop;
procedure GuidePlay(Kind: TSfxKind);

implementation

uses
  SysUtils
  {$IFDEF WINDOWS}
  , Windows, MMSystem, Classes
  {$ENDIF}
  {$IFDEF LINUX}
  , Classes, Process, BaseUnix
  {$ENDIF}
  ;

{$IFDEF DARWIN}
{$linkframework AudioToolbox}
{$ENDIF}

var
  Mixer: TGuideMixer;
  ChannelOpen: Boolean;

procedure GuidePlay(Kind: TSfxKind);
begin
  if Mixer <> nil then
    Mixer.Trigger(Kind);
end;

{$IFDEF DARWIN}

const
  kAudioFormatLinearPCM = UInt32($6C70636D); { 'lpcm' }
  kAudioFormatFlagIsSignedInteger = UInt32(1 shl 2);
  kAudioFormatFlagIsPacked = UInt32(1 shl 3);
  StreamFrames = 256; { ~12 ms. Three of these is the whole queue. }
  StreamBuffers = 3;

type
  AudioQueueRef = Pointer;
  AudioQueueBufferRef = ^TAudioQueueBuffer;
  { Layout measured against AudioToolbox on arm64: 56 bytes, pointers at 8. }
  {$PACKRECORDS 1}
  TAudioQueueBuffer = record
    mAudioDataBytesCapacity: UInt32;
    mPad0: UInt32;
    mAudioData: Pointer;
    mAudioDataByteSize: UInt32;
    mPad1: UInt32;
    mUserData: Pointer;
    mPacketDescriptionCapacity: UInt32;
    mPad2: UInt32;
    mPacketDescriptions: Pointer;
    mPacketDescriptionCount: UInt32;
    mPad3: UInt32;
  end;
  {$PACKRECORDS DEFAULT}
  TAudioStreamBasicDescription = record
    mSampleRate: Double;
    mFormatID: UInt32;
    mFormatFlags: UInt32;
    mBytesPerPacket: UInt32;
    mFramesPerPacket: UInt32;
    mBytesPerFrame: UInt32;
    mChannelsPerFrame: UInt32;
    mBitsPerChannel: UInt32;
    mReserved: UInt32;
  end;

var
  Queue: AudioQueueRef;
  Closing: Boolean;

function AudioQueueNewOutput(Fmt: Pointer; Callback: Pointer; UserData: Pointer;
  RunLoop: Pointer; Mode: Pointer; Flags: UInt32; var OutAQ: AudioQueueRef): Int32; cdecl; external;
function AudioQueueAllocateBuffer(AQ: AudioQueueRef; ByteSize: UInt32;
  var OutBuf: AudioQueueBufferRef): Int32; cdecl; external;
function AudioQueueEnqueueBuffer(AQ: AudioQueueRef; Buf: AudioQueueBufferRef;
  NumDescs: UInt32; Descs: Pointer): Int32; cdecl; external;
function AudioQueueStart(AQ: AudioQueueRef; StartTime: Pointer): Int32; cdecl; external;
function AudioQueueStop(AQ: AudioQueueRef; Immediate: Byte): Int32; cdecl; external;
function AudioQueueDispose(AQ: AudioQueueRef; Immediate: Byte): Int32; cdecl; external;

procedure QueueCallback(UserData: Pointer; AQ: AudioQueueRef; Buf: AudioQueueBufferRef); cdecl;
var
  Frames: Integer;
begin
  if (Buf = nil) or (Buf^.mAudioData = nil) then
    Exit;
  Frames := Integer(Buf^.mAudioDataBytesCapacity) div 2;
  if Frames < 1 then
    Exit;
  if (Mixer = nil) or Closing then
    FillChar(Buf^.mAudioData^, Frames * 2, 0)
  else
    Mixer.Render(PSmallInt(Buf^.mAudioData), Frames);
  Buf^.mAudioDataByteSize := UInt32(Frames * 2);
  if not Closing then
    AudioQueueEnqueueBuffer(AQ, Buf, 0, nil);
end;

procedure GuidePlayStart;
var
  Fmt: TAudioStreamBasicDescription;
  Buf: AudioQueueBufferRef;
  St: Int32;
  I: Integer;
begin
  if ChannelOpen then
    Exit;
  Mixer := TGuideMixer.Create;
  Closing := False;
  FillChar(Fmt, SizeOf(Fmt), 0);
  Fmt.mSampleRate := GuideSfxRate;
  Fmt.mFormatID := kAudioFormatLinearPCM;
  Fmt.mFormatFlags := kAudioFormatFlagIsSignedInteger or kAudioFormatFlagIsPacked;
  Fmt.mBytesPerPacket := 2;
  Fmt.mFramesPerPacket := 1;
  Fmt.mBytesPerFrame := 2;
  Fmt.mChannelsPerFrame := 1;
  Fmt.mBitsPerChannel := 16;
  Queue := nil;
  St := AudioQueueNewOutput(@Fmt, @QueueCallback, nil, nil, nil, 0, Queue);
  if (St <> 0) or (Queue = nil) then
  begin
    Writeln('audio channel did not open');
    Flush(Output);
    FreeAndNil(Mixer);
    Exit;
  end;
  { Prime a few silent slices before anything is clicked, so Core Audio
    wakes on silence. The first index chirp is then just more samples. }
  for I := 1 to StreamBuffers do
  begin
    Buf := nil;
    if AudioQueueAllocateBuffer(Queue, StreamFrames * 2, Buf) <> 0 then
      Break;
    QueueCallback(nil, Queue, Buf);
  end;
  if AudioQueueStart(Queue, nil) <> 0 then
  begin
    Writeln('audio channel did not start');
    Flush(Output);
    AudioQueueDispose(Queue, 1);
    Queue := nil;
    FreeAndNil(Mixer);
    Exit;
  end;
  { State change: speaker asleep → one short queue, already running. }
  ChannelOpen := True;
end;

procedure GuidePlayStop;
begin
  if not ChannelOpen and (Queue = nil) and (Mixer = nil) then
    Exit;
  Closing := True;
  ChannelOpen := False;
  if Queue <> nil then
  begin
    AudioQueueStop(Queue, 1);
    AudioQueueDispose(Queue, 1);
    Queue := nil;
  end;
  FreeAndNil(Mixer);
end;

{$ENDIF}

{$IFDEF WINDOWS}

const
  StreamFrames = 256;
  StreamBuffers = 4;

type
  TWaveFeed = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  Feed: TWaveFeed;
  Wave: HWAVEOUT;

procedure TWaveFeed.Execute;
var
  Fmt: TWaveFormatEx;
  Hdr: array[0..StreamBuffers - 1] of TWaveHdr;
  Samples: array[0..StreamBuffers - 1, 0..StreamFrames - 1] of SmallInt;
  I, Sent: Integer;
begin
  FillChar(Fmt, SizeOf(Fmt), 0);
  Fmt.wFormatTag := WAVE_FORMAT_PCM;
  Fmt.nChannels := 1;
  Fmt.nSamplesPerSec := GuideSfxRate;
  Fmt.wBitsPerSample := 16;
  Fmt.nBlockAlign := 2;
  Fmt.nAvgBytesPerSec := GuideSfxRate * 2;
  Fmt.cbSize := 0;
  Wave := 0;
  if waveOutOpen(@Wave, WAVE_MAPPER, @Fmt, 0, 0, CALLBACK_NULL) <> 0 then
  begin
    Writeln('audio channel did not open');
    Flush(Output);
    Exit;
  end;
  FillChar(Hdr, SizeOf(Hdr), 0);
  for I := 0 to StreamBuffers - 1 do
  begin
    if Mixer <> nil then
      Mixer.Render(@Samples[I, 0], StreamFrames)
    else
      FillChar(Samples[I], SizeOf(Samples[I]), 0);
    Hdr[I].lpData := PChar(@Samples[I, 0]);
    Hdr[I].dwBufferLength := StreamFrames * 2;
    waveOutPrepareHeader(Wave, @Hdr[I], SizeOf(TWaveHdr));
    waveOutWrite(Wave, @Hdr[I], SizeOf(TWaveHdr));
  end;
  { State change: wave device held open. Four short buffers, no fifth. }
  ChannelOpen := True;
  while not Terminated do
  begin
    Sent := 0;
    for I := 0 to StreamBuffers - 1 do
      if (Hdr[I].dwFlags and WHDR_DONE) <> 0 then
      begin
        if Mixer <> nil then
          Mixer.Render(@Samples[I, 0], StreamFrames)
        else
          FillChar(Samples[I], SizeOf(Samples[I]), 0);
        Hdr[I].dwBufferLength := StreamFrames * 2;
        waveOutWrite(Wave, @Hdr[I], SizeOf(TWaveHdr));
        Inc(Sent);
      end;
    if Sent = 0 then
      Sleep(2);
  end;
  ChannelOpen := False;
  waveOutReset(Wave);
  for I := 0 to StreamBuffers - 1 do
    waveOutUnprepareHeader(Wave, @Hdr[I], SizeOf(TWaveHdr));
  waveOutClose(Wave);
  Wave := 0;
end;

procedure GuidePlayStart;
begin
  if ChannelOpen or (Feed <> nil) then
    Exit;
  Mixer := TGuideMixer.Create;
  Feed := TWaveFeed.Create(True);
  Feed.FreeOnTerminate := False;
  Feed.Start;
end;

procedure GuidePlayStop;
begin
  if Feed <> nil then
  begin
    Feed.Terminate;
    Feed.WaitFor;
    FreeAndNil(Feed);
  end;
  ChannelOpen := False;
  FreeAndNil(Mixer);
end;

{$ENDIF}

{$IFDEF LINUX}

const
  StreamFrames = 512; { ~23 ms. Written at that pace, never in a burst. }
  F_SETPIPE_SZ = 1031;
  PipeBytes = 4096; { smallest usual pipe: ~90 ms, a backstop if pace slips }

type
  TPipeFeed = class(TThread)
  private
    FLowLatency: Boolean;
    function PlayerExe: string;
    function OpenPlayer: Boolean;
    function WriteAll(const Buf; N: Integer): Boolean;
  protected
    procedure Execute; override;
  end;

var
  Feed: TPipeFeed;
  Player: TProcess;
  PlayerLock: TRTLCriticalSection;
  LockReady: Boolean;
  Reported: Boolean;

function TPipeFeed.PlayerExe: string;
begin
  if FileExists('/usr/bin/pw-play') then
    Result := '/usr/bin/pw-play'
  else if FileExists('/usr/bin/pw-cat') then
    Result := '/usr/bin/pw-cat'
  else if FileExists('/usr/bin/paplay') then
    Result := '/usr/bin/paplay'
  else if FileExists('/usr/bin/aplay') then
    Result := '/usr/bin/aplay'
  else
    Result := '';
end;

function TPipeFeed.OpenPlayer: Boolean;
var
  Exe, Name: string;
begin
  Result := False;
  Exe := PlayerExe;
  if Exe = '' then
  begin
    if not Reported then
    begin
      Writeln('audio channel: no pw-play, paplay, or aplay');
      Flush(Output);
      Reported := True;
    end;
    Exit;
  end;
  EnterCriticalSection(PlayerLock);
  try
    FreeAndNil(Player);
    Player := TProcess.Create(nil);
    Player.Executable := Exe;
    Name := ExtractFileName(Exe);
    if (Name = 'pw-play') or (Name = 'pw-cat') then
    begin
      if Name = 'pw-cat' then
        Player.Parameters.Add('--playback');
      if FLowLatency then
        Player.Parameters.Add('--latency=40');
      Player.Parameters.Add('--raw');
      Player.Parameters.Add('--format=s16');
      Player.Parameters.Add('--rate=' + IntToStr(GuideSfxRate));
      Player.Parameters.Add('--channels=1');
      Player.Parameters.Add('-');
    end
    else if Name = 'paplay' then
    begin
      if FLowLatency then
        Player.Parameters.Add('--latency-msec=40');
      Player.Parameters.Add('--raw');
      Player.Parameters.Add('--format=s16le');
      Player.Parameters.Add('--rate=' + IntToStr(GuideSfxRate));
      Player.Parameters.Add('--channels=1');
    end
    else
    begin
      Player.Parameters.Add('-q');
      Player.Parameters.Add('-t');
      Player.Parameters.Add('raw');
      Player.Parameters.Add('-f');
      Player.Parameters.Add('S16_LE');
      Player.Parameters.Add('-r');
      Player.Parameters.Add(IntToStr(GuideSfxRate));
      Player.Parameters.Add('-c');
      Player.Parameters.Add('1');
      if FLowLatency then
      begin
        Player.Parameters.Add('-B');
        Player.Parameters.Add('40000');
        Player.Parameters.Add('-F');
        Player.Parameters.Add('10000');
      end;
    end;
    Player.Options := [poUsePipes];
    try
      Player.Execute;
    except
      FreeAndNil(Player);
      Exit;
    end;
    if not Player.Running then
    begin
      FreeAndNil(Player);
      Exit;
    end;
    { A deep pipe is how the pips fall behind the letters: the writer
      fills it, and every new cue waits at the tail. Keep it tiny. }
    fpfcntl(cint(Player.Input.Handle), F_SETPIPE_SZ, PipeBytes);
    Result := True;
  finally
    LeaveCriticalSection(PlayerLock);
  end;
end;

function TPipeFeed.WriteAll(const Buf; N: Integer): Boolean;
var
  P: PByte;
  Left, Got: Integer;
  H: THandle;
begin
  Result := False;
  P := @Buf;
  Left := N;
  while Left > 0 do
  begin
    if Terminated then
      Exit;
    EnterCriticalSection(PlayerLock);
    try
      if (Player = nil) or not Player.Running then
        Exit;
      H := Player.Input.Handle;
    finally
      LeaveCriticalSection(PlayerLock);
    end;
    Got := FileWrite(H, P^, Left);
    if Got < 0 then
    begin
      if fpgeterrno = ESysEINTR then
        Continue;
      Exit;
    end;
    if Got = 0 then
      Exit;
    Inc(P, Got);
    Dec(Left, Got);
  end;
  Result := True;
end;

procedure TPipeFeed.Execute;
var
  Buf: array[0..StreamFrames - 1] of SmallInt;
  Next, Now: QWord;
  ChunkMs: QWord;
begin
  FLowLatency := True;
  ChunkMs := QWord(StreamFrames) * 1000 div GuideSfxRate;
  if ChunkMs < 1 then
    ChunkMs := 1;
  Next := GetTickCount64;
  while not Terminated do
  begin
    if not OpenPlayer then
    begin
      FLowLatency := False; { the latency flags may be what the player refused }
      Sleep(1000);
      Continue;
    end;
    { State change: raw stream open. Silence from here keeps the port awake. }
    ChannelOpen := True;
    while not Terminated and (Player <> nil) and Player.Running do
    begin
      if Mixer <> nil then
        Mixer.Render(@Buf[0], StreamFrames)
      else
        FillChar(Buf, SizeOf(Buf), 0);
      if not WriteAll(Buf, SizeOf(Buf)) then
        Break;
      { Realtime pace. A late slice is dropped, not poured in afterwards,
        or the pipe would grow and the pips would walk away from the text. }
      Next := Next + ChunkMs;
      Now := GetTickCount64;
      if (Now + 1000 < Next) or (Now >= Next) then
        Next := Now
      else
        Sleep(LongInt(Next - Now));
    end;
    ChannelOpen := False;
    EnterCriticalSection(PlayerLock);
    try
      FreeAndNil(Player);
    finally
      LeaveCriticalSection(PlayerLock);
    end;
    if not Terminated then
    begin
      FLowLatency := False;
      Sleep(400);
    end;
  end;
end;

procedure GuidePlayStart;
begin
  if Feed <> nil then
    Exit;
  if not LockReady then
  begin
    InitCriticalSection(PlayerLock);
    LockReady := True;
  end;
  Mixer := TGuideMixer.Create;
  Feed := TPipeFeed.Create(True);
  Feed.FreeOnTerminate := False;
  Feed.Start;
end;

procedure GuidePlayStop;
begin
  if Feed <> nil then
  begin
    Feed.Terminate;
    if LockReady then
    begin
      EnterCriticalSection(PlayerLock);
      try
        if Player <> nil then
          Player.Terminate(0); { unblocks a write parked in the pipe }
      finally
        LeaveCriticalSection(PlayerLock);
      end;
    end;
    Feed.WaitFor;
    FreeAndNil(Feed);
  end;
  if LockReady then
  begin
    EnterCriticalSection(PlayerLock);
    try
      FreeAndNil(Player);
    finally
      LeaveCriticalSection(PlayerLock);
    end;
    DoneCriticalSection(PlayerLock);
    LockReady := False;
  end;
  ChannelOpen := False;
  FreeAndNil(Mixer);
end;

{$ENDIF}

{$IF not defined(DARWIN) and not defined(WINDOWS) and not defined(LINUX)}
procedure GuidePlayStart;
begin
end;

procedure GuidePlayStop;
begin
end;
{$ENDIF}

end.
