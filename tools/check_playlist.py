#!/usr/bin/env python3
"""Report on signed-token expiry (and optionally reachability) for kino.m3u.

Some entries proxy an upstream stream through a stitcher, carrying the real URL
base64-encoded in a `source=` query param. That inner URL has an `e=` field --
a Unix timestamp after which the signature `st=` stops being accepted. This
script decodes those and says which ones are dead or about to die.

Usage:
    tools/check_playlist.py                    # expiry report
    tools/check_playlist.py --check-links      # also probe every URL
    tools/check_playlist.py --json             # machine-readable
    tools/check_playlist.py --days 14          # "expiring soon" window

Exits 1 if any token has already expired, 0 otherwise.
"""

import argparse
import base64
import binascii
import gzip
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

DEFAULT_PLAYLIST = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "kino.m3u"
)
DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
)


class Entry(object):
    """One channel: its #EXTINF name, its URL, and any VLC option lines."""

    def __init__(self, name, url, line_no, opts):
        self.name = name
        self.url = url
        self.line_no = line_no
        self.opts = opts

    @property
    def referrer(self):
        return self.opts.get("http-referrer")

    @property
    def user_agent(self):
        return self.opts.get("http-user-agent", DEFAULT_UA)


def extinf_title(line):
    """Title is what follows the attribute list.

    The attributes carry quoted values that themselves contain commas (a
    user-agent string, most often), so split on the first comma that falls
    outside quotes rather than the first comma outright.
    """
    in_quote = False
    for index, char in enumerate(line):
        if char == '"':
            in_quote = not in_quote
        elif char == "," and not in_quote:
            return line[index + 1:].strip() or "(unnamed)"
    return "(unnamed)"


def parse_playlist(path):
    """Walk the m3u, pairing each #EXTINF (plus its #EXTVLCOPTs) with its URL."""
    entries = []
    name = None
    opts = {}
    with open(path, encoding="utf-8") as fh:
        for line_no, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#EXTINF:"):
                name = extinf_title(line)
                opts = {}
            elif line.startswith("#EXTVLCOPT:"):
                kv = line[len("#EXTVLCOPT:"):]
                if "=" in kv:
                    key, value = kv.split("=", 1)
                    opts[key.strip()] = value.strip()
            elif line.startswith("#"):
                continue
            else:
                entries.append(Entry(name or "(unnamed)", line, line_no, opts))
                name = None
                opts = {}
    return entries


def decode_source(url):
    """Return the decoded upstream URL from a `source=` param, or None."""
    query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    values = query.get("source")
    if not values:
        return None
    blob = values[0]
    # parse_qs already percent-decoded; base64 needs its padding restored.
    padded = blob + "=" * (-len(blob) % 4)
    try:
        return base64.b64decode(padded).decode("utf-8", "replace")
    except (binascii.Error, ValueError):
        return None


AUTH_PARAM = re.compile(
    r"(?:^|[?&])(token|secret|st|sig|signature|key|auth|hash|password|username|id)=",
    re.I,
)


def has_credentials(url):
    """True if the URL carries subscriber credentials, surface or embedded.

    Stitcher URLs hide the real query string inside a base64 `source=` param,
    so a plain scan of the outer URL misses the account id and secret entirely.
    """
    if AUTH_PARAM.search(urllib.parse.urlparse(url).query):
        return True
    inner = decode_source(url)
    return bool(inner and AUTH_PARAM.search(urllib.parse.urlparse(inner).query))


def token_info(url):
    """Extract expiry and identity fields from a stitched URL, if present."""
    inner = decode_source(url)
    if inner is None:
        return None
    fields = urllib.parse.parse_qs(urllib.parse.urlparse(inner).query)
    first = lambda key: (fields.get(key) or [None])[0]
    expires_raw = first("e")
    expires_at = None
    if expires_raw and expires_raw.isdigit():
        expires_at = datetime.fromtimestamp(int(expires_raw), tz=timezone.utc)
    return {
        "upstream": inner.split("?", 1)[0],
        "expires_at": expires_at,
        "account_id": first("id"),
        "secret": first("secret"),
        "signature": first("st"),
    }


def humanize(delta):
    """Render a timedelta as a coarse, signed duration string."""
    seconds = int(abs(delta.total_seconds()))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        text = "%dd %dh" % (days, hours)
    elif hours:
        text = "%dh %dm" % (hours, minutes)
    else:
        text = "%dm" % minutes
    return text if delta.total_seconds() >= 0 else text + " ago"


def probe(entry, timeout):
    """Fetch the URL and report the HTTP status / whether it looks like HLS."""
    request = urllib.request.Request(entry.url, method="GET")
    request.add_header("User-Agent", entry.user_agent)
    request.add_header("Accept-Encoding", "identity")
    if entry.referrer:
        request.add_header("Referer", entry.referrer)
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as resp:
            raw = resp.read(4096)
            # Some origins gzip regardless of Accept-Encoding.
            if raw[:2] == b"\x1f\x8b":
                try:
                    raw = gzip.decompress(raw)
                except (OSError, EOFError):
                    pass  # truncated at 4096 bytes; the prefix check below still works
            body = raw.decode("utf-8", "replace")
            return {
                "status": resp.status,
                "ok": resp.status == 200 and body.lstrip().startswith("#EXTM3U"),
                "detail": "manifest" if "#EXTM3U" in body else "not a manifest",
            }
    except urllib.error.HTTPError as exc:
        return {"status": exc.code, "ok": False, "detail": exc.reason or "http error"}
    except Exception as exc:  # socket, DNS, TLS, timeout -- all just "unreachable"
        return {"status": None, "ok": False, "detail": type(exc).__name__}


def redact(secret, show):
    if not secret:
        return None
    return secret if show else secret[:2] + "*" * (len(secret) - 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("playlist", nargs="?", default=DEFAULT_PLAYLIST)
    parser.add_argument("--days", type=float, default=7,
                        help="warn when a token expires within this many days (default: 7)")
    parser.add_argument("--check-links", action="store_true",
                        help="also probe every URL in the playlist over HTTP")
    parser.add_argument("--timeout", type=float, default=10,
                        help="per-request timeout in seconds (default: 10)")
    parser.add_argument("--workers", type=int, default=12,
                        help="concurrent probes when --check-links (default: 12)")
    parser.add_argument("--show-secrets", action="store_true",
                        help="print account secrets in full instead of masking them")
    parser.add_argument("--json", action="store_true", dest="as_json")
    args = parser.parse_args()

    entries = parse_playlist(args.playlist)
    now = datetime.now(timezone.utc)
    warn_window = args.days * 86400

    rows = []
    for entry in entries:
        info = token_info(entry.url)
        row = {
            "name": entry.name,
            "line": entry.line_no,
            "signed": info is not None,
        }
        if info:
            row["upstream"] = info["upstream"]
            row["account_id"] = info["account_id"]
            row["secret"] = redact(info["secret"], args.show_secrets)
            if info["expires_at"]:
                remaining = info["expires_at"] - now
                row["expires_at"] = info["expires_at"].isoformat()
                row["seconds_left"] = int(remaining.total_seconds())
                if remaining.total_seconds() <= 0:
                    row["state"] = "EXPIRED"
                elif remaining.total_seconds() <= warn_window:
                    row["state"] = "SOON"
                else:
                    row["state"] = "OK"
            else:
                row["state"] = "NO EXPIRY"
        rows.append(row)

    if args.check_links:
        # Probing is all network wait, so fan it out; results stay in row order.
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            results = list(pool.map(lambda e: probe(e, args.timeout), entries))
        # A third of this playlist sits on one host, so the fan-out can trip
        # throttling and report a live stream as dead. Retry failures serially
        # before believing them.
        for index, result in enumerate(results):
            if not result["ok"]:
                results[index] = probe(entries[index], args.timeout)
        for row, result in zip(rows, results):
            row["probe"] = result

    signed = [r for r in rows if r["signed"]]
    expired = [r for r in signed if r.get("state") == "EXPIRED"]

    if args.as_json:
        json.dump(rows, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 1 if expired else 0

    print("Playlist: %s" % args.playlist)
    print("Now:      %s UTC\n" % now.strftime("%Y-%m-%d %H:%M"))

    if signed:
        print("Signed (token-bearing) entries")
        print("-" * 78)
        for row in signed:
            state = row.get("state", "?")
            when = row.get("expires_at", "")[:16].replace("T", " ")
            left = humanize(
                datetime.fromisoformat(row["expires_at"]) - now
            ) if row.get("expires_at") else "-"
            print("  [%-7s] %-28s expires %s UTC  (%s)"
                  % (state, row["name"][:28], when or "unknown", left))
            print("             line %-4d account %s  secret %s"
                  % (row["line"], row.get("account_id") or "?", row.get("secret") or "?"))
            print("             upstream %s" % row.get("upstream", "?"))
        print()
    else:
        print("No token-bearing entries found.\n")

    if args.check_links:
        failures = [r for r in rows if not r["probe"]["ok"]]
        print("Reachability: %d/%d entries served a manifest"
              % (len(rows) - len(failures), len(rows)))
        print("-" * 78)
        for row in failures:
            probe_result = row["probe"]
            status = probe_result["status"] or "---"
            print("  [%-4s] line %-4d %-34s %s"
                  % (status, row["line"], row["name"][:34], probe_result["detail"]))
        print()

    if expired:
        print("%d token(s) already expired -- refresh them from your provider."
              % len(expired))
    return 1 if expired else 0


if __name__ == "__main__":
    sys.exit(main())
