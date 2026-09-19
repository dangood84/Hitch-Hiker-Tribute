program HitchHikersGuide;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$linkframework Cocoa}
{$ENDIF}

{ The Hitch-Hiker's Guide to the Galaxy — 1981 TV-series tribute in Pascal.

  macOS:    titled, resizable window, Dock icon, native fullscreen, NSSound.
  Windows:  titled, resizable window on the taskbar, F11 fullscreen, PlaySound.
  Linux:    GTK 2 window (Raspberry Pi OS friendly), F11 fullscreen, paplay.

  Only one HostRun is linked; the other two host units are not compiled.
  Build: see the Makefile. }

uses
  {$IFDEF DARWIN}
  uhostcocoa
  {$ELSE}
    {$IFDEF WINDOWS}
    uhostwin
    {$ELSE}
    uhostgtk
    {$ENDIF}
  {$ENDIF};

begin
  HostRun; { Cocoa run loop, Win32 GetMessage, or gtk_main — see uhost*.pas }
end.
