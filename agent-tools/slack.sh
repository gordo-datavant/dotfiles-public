#!/usr/bin/env bash
# fetch-slack.sh — Read-only Slack fetcher using browser session tokens
set -euo pipefail

# Browser fingerprint constants — update when Chrome version changes
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36'
SEC_CH_UA='"Not:A-Brand";v="99", "Google Chrome";v="145", "Chromium";v="145"'
PAGE_DELAY_MIN=0.8
PAGE_DELAY_MAX=2.0

usage() {
  cat <<'EOF'
Usage: fetch-slack.sh [OPTIONS] <query|url>

Fetch Slack messages via search, channel/DM history, or thread replies.

Arguments:
  <query|url>   A search query ("from:user keyword") or a Slack URL:
                   Channel/DM:  https://...slack.com/archives/CHANNEL_ID
                   Thread:      https://...slack.com/archives/CHANNEL_ID/pTIMESTAMP

Options:
  -n, --count NUM       Number of results for search (default: 30)
  -p, --max-pages NUM   Max pages for channel history (default: 5)
  -s, --page-size NUM   Messages per page for channel history (default: 200,
                        max: 200)
  --raw                 Output raw JSON instead of formatted text
  --setup               Extract credentials from Chrome and print export commands
  --update-creds        Read pasted cURL/headers from stdin, extract token & cookie,
                        print export commands. Usage: pbpaste | slack.sh --update-creds
  -h, --help            Show this help message

Environment variables (required):
  SLACK_TOKEN    Browser session token (xoxc-...)
  SLACK_COOKIE   Browser session cookie (d=xoxd-...)

  Run --setup to extract these automatically from Chrome, or manually:
    1. Open Slack in Chrome → DevTools (F12) → Network tab
    2. Filter by "api", right-click any request → Copy as cURL
    3. Run: pbpaste | slack.sh --update-creds

Examples:
  eval "$(fetch-slack.sh --setup)"
  fetch-slack.sh "from:alice project update"
  fetch-slack.sh https://myco.slack.com/archives/C0AHG8YG8G3
  fetch-slack.sh -n 50 "in:#general hello"
  fetch-slack.sh --max-pages 20 https://myco.slack.com/archives/C0AHG8YG8G3
EOF
  exit "${1:-0}"
}

setup_credentials() {
  python3 << 'PYEOF'
import subprocess, sqlite3, tempfile, shutil, re, sys, os
from hashlib import pbkdf2_hmac
import urllib.request

# --- Get Chrome decryption key from macOS Keychain ---
try:
    pw = subprocess.check_output(
        ["security", "find-generic-password", "-s", "Chrome Safe Storage", "-a", "Chrome", "-w"],
        text=True, stderr=subprocess.DEVNULL
    ).strip()
except subprocess.CalledProcessError:
    print("ERROR: Could not read Chrome Safe Storage from Keychain.", file=sys.stderr)
    print("Make sure Chrome is installed and you have granted Keychain access.", file=sys.stderr)
    sys.exit(1)

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding as sym_padding

key = pbkdf2_hmac("sha1", pw.encode(), b"saltysalt", 1003, dklen=16)
print(f"Keychain password OK", file=sys.stderr)

def decrypt_v10(blob, strip_domain_hash=False):
    """AES-128-CBC decrypt a v10 cookie blob."""
    ct = blob[3:]
    iv = b' ' * 16
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    dec = cipher.decryptor()
    padded = dec.update(ct) + dec.finalize()
    # PKCS7 unpadding
    pad_len = padded[-1]
    if pad_len < 1 or pad_len > 16 or padded[-pad_len:] != bytes([pad_len]) * pad_len:
        raise ValueError(f"bad PKCS7 padding (pad_byte={pad_len})")
    raw = padded[:-pad_len]
    # Chrome 128+ (DB version >= 24): 32-byte SHA-256 domain hash prepended
    if strip_domain_hash:
        raw = raw[32:]
    return raw.decode("utf-8")

# --- Find the right Chrome profile ---
chrome_base = os.path.expanduser("~/Library/Application Support/Google/Chrome")
if not os.path.isdir(chrome_base):
    print("ERROR: Chrome data directory not found.", file=sys.stderr)
    sys.exit(1)

profiles = ["Default"] + sorted([
    d for d in os.listdir(chrome_base)
    if d.startswith("Profile") and os.path.isdir(os.path.join(chrome_base, d))
])

cookie_val = None
errors = []
for profile in profiles:
    db_path = os.path.join(chrome_base, profile, "Cookies")
    if not os.path.exists(db_path):
        continue
    tmp = tempfile.mktemp(suffix=".db")
    shutil.copy2(db_path, tmp)
    try:
        conn = sqlite3.connect(tmp)
        # Chrome 128+ (DB version >= 24) prepends 32-byte domain hash to plaintext
        db_version = conn.execute(
            "SELECT value FROM meta WHERE key = 'version'"
        ).fetchone()
        strip_hash = db_version is not None and int(db_version[0]) >= 24
        if strip_hash:
            print(f"  {profile}: cookie DB version {db_version[0]} (domain hash enabled)", file=sys.stderr)

        rows = conn.execute(
            "SELECT encrypted_value FROM cookies "
            "WHERE host_key LIKE '%slack.com' AND name = 'd' "
            "ORDER BY expires_utc DESC LIMIT 1"
        ).fetchall()
        conn.close()
    finally:
        os.unlink(tmp)
    if rows:
        blob = rows[0][0]
        try:
            version = blob[:3]
            if blob.startswith(b"xoxd-"):
                cookie_val = blob.decode("utf-8")
            elif version == b"v10":
                cookie_val = decrypt_v10(blob, strip_domain_hash=strip_hash)
            else:
                raise ValueError(f"unsupported cookie version: {version!r}")
            if cookie_val.startswith("xoxd-"):
                print(f"Found Slack cookie in Chrome ({profile})", file=sys.stderr)
                break
            else:
                errors.append(f"{profile}: decrypted but got unexpected value (starts with {cookie_val[:10]!r}...)")
                cookie_val = None
        except Exception as e:
            errors.append(f"{profile}: {e} [version={blob[:3]!r}, len={len(blob)}]")
            continue

if not cookie_val:
    print("ERROR: Could not decrypt Slack cookie from Chrome.", file=sys.stderr)
    for err in errors:
        print(f"  {err}", file=sys.stderr)
    print("", file=sys.stderr)
    print("Try the manual method instead:", file=sys.stderr)
    print("  1. Open Slack in Chrome → DevTools (F12) → Network tab", file=sys.stderr)
    print("  2. Filter by 'api', right-click any request → Copy as cURL", file=sys.stderr)
    print("  3. Run: pbpaste | slack.sh --update-creds", file=sys.stderr)
    sys.exit(1)

# --- Extract token from Slack ---
# Fetch a Slack page that embeds the xoxc- session token in its boot data.
# /customize/emoji works reliably; app.slack.com often doesn't for enterprise.
print("Fetching token from Slack...", file=sys.stderr)
headers = {
    "Cookie": f"d={cookie_val}",
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
}
token = None
for url in ["https://slack.com/customize/emoji", "https://app.slack.com/"]:
    try:
        req = urllib.request.Request(url, headers=headers)
        html = urllib.request.urlopen(req).read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"  {url}: fetch failed ({e})", file=sys.stderr)
        continue
    m = re.search(r'"token"\s*:\s*"(xoxc-[^"]+)"', html) or \
        re.search(r'(xoxc-[0-9]+-[0-9]+-[0-9]+-[0-9a-f]{64})', html)
    if m:
        token = m.group(1)
        break

if not token:
    print("Got cookie but could not extract token from Slack.", file=sys.stderr)
    print("Cookie extracted — to get the token, copy a Slack API request as cURL and run:", file=sys.stderr)
    print("  pbpaste | slack.sh --update-creds", file=sys.stderr)
    print(f'export SLACK_COOKIE="d={cookie_val}"')
    sys.exit(1)

print("Done!", file=sys.stderr)
print(f'export SLACK_TOKEN="{token}"')
print(f'export SLACK_COOKIE="d={cookie_val}"')
PYEOF
}

update_credentials() {
  local input
  input=$(cat)
  _SLACK_CRED_INPUT="$input" python3 << 'PYEOF'
import sys, re, os

data = os.environ["_SLACK_CRED_INPUT"]
if not data.strip():
    print("ERROR: No input. Pipe a 'Copy as cURL' command or raw headers.", file=sys.stderr)
    print("Usage: pbpaste | slack.sh --update-creds", file=sys.stderr)
    sys.exit(1)

token = None
cookie = None

# Look for xoxc- token
m = re.search(r'(xoxc-[0-9A-Za-z]+-[0-9A-Za-z+/=%-]+)', data)
if m:
    token = m.group(1)

# Look for xoxd- cookie (may be URL-encoded with %3D for =)
m = re.search(r'(xoxd-[0-9A-Za-z%+/=-]+)', data)
if m:
    cookie = m.group(1)

if not token and not cookie:
    print("ERROR: Could not find xoxc- token or xoxd- cookie in input.", file=sys.stderr)
    print("Make sure you pasted a 'Copy as cURL' command from a Slack API request.", file=sys.stderr)
    sys.exit(1)

if token:
    print(f'export SLACK_TOKEN="{token}"')
else:
    print("WARNING: Could not find xoxc- token in input.", file=sys.stderr)

if cookie:
    print(f'export SLACK_COOKIE="d={cookie}"')
else:
    print("WARNING: Could not find xoxd- cookie in input.", file=sys.stderr)

found = []
if token: found.append("token")
if cookie: found.append("cookie")
print(f"Extracted: {', '.join(found)}", file=sys.stderr)
PYEOF
}

# --- Parse arguments ---
COUNT=30
MAX_PAGES=5
PAGE_SIZE=200
RAW=false
INPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      usage 0 ;;
    --setup)        setup_credentials; exit ;;
    --update-creds) update_credentials; exit ;;
    -n|--count)     COUNT="$2"; shift 2 ;;
    -p|--max-pages) MAX_PAGES="$2"; shift 2 ;;
    -s|--page-size) PAGE_SIZE="$2"; shift 2 ;;
    --raw)          RAW=true; shift ;;
    -*)             echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    *)
      if [[ -z "$INPUT" ]]; then
        INPUT="$1"; shift
      else
        echo "Unexpected argument: $1 (try --help)" >&2; exit 1
      fi
      ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  usage 1
fi

TOKEN="${SLACK_TOKEN:?Set SLACK_TOKEN — see --help}"
COOKIE="${SLACK_COOKIE:?Set SLACK_COOKIE — see --help}"

slack_api() {
  local method="$1"; shift
  curl -sf -X POST "https://slack.com/api/$method" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
    -H "User-Agent: $UA" \
    -H "sec-ch-ua: $SEC_CH_UA" \
    -H "sec-ch-ua-mobile: ?0" \
    -H 'sec-ch-ua-platform: "macOS"' \
    -H "Origin: https://app.slack.com" \
    -H "Sec-Fetch-Dest: empty" \
    -H "Sec-Fetch-Mode: cors" \
    -H "Sec-Fetch-Site: same-site" \
    -H "Accept: */*" \
    -H "Accept-Language: en-US,en;q=0.9" \
    -H "Cache-Control: no-cache" \
    -H "Pragma: no-cache" \
    -H "Cookie: $COOKIE" \
    -d "token=$TOKEN" \
    "$@"
}

# Verify token
echo "Verifying token..." >&2
AUTH=$(slack_api auth.test)
USER=$(echo "$AUTH" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('user','FAILED: '+d.get('error','unknown')))" 2>/dev/null)
echo "Authenticated as: $USER" >&2
if [[ "$USER" == FAILED* ]]; then exit 1; fi

# --- Fetch messages ---
if [[ "$INPUT" =~ ^https://.*slack\.com/archives/([A-Z0-9]+)/p([0-9]+) ]]; then
  # Thread replies
  CHANNEL="${BASH_REMATCH[1]}"
  RAW_TS="${BASH_REMATCH[2]}"
  TS="${RAW_TS:0:10}.${RAW_TS:10}"

  slack_api conversations.replies \
    --data-urlencode "channel=$CHANNEL" \
    --data-urlencode "ts=$TS" \
    --data-urlencode "limit=100"
elif [[ "$INPUT" =~ ^https://.*slack\.com/archives/([A-Z0-9]+)$ ]]; then
  # Channel/DM history (paginated)
  CHANNEL="${BASH_REMATCH[1]}"
  TMPFILE=$(mktemp)
  trap "rm -f '$TMPFILE'" EXIT
  CURSOR=""
  PAGE=0
  while true; do
    PAGE=$((PAGE + 1))
    if [[ $PAGE -gt $MAX_PAGES ]]; then
      echo "  stopped at $MAX_PAGES pages ($(( MAX_PAGES * PAGE_SIZE )) msgs). Use --max-pages to fetch more." >&2
      break
    fi
    ARGS=(--data-urlencode "channel=$CHANNEL" --data-urlencode "limit=$PAGE_SIZE")
    [[ -n "$CURSOR" ]] && ARGS+=(--data-urlencode "cursor=$CURSOR")
    slack_api conversations.history "${ARGS[@]}" >> "$TMPFILE"
    echo >> "$TMPFILE"
    CURSOR=$(tail -2 "$TMPFILE" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        resp = json.loads(line)
        if not resp.get('ok'):
            print(''); sys.exit(1)
        cursor = resp.get('response_metadata', {}).get('next_cursor', '')
        has_more = resp.get('has_more', False)
        print(f'{cursor}' if has_more and cursor else '')
    except: print('')
")
    echo "  fetched page $PAGE" >&2
    [[ -n "$CURSOR" ]] || break
    # Random delay between pages to avoid rate-limit / volume detections
    sleep $(awk "BEGIN{srand($RANDOM); printf \"%.1f\", $PAGE_DELAY_MIN + rand()*($PAGE_DELAY_MAX-$PAGE_DELAY_MIN)}")
  done
  python3 -c "
import json, sys
messages = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    resp = json.loads(line)
    messages.extend(resp.get('messages', []))
print(json.dumps({'ok': True, 'messages': messages}))
" "$TMPFILE"
else
  # Search
  slack_api search.messages \
    --data-urlencode "query=$INPUT" \
    --data-urlencode "sort=timestamp" \
    --data-urlencode "sort_dir=desc" \
    --data-urlencode "count=$COUNT"
fi | if [[ "$RAW" == true ]]; then
  cat
else
  python3 -c "
import json, sys, datetime

d = json.load(sys.stdin)
if not d.get('ok'):
    print(f'Error: {d.get(\"error\")}')
    sys.exit(1)

# Handle both thread replies and search results
messages = d.get('messages', [])
if isinstance(messages, dict):
    messages = messages.get('matches', [])

for m in messages:
    user = m.get('user', m.get('username', '?'))
    ts = float(m.get('ts', '0'))
    dt = datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
    txt = m.get('text', '')
    ch = m.get('channel', {}).get('name', '') if isinstance(m.get('channel'), dict) else ''
    prefix = f'#{ch} ' if ch else ''
    print(f'[{dt}] {prefix}@{user}')
    print(f'  {txt}')
    print()
"
fi
