#!/usr/bin/env python3
"""Query the local r18.dev SQLite cache and emit old-API-shaped JSON.

Given a dvd_id or content_id, this reconstructs the exact JSON object that
r18.dev's retired ``/json`` detail endpoint used to return, so Javinizer's
existing PowerShell field extractors (Scraper.R18dev.ps1) consume it
unchanged. Prints the JSON object to stdout, or nothing (exit 3) on a miss.

Usage:
    python3 r18dump_query.py --db r18dev.sqlite --dvd-id ABF-343
    python3 r18dump_query.py --db r18dev.sqlite --content-id abf00343
"""

import argparse
import json
import re
import sqlite3
import sys


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# DMM image CDN. The dump stores image *paths* relative to this host and
# *without* a file extension; the old r18.dev API returned the full URLs.
DMM_BASE = "https://pics.dmm.co.jp/"
ACTRESS_BASE = "mono/actjpgs/"  # PowerShell prepends DMM_BASE to this itself
_IMG_EXT_RE = re.compile(r"\.(jpe?g|png|gif|webp)$", re.IGNORECASE)
_TRAIL_NUM_RE = re.compile(r"^(.*?)(\d+)$")
_NULL_ACTRESS = {"", "null", "----", "-", "n/a"}


def _media_url(path):
    """Turn a stored relative, extension-less image path into a full URL."""
    if not path:
        return None
    url = path if path.startswith("http") else DMM_BASE + path.lstrip("/")
    if not _IMG_EXT_RE.search(url):
        url += ".jpg"
    return url


def reconstruct_gallery(first, last):
    """Enumerate gallery image *paths* between the stored first/last markers.

    The dump stores only the first and last image path (e.g.
    ``.../<cid>jp-1`` .. ``.../<cid>jp-15``); the in-between images follow the
    same numbered pattern. Returns the ordered list of relative paths.
    """
    if not first:
        return []
    if not last or first == last:
        return [first]
    mf = _TRAIL_NUM_RE.match(first)
    ml = _TRAIL_NUM_RE.match(last)
    if not mf or not ml:
        return [first, last]
    prefix_f, n_first = mf.group(1), int(mf.group(2))
    prefix_l, n_last = ml.group(1), int(ml.group(2))
    if prefix_f != prefix_l:
        return [first, last]
    if n_last < n_first:           # malformed marker (e.g. last "-0")
        return [first]
    if n_last - n_first > 200:     # sanity guard
        return [first, last]
    return ["%s%d" % (prefix_f, i) for i in range(n_first, n_last + 1)]


def normalize_actress_image(value):
    """The dump stores bare filenames (sometimes extension-less) or sentinels."""
    if value is None:
        return None
    v = value.strip()
    if v.lower() in _NULL_ACTRESS:
        return None
    if v.startswith("http"):
        return v
    if not _IMG_EXT_RE.search(v):
        v += ".jpg"
    return v


def lookup(conn, dvd_id=None, content_id=None):
    cur = conn.cursor()
    cols = [r[1] for r in cur.execute("PRAGMA table_info(derived_video)")]
    if not cols:
        return None
    if content_id:
        cur.execute("SELECT * FROM derived_video WHERE content_id = ? LIMIT 1",
                    (content_id,))
    else:
        # dvd_id matches are case-insensitive; r18 stores upper-case.
        cur.execute("SELECT * FROM derived_video "
                    "WHERE dvd_id = ? COLLATE NOCASE LIMIT 1", (dvd_id,))
    row = cur.fetchone()
    if not row:
        return None
    v = dict(zip(cols, row))
    cid = v.get("content_id")

    _has_mt = cur.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='machine_translation'").fetchone() is not None

    def translate(ja):
        """JA->EN via r18.dev's machine_translation dictionary (exact match)."""
        if not _has_mt or not ja:
            return None
        r = cur.execute("SELECT target_en FROM machine_translation "
                        "WHERE source_ja = ? LIMIT 1", (ja,)).fetchone()
        return r[0] if r else None

    def en_or_translate(en, ja):
        """Prefer official English; fall back to the JA->EN translation."""
        return en if en else translate(ja)

    def name_row(table, _id):
        if _id in (None, ""):
            return {}
        r = cur.execute('SELECT * FROM "%s" WHERE id = ? LIMIT 1' % table,
                        (_id,)).fetchone()
        if not r:
            return {}
        tcols = [d[1] for d in cur.execute('PRAGMA table_info("%s")' % table)]
        return dict(zip(tcols, r))

    maker = name_row("derived_maker", v.get("maker_id"))
    label = name_row("derived_label", v.get("label_id"))
    series = name_row("derived_series", v.get("series_id"))

    # Categories (genres), ordered by category id for stability.
    categories = []
    for (catid,) in cur.execute(
            "SELECT category_id FROM derived_video_category "
            "WHERE content_id = ? ORDER BY CAST(category_id AS INTEGER)",
            (cid,)).fetchall():
        c = name_row("derived_category", catid)
        if c:
            categories.append({
                "name_en": en_or_translate(c.get("name_en"), c.get("name_ja")),
                "name_ja": c.get("name_ja"),
            })

    # Actresses, ordered by ordinality.
    actresses = []
    for (aid, _ord) in cur.execute(
            "SELECT actress_id, ordinality FROM derived_video_actress "
            "WHERE content_id = ? ORDER BY CAST(ordinality AS INTEGER)",
            (cid,)).fetchall():
        a = name_row("derived_actress", aid)
        if a:
            actresses.append({
                "name_romaji": a.get("name_romaji"),
                "name_kanji": a.get("name_kanji"),
                "image_url": normalize_actress_image(a.get("image_url")),
            })

    # Directors.
    directors = []
    for (did,) in cur.execute(
            "SELECT director_id FROM derived_video_director "
            "WHERE content_id = ?", (cid,)).fetchall():
        d = name_row("derived_director", did)
        if d:
            directors.append({"name_romaji": d.get("name_romaji"),
                              "name_kanji": d.get("name_kanji")})

    # Gallery: reconstruct full + thumb path lists, turn into URLs, pair them.
    full = reconstruct_gallery(v.get("gallery_full_first"),
                               v.get("gallery_full_last"))
    thumb = reconstruct_gallery(v.get("gallery_thumb_first"),
                                v.get("gallery_thumb_last"))
    gallery = []
    for i, fu in enumerate(full):
        gallery.append({
            "image_full": _media_url(fu),
            "image_thumb": _media_url(thumb[i]) if i < len(thumb) else None,
        })

    # Trailer: prefer derived_video.sample_url, fall back to source_dmm_trailer.
    sample_url = v.get("sample_url")
    if not sample_url:
        try:
            r = cur.execute("SELECT url FROM source_dmm_trailer "
                            "WHERE content_id = ? LIMIT 1", (cid,)).fetchone()
            if r:
                sample_url = r[0]
        except sqlite3.OperationalError:
            pass

    title_ja = v.get("title_ja")
    title_en = en_or_translate(v.get("title_en"), title_ja)
    comment_ja = v.get("comment_ja")
    return {
        "content_id": cid,
        "dvd_id": v.get("dvd_id"),
        "title_en": title_en,
        "title_ja": title_ja,
        "title": title_en or title_ja,
        "comment_en": en_or_translate(v.get("comment_en"), comment_ja),
        "comment_ja": comment_ja,
        "release_date": v.get("release_date"),
        "runtime_mins": v.get("runtime_mins"),
        "sample_url": sample_url,
        "maker_name_en": en_or_translate(maker.get("name_en"),
                                         maker.get("name_ja")),
        "maker_name_ja": maker.get("name_ja"),
        "label_name_en": en_or_translate(label.get("name_en"),
                                         label.get("name_ja")),
        "label_name_ja": label.get("name_ja"),
        "series_name_en": en_or_translate(series.get("name_en"),
                                          series.get("name_ja")),
        "series_name_ja": series.get("name_ja"),
        "categories": categories,
        "actresses": actresses,
        "directors": directors,
        "jacket_full_url": _media_url(v.get("jacket_full_url")),
        "jacket_thumb_url": _media_url(v.get("jacket_thumb_url")),
        "gallery": gallery,
    }


def main():
    ap = argparse.ArgumentParser(description="Query local r18.dev SQLite cache")
    ap.add_argument("--db", required=True)
    ap.add_argument("--dvd-id")
    ap.add_argument("--content-id")
    args = ap.parse_args()

    if not args.dvd_id and not args.content_id:
        ap.error("one of --dvd-id or --content-id is required")

    try:
        conn = sqlite3.connect("file:%s?mode=ro" % args.db, uri=True)
    except sqlite3.OperationalError as exc:
        log("[r18query] cannot open db: %s" % exc)
        return 2

    try:
        result = lookup(conn, dvd_id=args.dvd_id, content_id=args.content_id)
    finally:
        conn.close()

    if not result:
        return 3
    json.dump(result, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
