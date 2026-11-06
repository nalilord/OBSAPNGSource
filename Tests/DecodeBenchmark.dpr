program DecodeBenchmark;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF FPC}SysUtils,{$ELSE}System.SysUtils, Winapi.Windows,{$ENDIF} APNGDecoder in '..\Source\APNGDecoder.pas';

var
  Animation: TAPNGAnimation;
  I, Iterations: Integer;
  Started, Elapsed: UInt64;
  Premultiply: Boolean;
  PixelFormat: String;
begin
  Animation:=TAPNGAnimation.Create;
  try
    try
      if (ParamCount < 1) OR (ParamCount > 3) then
        raise Exception.Create('Usage: DecodeBenchmark input.apng [iterations=30] [straight]');

      Iterations:=30;
      if ParamCount >= 2 then
        Iterations:=StrToInt(ParamStr(2));
      if Iterations < 1 then
        raise Exception.Create('Iterations must be positive.');
      if (ParamCount = 3) AND (ParamStr(3) <> 'straight') then
        raise Exception.Create('Unknown pixel format; use straight or omit for premultiplied.');

      Premultiply:=ParamStr(3) <> 'straight';
      PixelFormat:='premultiplied RGBA';
      if NOT Premultiply then
        PixelFormat:='straight RGBA';

      Animation.LoadFromFile(ParamStr(1), Premultiply);
      Started:=GetTickCount64;
      for I:=1 to Iterations do
        Animation.LoadFromFile(ParamStr(1), Premultiply);

      Elapsed:=GetTickCount64 - Started;
      WriteLn(Format('%d x %d, %d frames, %d iterations: %.3f ms/load (warm file cache, %s)',
        [Animation.Width, Animation.Height, Length(Animation.Frames), Iterations, Elapsed / Iterations, PixelFormat]));
    except
      on E: Exception do
      begin
        WriteLn('ERROR: ' + E.Message);
        ExitCode:=1;
      end;
    end;
  finally
    Animation.Free;
  end;
end.
