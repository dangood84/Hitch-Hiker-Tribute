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
procedure GuidePlayPump; { Linux: one slice from the window timer. Elsewhere a no-op. }

implementation

uses
  SysUtils
  {$IFDEF WINDOWS}
  , Windows, MMSystem, Classes
  {$ENDIF}
  {$IFDEF LINUX}
  , Process, BaseUnix
  {$ENDIF}
  ;

{$IFDEF DARWIN}
{$linkframework AudioToolbox}
{$ENDIF}

var
  Mixer: TGuideMixer;
  {$IFNDEF LINUX}
  ChannelOpen: Boolean; { read on macOS and Windows; the Linux feed just runs }
  {$ENDIF}

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

procedure GuidePlayPump;
begin
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

procedure GuidePlayPump;
begin
end;

{$ENDIF}

{$IFDEF LINUX}

{ The player is forked on the window thread and fed from the 50 ms timer.
  A worker thread that forks pw-play while GTK is already up can leave the
  child stuck before it reads a sample, and the tube is then silent.
  The command line is the one NoBugs uses on the Panasonic set. }

const
  ChunkFrames = 1102; { one CRT tick, 50 ms at GuideSfxRate }

var
  Player: TProcess;
  Pending: TBytes;
  NextFeed: QWord;
  RetryAt: QWord;
  Reported: Boolean;

function PlayerExe: string;
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

procedure Unblock(H: THandle);
var
  Flags: cint;
begin
  Flags := fpfcntl(H, F_GETFL);
  if Flags >= 0 then
    fpfcntl(H, F_SETFL, Flags or O_NONBLOCK);
end;

procedure SpeakPlayer;
var
  Buf: array[0..511] of Byte;
  N, At: Integer;
  Msg: string;
begin
  if (Player = nil) or (Player.Output = nil) then
    Exit;
  Msg := '';
  repeat
    N := FileRead(Player.Output.Handle, Buf, SizeOf(Buf));
    if N > 0 then
    begin
      At := Length(Msg);
      SetLength(Msg, At + N);
      Move(Buf[0], Msg[At + 1], N);
    end;
  until N <= 0;
  if Msg <> '' then
  begin
    Writeln(Msg);
    Flush(Output);
  end;
end;

procedure ClosePlayer;
begin
  FreeAndNil(Player);
  Pending := nil;
end;

function OpenPlayer: Boolean;
var
  Exe, Name: string;
begin
  Result := False;
  if GetTickCount64 < RetryAt then
    Exit;
  Exe := PlayerExe;
  if Exe = '' then
  begin
    if not Reported then
    begin
      Writeln('audio channel: no pw-play, paplay, or aplay');
      Flush(Output);
      Reported := True;
    end;
    RetryAt := GetTickCount64 + 5000;
    Exit;
  end;
  ClosePlayer;
  Player := TProcess.Create(nil);
  Player.Executable := Exe;
  Name := ExtractFileName(Exe);
  if (Name = 'pw-play') or (Name = 'pw-cat') then
  begin
    if Name = 'pw-cat' then
      Player.Parameters.Add('--playback');
    Player.Parameters.Add('--raw');
    Player.Parameters.Add('--format=s16');
    Player.Parameters.Add('--rate=' + IntToStr(GuideSfxRate));
    Player.Parameters.Add('--channels=1');
    Player.Parameters.Add('-');
  end
  else if Name = 'paplay' then
  begin
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
  end;
  Player.Options := [poUsePipes, poStderrToOutPut];
  try
    Player.Execute;
  except
    ClosePlayer;
    RetryAt := GetTickCount64 + 1000;
    Exit;
  end;
  if Player.Input <> nil then
    Unblock(Player.Input.Handle);
  if Player.Output <> nil then
    Unblock(Player.Output.Handle);
  if not Player.Running then
  begin
    SpeakPlayer;
    Writeln('audio channel did not stay open');
    Flush(Output);
    ClosePlayer;
    RetryAt := GetTickCount64 + 1000;
    Exit;
  end;
  { State change: raw stream open. Silence from the timer keeps the port awake. }
  Writeln('audio channel open (', Name, ')');
  Flush(Output);
  NextFeed := 0;
  Result := True;
end;

procedure FlushPending;
var
  Got: Integer;
  Err: cint;
begin
  if (Player = nil) or (Player.Input = nil) or (Length(Pending) = 0) then
    Exit;
  Got := FileWrite(Player.Input.Handle, Pending[0], Length(Pending));
  if Got > 0 then
    Delete(Pending, 0, Got)
  else if Got < 0 then
  begin
    Err := fpgeterrno;
    if (Err = ESysEINTR) or (Err = ESysEAGAIN) or (Err = ESysEWOULDBLOCK) then
      Exit;
    SpeakPlayer;
    Writeln('audio channel closed');
    Flush(Output);
    ClosePlayer;
    RetryAt := GetTickCount64 + 1000;
  end;
end;

procedure GuidePlayPump;
var
  Now: QWord;
  Frames: array[0..ChunkFrames - 1] of SmallInt;
  Old: Integer;
begin
  if (Player = nil) or not Player.Running then
  begin
    if (Player <> nil) and not Player.Running then
    begin
      SpeakPlayer;
      Writeln('audio channel closed');
      Flush(Output);
      ClosePlayer;
      RetryAt := GetTickCount64 + 1000;
    end;
    if not OpenPlayer then
      Exit;
  end;
  SpeakPlayer;
  Now := GetTickCount64;
  if Now >= NextFeed then
  begin
    { One slice per tick. A second slice would sit in the pipe and the
      pips would walk away from the letters. }
    if Length(Pending) < ChunkFrames * 2 then
    begin
      if Mixer <> nil then
        Mixer.Render(@Frames[0], ChunkFrames)
      else
        FillChar(Frames, SizeOf(Frames), 0);
      Old := Length(Pending);
      SetLength(Pending, Old + SizeOf(Frames));
      Move(Frames[0], Pending[Old], SizeOf(Frames));
    end;
    NextFeed := Now + 50;
  end;
  FlushPending;
end;

procedure GuidePlayStart;
begin
  if Mixer <> nil then
    Exit;
  Mixer := TGuideMixer.Create;
  NextFeed := 0;
  RetryAt := 0;
  OpenPlayer;
end;

procedure GuidePlayStop;
begin
  ClosePlayer;
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

procedure GuidePlayPump;
begin
end;
{$ENDIF}

end.
