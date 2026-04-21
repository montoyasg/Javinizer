#!/usr/bin/env python3
"""Extract javdb.com cookies from a local browser profile.

Usage: python3 browser_cookies.py <browser>
  where <browser> is one of: chrome, chromium, edge, brave, firefox, opera, safari

Prints a JSON object to stdout on success:
  {"session": "...", "cf_clearance": "...", "remember": "...", "source": "browser:chrome"}

Exits non-zero on error and prints a human-readable message to stderr.
Values may be null when the cookie is missing from the profile.
"""

import json
import sys

SUPPORTED = {
    'chrome':   'chrome',
    'chromium': 'chromium',
    'edge':     'edge',
    'brave':    'brave',
    'firefox':  'firefox',
    'opera':    'opera',
    'safari':   'safari',
}


def main() -> int:
    if len(sys.argv) < 2:
        print('usage: browser_cookies.py <chrome|chromium|edge|brave|firefox|opera|safari>', file=sys.stderr)
        return 2

    browser = sys.argv[1].strip().lower()
    if browser not in SUPPORTED:
        print(f'unsupported browser: {browser}', file=sys.stderr)
        return 2

    try:
        import browser_cookie3  # type: ignore
    except ImportError:
        print('browser_cookie3 is not installed. Run: pip3 install browser_cookie3', file=sys.stderr)
        return 3

    fn = getattr(browser_cookie3, SUPPORTED[browser], None)
    if fn is None:
        print(f'browser_cookie3 has no loader for {browser}', file=sys.stderr)
        return 4

    try:
        cj = fn(domain_name='javdb.com')
    except Exception as e:
        print(f'failed to read cookies from {browser}: {e}', file=sys.stderr)
        return 5

    cookies = {c.name: c.value for c in cj}

    out = {
        'session':      cookies.get('_jdb_session'),
        'cf_clearance': cookies.get('cf_clearance'),
        'remember':     cookies.get('remember_me_token'),
        'source':       f'browser:{browser}',
    }
    json.dump(out, sys.stdout)
    return 0


if __name__ == '__main__':
    sys.exit(main())
