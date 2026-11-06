program OBSRenderProbe;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, Winapi.Windows, XENOME.OBS, XENOME.OBS.Types, XENOME.OBS.Data, XENOME.OBS.Source,
  XENOME.OBS.Graphics, XENOME.OBS.Math, XENOME.OBS.Video, XENOME.OBS.Properties;

function obs_startup(ALocale, AConfigPath: PAnsiChar; AProfiler: Pointer): Boolean; cdecl; external 'obs.dll';
procedure obs_add_data_path(APath: PAnsiChar); cdecl; external 'obs.dll';
function obs_reset_video(AInfo: POBSVideoInfo): Integer; cdecl; external 'obs.dll';
function obs_open_module(out AModule: POBSModule; APath, ADataPath: PAnsiChar): Integer; cdecl; external 'obs.dll';
function obs_init_module(AModule: POBSModule): Boolean; cdecl; external 'obs.dll';
procedure obs_enter_graphics; cdecl; external 'obs.dll';
procedure obs_leave_graphics; cdecl; external 'obs.dll';

var
  Info: TOBSVideoInfo;
  Module: POBSModule;
  Source: POBSSource;
  Settings: POBSData;
  Props: POBSProperties;
  SpeedProperty: POBSProperty;
  ActualSettings: POBSData;
  Target: POBSGSTexRender;
  Stage: POBSGSStageSurface;
  Pixels: PByte;
  Pitch: Cardinal;
  ClearColor: TOBSVec4;
  FileStream: TFileStream;
  I, Y, Code, SpeedPercent: Integer;
  DLLPath, DataPath, FilePath, GraphicsPath, OutputPath: UTF8String;

procedure Require(AValue: Boolean; const AMessage: String);
begin
  if NOT AValue then
    raise Exception.Create(AMessage);
end;

begin
  try
    Require(ParamCount IN [5, 6], 'Usage: OBSRenderProbe plugin.dll input.apng libobs-data libobs-d3d11.dll capture-directory [speed-percent]');

    SpeedPercent:=100;
    if ParamCount = 6 then
      SpeedPercent:=StrToInt(ParamStr(6));

    DLLPath:=UTF8String(ParamStr(1));
    FilePath:=UTF8String(ParamStr(2));
    DataPath:=UTF8String(ParamStr(3));
    GraphicsPath:=UTF8String(ParamStr(4));
    OutputPath:=UTF8String(ParamStr(5));
    ForceDirectories(ParamStr(5));

    Require(obs_startup('en-US', PAnsiChar(OutputPath), nil), 'obs_startup failed');
    obs_add_data_path(PAnsiChar(DataPath));
    try
      FillChar(Info, SizeOf(Info), 0);
      Info.GraphicsModule:=PAnsiChar(GraphicsPath);
      Info.FPSNum:=30;
      Info.FPSDen:=1;
      Info.BaseWidth:=508;
      Info.BaseHeight:=286;
      Info.OutputWidth:=508;
      Info.OutputHeight:=286;
      Info.OutputFormat:=VIDEO_FORMAT_RGBA;
      Info.Colorspace:=VIDEO_CS_SRGB;
      Info.Range:=VIDEO_RANGE_FULL;
      Info.ScaleType:=TOBSVideoScaleType(Ord(OBS_SCALE_BILINEAR));
      Code:=obs_reset_video(@Info);
      Require(Code = 0, 'obs_reset_video failed: ' + IntToStr(Code));
      Code:=obs_open_module(Module, PAnsiChar(DLLPath), PAnsiChar(OutputPath));
      Require(Code = 0, 'obs_open_module failed: ' + IntToStr(Code));
      Require(obs_init_module(Module), 'obs_init_module failed');

      Settings:=obs_data_create;
      try
        obs_data_set_string(Settings, 'file', PAnsiChar(FilePath));
        if ParamCount = 6 then
          obs_data_set_int(Settings, 'speed_percent', SpeedPercent);

        Source:=obs_source_create_private('delphi_apng_image', 'APNG render test', Settings);
        Require(Source <> nil, 'Source creation failed');
        try
          Require((obs_source_get_width(Source) = 508) AND (obs_source_get_height(Source) = 286), 'Wrong source size');

          Props:=obs_source_properties(Source);
          Require(Props <> nil, 'Properties creation failed');
          try
            SpeedProperty:=obs_properties_get(Props, 'speed_percent');
            Require(SpeedProperty <> nil, 'Playback speed property missing');
            Require((obs_property_int_min(SpeedProperty) = 1) AND (obs_property_int_max(SpeedProperty) = 1000), 'Wrong playback speed limits');
            Require(String(AnsiString(obs_property_int_suffix(SpeedProperty))) = '%', 'Playback speed suffix missing');
          finally
            obs_properties_destroy(Props);
          end;

          ActualSettings:=obs_source_get_settings(Source);
          try
            Require(obs_data_get_int(ActualSettings, 'speed_percent') = SpeedPercent, 'Wrong playback speed setting/default');
          finally
            obs_data_release(ActualSettings);
          end;

          obs_source_inc_showing(Source);

          obs_enter_graphics;
          try
            Target:=gs_texrender_create(GS_RGBA, GS_ZS_NONE);
            Stage:=gs_stagesurface_create(508, 286, GS_RGBA);
          finally
            obs_leave_graphics;
          end;
          try
            Require((Target <> nil) AND (Stage <> nil), 'Could not allocate render target');

            FillChar(ClearColor, SizeOf(ClearColor), 0);
            for I:=0 to 44 do
            begin
              Sleep(100);

              obs_enter_graphics;
              try
                gs_texrender_reset(Target);
                Require(gs_texrender_begin(Target, 508, 286), 'Begin render failed');
                gs_clear(1, @ClearColor, 0, 0);
                gs_ortho(0, 508, 0, 286, -100, 100);
                obs_source_video_render(Source);
                gs_texrender_end(Target);

                gs_stage_texture(Stage, gs_texrender_get_texture(Target));
                Require(gs_stagesurface_map(Stage, @Pixels, @Pitch), 'Readback failed');
                try
                  FileStream:=TFileStream.Create(TPath.Combine(ParamStr(5), Format('render-%d.rgba', [I])), fmCreate);
                  try
                    for Y:=0 to 285 do
                      FileStream.WriteBuffer(Pixels[Cardinal(Y) * Pitch], 508 * 4);
                  finally
                    FileStream.Free;
                  end;
                finally
                  gs_stagesurface_unmap(Stage);
                end;
              finally
                obs_leave_graphics;
              end;
            end;
          finally
            obs_enter_graphics;
            try
              gs_stagesurface_destroy(Stage);
              gs_texrender_destroy(Target);
            finally
              obs_leave_graphics;
            end;
            obs_source_dec_showing(Source);
          end;

          // A missing file must leave a clean, empty source; a later update must recover.
          obs_data_set_string(Settings, 'file', 'missing-apng-test-file.apng');
          obs_source_update(Source, Settings);
          Sleep(100);
          Require(obs_source_get_width(Source) = 0, 'Invalid file did not clear source');

          obs_data_set_string(Settings, 'file', PAnsiChar(FilePath));
          obs_source_update(Source, Settings);
          Sleep(100);
          Require(obs_source_get_width(Source) = 508, 'Source did not recover');

          WriteLn('PASS: load, properties, render, invalid-file recovery and source cleanup');
        finally
          obs_source_release(Source);
        end;
      finally
        obs_data_release(Settings);
      end;
    finally
      obs_shutdown;
    end;
  except
    on E: Exception do
    begin
      WriteLn('ERROR: ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
