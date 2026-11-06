unit PNGDecoder;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$POINTERMATH ON}

interface

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF};

type
  EPNGError = class(Exception);

  // PNG sample decoding only. APNG owns chunk parsing, CRCs and compositing.
  TPNGDecoder = class
  private
    FDepth: Integer;
    FColor: Integer;
    FInterlace: Integer;
    FChannels: Integer;
    FPixelBytes: Integer;
    FPalette: Array[0..255, 0..3] of Byte;
    FPaletteCount: Integer;
    FTransparent: Boolean;
    FTransparentSamples: Array[0..2] of Word;
    FRaw: TBytes;
    FZeroRow: TBytes;
    procedure ExpandRow(ARow, ADestination: PByte; AWidth, AStep: Integer);
  public
    constructor Create(const AHeader, APalette, ATransparency: TBytes);
    function Decode(AData: Pointer; ASize, AWidth, AHeight: Integer): TBytes;
  end;

implementation

uses
  {$IFDEF FPC}ZLib{$ELSE}System.ZLib{$ENDIF};

procedure Require(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise EPNGError.Create(AMessage);
end;

function ReadWord(AData: PByte): Word; inline;
begin
  Result:=(Word(AData[0]) SHL 8) OR AData[1];
end;

constructor TPNGDecoder.Create(const AHeader, APalette, ATransparency: TBytes);
var
  I: Integer;
begin
  inherited Create;

  Require(Length(AHeader) = 13, 'Invalid PNG header.');
  FDepth:=AHeader[8];
  FColor:=AHeader[9];
  FInterlace:=AHeader[12];
  Require((AHeader[10] = 0) AND (AHeader[11] = 0) AND (FInterlace <= 1), 'Unsupported PNG header.');

  case FColor of
    0: FChannels:=1;
    2: FChannels:=3;
    3: FChannels:=1;
    4: FChannels:=2;
    6: FChannels:=4;
    else raise EPNGError.Create('Invalid PNG color type.');
  end;

  if FColor = 3 then
    Require(FDepth IN [1, 2, 4, 8], 'Invalid indexed PNG bit depth.')
  else
  if FColor = 0 then
    Require(FDepth IN [1, 2, 4, 8, 16], 'Invalid grayscale PNG bit depth.')
  else
    Require(FDepth IN [8, 16], 'Invalid PNG bit depth.');
  FPixelBytes:=(FChannels * FDepth + 7) DIV 8;

  FPaletteCount:=Length(APalette) DIV 3;
  if Length(APalette) > 0 then
    Require((FColor IN [2, 3, 6]) AND (Length(APalette) MOD 3 = 0) AND (FPaletteCount <= 256), 'Invalid PNG palette.');

  if FColor = 3 then
  begin
    Require((FPaletteCount > 0) AND (FPaletteCount <= 1 SHL FDepth), 'Missing or oversized PNG palette.');
    Require(Length(ATransparency) <= FPaletteCount, 'Invalid palette transparency.');
    for I:=0 to FPaletteCount - 1 do
    begin
      Move(APalette[I * 3], FPalette[I, 0], 3);
      FPalette[I, 3]:=255;
      if I < Length(ATransparency) then
        FPalette[I, 3]:=ATransparency[I];
    end;
  end else
  if Length(ATransparency) > 0 then
  begin
    Require(((FColor = 0) AND (Length(ATransparency) = 2)) OR ((FColor = 2) AND (Length(ATransparency) = 6)), 'Invalid PNG transparency.');

    FTransparent:=True;
    for I:=0 to FChannels - 1 do
    begin
      FTransparentSamples[I]:=ReadWord(@ATransparency[I * 2]);
      Require(Cardinal(FTransparentSamples[I]) < Cardinal(1) SHL FDepth, 'PNG transparency sample out of range.');
    end;
  end;
end;

function Paeth(ALeft, AUp, ACorner: Integer): Integer; inline;
var
  P, LeftDistance, UpDistance, CornerDistance: Integer;
begin
  Result:=ACorner;

  P:=ALeft + AUp - ACorner;
  LeftDistance:=Abs(P - ALeft);
  UpDistance:=Abs(P - AUp);
  CornerDistance:=Abs(P - ACorner);

  if (LeftDistance <= UpDistance) AND (LeftDistance <= CornerDistance) then
    Result:=ALeft
  else
  if UpDistance <= CornerDistance then
    Result:=AUp;
end;

procedure Unfilter(ARow, APrevious: PByte; ASize, APixelBytes, AFilter: Integer);
var
  I, Left, Corner: Integer;
begin
  // Select the filter once per row. The additions wrap modulo 256, even with range checks enabled.
  case AFilter of
    0: ;

    1:
    begin
      for I:=APixelBytes to ASize - 1 do
        ARow[I]:=(Integer(ARow[I]) + ARow[I - APixelBytes]) AND $FF;
    end;

    2:
    begin
      for I:=0 to ASize - 1 do
        ARow[I]:=(Integer(ARow[I]) + APrevious[I]) AND $FF;
    end;

    3, 4:
    begin
      for I:=0 to ASize - 1 do
      begin
        Left:=0;
        Corner:=0;
        if I >= APixelBytes then
        begin
          Left:=ARow[I - APixelBytes];
          Corner:=APrevious[I - APixelBytes];
        end;

        if AFilter = 3 then
          ARow[I]:=(Integer(ARow[I]) + (Left + APrevious[I]) DIV 2) AND $FF
        else
          ARow[I]:=(Integer(ARow[I]) + Paeth(Left, APrevious[I], Corner)) AND $FF;
      end;
    end;

    else raise EPNGError.Create('Invalid PNG row filter.');
  end;
end;

procedure TPNGDecoder.ExpandRow(ARow, ADestination: PByte; AWidth, AStep: Integer);
var
  X, I, SampleIndex, Value, Mask: Integer;
  Samples: Array[0..3] of Word;
  Alpha: Byte;
begin
  // The common RGBA8, non-interlaced path needs no sample conversion.
  if (FColor = 6) AND (FDepth = 8) AND (AStep = 1) then
  begin
    Move(ARow^, ADestination^, AWidth * 4);
    Exit;
  end;

  SampleIndex:=0;
  FillChar(Samples, SizeOf(Samples), 0);
  Mask:=(1 SHL FDepth) - 1;

  for X:=0 to AWidth - 1 do
  begin
    for I:=0 to FChannels - 1 do
    begin
      if FDepth = 16 then
        Samples[I]:=ReadWord(@ARow[SampleIndex * 2])
      else
      if FDepth = 8 then
        Samples[I]:=ARow[SampleIndex]
      else
        Samples[I]:=(ARow[(SampleIndex * FDepth) DIV 8] SHR (8 - FDepth - (SampleIndex * FDepth) MOD 8)) AND Mask;
      Inc(SampleIndex);
    end;

    if FColor = 3 then
    begin
      Require(Samples[0] < FPaletteCount, 'PNG palette index out of range.');
      Move(FPalette[Samples[0], 0], ADestination^, 4);
    end else
    begin
      Alpha:=255;
      if FTransparent then
      begin
        if ((FColor = 0) AND (Samples[0] = FTransparentSamples[0])) OR ((FColor = 2) AND (Samples[0] = FTransparentSamples[0]) AND
           (Samples[1] = FTransparentSamples[1]) AND (Samples[2] = FTransparentSamples[2])) then
          Alpha:=0;
      end;

      // Match tRNS at original precision before reducing 16-bit samples to their high byte.
      for I:=0 to FChannels - 1 do
        if FDepth = 16 then
          Samples[I]:=Samples[I] SHR 8
        else
        if FDepth < 8 then
          Samples[I]:=(Integer(Samples[I]) * 255) DIV Mask;

      if FColor IN [0, 4] then
      begin
        Value:=Samples[0];
        ADestination[0]:=Value;
        ADestination[1]:=Value;
        ADestination[2]:=Value;
        if FColor = 4 then
          Alpha:=Samples[1];
      end else
      begin
        ADestination[0]:=Samples[0];
        ADestination[1]:=Samples[1];
        ADestination[2]:=Samples[2];
        if FColor = 6 then
          Alpha:=Samples[3];
      end;
      ADestination[3]:=Alpha;
    end;

    Inc(ADestination, AStep * 4);
  end;
end;

function TPNGDecoder.Decode(AData: Pointer; ASize, AWidth, AHeight: Integer): TBytes;
const
  StartX: Array[0..7] of Integer = (0, 0, 4, 0, 2, 0, 1, 0);
  StartY: Array[0..7] of Integer = (0, 0, 0, 4, 0, 2, 0, 1);
  StepX: Array[0..7] of Integer = (1, 8, 8, 4, 4, 2, 2, 1);
  StepY: Array[0..7] of Integer = (1, 8, 8, 8, 4, 4, 2, 2);
var
  Z: z_stream;
  FirstPass, LastPass, Pass, PassWidth, PassHeight, RowSize, RawSize, Offset, Y, Status: Integer;
  Row, Previous: PByte;
begin
  Result:=nil;

  Require((AData <> nil) AND (ASize > 0), 'Empty PNG compressed data.');
  Require((AWidth > 0) AND (AHeight > 0) AND (AWidth <= 4096) AND (AHeight <= 4096), 'Invalid PNG dimensions.');

  FirstPass:=0;
  LastPass:=0;
  if FInterlace = 1 then
  begin
    FirstPass:=1;
    LastPass:=7;
  end;

  RawSize:=0;
  for Pass:=FirstPass to LastPass do
  begin
    PassWidth:=(AWidth - StartX[Pass] + StepX[Pass] - 1) DIV StepX[Pass];
    PassHeight:=(AHeight - StartY[Pass] + StepY[Pass] - 1) DIV StepY[Pass];
    if (PassWidth > 0) AND (PassHeight > 0) then
      Inc(RawSize, (((PassWidth * FChannels * FDepth + 7) DIV 8) + 1) * PassHeight);
  end;

  // One extra byte detects overlong output without ever growing to an attacker-supplied size.
  SetLength(FRaw, RawSize + 1);
  FillChar(Z, SizeOf(Z), 0);
  Require(inflateInit(Z) = Z_OK, 'Cannot initialize PNG decompressor.');
  try
    Z.next_in:=AData;
    Z.avail_in:=ASize;
    Z.next_out:=@FRaw[0];
    Z.avail_out:=Length(FRaw);

    Status:=inflate(Z, Z_FINISH);
    Require((Status = Z_STREAM_END) AND (Z.total_out = Cardinal(RawSize)) AND (Z.avail_in = 0), 'Invalid PNG compressed data or scanline length.');
  finally
    inflateEnd(Z);
  end;

  SetLength(Result, AWidth * AHeight * 4);
  SetLength(FZeroRow, (AWidth * FChannels * FDepth + 7) DIV 8);
  FillChar(FZeroRow[0], Length(FZeroRow), 0);

  Offset:=0;
  for Pass:=FirstPass to LastPass do
  begin
    PassWidth:=(AWidth - StartX[Pass] + StepX[Pass] - 1) DIV StepX[Pass];
    PassHeight:=(AHeight - StartY[Pass] + StepY[Pass] - 1) DIV StepY[Pass];
    if (PassWidth <= 0) OR (PassHeight <= 0) then
      Continue;

    RowSize:=(PassWidth * FChannels * FDepth + 7) DIV 8;
    Previous:=@FZeroRow[0];
    for Y:=0 to PassHeight - 1 do
    begin
      Row:=@FRaw[Offset + 1];
      Unfilter(Row, Previous, RowSize, FPixelBytes, FRaw[Offset]);
      ExpandRow(Row, @Result[((StartY[Pass] + Y * StepY[Pass]) * AWidth + StartX[Pass]) * 4], PassWidth, StepX[Pass]);

      Previous:=Row;
      Inc(Offset, RowSize + 1);
    end;
  end;
end;

end.
