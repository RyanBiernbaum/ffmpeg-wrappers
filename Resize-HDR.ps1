#Requires -Version 7.0.0
#Requires -Module Write-ProgressEx

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateScript({Test-Path -LiteralPath $_ -PathType Leaf})]
    [String]
    $InputFile,
    [String]
    $OutputFile = "$($InputFile)_output.mkv",
    # At this time only libx265 supports setting the appropriate colorspace flags for HDR content.
    [ValidateSet('libx265')]
    [String]
    $Encoder = 'libx265',
    [int]
    $Crf = 18,
    [ValidateSet('grain','animation')]
    [String]
    $Tune = '',
    [ValidateSet('ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow')]
    $Preset = 'medium',
    [int]
    $CropScan = 300,
    [Switch]
    $DisableHardwareDecode
)

# Define Constants for encoder arguments
$LIBX265ARGS = @(
  '-c:v', 'libx265',
  '-crf', $crf,
  '-preset', $Preset
)
if ($Tune -ne ''){
  $LIBX265ARGS += @('-tune', $Tune)
}

# Locate ffmpeg
if (Test-Path "$PSScriptRoot\ffmpeg.exe") {
  $ffmpegbinary = "$PSScriptRoot\ffmpeg.exe"
} elseif (Get-Command 'ffmpeg') {
  $ffmpegbinary = $(Get-Command 'ffmpeg').Source
} else {
  throw "Could not locate ffmpeg in $PSScriptRoot or PATH"
}

# Locate ffprobe
if (Test-Path "$PSScriptRoot\ffprobe.exe") {
  $ffprobebinary = "$PSScriptRoot\ffprobe.exe"
} elseif (Get-Command 'ffprobe') {
  $ffprobebinary = $(Get-Command 'ffprobe').Source
} else {
  throw "Could not locate ffprobe in $PSScriptRoot or PATH"
}

# Scan the first N seconds of the file to detect what can be cropped
Write-Host "Scanning the first $CropScan seconds to determine proper crop settings."
$cropdetectargs = @('-hide_banner')
if (-not $DisableHardwareDecode) {
  $cropdetectargs += @('-hwaccel', 'auto')
}
$cropdetectargs += @(
  '-analyzeduration', '6000M',
  '-probesize', '6000M'
  '-i', "$InputFile", 
  '-t', $CropScan, 
  '-vf', 'cropdetect=round=2',
  '-max_muxing_queue_size', '4096', 
  '-f', 'null', 'NUL')

$crop = & $ffmpegbinary @cropdetectargs *>&1 | Where-Object { $_ -match 't:(?<Time>[\d]*).*?(?<Crop>crop=[-\d:]*)' } | ForEach-Object {
    $ProgressParam = @{
        Activity = 'Detecting crop settings'
        Status   = 'time={0} {1}' -f $Matches['Time'], $Matches['Crop']
        Current  = [int] $Matches['Time']
        Total    = $CropScan
    }
    Write-ProgressEx @ProgressParam
    Write-Output $Matches['Crop']
} | Select-Object -Last 1
Write-Host "Using $crop"

# Extract and normalize color settings
Write-Host 'Detecting color space and HDR parameters'
$ffprobeargs = @(
  '-hide_banner',
  '-loglevel', 'warning'
  '-select_streams', 'v'
  '-analyzeduration', '6000M',
  '-probesize', '6000M',
  '-print_format', 'json',
  '-show_frames',
  '-read_intervals', "%+#1",
  '-show_entries', 'frame=color_space,color_primaries,color_transfer,side_data_list,pix_fmt',
  '-i', $InputFile
)
$rawprobe = & $ffprobebinary @ffprobeargs
$hdrmeta = ($rawprobe | ConvertFrom-Json -AsHashtable)['frames']

$DisplayMeta = $hdrmeta.side_data_list.Where{ $_['side_data_type'] -like '*display metadata*' }[0]
$LightMeta = $hdrmeta.side_data_list.Where{ $_['side_data_type'] -like '*light level metadata*' }[0]

$colordata = @{}
$Pattern = [regex]::new( '^(?<Dividend>.*)\/(?<Divisor>.*)$' )
@('red', 'green', 'blue', 'white_point').ForEach{ "$_`_x", "$_`_y" }, 'min_luminance', 'max_luminance' | Write-Output -PipelineVariable Property | ForEach-Object {
    $Dividend, $Divisor = [int[]] $Pattern.Match( $DisplayMeta[ $Property ] ).Groups[ 'Dividend', 'Divisor' ].Value
    $colordata[ $Property ] = $Dividend * ( $Property -match '(min|max)_luminance' ? 10000 : 50000  ) / $Divisor
}
$contentlightlevel = @{
    'max_content' = [int] $LightMeta['max_content']
    'max_avg'     = [int] $LightMeta['max_average']
}

$encodeargs = @(
  '-hide_banner', '-loglevel', 'quiet', '-stats',
  '-analyzeduration', '6000M',
  '-probesize', '6000M'
)
# Set decoder
if (!$DisableHardwareDecode) {
  $encodeargs += @('-hwaccel', 'auto')
}

$encodeargs += @(
  '-i', $InputFile,
  '-map','0'
)
# Set encoder
switch ($Encoder) {
  'libx265' {$encodeargs += $LIBX265ARGS}
}

# Add filters
$encodeargs += @(
  '-vf', $crop
)

# Add HDR flags
$hdrparams = 'hdr-opt=1:repeat-headers=1:colorprim=' + $hdrmeta.color_primaries + 
  ':transfer=' + $hdrmeta.color_transfer + 
  ':colormatrix=' + $hdrmeta.color_space + 
  ':master-display='+ "G($($colordata.green_x),$($colordata.green_y))" +
  "B($($colordata.blue_x),$($colordata.blue_y))" + 
  "R($($colordata.red_x),$($colordata.red_y))" +
  "WP($($colordata.white_point_x),$($colordata.white_point_y))" + 
  "L($($colordata.max_luminance),$($colordata.min_luminance))" +
  ":max-cll=$($contentlightlevel['max_content']),$($contentlightlevel['max_avg'])"

$encodeargs += @(
  '-x265-params', $hdrparams
)

# Copy audio and subtitle streams
$encodeargs += @(
  '-c:a', 'copy',
  '-c:s', 'copy'
)

# Ensure we have a sufficient muxing queue
$encodeargs += @(
  '-max_muxing_queue_size', '4096',
  '-pix_fmt', 'yuv420p10le'
)

# Specify destination
$encodeargs += @($OutputFile)
Write-Host "Calling ffmpeg with: $($encodeargs -join ' ')"
& $ffmpegbinary @encodeargs