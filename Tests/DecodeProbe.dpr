program DecodeProbe;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF FPC}SysUtils, Classes,{$ELSE}System.SysUtils, System.Classes,{$ENDIF} APNGDecoder in '..\Source\APNGDecoder.pas';

var
  Animation, Premultiplied: TAPNGAnimation;
  I, J, C: Integer;
  Expected: Cardinal;
  Metadata: TStringList;
  Stream: TFileStream;
  TimeNS: UInt64;
begin
  Animation:=TAPNGAnimation.Create;
  Premultiplied:=nil;
  Metadata:=nil;
  try
    Premultiplied:=TAPNGAnimation.Create;
    Metadata:=TStringList.Create;

    try
      if ParamCount <> 2 then
        raise Exception.Create('Usage: DecodeProbe input.apng output-folder');

      Animation.LoadFromFile(ParamStr(1));
      Premultiplied.LoadFromFile(ParamStr(1), True);

      ForceDirectories(ParamStr(2));
      Metadata.Add(Format('%d %d %d %d', [Animation.Width, Animation.Height, Length(Animation.Frames), Animation.Plays]));

      TimeNS:=0;
      for I:=0 to High(Animation.Frames) do
      begin
        // Check the actual upload cache against straight compositing for every fixture.
        for J:=0 to Length(Animation.Frames[I].FPixels) DIV 4 - 1 do
          for C:=0 to 3 do
          begin
            Expected:=Animation.Frames[I].FPixels[J * 4 + C];
            if C < 3 then
              Expected:=(Expected * Animation.Frames[I].FPixels[J * 4 + 3] + 127) DIV 255;
            if Premultiplied.Frames[I].FPixels[J * 4 + C] <> Expected then
              raise Exception.Create('Premultiplied frame mismatch');
          end;

        if Animation.FrameAt(TimeNS, True) <> I then
          raise Exception.Create('Frame boundary timing mismatch');
        if Animation.FrameAt(TimeNS + Animation.Frames[I].FDurationNS - 1, True) <> I then
          raise Exception.Create('End of frame timing mismatch');
        if Animation.FrameAt(Animation.DurationNS + TimeNS, True) <> I then
          raise Exception.Create('Second loop timing mismatch');
        if (Animation.Plays = 0) AND (Animation.FrameAt(Animation.DurationNS + TimeNS, False) <> I) then
          raise Exception.Create('File infinite loop timing mismatch');

        Inc(TimeNS, Animation.Frames[I].FDurationNS);
        Metadata.Add(UIntToStr(Animation.Frames[I].FDurationNS));

        Stream:=TFileStream.Create(IncludeTrailingPathDelimiter(ParamStr(2)) + Format('frame-%d.rgba', [I]), fmCreate);
        try
          Stream.WriteBuffer(Animation.Frames[I].FPixels[0], Length(Animation.Frames[I].FPixels));
        finally
          Stream.Free;
        end;
      end;

      if Animation.FrameAt(TimeNS, True) <> 0 then
        raise Exception.Create('Infinite loop timing mismatch');
      if (Animation.Plays > 0) AND (Animation.FrameAt(TimeNS * Animation.Plays, False) <> High(Animation.Frames)) then
        raise Exception.Create('Finite play count timing mismatch');

      Metadata.SaveToFile(IncludeTrailingPathDelimiter(ParamStr(2)) + 'metadata.txt');
      WriteLn(Format('OK: %d frames, %d x %d, %d ns', [Length(Animation.Frames), Animation.Width, Animation.Height, Animation.DurationNS]));
    except
      on E: Exception do
      begin
        WriteLn('ERROR: ' + E.Message);
        ExitCode:=1;
      end;
    end;
  finally
    Metadata.Free;
    Premultiplied.Free;
    Animation.Free;
  end;
end.
