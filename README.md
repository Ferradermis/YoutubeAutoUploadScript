# YouTube Auto-Upload Script

PowerShell script that scans a folder for new videos and uploads them to YouTube using the YouTube Data API v3.

## Setup

### 1. Google Cloud Credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a project (or select an existing one)
3. Enable the **YouTube Data API v3**
4. Go to **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**
5. Application type: **Desktop app**
6. Copy the **Client ID** and **Client Secret**

### 2. Config File

Copy `config.example.json` to `config.json` and fill in your values:

```json
{
  "ClientId":            "YOUR_CLIENT_ID.apps.googleusercontent.com",
  "ClientSecret":        "YOUR_CLIENT_SECRET",
  "ScanFolder":          "C:\\Videos\\Upload",
  "StateFile":           "uploaded_state.json",
  "TokenFile":           "tokens.json",
  "DefaultPrivacy":      "public",
  "DefaultCategoryId":   "22",
  "SupportedExtensions": [".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm"],
  "LogFile":             "upload_log.txt"
}
```

**YouTube Category IDs** (common ones):
| ID | Category |
|----|----------|
| 1  | Film & Animation |
| 2  | Autos & Vehicles |
| 10 | Music |
| 15 | Pets & Animals |
| 17 | Sports |
| 20 | Gaming |
| 22 | People & Blogs |
| 23 | Comedy |
| 24 | Entertainment |
| 25 | News & Politics |
| 26 | How-to & Style |
| 27 | Education |
| 28 | Science & Technology |

### 3. First Run (Authorization)

On first run, the script will open a browser for you to authorize the app. After approval, paste the code back into the terminal. The tokens are saved to `tokens.json` and reused (with automatic refresh) going forward.

## Usage

```powershell
# Watch mode (scans every 60 seconds)
.\Upload-ToYouTube.ps1

# Scan once and exit
.\Upload-ToYouTube.ps1 -Once

# Custom config and scan interval
.\Upload-ToYouTube.ps1 -ConfigFile "C:\MyConfig.json" -WatchIntervalSeconds 300
```

## Filename Convention

Files are parsed by splitting on `_`. Fields in order:

```
[YYYY-MM-DD_]Title of the Video[_tag1,tag2][_public|private|unlisted].ext
```

| Example | Title | Tags | Privacy |
|---------|-------|------|---------|
| `My Video.mp4` | "My Video" | — | default |
| `2024-03-15_Tutorial on Cooking_food,cooking.mp4` | "Tutorial on Cooking" | food, cooking | default |
| `2024-03-15_My Vlog_vlog,daily_private.mp4` | "My Vlog" | vlog, daily | private |
| `Gaming Session_gaming,fps_public.mp4` | "Gaming Session" | gaming, fps | public |

## Sidecar Metadata Files

For full control, place a `.json` file with the same base name as your video. Sidecar values **override** parsed filename values.

**`My Video.json`:**
```json
{
  "Title":       "My Amazing Video: Full Edition",
  "Description": "This is a detailed description of my video.\n\nTimestamps:\n0:00 - Intro",
  "Tags":        ["tag1", "tag2", "tag3"],
  "CategoryId":  "20",
  "Privacy":     "public"
}
```

## State Tracking

Uploaded files are tracked in `uploaded_state.json`. A file is identified by a hash of its path, size, and modification time — so renaming or editing a file will cause it to be uploaded again.

To re-upload a specific file, remove its entry from `uploaded_state.json`.
