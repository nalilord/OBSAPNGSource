unit OBSAPNGSource;

interface

procedure RegisterAPNGSource;

implementation

uses
  System.SysUtils, System.SyncObjs, APNGDecoder, XENOME.OBS, XENOME.OBS.Types, XENOME.OBS.Source, XENOME.OBS.Data, XENOME.OBS.Graphics, XENOME.OBS.Properties;

const
  SOURCE_ID: AnsiString = 'delphi_apng_image';
  SOURCE_NAME: AnsiString = 'APNG Image';
  GS_DYNAMIC = 1 SHL 1;
  DEFAULT_SPEED_PERCENT = 100;
  MIN_SPEED_PERCENT = 1;
  MAX_SPEED_PERCENT = 1000;

// These stable libobs entry points are not declared in the reused binding snapshot.
procedure obs_enter_graphics; cdecl; external 'obs.dll';
procedure obs_leave_graphics; cdecl; external 'obs.dll';

type
  TAPNGSource = class
  private
    FLock: TCriticalSection;
    FAnimation: TAPNGAnimation;
    FTexture: POBSGSTexture;
    FTextureFrame: Integer;
    FElapsedNS: UInt64;
    FSpeedMultiplier: Double;
    FLoop: Boolean;
    FRestart: Boolean;
    FFileName: String;
    FStatus: String;
    FSource: POBSSource;
  public
    constructor Create(ASource: POBSSource);
    destructor Destroy; override;
    procedure Update(ASettings: POBSData; AForce: Boolean = False);
    procedure Tick(ASeconds: Single);
    procedure Render(AEffect: POBSGSEffect);
    procedure Show;
    function Width: Cardinal;
    function Height: Cardinal;
    function Status: String;
  end;

var
  SourceInfo: TOBSSourceInfo;

procedure LogError(const AMessage: String);
var
  Text: UTF8String;
begin
  Text:=UTF8String('[obs-apng] ' + AMessage);
  obs_log(LOG_ERROR, '%s', PAnsiChar(Text));
end;

constructor TAPNGSource.Create(ASource: POBSSource);
begin
  inherited Create;

  FLock:=TCriticalSection.Create;
  FSource:=ASource;
  FTextureFrame:=-1;
  FSpeedMultiplier:=1.0;
  FStatus:='Select an animated PNG file.';
end;

destructor TAPNGSource.Destroy;
begin
  // Graphics must always be acquired before the source lock: render already owns it.
  obs_enter_graphics;
  try
    FLock.Acquire;
    try
      gs_texture_destroy(FTexture);
      FTexture:=nil;
      FreeAndNil(FAnimation);
    finally
      FLock.Release;
    end;
  finally
    obs_leave_graphics;
  end;
  FLock.Free;
  inherited Destroy;
end;

procedure TAPNGSource.Update(ASettings: POBSData; AForce: Boolean);
var
  FileName, NewStatus: String;
  Animation: TAPNGAnimation;
  NeedLoad: Boolean;
  SpeedPercent: Int64;
begin
  FileName:=UTF8ToString(obs_data_get_string(ASettings, 'file'));
  FLock.Acquire;
  try
    FLoop:=obs_data_get_bool(ASettings, 'loop');
    FRestart:=obs_data_get_bool(ASettings, 'restart');

    SpeedPercent:=obs_data_get_int(ASettings, 'speed_percent');
    // Older scene settings have no speed value; zero is not a pause setting.
    if SpeedPercent = 0 then
      SpeedPercent:=DEFAULT_SPEED_PERCENT;
    if SpeedPercent < MIN_SPEED_PERCENT then
      SpeedPercent:=MIN_SPEED_PERCENT
    else
    if SpeedPercent > MAX_SPEED_PERCENT then
      SpeedPercent:=MAX_SPEED_PERCENT;
    FSpeedMultiplier:=SpeedPercent / 100.0;

    NeedLoad:=AForce OR (FileName <> FFileName);
  finally
    FLock.Release;
  end;

  if NOT NeedLoad then
    Exit;

  Animation:=nil;
  NewStatus:='Select an animated PNG file.';
  try
    if FileName <> '' then
    begin
      Animation:=TAPNGAnimation.Create;
      try
        Animation.LoadFromFile(FileName, True);

        NewStatus:=Format('%d x %d | %d frames | %.2f seconds at 100%% | %.1f MiB decoded',
          [Animation.Width, Animation.Height, Length(Animation.Frames), Animation.DurationNS / 1000000000.0,
           UInt64(Animation.Width) * Animation.Height * 4 * UInt64(Length(Animation.Frames)) / 1048576.0]);
      except
        on E: Exception do
        begin
          NewStatus:='Could not load APNG: ' + E.Message;
          LogError(NewStatus);
          FreeAndNil(Animation);
        end;
      end;
    end;

    obs_enter_graphics;
    try
      FLock.Acquire;
      try
        gs_texture_destroy(FTexture);
        FTexture:=nil;
        FTextureFrame:=-1;
        FAnimation.Free;
        FAnimation:=Animation;
        Animation:=nil;
        FElapsedNS:=0;
        FFileName:=FileName;
        FStatus:=NewStatus;
      finally
        FLock.Release;
      end;
    finally
      obs_leave_graphics;
    end;
  finally
    Animation.Free;
  end;
end;

procedure TAPNGSource.Tick(ASeconds: Single);
begin
  if NOT obs_source_showing(FSource) OR (ASeconds <= 0) then
    Exit;
  FLock.Acquire;
  try
    if Assigned(FAnimation) then
      // Scale only new elapsed time so changing speed preserves the current position.
      Inc(FElapsedNS, UInt64(Round(Double(ASeconds) * FSpeedMultiplier * 1000000000.0)));
  finally
    FLock.Release;
  end;
end;

procedure TAPNGSource.Render(AEffect: POBSGSEffect);
var
  FrameIndex: Integer;
  PreviousSRGB: Boolean;
begin
  FLock.Acquire;
  try
    if NOT Assigned(FAnimation) OR (AEffect = nil) then
      Exit;

    FrameIndex:=FAnimation.FrameAt(FElapsedNS, FLoop);
    if FrameIndex <> FTextureFrame then
    begin
      // Pixels were premultiplied once at load time; no CPU conversion or copy during playback.
      if FTexture = nil then
        FTexture:=gs_texture_create(FAnimation.Width, FAnimation.Height, GS_RGBA, 1, nil, GS_DYNAMIC);
      if FTexture = nil then
        Exit;

      gs_texture_set_image(FTexture, @FAnimation.Frames[FrameIndex].FPixels[0], FAnimation.Width * 4, False);
      FTextureFrame:=FrameIndex;
    end;

    PreviousSRGB:=gs_framebuffer_srgb_enabled;
    gs_enable_framebuffer_srgb(True);
    gs_blend_state_push;
    try
      gs_blend_function(GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);
      gs_effect_set_texture_srgb(gs_effect_get_param_by_name(AEffect, 'image'), FTexture);
      gs_draw_sprite(FTexture, 0, FAnimation.Width, FAnimation.Height);
    finally
      gs_blend_state_pop;
      gs_enable_framebuffer_srgb(PreviousSRGB);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TAPNGSource.Show;
begin
  FLock.Acquire;
  try
    if FRestart then
      FElapsedNS:=0;
  finally
    FLock.Release;
  end;
end;

function TAPNGSource.Width: Cardinal;
begin
  Result:=0;

  FLock.Acquire;
  try
    if Assigned(FAnimation) then
      Result:=FAnimation.Width;
  finally
    FLock.Release;
  end;
end;

function TAPNGSource.Height: Cardinal;
begin
  Result:=0;

  FLock.Acquire;
  try
    if Assigned(FAnimation) then
      Result:=FAnimation.Height;
  finally
    FLock.Release;
  end;
end;

function TAPNGSource.Status: String;
begin
  Result:='';

  FLock.Acquire;
  try
    Result:=FStatus;
  finally
    FLock.Release;
  end;
end;

function GetName(AData: Pointer): PAnsiChar; cdecl;
begin
  Result:=PAnsiChar(SOURCE_NAME);
end;

function CreateSource(ASettings: POBSData; ASource: POBSSource): Pointer; cdecl;
var
  Source: TAPNGSource;
begin
  Result:=nil;

  Source:=nil;
  try
    Source:=TAPNGSource.Create(ASource);
    Source.Update(ASettings);
    Result:=Source;
  except
    on E: Exception do
    begin
      Source.Free;
      LogError(E.Message);
    end;
  end;
end;

procedure DestroySource(AData: Pointer); cdecl;
begin
  try
    TAPNGSource(AData).Free;
  except
    on E: Exception do
      LogError(E.Message);
  end;
end;

procedure UpdateSource(AData: Pointer; ASettings: POBSData); cdecl;
begin
  try
    TAPNGSource(AData).Update(ASettings);
  except
    on E: Exception do
      LogError(E.Message);
  end;
end;

procedure TickSource(AData: Pointer; ASeconds: Single); cdecl;
begin
  try
    TAPNGSource(AData).Tick(ASeconds);
  except
    on E: Exception do
      LogError(E.Message);
  end;
end;

procedure RenderSource(AData: Pointer; AEffect: POBSGSEffect); cdecl;
begin
  try
    TAPNGSource(AData).Render(AEffect);
  except
    on E: Exception do
      LogError(E.Message);
  end;
end;

procedure ShowSource(AData: Pointer); cdecl;
begin
  TAPNGSource(AData).Show;
end;

function GetWidth(AData: Pointer): Cardinal; cdecl;
begin
  Result:=TAPNGSource(AData).Width;
end;

function GetHeight(AData: Pointer): Cardinal; cdecl;
begin
  Result:=TAPNGSource(AData).Height;
end;

procedure Defaults(ASettings: POBSData); cdecl;
begin
  obs_data_set_default_bool(ASettings, 'loop', True);
  obs_data_set_default_bool(ASettings, 'restart', True);
  obs_data_set_default_int(ASettings, 'speed_percent', DEFAULT_SPEED_PERCENT);
end;

function Reload(AProps: POBSProperties; AProperty: POBSProperty; AData: Pointer): Boolean; cdecl;
var
  Settings: POBSData;
  Source: TAPNGSource;
  Text: UTF8String;
begin
  Result:=False;

  if AData = nil then
    Exit;

  Source:=TAPNGSource(AData);
  try
    Settings:=obs_source_get_settings(Source.FSource);
    try
      Source.Update(Settings, True);
    finally
      obs_data_release(Settings);
    end;

    Text:=UTF8String(Source.Status);
    obs_property_set_description(obs_properties_get(AProps, 'status'), PAnsiChar(Text));
    Result:=True;
  except
    on E: Exception do
      LogError(E.Message);
  end;
end;

function Properties(AData: Pointer): POBSProperties; cdecl;
var
  Text: UTF8String;
  SpeedProperty: POBSProperty;
begin
  Result:=obs_properties_create;

  obs_properties_add_path(Result, 'file', 'Animated PNG', OBS_PATH_FILE, 'Animated PNG (*.apng *.png);;All files (*.*)', nil);
  obs_properties_add_bool(Result, 'loop', 'Loop continuously (override file play count)');
  obs_properties_add_bool(Result, 'restart', 'Restart animation when shown');
  SpeedProperty:=obs_properties_add_int_slider(Result, 'speed_percent', 'Playback speed', MIN_SPEED_PERCENT, MAX_SPEED_PERCENT, 1);
  obs_property_int_set_suffix(SpeedProperty, '%');
  obs_properties_add_button2(Result, 'reload', 'Reload file / restart', Reload, AData);
  Text:='Select an animated PNG file.';
  if AData <> nil then
    Text:=UTF8String(TAPNGSource(AData).Status);
  obs_properties_add_text(Result, 'status', PAnsiChar(Text), OBS_TEXT_INFO);
end;

procedure RegisterAPNGSource;
begin
  FillChar(SourceInfo, SizeOf(SourceInfo), 0);

  SourceInfo.Id:=PAnsiChar(SOURCE_ID);
  SourceInfo.Typ:=OBS_SOURCE_TYPE_INPUT;
  SourceInfo.OutputFlags:=OBS_SOURCE_VIDEO OR OBS_SOURCE_SRGB;
  SourceInfo.GetName:=GetName;
  SourceInfo.Create:=CreateSource;
  SourceInfo.Destroy:=DestroySource;
  SourceInfo.Update:=UpdateSource;
  SourceInfo.VideoTick:=TickSource;
  SourceInfo.VideoRender:=RenderSource;
  SourceInfo.Show:=ShowSource;
  SourceInfo.GetWidth:=GetWidth;
  SourceInfo.GetHeight:=GetHeight;
  SourceInfo.GetDefaults:=Defaults;
  SourceInfo.GetProperties:=Properties;
  SourceInfo.IconType:=OBS_ICON_TYPE_IMAGE;

  obs_register_source(@SourceInfo);
end;

end.
