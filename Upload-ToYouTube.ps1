#Requires -Version 5.1
<#
.SYNOPSIS
    Scans a folder for new videos and uploads them to YouTube.

.DESCRIPTION
    Watches a folder for video files matching a naming convention and uploads
    any not yet uploaded to a YouTube channel via the YouTube Data API v3.

    FILENAME CONVENTION
    -------------------
    Files are parsed as: [Date_]Title[_tags][_privacy]

    Examples:
      2024-03-15_My Cool Video_gaming,tutorial_public.mp4
      My Cool Video.mp4
      2024-03-15_Tutorial How To Cook Pasta_cooking,food.mp4

    Rules:
      - Underscores separate fields; spaces within a field are fine.
      - Field 1 (optional): Date in YYYY-MM-DD format.
      - Field 2: Video title.
      - Field 3 (optional): Comma-separated tags.
      - Field 4 (optional): Privacy override — "public", "private", or "unlisted".

    SIDECAR METADATA FILES
    ----------------------
    Place a .json file with the same base name as the video to override any
    parsed metadata. Example: "My Video.json" alongside "My Video.mp4".

    Sidecar JSON schema:
      {
        "Title":       "My Custom Title",
        "Description": "A longer description of the video.",
        "Tags":        ["tag1", "tag2"],
        "CategoryId":  "22",
        "Privacy":     "public"
      }

.PARAMETER ConfigFile
    Path to the JSON config file. Defaults to "config.json" in the script directory.

.PARAMETER Once
    Run once and exit instead of watching continuously.

.PARAMETER WatchIntervalSeconds
    How often (in seconds) to scan the folder when running in watch mode. Default: 60.

.EXAMPLE
    .\Upload-ToYouTube.ps1
    .\Upload-ToYouTube.ps1 -Once
    .\Upload-ToYouTube.ps1 -ConfigFile "C:\MyConfig.json" -WatchIntervalSeconds 300
#>

[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot "config.json"),
    [switch]$Once,
    [int]$WatchIntervalSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ──────────────────────────────────────────────────────────────────────────────

$OAUTH_AUTH_URL  = "https://accounts.google.com/o/oauth2/v2/auth"
$OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
$YOUTUBE_SCOPE   = "https://www.googleapis.com/auth/youtube.upload"
$UPLOAD_URL      = "https://www.googleapis.com/upload/youtube/v3/videos"
$CHUNK_SIZE      = 8MB   # Resumable upload chunk size

# ──────────────────────────────────────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────────────────────────────────────

$script:LogFile = $null

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "OK"    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.Hashtable]) { return $InputObject }
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $ht[$prop.Name] = $prop.Value
        }
        return $ht
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# CONFIG
# ──────────────────────────────────────────────────────────────────────────────

function Load-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path`nCopy config.example.json to config.json and fill in your credentials."
    }
    $cfg = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    # Resolve relative paths against the script directory
    foreach ($key in @("StateFile", "TokenFile", "LogFile")) {
        $val = $cfg.$key
        if ($val -and -not [System.IO.Path]::IsPathRooted($val)) {
            $cfg.$key = Join-Path $PSScriptRoot $val
        }
    }
    if (-not [System.IO.Path]::IsPathRooted($cfg.ScanFolder)) {
        $cfg.ScanFolder = Join-Path $PSScriptRoot $cfg.ScanFolder
    }

    return $cfg
}

# ──────────────────────────────────────────────────────────────────────────────
# STATE — tracks which files have already been uploaded
# ──────────────────────────────────────────────────────────────────────────────

function Load-State {
    param([string]$Path)
    if (Test-Path $Path) {
        return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-Hashtable
    }
    return @{}
}

function Save-State {
    param([hashtable]$State, [string]$Path)
    $State | ConvertTo-Json -Depth 5 | Set-Content $Path -Encoding UTF8
}

function Get-FileHash-Short {
    param([string]$FilePath)
    # Use a quick hash of path + size + last-write to identify a file
    $info = Get-Item $FilePath
    $raw  = "$($info.FullName)|$($info.Length)|$($info.LastWriteTimeUtc.Ticks)"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-").Substring(0, 16)
}

# ──────────────────────────────────────────────────────────────────────────────
# FILENAME PARSING
# ──────────────────────────────────────────────────────────────────────────────

function Parse-VideoFilename {
    param([System.IO.FileInfo]$File)

    $base   = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $parts  = @($base -split "_")

    $dateStr    = $null
    $titlePart  = $null
    $tagsPart   = $null
    $privacyPart = $null
    $idx = 0

    # Field 1: optional date YYYY-MM-DD
    if ($parts[$idx] -match '^\d{4}-\d{2}-\d{2}$') {
        $dateStr = $parts[$idx]
        $idx++
    }

    # Field 2: title (required)
    $titlePart = if ($idx -lt $parts.Count) { $parts[$idx] } else { $base }
    $idx++

    # Field 3: optional tags (comma-separated)
    if ($idx -lt $parts.Count -and $parts[$idx] -notmatch '^(public|private|unlisted)$') {
        $tagsPart = $parts[$idx]
        $idx++
    }

    # Field 4: optional privacy
    if ($idx -lt $parts.Count -and $parts[$idx] -match '^(public|private|unlisted)$') {
        $privacyPart = $parts[$idx]
    }

    $tags = @()
    if ($tagsPart) {
        $tags = $tagsPart -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    return @{
        Title       = $titlePart.Trim()
        Description = if ($dateStr) { "Uploaded on $dateStr" } else { "" }
        Tags        = $tags
        Privacy     = $privacyPart
        Date        = $dateStr
    }
}

function Load-Sidecar {
    param([System.IO.FileInfo]$VideoFile)
    $sidecar = [System.IO.Path]::ChangeExtension($VideoFile.FullName, ".json")
    if (Test-Path $sidecar) {
        Write-Log "  Found sidecar: $sidecar"
        return Get-Content $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-Hashtable
    }
    return $null
}

function Build-Metadata {
    param([System.IO.FileInfo]$VideoFile, [hashtable]$Config)

    $parsed  = Parse-VideoFilename -File $VideoFile
    $sidecar = Load-Sidecar -VideoFile $VideoFile

    # Sidecar values override parsed values
    $title       = if ($sidecar -and $sidecar.Title)       { $sidecar.Title }       else { $parsed.Title }
    $description = if ($sidecar -and $sidecar.Description) { $sidecar.Description } else { $parsed.Description }
    $tags        = if ($sidecar -and $sidecar.Tags)        { @($sidecar.Tags) }     else { $parsed.Tags }
    $categoryId  = if ($sidecar -and $sidecar.CategoryId)  { $sidecar.CategoryId }  else { $Config.DefaultCategoryId }
    $privacy     = if ($sidecar -and $sidecar.Privacy)     { $sidecar.Privacy }     `
                   elseif ($parsed.Privacy)                { $parsed.Privacy }      `
                   else                                    { $Config.DefaultPrivacy }

    return @{
        Title       = $title
        Description = $description
        Tags        = $tags
        CategoryId  = $categoryId
        Privacy     = $privacy
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# OAUTH2 — device/loopback flow + token refresh
# ──────────────────────────────────────────────────────────────────────────────

function Load-Tokens {
    param([string]$Path)
    if (Test-Path $Path) {
        return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-Hashtable
    }
    return $null
}

function Save-Tokens {
    param([hashtable]$Tokens, [string]$Path)
    $Tokens | ConvertTo-Json | Set-Content $Path -Encoding UTF8
}

function Refresh-AccessToken {
    param([hashtable]$Tokens, [hashtable]$Config)

    Write-Log "Refreshing access token..."
    $body = @{
        client_id     = $Config.ClientId
        client_secret = $Config.ClientSecret
        refresh_token = $Tokens.refresh_token
        grant_type    = "refresh_token"
    }
    $resp = Invoke-RestMethod -Uri $OAUTH_TOKEN_URL -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
    $Tokens.access_token = $resp.access_token
    $Tokens.expires_at   = (Get-Date).AddSeconds($resp.expires_in - 60).Ticks
    return $Tokens
}

function Get-ValidAccessToken {
    param([hashtable]$Tokens, [hashtable]$Config, [string]$TokenFile)

    if ($Tokens.expires_at -and (Get-Date).Ticks -gt [long]$Tokens.expires_at) {
        $Tokens = Refresh-AccessToken -Tokens $Tokens -Config $Config
        Save-Tokens -Tokens $Tokens -Path $TokenFile
    }
    return $Tokens
}

function Start-OAuthFlow {
    param([hashtable]$Config, [string]$TokenFile)

    Write-Log "No saved tokens found. Starting OAuth2 authorization flow..." "WARN"

    # Use a loopback redirect URI — user must approve in browser
    $redirectUri = "urn:ietf:wg:oauth:2.0:oob"
    $authUri = "${OAUTH_AUTH_URL}?client_id=$($Config.ClientId)" +
               "&redirect_uri=$([Uri]::EscapeDataString($redirectUri))" +
               "&response_type=code" +
               "&scope=$([Uri]::EscapeDataString($YOUTUBE_SCOPE))" +
               "&access_type=offline" +
               "&prompt=consent"

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " AUTHORIZATION REQUIRED" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Open this URL in your browser and authorize the application:"
    Write-Host ""
    Write-Host $authUri -ForegroundColor Yellow
    Write-Host ""

    # Try to open the browser automatically
    try { Start-Process $authUri } catch {}

    $code = Read-Host "Paste the authorization code here"
    $code = $code.Trim()

    $body = @{
        client_id     = $Config.ClientId
        client_secret = $Config.ClientSecret
        code          = $code
        redirect_uri  = $redirectUri
        grant_type    = "authorization_code"
    }

    $resp   = Invoke-RestMethod -Uri $OAUTH_TOKEN_URL -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
    $tokens = @{
        access_token  = $resp.access_token
        refresh_token = $resp.refresh_token
        expires_at    = (Get-Date).AddSeconds($resp.expires_in - 60).Ticks
    }
    Save-Tokens -Tokens $tokens -Path $TokenFile
    Write-Log "Tokens saved to $TokenFile" "OK"
    return $tokens
}

# ──────────────────────────────────────────────────────────────────────────────
# YOUTUBE UPLOAD — resumable upload protocol
# ──────────────────────────────────────────────────────────────────────────────

function Upload-Video {
    param(
        [System.IO.FileInfo]$VideoFile,
        [hashtable]$Metadata,
        [string]$AccessToken
    )

    $fileSize = $VideoFile.Length
    Write-Log "  Size:     $([math]::Round($fileSize / 1MB, 1)) MB"
    Write-Log "  Title:    $($Metadata.Title)"
    Write-Log "  Tags:     $($Metadata.Tags -join ', ')"
    Write-Log "  Privacy:  $($Metadata.Privacy)"

    # Step 1: Initiate the resumable upload session
    $snippet = @{
        title       = $Metadata.Title
        description = $Metadata.Description
        categoryId  = $Metadata.CategoryId
    }
    # Only include tags when non-empty; PS5.1 serialises @() as null which the API rejects
    $tagList = @($Metadata.Tags | Where-Object { $_ })
    if ($tagList.Count -gt 0) {
        $snippet.tags = $tagList
    }

    $body = @{
        snippet = $snippet
        status  = @{
            privacyStatus = $Metadata.Privacy
        }
    } | ConvertTo-Json -Depth 5

    $mimeType = Get-MimeType -Extension $VideoFile.Extension
    $headers  = @{
        Authorization            = "Bearer $AccessToken"
        "X-Upload-Content-Type"  = $mimeType
        "X-Upload-Content-Length" = $fileSize.ToString()
        "Content-Type"           = "application/json; charset=UTF-8"
    }

    $initUri  = "${UPLOAD_URL}?uploadType=resumable&part=snippet,status"
    $initResp = Invoke-WebRequest -Uri $initUri -Method Post -Headers $headers -Body $body -UseBasicParsing
    $uploadUri = $initResp.Headers["Location"]

    if (-not $uploadUri) {
        throw "Failed to get upload URI from YouTube API."
    }

    # Step 2: Upload file in chunks
    $stream    = [System.IO.File]::OpenRead($VideoFile.FullName)
    $buffer    = New-Object byte[] $CHUNK_SIZE
    $uploaded  = 0
    $videoId   = $null

    try {
        while ($uploaded -lt $fileSize) {
            $read      = $stream.Read($buffer, 0, $buffer.Length)
            $chunk     = $buffer[0..($read - 1)]
            $rangeEnd  = $uploaded + $read - 1
            $percent   = [math]::Round(($uploaded / $fileSize) * 100, 1)

            Write-Progress -Activity "Uploading $($VideoFile.Name)" `
                           -Status "$percent% ($([math]::Round($uploaded/1MB,1)) / $([math]::Round($fileSize/1MB,1)) MB)" `
                           -PercentComplete $percent

            $chunkHeaders = @{
                Authorization  = "Bearer $AccessToken"
                "Content-Range" = "bytes $uploaded-$rangeEnd/$fileSize"
                "Content-Type"  = $mimeType
            }

            try {
                $chunkResp = Invoke-WebRequest -Uri $uploadUri -Method Put `
                                               -Headers $chunkHeaders -Body $chunk `
                                               -UseBasicParsing
                # 200/201 means upload complete
                if ($chunkResp.StatusCode -in 200, 201) {
                    $respObj = $chunkResp.Content | ConvertFrom-Json
                    $videoId = $respObj.id
                }
            } catch [System.Net.WebException] {
                $statusCode = [int]$_.Exception.Response.StatusCode
                # 308 Resume Incomplete is expected for intermediate chunks
                if ($statusCode -ne 308) {
                    throw
                }
            }

            $uploaded += $read
        }
    } finally {
        $stream.Close()
        Write-Progress -Activity "Uploading $($VideoFile.Name)" -Completed
    }

    if (-not $videoId) {
        throw "Upload completed but no video ID returned."
    }
    return $videoId
}

function Get-MimeType {
    param([string]$Extension)
    $map = @{
        ".mp4"  = "video/mp4"
        ".mkv"  = "video/x-matroska"
        ".avi"  = "video/x-msvideo"
        ".mov"  = "video/quicktime"
        ".wmv"  = "video/x-ms-wmv"
        ".flv"  = "video/x-flv"
        ".webm" = "video/webm"
    }
    $mimeType = $map[$Extension.ToLower()]
    if ($mimeType) { return $mimeType } else { return "video/mp4" }
}

# ──────────────────────────────────────────────────────────────────────────────
# SCAN & UPLOAD LOOP
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-ScanAndUpload {
    param([hashtable]$Config, [hashtable]$Tokens, [hashtable]$State)

    if (-not (Test-Path $Config.ScanFolder)) {
        Write-Log "Scan folder does not exist: $($Config.ScanFolder)" "WARN"
        return
    }

    $extensions = $Config.SupportedExtensions
    $videos     = @(Get-ChildItem -Path $Config.ScanFolder -File |
                  Where-Object { $extensions -contains $_.Extension.ToLower() } |
                  Sort-Object LastWriteTime)

    if ($videos.Count -eq 0) {
        Write-Log "No video files found in $($Config.ScanFolder)"
        return
    }

    Write-Log "Found $($videos.Count) video file(s) in scan folder."

    foreach ($video in $videos) {
        $fileKey = Get-FileHash-Short -FilePath $video.FullName

        if ($State.ContainsKey($fileKey)) {
            Write-Log "Skipping (already uploaded): $($video.Name)"
            continue
        }

        Write-Log "Processing: $($video.Name)"

        try {
            $Tokens  = Get-ValidAccessToken -Tokens $Tokens -Config $Config -TokenFile $Config.TokenFile
            $meta    = Build-Metadata -VideoFile $video -Config $Config
            $videoId = Upload-Video -VideoFile $video -Metadata $meta -AccessToken $Tokens.access_token

            $State[$fileKey] = @{
                File      = $video.FullName
                VideoId   = $videoId
                Title     = $meta.Title
                UploadedAt = (Get-Date -Format "o")
                Url       = "https://www.youtube.com/watch?v=$videoId"
            }
            Save-State -State $State -Path $Config.StateFile

            Write-Log "Uploaded: $($video.Name) -> https://www.youtube.com/watch?v=$videoId" "OK"

        } catch {
            Write-Log "Failed to upload $($video.Name): $_" "ERROR"
        }
    }

    return $Tokens
}

# ──────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ──────────────────────────────────────────────────────────────────────────────

$cfg = Load-Config -Path $ConfigFile
$script:LogFile = $cfg.LogFile

Write-Log "YouTube Auto-Upload starting. Scan folder: $($cfg.ScanFolder)"

$cfgHash = @{}
$cfg.PSObject.Properties | ForEach-Object { $cfgHash[$_.Name] = $_.Value }
$cfgHash.SupportedExtensions = @($cfgHash.SupportedExtensions)

$tokens = Load-Tokens -Path $cfgHash.TokenFile
if (-not $tokens) {
    $tokens = Start-OAuthFlow -Config $cfgHash -TokenFile $cfgHash.TokenFile
}

$state = Load-State -Path $cfgHash.StateFile

if ($Once) {
    $tokens = Invoke-ScanAndUpload -Config $cfgHash -Tokens $tokens -State $state
    Write-Log "Done."
} else {
    Write-Log "Watch mode: scanning every $WatchIntervalSeconds second(s). Press Ctrl+C to stop."
    while ($true) {
        $tokens = Invoke-ScanAndUpload -Config $cfgHash -Tokens $tokens -State $state
        Write-Log "Next scan in $WatchIntervalSeconds second(s)..."
        Start-Sleep -Seconds $WatchIntervalSeconds
    }
}
