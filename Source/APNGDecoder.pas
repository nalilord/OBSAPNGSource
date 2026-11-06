unit APNGDecoder;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF};

type
  EAPNGError = class(Exception);

  TAPNGFrame = record
    FPixels: TBytes;
    FDurationNS: UInt64;
  end;

  TAPNGAnimation = class
  private
    FWidth: Cardinal;
    FHeight: Cardinal;
    FPlays: Cardinal;
    FFrames: TArray<TAPNGFrame>;
    FDurationNS: UInt64;
    FFrameEnds: TArray<UInt64>;
  public
    // Default is straight RGBA for tools; OBS requests a premultiplied upload cache.
    procedure LoadFromFile(const AFileName: String; APremultiply: Boolean = False);
    function FrameAt(ATimeNS: UInt64; ALoop: Boolean): Integer;
    property Width: Cardinal read FWidth;
    property Height: Cardinal read FHeight;
    property Plays: Cardinal read FPlays;
    property Frames: TArray<TAPNGFrame> read FFrames;
    property DurationNS: UInt64 read FDurationNS;
  end;

implementation

uses
  {$IFDEF FPC}Classes, Generics.Collections,{$ELSE}System.Classes, System.Generics.Collections,{$ENDIF} PNGDecoder;

const
  MAX_FILE_BYTES = 64 * 1024 * 1024;
  MAX_CACHE_BYTES = 256 * 1024 * 1024;
  MAX_DIMENSION = 4096;
  MAX_FRAMES = 1024;
  PNG_SIGNATURE: Array[0..7] of Byte = (137, 80, 78, 71, 13, 10, 26, 10);

type
  TFrameControl = record
    FWidth: Cardinal;
    FHeight: Cardinal;
    FX: Cardinal;
    FY: Cardinal;
    FDelayNumerator: Word;
    FDelayDenominator: Word;
    FDispose: Byte;
    FBlend: Byte;
  end;

var
  CRCTable: Array[0..255] of Cardinal;

function CRC32(AData: PByte; ALength: Integer): Cardinal;
var
  I: Integer;
begin
  Result:=$FFFFFFFF;

  for I:=0 to ALength - 1 do
    Result:=CRCTable[(Result XOR AData[I]) AND $FF] XOR (Result SHR 8);

  Result:=Result XOR $FFFFFFFF;
end;

function BE32(const AData: TBytes; AOffset: Integer): Cardinal;
begin
  Result:=(Cardinal(AData[AOffset]) SHL 24) OR (Cardinal(AData[AOffset + 1]) SHL 16) OR (Cardinal(AData[AOffset + 2]) SHL 8) OR AData[AOffset + 3];
end;

procedure TAPNGAnimation.LoadFromFile(const AFileName: String; APremultiply: Boolean);
var
  Input: TFileStream;
  Bytes, Header, Palette, Transparency, Canvas, Previous, Pixels: TBytes;
  DataStream: TMemoryStream;
  Frames: TList<TAPNGFrame>;
  Decoder: TPNGDecoder;
  Control: TFrameControl;
  Frame: TAPNGFrame;
  Offset, ChunkSize, DataOffset, I: Integer;
  DeclaredFrames, ExpectedSequence, Denominator, SrcAlpha, DstAlpha, AlphaNumerator: Cardinal;
  ChunkType: AnsiString;
  HaveControl, HaveAnimation, HaveImageData, Ended, UsesDefaultImage, HavePalette, HaveTransparency, IDATEnded: Boolean;

  procedure Require(ACondition: Boolean; const AMessage: String);
  begin
    if NOT ACondition then
      raise EAPNGError.Create(AMessage);
  end;

  procedure CheckSequence;
  begin
    Require(BE32(Bytes, DataOffset) = ExpectedSequence, 'Invalid APNG chunk sequence.');
    Inc(ExpectedSequence);
  end;

  procedure FinishFrame;
  var
    X, Y, Src, Dst, C, RowBytes: Integer;
    Alpha: Cardinal;
  begin
    if NOT HaveControl then
      Exit;

    Require(DataStream.Size > 0, 'APNG frame has no pixel data.');
    Require(Frames.Count < Integer(DeclaredFrames), 'Too many APNG frames.');
    try
      if Decoder = nil then
        Decoder:=TPNGDecoder.Create(Header, Palette, Transparency);
      Pixels:=Decoder.Decode(DataStream.Memory, DataStream.Size, Control.FWidth, Control.FHeight);
    except
      on E: EPNGError do
        raise EAPNGError.Create(E.Message);
    end;

    RowBytes:=Control.FWidth * 4;
    // PREVIOUS only needs the affected rectangle, not another complete canvas.
    if Control.FDispose = 2 then
    begin
      SetLength(Previous, RowBytes * Integer(Control.FHeight));
      for Y:=0 to Integer(Control.FHeight) - 1 do
        Move(Canvas[((Y + Integer(Control.FY)) * Integer(FWidth) + Integer(Control.FX)) * 4], Previous[Y * RowBytes], RowBytes);
    end;

    for Y:=0 to Integer(Control.FHeight) - 1 do
    begin
      Src:=Y * RowBytes;
      Dst:=((Y + Integer(Control.FY)) * Integer(FWidth) + Integer(Control.FX)) * 4;
      if Control.FBlend = 0 then
        Move(Pixels[Src], Canvas[Dst], RowBytes)
      else
        for X:=0 to Integer(Control.FWidth) - 1 do
        begin
          SrcAlpha:=Pixels[Src + 3];
          DstAlpha:=Canvas[Dst + 3];
          if (SrcAlpha = 255) OR (DstAlpha = 0) then
            Move(Pixels[Src], Canvas[Dst], 4)
          else
          if SrcAlpha <> 0 then
          begin
            AlphaNumerator:=SrcAlpha * 255 + DstAlpha * (255 - SrcAlpha);
            for C:=0 to 2 do
              Canvas[Dst + C]:=(Cardinal(Pixels[Src + C]) * SrcAlpha * 255 +
                Cardinal(Canvas[Dst + C]) * DstAlpha * (255 - SrcAlpha) + AlphaNumerator DIV 2) DIV AlphaNumerator;
            Canvas[Dst + 3]:=(AlphaNumerator + 127) DIV 255;
          end;
          // Preserve the existing straight-RGBA convention for fully transparent OVER pixels.
          if (SrcAlpha = 0) AND (DstAlpha = 0) then
            FillChar(Canvas[Dst], 4, 0);
          Inc(Src, 4);
          Inc(Dst, 4);
        end;
    end;

    Frame.FPixels:=Copy(Canvas);
    // Composite in straight RGBA; premultiply only the cached copy for OBS uploads.
    if APremultiply then
      for X:=0 to Length(Frame.FPixels) DIV 4 - 1 do
      begin
        Alpha:=Frame.FPixels[X * 4 + 3];
        if Alpha <> 255 then
          for C:=0 to 2 do
            Frame.FPixels[X * 4 + C]:=(Cardinal(Frame.FPixels[X * 4 + C]) * Alpha + 127) DIV 255;
      end;

    Denominator:=Control.FDelayDenominator;
    if Denominator = 0 then
      Denominator:=100;
    Frame.FDurationNS:=(UInt64(Control.FDelayNumerator) * 1000000000) DIV Denominator;
    // Zero and extremely short delays are clamped to avoid a busy playback loop.
    if Frame.FDurationNS < 1000000 then
      Frame.FDurationNS:=1000000;

    Frames.Add(Frame);

    if Control.FDispose = 1 then
      for Y:=0 to Integer(Control.FHeight) - 1 do
      begin
        Dst:=((Y + Integer(Control.FY)) * Integer(FWidth) + Integer(Control.FX)) * 4;
        FillChar(Canvas[Dst], Control.FWidth * 4, 0);
      end else
    if Control.FDispose = 2 then
      for Y:=0 to Integer(Control.FHeight) - 1 do
        Move(Previous[Y * RowBytes], Canvas[((Y + Integer(Control.FY)) * Integer(FWidth) + Integer(Control.FX)) * 4], RowBytes);

    HaveControl:=False;
    DataStream.Clear;
  end;

begin
  FFrames:=nil;
  FFrameEnds:=nil;
  FDurationNS:=0;
  FWidth:=0;
  FHeight:=0;
  FPlays:=0;

  Input:=TFileStream.Create(AFileName, fmOpenRead OR fmShareDenyWrite);
  try
    if (Input.Size < 33) OR (Input.Size > MAX_FILE_BYTES) then
      raise EAPNGError.Create('APNG file must be between 33 bytes and 64 MiB.');
    SetLength(Bytes, Input.Size);
    Input.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Input.Free;
  end;

  Require(CompareMem(@Bytes[0], @PNG_SIGNATURE[0], 8), 'Not a PNG/APNG file.');

  Decoder:=nil;
  DataStream:=TMemoryStream.Create;
  Frames:=nil;
  try
    Frames:=TList<TAPNGFrame>.Create;

    Offset:=8;
    ExpectedSequence:=0;
    DeclaredFrames:=0;

    HaveControl:=False;
    HaveAnimation:=False;
    HaveImageData:=False;
    UsesDefaultImage:=False;
    Ended:=False;
    HavePalette:=False;
    HaveTransparency:=False;
    IDATEnded:=False;

    while Offset < Length(Bytes) do
    begin
      Require(Length(Bytes) - Offset >= 12, 'Truncated PNG chunk.');
      Require(BE32(Bytes, Offset) <= Cardinal(Length(Bytes) - Offset - 12), 'PNG chunk exceeds file bounds.');

      ChunkSize:=Integer(BE32(Bytes, Offset));
      DataOffset:=Offset + 8;
      SetString(ChunkType, PAnsiChar(@Bytes[Offset + 4]), 4);
      Require(CRC32(@Bytes[Offset + 4], ChunkSize + 4) = BE32(Bytes, DataOffset + ChunkSize), 'PNG checksum mismatch.');
      Require((Offset <> 8) OR (ChunkType = 'IHDR'), 'PNG must begin with IHDR.');

      if HaveImageData AND (ChunkType <> 'IDAT') then
        IDATEnded:=True;

      if ChunkType = 'IHDR' then
      begin
        Require((Offset = 8) AND (ChunkSize = 13), 'Invalid PNG header.');
        Header:=Copy(Bytes, DataOffset, 13);
        FWidth:=BE32(Header, 0);
        FHeight:=BE32(Header, 4);
        Require((FWidth > 0) AND (FHeight > 0) AND (FWidth <= MAX_DIMENSION) AND (FHeight <= MAX_DIMENSION), 'APNG dimensions must be between 1 and 4096.');
        Require((Header[10] = 0) AND (Header[11] = 0) AND (Header[12] <= 1), 'Unsupported PNG header.');
        SetLength(Canvas, FWidth * FHeight * 4);
      end else
      if ChunkType = 'acTL' then
      begin
        Require((ChunkSize = 8) AND NOT HaveAnimation AND NOT HaveImageData, 'Invalid animation header.');
        DeclaredFrames:=BE32(Bytes, DataOffset);
        FPlays:=BE32(Bytes, DataOffset + 4);
        Require((DeclaredFrames > 0) AND (DeclaredFrames <= MAX_FRAMES), 'APNG must have 1 to 1024 frames.');
        Require(UInt64(FWidth) * FHeight * 4 * DeclaredFrames <= MAX_CACHE_BYTES, 'Decoded animation exceeds the 256 MiB cache limit.');
        HaveAnimation:=True;
      end else
      if ChunkType = 'fcTL' then
      begin
        Require(HaveAnimation AND (ChunkSize = 26), 'Invalid frame control.');
        FinishFrame;
        CheckSequence;
        Control.FWidth:=BE32(Bytes, DataOffset + 4);
        Control.FHeight:=BE32(Bytes, DataOffset + 8);
        Control.FX:=BE32(Bytes, DataOffset + 12);
        Control.FY:=BE32(Bytes, DataOffset + 16);
        Control.FDelayNumerator:=(Word(Bytes[DataOffset + 20]) SHL 8) OR Bytes[DataOffset + 21];
        Control.FDelayDenominator:=(Word(Bytes[DataOffset + 22]) SHL 8) OR Bytes[DataOffset + 23];
        Control.FDispose:=Bytes[DataOffset + 24];
        Control.FBlend:=Bytes[DataOffset + 25];
        Require((Control.FWidth > 0) AND (Control.FHeight > 0) AND (UInt64(Control.FX) + Control.FWidth <= FWidth) AND
          (UInt64(Control.FY) + Control.FHeight <= FHeight), 'Frame rectangle lies outside the canvas.');
        Require((Control.FDispose <= 2) AND (Control.FBlend <= 1), 'Invalid frame blend/disposal operation.');
        UsesDefaultImage:=NOT HaveImageData;
        if UsesDefaultImage then
          Require((Control.FX = 0) AND (Control.FY = 0) AND (Control.FWidth = FWidth) AND
            (Control.FHeight = FHeight), 'Default image frame must cover the canvas.');
        HaveControl:=True;
      end else
      if ChunkType = 'IDAT' then
      begin
        Require(HaveAnimation, 'This PNG is not animated (no acTL chunk).');
        Require(NOT IDATEnded, 'Non-consecutive PNG image data.');
        HaveImageData:=True;
        Require((Frames.Count = 0) AND ((NOT HaveControl) OR UsesDefaultImage), 'Unexpected IDAT chunk.');
        if HaveControl AND (ChunkSize > 0) then
          DataStream.WriteBuffer(Bytes[DataOffset], ChunkSize);
      end else
      if ChunkType = 'fdAT' then
      begin
        Require(HaveControl AND HaveImageData AND NOT UsesDefaultImage AND (ChunkSize >= 4), 'Unexpected frame data.');
        CheckSequence;
        if ChunkSize > 4 then
          DataStream.WriteBuffer(Bytes[DataOffset + 4], ChunkSize - 4);
      end else
      if ChunkType = 'PLTE' then
      begin
        Require(NOT HaveImageData AND NOT HavePalette AND NOT HaveTransparency AND (ChunkSize > 0), 'Unexpected PNG palette.');
        HavePalette:=True;
        Palette:=Copy(Bytes, DataOffset, ChunkSize);
      end else
      if ChunkType = 'tRNS' then
      begin
        Require(NOT HaveImageData AND NOT HaveTransparency AND (ChunkSize > 0) AND ((Header[9] <> 3) OR HavePalette), 'Unexpected PNG transparency chunk.');
        HaveTransparency:=True;
        Transparency:=Copy(Bytes, DataOffset, ChunkSize);
      end else
      if ChunkType = 'IEND' then
      begin
        Require((ChunkSize = 0) AND HaveImageData, 'Invalid PNG end.');
        FinishFrame;
        Ended:=True;
        Require(Offset + 12 = Length(Bytes), 'Data follows PNG end.');
      end else
        Require((Bytes[Offset + 4] AND $20) <> 0, 'Unsupported critical PNG chunk.');

      Inc(Offset, ChunkSize + 12);
    end;

    Require(Ended AND HaveAnimation AND (Frames.Count = Integer(DeclaredFrames)), 'Incomplete APNG animation.');

    FFrames:=Frames.ToArray;
    SetLength(FFrameEnds, Length(FFrames));
    FDurationNS:=0;
    for I:=0 to High(FFrames) do
    begin
      Inc(FDurationNS, FFrames[I].FDurationNS);
      FFrameEnds[I]:=FDurationNS;
    end;
  finally
    Decoder.Free;
    Frames.Free;
    DataStream.Free;
  end;
end;

function TAPNGAnimation.FrameAt(ATimeNS: UInt64; ALoop: Boolean): Integer;
var
  Left, Right, Middle: Integer;
begin
  Result:=0;

  if (Length(FFrames) = 0) OR (FDurationNS = 0) then
    Exit;

  if NOT ALoop then
  begin
    // With override disabled, honour the file's play count (zero means forever).
    if (FPlays > 0) AND (ATimeNS DIV FDurationNS >= FPlays) then
      Exit(High(FFrames));
  end;

  ATimeNS:=ATimeNS MOD FDurationNS;
  Left:=0;
  Right:=High(FFrames);
  while Left < Right do
  begin
    Middle:=Left + (Right - Left) DIV 2;
    if ATimeNS < FFrameEnds[Middle] then
      Right:=Middle
    else
      Left:=Middle + 1;
  end;

  Result:=Left;
end;

procedure InitCRC;
var
  I, J: Integer;
  C: Cardinal;
begin
  for I:=0 to 255 do
  begin
    C:=I;
    for J:=0 to 7 do
      if (C AND 1) <> 0 then
        C:=$EDB88320 XOR (C SHR 1)
      else
        C:=C SHR 1;
    CRCTable[I]:=C;
  end;
end;

initialization
  InitCRC;

end.
