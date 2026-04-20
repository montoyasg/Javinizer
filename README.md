<h1 align="center">
  Javinizer (JAV Organizer)
  <br>
</h1>

<h4 align="center"><strong>A commandline and web GUI based PowerShell module used to scrape metadata and sort your local Japanese Adult Video (JAV) files into a media library compatible format.</strong></h4>

<br>

<p align="center">
  <a href="https://github.com/javinizer/Javinizer/releases">
    <img src="https://img.shields.io/github/v/release/javinizer/Javinizer?include_prereleases&style=plastic&label=release"
         alt="GitHub">
  </a>
  <a href="https://www.powershellgallery.com/packages/Javinizer/"><img src="https://img.shields.io/powershellgallery/dt/javinizer?color=red&label=psgallery&style=plastic"
  alt="PSGallery">
  </a>
  <a href="https://hub.docker.com/r/javinizer/javinizer">
      <img src="https://img.shields.io/docker/pulls/javinizer/javinizer?style=plastic&color=red&label=docker"
      alt="Docker">
  </a>
  <a href="https://discord.gg/Pds7xCpzpc">
    <img src="https://img.shields.io/discord/608449512352120834?color=brightgreen&style=plastic&label=discord"
    alt="Discord">
  </a>
    <a href="https://github.com/javinizer/Javinizer/compare/dev">
    <img src="https://img.shields.io/github/commits-since/javinizer/javinizer/latest/dev?style=plastic"
    alt="Commits">
  </a>
</p>

<p align="center">
  <a href="#features"><strong>Features</strong></a> •
  <a href="#getting-started"><strong>Getting Started</strong></a> •
  <a href="#example-output"><strong>Examples</strong></a> •
  <a href="https://javinizer.gitbook.io/docs" target="_blank"><strong>Documentation</strong></a>

</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/javinizer/Javinizer/master/media/demo.gif" width="1280">
</p>

## Features

-   **Highly customizable**. An assortment of scrapers are available for you to mix-and-match metadata with. Scrapers sources include sites such as Javlibrary, R18, Dmm (Fanza), JavBus, Jav321, AVEntertainment, MGStage, and DLGetchu. Various _.csv_ settings files are also provided to customize your metadata even further.

-   **Flexible file detection**. Multiple methods are provided to detect your local JAV files such as the built-in file matcher as well as a customizable regex string.

-   **Multi-language support**. Scraper sources provide English, Japanese, and occasionally Chinese language support. Machine translation modules are also available to translate individual metadata fields of your choice.

-   **You own the data**. Metadata _.nfo_ files are created for each JAV file to be read by a media library application. Contrary to a media library metadata plugin, if an online scraper suddenly disappears, you still keep your metadata.

## Getting Started

View the full Javinizer installation and usage documentation on [GitBook](https://javinizer.gitbook.io/docs/).

### Prerequisites

To run Javinizer, you will need to install following:

**NOTE**: You will need to add Python and MediaInfo to your system PATH. Windows calls `python`, while Unix/MacOS calls `python3`.

-   [PowerShell 7](https://github.com/PowerShell/PowerShell)
-   [Python 3](https://www.python.org/downloads/)
    -   [Pillow](https://pypi.org/project/Pillow/)
    -   [googletrans >= 4.0.0rc1](https://pypi.org/project/googletrans/) or [google_trans_new](https://pypi.org/project/google-trans-new/)
-   [MediaInfo](https://mediaarea.net/en/MediaInfo/Download) (Optional)

```python
# Install the python modules using pip. If running Unix/MacOS, use pip3/python3
> pip install pillow
> pip install googletrans==4.0.0rc1
> pip install google_trans_new
```

### Installation

After installing the required prerequisites, run the following command in an administrator PowerShell 7 (pwsh.exe) console to install the Javinizer module. If this is your first time using PowerShell, you may run into some prompts about security policies. Follow the instructions given in the prompts to unrestrict the code.

```powershell
# Install the module from PowerShell gallery
> Install-Module Javinizer

# Check that the module has been installed; if error, restart your console
> Javinizer -v
```

### Quick start (CLI)

Here are some common commands that you can run with Javinizer:

```powershell
# Run a command to sort your JAV files using default settings
> Javinizer -Path "C:\JAV\Unsorted" -DestinationPath "C:\JAV\Sorted"

# Run a command to sort your JAV files while searching folders recursively (within the folders)
> Javinizer -Path "C:\JAV\Unsorted" -DestinationPath "C:\JAV\Sorted" -Recurse

# Run a command to sort a JAV file using direct URLs
> Javinizer -Path "C:\JAV\Unsorted\IPX-535.mp4" -Url 'https://www.javlibrary.com/en/?v=javmeza7s4', 'https://www.r18.com/videos/vod/movies/detail/-/id=ipx00535/'

# Run a command to find metadata
> Javinizer -Find "ABP-420" -Javlibrary

# Run a command to find metadata and aggregate it according to your settings file
> Javinizer -Find "ABP-420" -Javlibrary -R18Dev -DmmJa -Aggregated

# Run a command to find metadata, aggregate it according to your settings file, and output the nfo
> Javinizer -Find "ABP-420" -Javlibrary -R18Dev -DmmJa -Aggregated -Nfo

# Open the Javinizer settings configuration
> Javinizer -OpenSettings

# Update your Javinizer module
> Javinizer -UpdateModule

# View the Javinizer commandline help (may not be up to date)
> Javinizer -Help
```

### Quick start (Web GUI)

```powershell
# Launch the cross-platform web GUI on http://127.0.0.1:8600
> Start-JVWeb
```

See the [Web GUI](#web-gui) section below for `-Port`/`-Bind`/`-NoBrowser`, the API, troubleshooting, and the javdb fallback setup.

#### Docker

A self-contained Docker image is published to [`montoyasg/javinizer-ng`](https://hub.docker.com/r/montoyasg/javinizer-ng) on every push to `master`. It bundles JVWeb, Pode, the Javinizer module, Microsoft.Playwright + Chromium (for the javdb fallback), and a noVNC web desktop so the one-time javdb login can be done from your browser. Multi-arch: `linux/amd64` and `linux/arm64`.

```bash
docker run -d --name javinizer-ng \
  -p 8600:8600 \
  -p 6080:6080 \
  -v jvweb-settings:/root/.jvsettings \
  -v jvweb-cache:/root/.javinizer \
  -v jvweb-config:/root/.config/Javinizer \
  -v /path/to/your/media:/media \
  -e VNC_PASSWORD=changeme \
  montoyasg/javinizer-ng:latest
```

- **`http://localhost:8600`** — JVWeb UI.
- **`http://localhost:6080/vnc.html`** — noVNC desktop. Use this once to complete the javdb login when JVWeb prompts; the captured session is persisted in the `jvweb-config` volume and reused for ~30 days.
- **`VNC_PASSWORD`** — leave unset for no auth (only safe on localhost). Set a value when exposing port `6080` beyond `127.0.0.1`.
- **Settings** — JVWeb writes user preferences to `/root/.jvsettings/jvSettings.json` inside the container. To start from the bundled defaults, copy [`src/Javinizer/jvSettings.json`](./src/Javinizer/jvSettings.json) into the `jvweb-settings` volume before first launch.
- **Translation is not bundled.** `googletrans` has known dependency conflicts on Python 3.10 and the JVWeb UI exposes no toggle for it. If you hand-set `sort.metadata.nfo.translate=true` in `jvSettings.json`, install the package inside the container with `docker exec javinizer-ng pip3 install googletrans==4.0.0rc1`.

## Web GUI

A lightweight, portable replacement for the old PowerShell Universal dashboard. Pure PowerShell backend (via [Pode](https://badgerati.github.io/Pode/)) + vanilla HTML/CSS/JS frontend. Cross-platform (Windows / macOS / Linux). No bundled binaries.

Scope of v1: **Sort page only**. Primary scraper is R18.dev; **javdb.com is used as a fallback** when R18.dev has no match (gated by `web.scrape.javdb.fallback` and a cached login session). NFO + cover crop + thumbs are retained via the existing `Set-JVMovie` pipeline — nothing in the core scrape/sort stack is re-implemented here.

### Web GUI requirements

- **PowerShell 7.2+** (javdb session capture uses Playwright for .NET which targets .NET 6+)
- **Pode** PowerShell module (`Install-Module Pode -Scope CurrentUser`)
- **Javinizer** module loaded or available for import
- **Network on first launch** — to auto-download SixLabors.ImageSharp (~1 MB, used for cropped posters). Cached afterwards at `~/.javinizer/assemblies/`.
- **Microsoft.Playwright (optional, for javdb fallback)** — javdb is behind Cloudflare; the module auto-captures the `_jdb_session` cookie by launching Chromium and waiting for you to log in once. Install:

  ```bash
  dotnet new console -o ~/.javinizer/playwright
  cd ~/.javinizer/playwright
  dotnet add package Microsoft.Playwright
  dotnet build
  pwsh bin/Debug/net*/playwright.ps1 install chromium
  ```

  Then ensure `Microsoft.Playwright.dll` is discoverable (e.g. `Add-Type -Path` in a profile or dot-source script before importing Javinizer). Set `web.scrape.javdb.fallback = false` in `jvSettings.json` to disable the fallback path entirely and skip this dependency.

### Run

#### As a Javinizer cmdlet

```powershell
Import-Module Javinizer
Start-JVWeb            # http://127.0.0.1:8600, opens browser
Start-JVWeb -Port 9000 # custom port
Start-JVWeb -Bind 0.0.0.0 -NoBrowser  # LAN access, don't auto-open
```

#### Standalone

```bash
pwsh ./src/Javinizer/JVWeb/JVWeb.ps1 -Port 8600
```

`JVWeb.ps1` finds the Javinizer manifest in its parent directory and imports it automatically.

### Folder layout

```text
src/Javinizer/JVWeb/
├── JVWeb.ps1                    entrypoint
├── Server/
│   ├── Start-JVWebServer.ps1    Pode bootstrap
│   ├── Routes.Browse.ps1        /api/browse, /api/files
│   ├── Routes.Scrape.ps1        /api/scrape, /api/screens, /api/manual-search
│   ├── Routes.Preview.ps1       /api/preview, /api/preview-tree
│   └── Routes.Sort.ps1          /api/sort
├── Lib/
│   ├── Invoke-JVScrapeCached.ps1   session cache around Get-R18DevUrl/Data
│   ├── Resolve-JVPreview.ps1       single + bulk tree dry-run
│   ├── Invoke-JVSortOne.ps1        thin wrapper over Set-JVMovie
│   ├── Get-JVEffectiveSettings.ps1 merges base settings + UI overrides
│   └── Open-JVBrowser.ps1          cross-platform browser opener
└── static/
    ├── index.html
    ├── app.js
    └── style.css
```

### API reference

All responses are JSON. No scriptblocks in payloads (that was the bug in the old GUI).

#### `GET /api/browse?path=<str>`

Returns folder contents.

```json
{
  "cwd": "/Users/me/media",
  "parent": "/Users/me",
  "entries": [
    { "name": "CAWD-125.mp4", "fullPath": "...", "isDir": false,
      "isVideo": true, "size": 2147483648, "lastModified": "2026-04-01T..." }
  ]
}
```

#### `GET /api/files?path=&page=&pageSize=&search=`

Same shape but paginated + searchable.

#### `POST /api/scrape`

Body: `{ "path": "/full/path/to/video.mp4" }`
Extracts ID from filename, scrapes R18.dev, falls back to javdb if enabled and R18.dev has no match, returns full metadata object (the `Source` field identifies which scraper won).

#### `POST /api/manual-search`

Body: `{ "query": "CAWD-125" }`, `{ "query": "https://r18.dev/videos/..." }`, or `{ "query": "https://javdb.com/v/..." }`
Bypasses filename parsing. Direct URLs are routed by domain.

#### `POST /api/javdb/session/refresh`

No body. Launches Chromium via Playwright and waits for the user to log in to javdb. Captures `_jdb_session` (and `cf_clearance` if present), persists to `~/.config/Javinizer/javdb-session.json` (macOS/Linux) or `%LOCALAPPDATA%\Javinizer\javdb-session.json` (Windows), and returns `{ status, capturedAt, expiresAt }`. The cookie itself is never returned to the browser.

#### `POST /api/preview`

Body: `{ path, destinationPath, settingsOverride }`
Dry-run. Returns the computed `folderPath`/`filePath` without moving anything.

#### `POST /api/preview-tree`

Body: `{ paths: [], destinationPath, settingsOverride }`
Bulk dry-run. Returns a nested tree structure + an `unresolved` array for failures.

#### `POST /api/sort`

Body: `{ path, destinationPath, settingsOverride, flags, data }`
Commits the move via `Set-JVMovie`. `data` is optional — if passed, overrides re-scraping.

### Scrape cache

`Invoke-JVScrapeCached` stores results in a Pode shared state (`scrapeCache`) keyed by content ID. It persists for the server's lifetime. This means:

- `preview-tree` + per-row `sort` never double-scrape the same ID.
- Manual-search results are cached too (by URL and by ID).
- Restart the server to flush.

### Customizing sort-tree

The right pane of the UI has three textboxes mapping to these `jvSettings.json` keys:

| Textbox | Setting key | Typical tokens |
| --- | --- | --- |
| `sort.format.outputfolder` | `sort.format.outputfolder` | `<ACTORS>`, `<STUDIO>`, `<SERIES>` |
| `sort.format.folder` | `sort.format.folder` | `<ID>`, `<TITLE>`, `<YEAR>`, `<STUDIO>` |
| `sort.format.file` | `sort.format.file` | `<ID>`, `<TITLE>` |

Plus two toggles:

- **groupActress** → `sort.format.groupactress` — multi-actress titles bucket into `@Group/`.
- **unknownActress** → `sort.metadata.nfo.unknownactress` — titles with no actress metadata bucket into `Unknown/`.

Overrides are request-scoped — they don't mutate `jvSettings.json`. Edit that file directly if you want persistent changes.

### Known limitations (v1)

- Two scrapers (R18.dev primary, javdb fallback). No aggregation across DMM/JavLibrary/etc.
- No settings-editor UI. Edit `jvSettings.json` directly.
- No Find tab, no trailer download UI, no metadata translation.
- javdb fallback requires Playwright + a manual one-time login. Session is cached for 30 days per the captured cookie.

### UI workflow

1. Type the source folder in the bottom-left path box, press Enter.
2. Toggle **Recurse source** to collate every video file beneath that root into one flat list (relative paths shown). Leave off for single-directory listings.
3. Type the destination folder in the **Sort** box.
4. Pick a preset button or edit the three format textboxes.
5. Use the dropdown + arrow buttons (top-left) to step through identified videos. Each step scrapes r18.dev, renders cover + Aggregated Data + actress cards, and updates the destination block under the cover.
6. **PREVIEW TREE** projects the entire output folder before committing anything.
7. Click ▶ Sort on a row, or **SORT ALL** inside the tree modal to commit.

### Web GUI troubleshooting

**"Pode module not found"** — `Install-Module Pode -Scope CurrentUser`.

**"JVWeb.ps1 not found at …"** — run from a Javinizer module tree. `JVWeb/` must sit next to `Public/` and `Private/`.

**Cover image shows, poster is uncropped** — first-run ImageSharp download failed (no network?). Restart with network available, or delete `~/.javinizer/assemblies/` to force re-download. Until the DLL caches, JVWeb falls back to copying the uncropped cover as `folder.jpg` and surfaces a warning toast.

**Browser didn't open** — pass `-NoBrowser` to suppress, then navigate manually. Or check that `Start-Process` (Windows) / `open` (macOS) / `xdg-open` (Linux) is on PATH.

## Example Output

A few examples of Javinizer's sort output are listed below.

### Basic Folder Structures

```json
"sort.format.folder": "<ID> [<STUDIO>] - <TITLE> (<YEAR>)",
"sort.format.outputfolder": []
```

```
├─IDBD-979 [Idea Pocket] - Yume Nishinomiya Ultimate Blowjob... (2020)
│      fanart.jpg
│      folder.jpg
│      IDBD-979.mp4
│      IDBD-979.nfo
│
├─IPX-399 [Idea Pocket] - Shes Luring You To Temptation... (2019)
│      fanart.jpg
│      folder.jpg
│      IPX-399.mp4
│      IPX-399.nfo
│
├─IPX-485 [Idea Pocket] - A Big Tits Wife Who Got Fucked... (2020)
│      fanart.jpg
│      folder.jpg
│      IPX-485.mp4
│      IPX-485.nfo
```

### Advanced Folder Structures

```json
"sort.format.folder": "<ID> [<STUDIO>] - <TITLE>",
"sort.format.outputfolder": ["<ACTORS>", "<YEAR>"]
```

```
├─Nishimiya Yume
│  └─2020
│      └─IDBD-979 [Idea Pocket] - Yume Nishinomiya Ultimate Blowjob...
│          │  fanart.jpg
│          │  folder.jpg
│          │  IDBD-979-trailer.mp4
│          │  IDBD-979.mp4
│          │  IDBD-979.nfo
│          │
│          ├─.actors
│          │      Nishimiya_Yume.jpg
│          │
│          └─extrafanart
│                  fanart1.jpg
│                  fanart2.jpg
│                  fanart3.jpg
│
└─Sakura Momo
    ├─2019
    │  └─IPX-399 [Idea Pocket] - Shes Luring You To Temptation...
    │      │  fanart.jpg
    │      │  folder.jpg
    │      │  IPX-399-trailer.mp4
    │      │  IPX-399.mp4
    │      │  IPX-399.nfo
    │      │
    │      ├─.actors
    │      │      Sakura_Momo.jpg
    │      │
    │      └─extrafanart
    │              fanart1.jpg
    │              fanart2.jpg
    │              fanart3.jpg
    │
    └─2020
        └─IPX-485 [Idea Pocket] - A Big Tits Wife Who Got Fucked...
            │  fanart.jpg
            │  folder.jpg
            │  IPX-485-trailer.mp4
            │  IPX-485.mp4
            │  IPX-485.nfo
            │
            ├─.actors
            │      Sakura_Momo.jpg
            │
            └─extrafanart
                    fanart1.jpg
                    fanart2.jpg
                    fanart3.jpg
```

### Metadata Output .nfo

A .nfo metadata file is created for each movie.

```
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
    <title>[IDBD-979] Yume Nishinomiya Ultimate Blowjoc Complete BEST - Lots of Cum, 40 Shots!</title>
    <originaltitle>西宮ゆめ 至高のフェラチオコンプリートBEST 大量射精40発！</originaltitle>
    <id>IDBD-979</id>
    <premiered>2020-09-12</premiered>
    <year>2020</year>
    <director></director>
    <studio>Idea Pocket</studio>
    <rating></rating>
    <votes></votes>
    <plot>デビュー4周年を迎えたアイポケの小悪魔美少女’’西宮ゆめ’’のフェラチオシーンのみを集めたベストが登場！</plot>
    <runtime>237</runtime>
    <trailer>https://awscc3001.r18.com/litevideo/freepv/i/idb/idbd00979/idbd00979_dmb_w.mp4</trailer>
    <mpaa>XXX</mpaa>
    <tagline></tagline>
    <set></set>
    <genre>Beautiful Girl</genre>
    <genre>Blowjob</genre>
    <genre>Facial</genre>
    <genre>Deep Throat</genre>
    <genre>Digital Mosaic</genre>
    <genre>Actress Best Compilation</genre>
    <actor>
        <name>Nishimiya Yume</name>
        <altname>西宮ゆめ</altname>
        <thumb>https://pics.r18.com/mono/actjpgs/nisimiya_yume.jpg</thumb>
        <role>Actress</role>
    </actor>
</movie>
```
