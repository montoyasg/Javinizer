#!/usr/bin/env python3
"""Build a local SQLite cache from r18.dev's weekly CC0 PostgreSQL dump.

r18.dev retired its public JSON detail API and now publishes a weekly,
public-domain PostgreSQL dump at https://r18.dev/dumps/latest. This script
streams that gzipped pg_dump, parses the plain-SQL CREATE TABLE / COPY blocks
for the tables Javinizer needs, and writes them into a local SQLite database
with the indexes required to look a movie up by dvd_id or content_id.

Stdlib only (urllib, gzip, sqlite3, json, re) -- no pip dependencies. The
companion r18dump_query.py reads the resulting database and emits a JSON
object in the shape the old r18.dev API returned, so the PowerShell field
extractors stay unchanged.

Usage:
    python3 r18dump_import.py --out /root/.javinizer/r18dev.sqlite
    python3 r18dump_import.py --out db.sqlite --source /path/to/dump.sql.gz
"""

import argparse
import gzip
import io
import json
import os
import re
import sqlite3
import sys
import tempfile
import time
import urllib.request

DEFAULT_URL = "https://r18.dev/dumps/latest"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; rv:128.0) Gecko/20100101 Firefox/128.0"
)

# Only the tables Javinizer reads. Each maps to the columns we keep (a subset
# is fine -- the parser aligns values by the COPY column list, not position).
WANTED_TABLES = {
    "derived_video",
    "derived_maker",
    "derived_label",
    "derived_series",
    "derived_category",
    "derived_video_category",
    "derived_actress",
    "derived_video_actress",
    "derived_director",
    "derived_video_director",
    "source_dmm_trailer",
    # JA->EN dictionary r18.dev applies on top of official DMM data; lets us
    # restore English titles/genres the derived_* tables leave untranslated.
    "machine_translation",
}

# Indexes to build after load: table -> list of column tuples.
INDEXES = {
    "derived_video": [("dvd_id",), ("content_id",), ("maker_id",),
                      ("label_id",), ("series_id",)],
    "derived_maker": [("id",)],
    "derived_label": [("id",)],
    "derived_series": [("id",)],
    "derived_category": [("id",)],
    "derived_actress": [("id",)],
    "derived_director": [("id",)],
    "derived_video_category": [("content_id",)],
    "derived_video_actress": [("content_id",)],
    "derived_video_director": [("content_id",)],
    "source_dmm_trailer": [("content_id",)],
    "machine_translation": [("source_ja",)],
}

BATCH = 5000

# pg COPY backslash escapes (text format). Real newlines/tabs inside data are
# escaped by pg_dump, so line-based reading is safe.
_UNESCAPE = {
    "\\": "\\", "b": "\b", "f": "\f", "n": "\n",
    "r": "\r", "t": "\t", "v": "\v",
}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def unescape_copy_field(value):
    """Decode one pg COPY text field. ``\\N`` (whole field) means NULL."""
    if value == "\\N":
        return None
    if "\\" not in value:
        return value
    out = []
    i = 0
    n = len(value)
    while i < n:
        ch = value[i]
        if ch == "\\" and i + 1 < n:
            nxt = value[i + 1]
            if nxt in _UNESCAPE:
                out.append(_UNESCAPE[nxt])
                i += 2
                continue
            # \ddd octal escape
            if nxt.isdigit():
                j = i + 1
                while j < n and j < i + 4 and value[j].isdigit():
                    j += 1
                try:
                    out.append(chr(int(value[i + 1:j], 8)))
                    i = j
                    continue
                except ValueError:
                    pass
            out.append(nxt)
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def open_dump(source):
    """Return (text_stream, source_url) for a local file or remote URL."""
    if source and os.path.exists(source):
        log("[r18dump] reading local dump %s" % source)
        raw = open(source, "rb")
        return io.TextIOWrapper(gzip.GzipFile(fileobj=raw), encoding="utf-8",
                                errors="replace"), source
    url = source or DEFAULT_URL
    log("[r18dump] downloading %s" % url)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    resp = urllib.request.urlopen(req, timeout=120)
    final_url = resp.geturl()
    log("[r18dump] resolved to %s" % final_url)
    return io.TextIOWrapper(gzip.GzipFile(fileobj=resp), encoding="utf-8",
                            errors="replace"), final_url


def dump_date_from_url(url):
    m = re.search(r"(\d{4}-\d{2}-\d{2})", url or "")
    return m.group(1) if m else None


def build(out_path, source):
    stream, source_url = open_dump(source)

    tmp_fd, tmp_path = tempfile.mkstemp(
        prefix=".r18dev.", suffix=".sqlite",
        dir=os.path.dirname(os.path.abspath(out_path)) or ".")
    os.close(tmp_fd)
    if os.path.exists(tmp_path):
        os.remove(tmp_path)

    conn = sqlite3.connect(tmp_path)
    conn.execute("PRAGMA journal_mode = OFF")
    conn.execute("PRAGMA synchronous = OFF")

    schemas = {}        # table -> [col, ...] from CREATE TABLE
    created = set()      # tables created in sqlite
    counts = {}

    copy_re = re.compile(r"^COPY public\.(\w+) \(([^)]*)\) FROM stdin;")
    create_re = re.compile(r"^CREATE TABLE public\.(\w+) \(")

    start = time.time()
    line_iter = iter(stream)
    for line in line_iter:
        line = line.rstrip("\n")

        m = create_re.match(line)
        if m:
            table = m.group(1)
            cols = []
            for col_line in line_iter:
                col_line = col_line.strip()
                if col_line.startswith(");") or col_line == ")":
                    break
                # "colname type ...," -> first token is the column name
                name = col_line.split()[0].strip('"')
                cols.append(name)
            schemas[table] = cols
            continue

        m = copy_re.match(line)
        if m:
            table = m.group(1)
            copy_cols = [c.strip().strip('"') for c in m.group(2).split(",")]
            if table not in WANTED_TABLES:
                # Skip this COPY block entirely.
                for skip in line_iter:
                    if skip.rstrip("\n") == "\\.":
                        break
                continue

            if table not in created:
                col_defs = ", ".join('"%s"' % c for c in copy_cols)
                conn.execute('CREATE TABLE "%s" (%s)' % (table, col_defs))
                created.add(table)
            placeholders = ", ".join("?" for _ in copy_cols)
            insert = 'INSERT INTO "%s" VALUES (%s)' % (table, placeholders)

            batch = []
            ncols = len(copy_cols)
            n = 0
            for data in line_iter:
                data = data.rstrip("\n")
                if data == "\\.":
                    break
                fields = data.split("\t")
                if len(fields) != ncols:
                    # be lenient: pad/truncate to column count
                    fields = (fields + [None] * ncols)[:ncols]
                row = [unescape_copy_field(f) if isinstance(f, str) else f
                       for f in fields]
                batch.append(row)
                if len(batch) >= BATCH:
                    conn.executemany(insert, batch)
                    n += len(batch)
                    batch = []
            if batch:
                conn.executemany(insert, batch)
                n += len(batch)
            counts[table] = n
            log("[r18dump]   loaded %s: %d rows" % (table, n))
            continue

    stream.close()

    missing = WANTED_TABLES - created
    if "derived_video" in missing:
        conn.close()
        os.remove(tmp_path)
        raise SystemExit("[r18dump] FATAL: derived_video not found in dump; "
                         "format may have changed")
    if missing:
        log("[r18dump] note: tables not present in dump: %s"
            % ", ".join(sorted(missing)))

    log("[r18dump] building indexes...")
    for table, idxs in INDEXES.items():
        if table not in created:
            continue
        for cols in idxs:
            if not all(c in schemas.get(table, cols) or True for c in cols):
                continue
            name = "idx_%s_%s" % (table, "_".join(cols))
            col_list = ", ".join('"%s"' % c for c in cols)
            try:
                conn.execute('CREATE INDEX "%s" ON "%s" (%s)'
                             % (name, table, col_list))
            except sqlite3.OperationalError as exc:
                log("[r18dump]   skip index %s: %s" % (name, exc))

    conn.commit()
    conn.close()

    os.replace(tmp_path, out_path)

    # Sidecar marker for the status indicator / staleness check.
    dump_date = dump_date_from_url(source_url)
    marker = {
        "dumpDate": dump_date,
        "sourceUrl": source_url,
        "builtAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "builtEpoch": int(time.time()),
        "rowCounts": counts,
    }
    with open(out_path + ".meta.json", "w", encoding="utf-8") as fh:
        json.dump(marker, fh, indent=2)

    elapsed = time.time() - start
    log("[r18dump] done in %.1fs -> %s (dump %s, %d videos)"
        % (elapsed, out_path, dump_date, counts.get("derived_video", 0)))
    return marker


def main():
    ap = argparse.ArgumentParser(description="Build local r18.dev SQLite cache")
    ap.add_argument("--out", required=True, help="output sqlite path")
    ap.add_argument("--source", default=None,
                    help="dump URL or local .sql.gz (default: dumps/latest)")
    args = ap.parse_args()

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    marker = build(args.out, args.source)
    # Machine-readable summary on stdout for callers that want it.
    print(json.dumps(marker))


if __name__ == "__main__":
    main()
