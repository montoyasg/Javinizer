# Javinizer Web GUI (`JVWeb/`)

A lightweight, portable replacement for the old PowerShell Universal dashboard. Pure PowerShell backend (via [Pode](https://badgerati.github.io/Pode/)) + vanilla HTML/CSS/JS frontend. Cross-platform (Windows / macOS / Linux). No bundled binaries.

Scope of v1: **Sort page only**. Primary scraper is R18.dev; **javdb.com is used as a fallback** when R18.dev has no match (gated by `web.scrape.javdb.fallback` and a cached login session). NFO + cover crop + thumbs are retained via the existing `Set-JVMovie` pipeline — nothing in the core scrape/sort stack is re-implemented here.

## Requirements

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

## Run

### As a Javinizer cmdlet

```powershell
Import-Module Javinizer
Start-JVWeb            # http://127.0.0.1:8600, opens browser
Start-JVWeb -Port 9000 # custom port
Start-JVWeb -Bind 0.0.0.0 -NoBrowser  # LAN access, don't auto-open
```

### Standalone

```bash
pwsh ./JVWeb.ps1 -Port 8600
```

`JVWeb.ps1` finds the Javinizer manifest in its parent directory and imports it automatically.

## Folder layout

```text
JVWeb/
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

## API reference

All responses are JSON. No scriptblocks in payloads (that was the bug in the old GUI).

### `GET /api/browse?path=<str>`

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

### `GET /api/files?path=&page=&pageSize=&search=`

Same shape but paginated + searchable.

### `POST /api/scrape`

Body: `{ "path": "/full/path/to/video.mp4" }`
Extracts ID from filename, scrapes R18.dev, falls back to javdb if enabled and R18.dev has no match, returns full metadata object (the `Source` field identifies which scraper won).

### `POST /api/manual-search`

Body: `{ "query": "CAWD-125" }`, `{ "query": "https://r18.dev/videos/..." }`, or `{ "query": "https://javdb.com/v/..." }`
Bypasses filename parsing. Direct URLs are routed by domain.

### `POST /api/javdb/session/refresh`

No body. Launches Chromium via Playwright and waits for the user to log in to javdb. Captures `_jdb_session` (and `cf_clearance` if present), persists to `~/.config/Javinizer/javdb-session.json` (macOS/Linux) or `%LOCALAPPDATA%\Javinizer\javdb-session.json` (Windows), and returns `{ status, capturedAt, expiresAt }`. The cookie itself is never returned to the browser.

### `POST /api/preview`

Body: `{ path, destinationPath, settingsOverride }`
Dry-run. Returns the computed `folderPath`/`filePath` without moving anything.

### `POST /api/preview-tree`

Body: `{ paths: [], destinationPath, settingsOverride }`
Bulk dry-run. Returns a nested tree structure + an `unresolved` array for failures.

### `POST /api/sort`

Body: `{ path, destinationPath, settingsOverride, flags, data }`
Commits the move via `Set-JVMovie`. `data` is optional — if passed, overrides re-scraping.

## Scrape cache

`Invoke-JVScrapeCached` stores results in a Pode shared state (`scrapeCache`) keyed by content ID. It persists for the server's lifetime. This means:

- `preview-tree` + per-row `sort` never double-scrape the same ID.
- Manual-search results are cached too (by URL and by ID).
- Restart the server to flush.

## Customizing sort-tree

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

## Known limitations (v1)

- Two scrapers (R18.dev primary, javdb fallback). No aggregation across DMM/JavLibrary/etc.
- No settings-editor UI. Edit `jvSettings.json` directly.
- No Find tab, no trailer download UI, no metadata translation.
- javdb fallback requires Playwright + a manual one-time login. Session is cached for 30 days per the captured cookie.

## UI workflow

1. Type the source folder in the bottom-left path box, press Enter.
2. Toggle **Recurse source** to collate every video file beneath that root into one flat list (relative paths shown). Leave off for single-directory listings.
3. Type the destination folder in the **Sort** box.
4. Pick a preset button or edit the three format textboxes.
5. Use the dropdown + arrow buttons (top-left) to step through identified videos. Each step scrapes r18.dev, renders cover + Aggregated Data + actress cards, and updates the destination block under the cover.
6. **PREVIEW TREE** projects the entire output folder before committing anything.
7. Click ▶ Sort on a row, or **SORT ALL** inside the tree modal to commit.

## Troubleshooting

**"Pode module not found"** — `Install-Module Pode -Scope CurrentUser`.

**"JVWeb.ps1 not found at …"** — run from a Javinizer module tree. `JVWeb/` must sit next to `Public/` and `Private/`.

**Cover image shows, poster is uncropped** — first-run ImageSharp download failed (no network?). Restart with network available, or delete `~/.javinizer/assemblies/` to force re-download. Until the DLL caches, JVWeb falls back to copying the uncropped cover as `folder.jpg` and surfaces a warning toast.

**Browser didn't open** — pass `-NoBrowser` to suppress, then navigate manually. Or check that `Start-Process` (Windows) / `open` (macOS) / `xdg-open` (Linux) is on PATH.
