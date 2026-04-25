<h1 align="center">
  Javinizer-NG (JAV Organizer)
  <br>
</h1>

<h4 align="center"><strong>A Dockerized web application that scrapes metadata and sorts local Japanese Adult Video (JAV) files into a media-library-compatible layout. Fork of the original PowerShell Javinizer — now ships as a single container with a React sort workspace, a Pode/PowerShell backend, Chromium-backed javdb fallback, a built-in Google Translate module, and a noVNC desktop for first-run javdb login.</strong></h4>

<br>

<p align="center">
  <a href="https://hub.docker.com/r/montoyasg/javinizer-ng">
      <img src="https://img.shields.io/docker/pulls/montoyasg/javinizer-ng?style=plastic&color=red&label=docker"
      alt="Docker">
  </a>
  <a href="https://github.com/montoyasg/javinizer-ng/actions/workflows/docker-build-publish.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/montoyasg/javinizer-ng/docker-build-publish.yml?branch=master&style=plastic&label=build"
         alt="Build">
  </a>
</p>

<p align="center">
  <a href="#features"><strong>Features</strong></a> •
  <a href="#getting-started"><strong>Getting Started</strong></a> •
  <a href="#web-gui"><strong>Web GUI</strong></a> •
  <a href="#example-output"><strong>Examples</strong></a>

</p>

## Features

-   **Multi-scraper aggregation.** Metadata mixed and matched from R18.dev, Javlibrary, DMM/Fanza, JavBus, Jav321, Javdb, MGStage, AVEntertainment, DLGetchu, and TokyoHot. Per-field source priority is configurable via `jvSettings.json`.
-   **Javdb with Cloudflare bypass.** Javdb is driven through Microsoft.Playwright + Chromium. A session cookie (`_jdb_session` + `cf_clearance` when present) is captured on first use, persisted under `~/.config/Javinizer/`, and reused for ~30 days. Anonymous capture is zero-interaction; logged-in capture can be completed once through the bundled noVNC desktop.
-   **Built-in translator.** A pure-PowerShell `google_web` module scrapes the mobile Google Translate endpoint (no API key, no Python deps) to localize Title/Description/Series/Maker and Japanese actress names into your preferred language. Legacy `googletrans`, `google_trans_new`, and `deepl` modules remain selectable for users with those Python packages installed.
-   **React sort workspace.** A single-page React UI (served at `/next/`) for browsing source folders, live scrape previews, manual URL/ID search, poster image picker, actress-name editing, bulk tree dry-run, and per-row sort commits. The classic HTML/JS UI is still mounted at `/` for anyone who preferred it.
-   **Container-first deployment.** One multi-arch Docker image (`linux/amd64` + `linux/arm64`) bundles PowerShell 7.4, Pode, the Javinizer module, Chromium via Playwright, Python Pillow (for poster cropping), and an Xvfb + Fluxbox + noVNC desktop so javdb's one-time login works without an X server on the host.
-   **You own the data.** Per-movie `.nfo` files + covers + thumbs + actress portraits are written alongside the renamed video. Nothing is locked inside a media-server database.

## Getting Started

### Docker (recommended)

The multi-arch image is published to [`montoyasg/javinizer-ng`](https://hub.docker.com/r/montoyasg/javinizer-ng) on every push to `master`. It bundles JVWeb, Pode, the Javinizer module, Microsoft.Playwright + Chromium (for the javdb fallback), and a noVNC web desktop so the one-time javdb login can be done from your browser. Multi-arch: `linux/amd64` and `linux/arm64`.

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
- **Translation.** The built-in `google_web` module needs no extra dependencies and is selected by default when translation is toggled on from the JVWeb UI. Python-backed modules (`googletrans`, `google_trans_new`, `deepl`) are only invoked if you switch `sort.metadata.nfo.translate.module` in `jvSettings.json`; they require `docker exec javinizer-ng pip3 install <package>` first.

#### Host file ownership

By default the container runs as root, so files written during sort are owned by `root:root` on the host — unplayable / unmodifiable from SMB clients, Plex, Jellyfin, and `*arr` containers. Pass `PUID` / `PGID` to take ownership of sorted output.

**Unraid (most common).** Use the standard `nobody:users` IDs that match every LinuxServer.io / community-template container. In the Docker template UI, add:

- `PUID` = `99`
- `PGID` = `100`

**Other Linux / macOS workstation.** Use your own host user/group:

```bash
docker run \
  -e PUID=$(id -u) -e PGID=$(id -g) \
  ... montoyasg/javinizer-ng:latest
```

When `PUID` / `PGID` are set, sort runs `chown -R` on the destination folder after each move. Leave them unset to keep the legacy root-ownership behavior.

### Running from source (development)

For contributors or users who prefer not to use Docker:

```powershell
# Prereqs: PowerShell 7.2+, Pode, .NET 8 SDK (for Playwright)
Install-Module Pode -Scope CurrentUser
git clone https://github.com/montoyasg/javinizer-ng.git
cd javinizer-ng
Import-Module ./src/Javinizer/Javinizer.psd1
Start-JVWeb                           # http://127.0.0.1:8600
Start-JVWeb -Bind 0.0.0.0 -NoBrowser  # LAN access, headless
```

For the javdb fallback locally, install Microsoft.Playwright + Chromium per the [Web GUI requirements](#web-gui-requirements) below. On first scrape, JVWeb auto-downloads SixLabors.ImageSharp (~1 MB) into `~/.javinizer/assemblies/` for poster cropping.

## Web GUI

A portable PowerShell-native replacement for the old PowerShell Universal dashboard. Backend is [Pode](https://badgerati.github.io/Pode/) (a PowerShell HTTP server). Two frontends are mounted:

- **`/next/`** — the current React sort workspace (`design/javinizer-sort/app.jsx`, vanilla React 18 UMD + Babel standalone, no build step). Source-folder browser, inline scrape previews, manual URL/ID search modal, custom poster picker, actress edit, translator toggle, bulk-tree dry-run + commit.
- **`/`** — the original HTML/CSS/JS UI; kept mounted for backward compat.

R18.dev is the primary scraper; **javdb.com is the fallback** when R18.dev has no match (gated by `web.scrape.javdb.fallback` and a cached Cloudflare/login session). NFO + cover crop + thumbs are retained via the existing `Set-JVMovie` pipeline — nothing in the core scrape/sort stack is re-implemented here.

### Web GUI requirements

These matter only when running from source — the Docker image has everything baked in.

- **PowerShell 7.2+** (javdb session capture uses Playwright for .NET which targets .NET 6+)
- **Pode** PowerShell module (`Install-Module Pode -Scope CurrentUser`)
- **Javinizer** module loaded or available for import
- **Network on first launch** — to auto-download SixLabors.ImageSharp (~1 MB, used for cropped posters). Cached afterwards at `~/.javinizer/assemblies/`.
- **Microsoft.Playwright (optional, for javdb fallback)** — javdb is behind Cloudflare; the module auto-captures the `_jdb_session` cookie by launching Chromium. Anonymous capture is zero-interaction; login-required sites can be completed through a browser window. Install:

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
│   ├── Start-JVWebServer.ps1    Pode bootstrap (16-thread pool, 300s timeout)
│   ├── Routes.Browse.ps1        /api/browse, /api/files
│   ├── Routes.Scrape.ps1        /api/scrape, /api/screens, /api/manual-search
│   ├── Routes.Preview.ps1       /api/preview, /api/preview-tree
│   ├── Routes.Sort.ps1          /api/sort
│   └── Routes.Settings.ps1      /api/settings, /api/translator/health
├── Lib/
│   ├── Invoke-JVScrapeCached.ps1      session cache around R18Dev + Javdb
│   ├── Apply-TranslationToScrapeData.ps1  wires google_web into /api/scrape
│   ├── Resolve-JVPreview.ps1          single + bulk tree dry-run
│   ├── Invoke-JVSortOne.ps1           thin wrapper over Set-JVMovie
│   ├── Get-JVEffectiveSettings.ps1    merges base settings + UI overrides
│   └── Open-JVBrowser.ps1              cross-platform browser opener
└── static/                      legacy HTML/CSS/JS UI, mounted at /

design/javinizer-sort/           React sort workspace, mounted at /next/
├── index.html
├── app.jsx                      single-file React 18 SPA
├── style.css
└── vendor/                      react + react-dom + babel UMD bundles
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

#### `GET /api/settings` / `POST /api/settings`

Returns or updates the whitelisted subset of `jvSettings.json` keys (sort formats, scraper toggles, javdb fallback, translator module + field list, deepl API key, etc.). POST persists to disk. The React UI's translator toggle writes here, forcing `sort.metadata.nfo.translate.module = "google_web"` and the Title/Description/Series/Maker field list when enabled.

#### `GET /api/translator/health`

Pings the currently configured translator with a short probe string and returns `{ status, module, latencyMs, captcha }`. Used by the UI to colour the translator badge.

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

### Known limitations

- Two scrapers are wired into JVWeb: R18.dev primary + javdb fallback. The other scrapers in the Javinizer module (DMM, Javlibrary, Javbus, etc.) are only reachable via the legacy CLI / module functions; no JVWeb aggregation UI across all ten sources yet.
- No full settings-editor UI. JVWeb exposes sort-format textboxes and a translator toggle; everything else still lives in `jvSettings.json`.
- No Find tab, no trailer download UI.
- Javdb fallback needs Chromium + Playwright. Anonymous capture is zero-interaction; for logged-in access, complete the one-time login inside the bundled noVNC desktop (Docker) or a headed Chromium window (source install). Session is cached ~30 days.

### UI workflow (React `/next/` UI)

1. Type the source folder in the path box, press Enter.
2. Toggle **Recurse source** to flatten every video below that root into one list (relative paths shown). Leave off for single-directory listings.
3. Type the destination folder in the **Sort** box.
4. Pick a preset or edit the `sort.format.outputfolder` / `sort.format.folder` / `sort.format.file` textboxes.
5. (Optional) Enable the **Translator** toggle to localize Title/Description/Series/Maker + Japanese actress names via the `google_web` module. Health/latency is shown inline.
6. Step through identified videos with the dropdown + arrow buttons. Each step scrapes R18.dev (falling back to javdb on no-match), renders cover + Aggregated Data + actress cards, and updates the destination block under the cover.
7. Need a non-matching title? Open the **Manual search** modal and paste an R18.dev or javdb URL, or a plain content ID.
8. Want a different poster crop? Open **Custom poster** and pick from scraped screenshots before committing.
9. **PREVIEW TREE** projects the entire output folder before committing anything.
10. Click ▶ Sort on a row, or **SORT ALL** inside the tree modal to commit.

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
