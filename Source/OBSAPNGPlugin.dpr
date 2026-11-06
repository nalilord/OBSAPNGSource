library OBSAPNGPlugin;

uses
  System.SysUtils, XENOME.OBS, XENOME.OBS.Compatibility, XENOME.OBS.Audio, XENOME.OBS.Data, XENOME.OBS.Graphics, XENOME.OBS.Math, XENOME.OBS.Misc,
  XENOME.OBS.Properties, XENOME.OBS.Source, XENOME.OBS.Types, XENOME.OBS.Video, XENOME.OBS.VideoScaler, APNGDecoder in 'APNGDecoder.pas',
  PNGDecoder in 'PNGDecoder.pas', OBSAPNGSource in 'OBSAPNGSource.pas';

var
  Module: POBSModule;

procedure obs_module_set_pointer(AModule: POBSModule); cdecl;
begin
  Module:=AModule;
end;

function obs_current_module: POBSModule; cdecl;
begin
  Result:=Module;
end;

function obs_module_ver: Cardinal; cdecl;
begin
  Result:=LIBOBS_MODULE_API_VER;
end;

function obs_module_load: Boolean; cdecl;
var
  MessageText: UTF8String;
begin
  Result:=False;

  try
    if NOT obs_compat_runtime_is_supported then
    begin
      MessageText:=UTF8String(Format('[obs-apng] Unsupported OBS %s; requires %s through %d.x.',
        [String(obs_compat_runtime_version_string), String(obs_compat_minimum_version_string), LIBOBS_API_MAJOR_VER]));
      obs_log(LOG_ERROR, '%s', PAnsiChar(MessageText));
      Exit;
    end;
    RegisterAPNGSource;
    obs_log(LOG_INFO, '[obs-apng] Registered native APNG Image source.');
    Result:=True;
  except
    Result:=False;
  end;
end;

function obs_module_name: PAnsiChar; cdecl;
begin
  Result:='APNG Image';
end;

function obs_module_author: PAnsiChar; cdecl;
begin
  Result:='NaliLord';
end;

function obs_module_description: PAnsiChar; cdecl;
begin
  Result:='Native animated PNG image source with alpha, frame compositing and looping.';
end;

exports
  obs_module_set_pointer, obs_current_module, obs_module_ver, obs_module_load, obs_module_name, obs_module_author, obs_module_description;

begin
end.
