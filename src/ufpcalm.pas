unit ufpcalm;

{$mode objfpc}{$H+}

{ Free Pascal enables floating-point traps. Metal draws on another thread,
  inherits them, and overflows on the first frame. src/fpcalm.c clears the
  traps on the main thread, again as each new thread starts, and once more
  if a thread faults after Pascal turns the traps back on. This unit is
  initialized before Cocoa. }

interface

implementation

uses
  Math;

{$L fpcalm.o}

procedure InstallFpCalm; cdecl; external name 'InstallFpCalm';

initialization
  InstallFpCalm;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
    exOverflow, exUnderflow, exPrecision]);
end.
