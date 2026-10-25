<#
  foobar2000 -> Discord Rich Presence.

  The card shows the song like the foo_discord_rich component does:
    details (bold)      Title
    state               by <album artist>
    large image         album cover from MusicBrainz / Cover Art Archive (falls back to largeImageKey)
    large image text    on <album>
    elapsed time        counted by this script from the moment the song starts (pauses excluded)
  The small status line under the user's name alternates every few seconds between
  the app name ("foobar2000") and the song title, by flipping status_display_type.

  The song is read from the foobar2000 window title, which must be set to
    "Title · Album artist · Album - foobar2000"   ("(paused) " in front when paused).
  Settings live in config.json next to this script:
    clientId         Discord application ID (required)
    intervalSeconds  seconds each status text stays visible (default 20)
    largeImageKey    Rich Presence art asset key used when no cover is found
  -PipeName and -TitleOverride exist only so the script can be tested without Discord/foobar.
#>
param(
    [string]$PipeName = '',
    [string]$TitleOverride = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'
$LogPath = Join-Path $ScriptDir 'log.txt'
$CoverCachePath = Join-Path $ScriptDir 'covers-cache.json'
$MaxLogBytes = 200KB
$AppName = 'foobar2000'
$AppSuffix = " - $AppName"
$PausedPrefix = '(paused) '
$TitleSeparator = " $([char]0x00B7) "
$Ellipsis = [string][char]0x2026
$ZeroWidthSpace = [string][char]0x200B
$MaxTextLength = 128
$MinTextLength = 2
$PipeTimeoutMs = 5000
$ReconnectDelaySeconds = 5
$ClearDelaySeconds = 3
$OpcodeHandshake = 0
$OpcodeFrame = 1
$ActivityTypeListening = 2
$StatusShowAppName = 0
$StatusShowDetails = 2
$WebUserAgent = 'foobar2000-discord-rpc/1.0 (https://github.com/ciclamato/foobar2000-discord-rpc)'
$WebTimeoutSeconds = 15
$MusicBrainzMinScore = 90
$MusicBrainzDelayMs = 1100
$CoverSize = 'front-500'
$CoverRetrySeconds = 30
$MutexName = 'Local\foobar-discord-rpc'

function Write-Log([string]$Message) {
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt $MaxLogBytes) { Remove-Item $LogPath }
    Add-Content -Path $LogPath -Value ('{0:s} {1}' -f (Get-Date), $Message) -Encoding UTF8
}

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Missing $ConfigPath (needs at least clientId)" }
    $config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.clientId) { throw 'config.json has no clientId' }
    $interval = if ($config.intervalSeconds) { [int]$config.intervalSeconds } else { 20 }
    [pscustomobject]@{ ClientId = [string]$config.clientId; Interval = $interval; LargeImageKey = [string]$config.largeImageKey }
}

function Send-Frame($Pipe, [int]$Opcode, $Payload) {
    $body = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 6 -Compress))
    $frame = New-Object byte[] (8 + $body.Length)
    [BitConverter]::GetBytes($Opcode).CopyTo($frame, 0)
    [BitConverter]::GetBytes($body.Length).CopyTo($frame, 4)
    $body.CopyTo($frame, 8)
    $Pipe.Write($frame, 0, $frame.Length)
    $Pipe.Flush()
}

function Read-Exactly($Pipe, [int]$Count) {
    $buffer = New-Object byte[] $Count
    $read = 0
    while ($read -lt $Count) {
        $task = $Pipe.ReadAsync($buffer, $read, $Count - $read)
        if (-not $task.Wait($PipeTimeoutMs)) { throw 'Discord did not answer in time' }
        if ($task.Result -le 0) { throw 'Discord pipe closed' }
        $read += $task.Result
    }
    , $buffer
}

function Read-Frame($Pipe) {
    $header = Read-Exactly $Pipe 8
    $length = [BitConverter]::ToInt32($header, 4)
    $text = [Text.Encoding]::UTF8.GetString((Read-Exactly $Pipe $length))
    $text | ConvertFrom-Json
}

function Connect-Discord([string]$ClientId) {
    $names = if ($PipeName) { @($PipeName) } else { 0..9 | ForEach-Object { "discord-ipc-$_" } }
    foreach ($name in $names) {
        $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $name, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
        try { $pipe.Connect(300) } catch { $pipe.Dispose(); continue }
        Send-Frame $pipe $OpcodeHandshake @{ v = 1; client_id = $ClientId }
        $reply = Read-Frame $pipe
        if ($reply.evt -ne 'READY') { $pipe.Dispose(); throw "Discord refused the handshake: $($reply | ConvertTo-Json -Compress)" }
        return $pipe
    }
    $null
}

function Read-CoverCache {
    $cache = @{}
    if (Test-Path $CoverCachePath) {
        $saved = Get-Content $CoverCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in $saved.PSObject.Properties) { $cache[$entry.Name] = [string]$entry.Value }
    }
    $cache
}

function Search-CoverUrl([string]$Artist, [string]$Album) {
    $query = 'artist:"{0}" AND releasegroup:"{1}"' -f ($Artist -replace '"', ''), ($Album -replace '"', '')
    $uri = 'https://musicbrainz.org/ws/2/release-group?fmt=json&limit=5&query=' + [uri]::EscapeDataString($query)
    $groups = (Invoke-RestMethod -Uri $uri -UserAgent $WebUserAgent -TimeoutSec $WebTimeoutSeconds).'release-groups'
    foreach ($group in $groups) {
        if ([int]$group.score -lt $MusicBrainzMinScore) { continue }
        Start-Sleep -Milliseconds $MusicBrainzDelayMs
        try {
            $response = Invoke-WebRequest -Uri "https://coverartarchive.org/release-group/$($group.id)/$CoverSize" `
                -UserAgent $WebUserAgent -TimeoutSec $WebTimeoutSeconds -UseBasicParsing
            return $response.BaseResponse.ResponseUri.AbsoluteUri
        }
        catch { continue }   # this release group has no front cover
    }
    $null
}

function Get-CoverUrl([string]$Artist, [string]$Album) {
    if (-not $Artist -or -not $Album) { return $null }
    $key = "$Artist|$Album".ToLowerInvariant()
    $script:CoverRetryAt = $null
    if ($script:CoverCache.ContainsKey($key)) { return $script:CoverCache[$key] }
    try { $url = Search-CoverUrl $Artist $Album }
    catch {
        Write-Log "cover lookup failed for '$key': $($_.Exception.Message)"
        $script:CoverRetryAt = [DateTime]::UtcNow.AddSeconds($CoverRetrySeconds)   # not cached, so it is retried
        return $null
    }
    $script:CoverCache[$key] = [string]$url
    $script:CoverCache | ConvertTo-Json | Set-Content -Path $CoverCachePath -Encoding UTF8
    Write-Log ("cover for '$key': " + $(if ($url) { $url } else { 'none found' }))
    $url
}

function Limit-Text([string]$Text) {
    if ($Text.Length -gt $MaxTextLength) { return $Text.Substring(0, $MaxTextLength - 1) + $Ellipsis }
    if ($Text.Length -lt $MinTextLength) { return $Text + $ZeroWidthSpace }
    $Text
}

function New-Activity($Config, $Desired) {
    $track = $Desired.Track
    $activity = @{
        type                = $ActivityTypeListening
        status_display_type = $Desired.Display
        details             = (Limit-Text $track.Title)
        timestamps          = @{ start = $Desired.StartUnix }
    }
    if ($track.Artist) { $activity.state = Limit-Text "by $($track.Artist)" }
    $assets = @{}
    $image = if ($Desired.CoverUrl) { $Desired.CoverUrl } else { $Config.LargeImageKey }
    if ($image) { $assets.large_image = $image }
    if ($track.Album) { $assets.large_text = Limit-Text "on $($track.Album)" }
    if ($assets.Count -gt 0) { $activity.assets = $assets }
    $activity
}

function Set-Presence($Pipe, $Config, $Desired) {
    $activity = if ($Desired) { New-Activity $Config $Desired } else { $null }
    Send-Frame $Pipe $OpcodeFrame @{ cmd = 'SET_ACTIVITY'; args = @{ pid = $PID; activity = $activity }; nonce = [guid]::NewGuid().ToString() }
    $reply = Read-Frame $Pipe
    if ($reply.evt -eq 'ERROR') { throw "Discord rejected the activity: $($reply | ConvertTo-Json -Compress)" }
}

function ConvertFrom-WindowTitle([string]$Title) {
    $body = $Title.Substring(0, $Title.Length - $AppSuffix.Length)
    $parts = @($body -split [regex]::Escape($TitleSeparator))
    [pscustomobject]@{
        Title  = $parts[0].Trim()
        Artist = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
        Album  = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)] -join $TitleSeparator).Trim() } else { '' }
    }
}

function Get-PlayerState {
    $title = $TitleOverride
    if (-not $title) {
        $window = Get-Process -Name foobar2000 -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle } | Select-Object -First 1
        if (-not $window) { return @{ Mode = 'closed' } }
        $title = $window.MainWindowTitle
    }
    $mode = 'playing'
    if ($title.StartsWith($PausedPrefix)) { $mode = 'paused'; $title = $title.Substring($PausedPrefix.Length) }
    if ($title.EndsWith($AppSuffix) -and $title.Length -gt $AppSuffix.Length) {
        return @{ Mode = $mode; Track = (ConvertFrom-WindowTitle $title) }
    }
    @{ Mode = 'stopped' }
}

function Get-TrackKey($Track) { "$($Track.Title)|$($Track.Artist)|$($Track.Album)" }

function Get-DesiredPresence($State, [int]$Interval) {
    $now = [DateTime]::UtcNow
    if ($State.Mode -eq 'paused' -and (Get-TrackKey $State.Track) -eq $script:LastTrackKey -and -not $script:PausedAt) {
        $script:PausedAt = $now
    }
    if ($State.Mode -ne 'playing') {
        if (-not $script:NotPlayingSince) { $script:NotPlayingSince = $now }
        # a window title can read empty for a moment; only clear after a short grace period
        if (($now - $script:NotPlayingSince).TotalSeconds -lt $ClearDelaySeconds) { return $script:LastDesired }
        if ($State.Mode -ne 'paused') { $script:LastTrackKey = $null; $script:PausedAt = $null }
        $script:LastDesired = $null
        return $null
    }
    $script:NotPlayingSince = $null
    $track = $State.Track
    $trackKey = Get-TrackKey $track
    if ($trackKey -ne $script:LastTrackKey) {
        $script:LastTrackKey = $trackKey
        $script:TrackStart = $now
        $script:PhaseStart = $now
        $script:PausedAt = $null
        $script:CoverUrl = Get-CoverUrl $track.Artist $track.Album
    }
    elseif ($script:PausedAt) {
        $script:TrackStart = $script:TrackStart + ($now - $script:PausedAt)   # time spent paused does not count
        $script:PausedAt = $null
    }
    if (-not $script:CoverUrl -and $script:CoverRetryAt -and $now -ge $script:CoverRetryAt) {
        $script:CoverUrl = Get-CoverUrl $track.Artist $track.Album
    }
    $phase = [int][math]::Floor(($now - $script:PhaseStart).TotalSeconds / $Interval)
    $display = if ($phase % 2 -eq 0) { $StatusShowDetails } else { $StatusShowAppName }
    $startUnix = ([DateTimeOffset]$script:TrackStart).ToUnixTimeSeconds()
    $script:LastDesired = [pscustomobject]@{
        Track = $track; Display = $display; StartUnix = $startUnix; CoverUrl = $script:CoverUrl
        Key = "$trackKey|$display|$startUnix|$($script:CoverUrl)"
    }
    $script:LastDesired
}

function Get-StatusLabel($Desired) {
    if (-not $Desired) { return '(cleared)' }
    $shows = if ($Desired.Display -eq $StatusShowDetails) { 'title' } else { $AppName }
    $cover = if ($Desired.CoverUrl) { 'cover' } else { 'no cover' }
    "status line shows $shows | $($Desired.Track.Title) / $($Desired.Track.Artist) / $($Desired.Track.Album) | $cover"
}

$mutex = New-Object Threading.Mutex($false, $MutexName)
try { $ownsMutex = $mutex.WaitOne(0) }
catch [Threading.AbandonedMutexException] { $ownsMutex = $true }   # previous copy was killed; the mutex is ours now
if (-not $ownsMutex) { Write-Log 'another instance is already running, exiting'; exit }

$config = Read-Config
Write-Log "started, interval $($config.Interval)s"
$pipe = $null
$shownKey = $null
$script:CoverCache = Read-CoverCache
$script:LastTrackKey = $null
$script:TrackStart = [DateTime]::UtcNow
$script:PhaseStart = [DateTime]::UtcNow
$script:PausedAt = $null
$script:NotPlayingSince = $null
$script:LastDesired = $null
$script:CoverUrl = $null
$script:CoverRetryAt = $null
try {
    while ($true) {
        $desired = Get-DesiredPresence (Get-PlayerState) $config.Interval
        $desiredKey = if ($desired) { $desired.Key } else { $null }
        if ($desiredKey -ne $shownKey) {
            try {
                if (-not $pipe) {
                    $pipe = Connect-Discord $config.ClientId
                    if (-not $pipe) { throw 'Discord is not running' }
                    Write-Log 'connected to Discord'
                }
                Set-Presence $pipe $config $desired
                $shownKey = $desiredKey
                Write-Log ("presence -> " + (Get-StatusLabel $desired))
            }
            catch {
                Write-Log "error: $($_.Exception.Message)"
                if ($pipe) { $pipe.Dispose(); $pipe = $null }
                $shownKey = $null
                Start-Sleep -Seconds $ReconnectDelaySeconds
            }
        }
        Start-Sleep -Seconds 1
    }
}
finally {
    if ($pipe) {
        try { Set-Presence $pipe $config $null } catch { Write-Log "could not clear presence: $($_.Exception.Message)" }
        $pipe.Dispose()
    }
    $mutex.ReleaseMutex()
    Write-Log 'stopped'
}
