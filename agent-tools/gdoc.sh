#!/bin/bash
# Helper script to fetch Google Docs content and comments
# Usage: ./fetch-gdoc.sh <FILE_ID> [output_file.txt]
#        ./fetch-gdoc.sh --comments <FILE_ID> [output_file.json]
#        ./fetch-gdoc.sh --all <FILE_ID> [output_dir]
#
# To get FILE_ID from Google Docs URL:
# https://docs.google.com/document/d/FILE_ID/edit

: "${GDRIVE_ACCOUNT:?}"
GDRIVE_CONFIG_DIR="$HOME/.config/gdrive3/$GDRIVE_ACCOUNT"

# --- OAuth token refresh ---
get_access_token() {
    local secret_file="$GDRIVE_CONFIG_DIR/secret.json"
    local tokens_file="$GDRIVE_CONFIG_DIR/tokens.json"

    if [ ! -f "$secret_file" ] || [ ! -f "$tokens_file" ]; then
        echo "Error: gdrive credentials not found at $GDRIVE_CONFIG_DIR" >&2
        echo "Run: gdrive account add" >&2
        return 1
    fi

    local client_id client_secret refresh_token
    client_id=$(python3 -c "import json; print(json.load(open('$secret_file'))['client_id'])")
    client_secret=$(python3 -c "import json; print(json.load(open('$secret_file'))['client_secret'])")
    refresh_token=$(python3 -c "import json; print(json.load(open('$tokens_file'))[0]['token']['refresh_token'])")

    local token_tmpfile
    token_tmpfile=$(mktemp)

    curl -s -X POST https://oauth2.googleapis.com/token \
        -d "client_id=$client_id" \
        -d "client_secret=$client_secret" \
        -d "refresh_token=$refresh_token" \
        -d "grant_type=refresh_token" > "$token_tmpfile"

    local access_token
    access_token=$(python3 -c "import json; print(json.load(open('$token_tmpfile'))['access_token'])" 2>/dev/null)
    rm -f "$token_tmpfile"

    if [ -z "$access_token" ]; then
        echo "Error: Failed to refresh access token" >&2
        echo "$response" >&2
        return 1
    fi

    echo "$access_token"
}

# --- Fetch comments via Drive API ---
fetch_comments() {
    local file_id="$1"
    local output="$2"
    local access_token

    access_token=$(get_access_token) || return 1

    local fields="comments(id,author/displayName,content,quotedFileContent,replies(author/displayName,content,createdTime),createdTime,resolved)"
    local url="https://www.googleapis.com/drive/v3/files/${file_id}/comments?fields=${fields}&pageSize=100"

    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f $tmpfile" RETURN

    curl -s "$url" -H "Authorization: Bearer $access_token" > "$tmpfile"

    # Check for errors
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'error' in d else 1)" "$tmpfile" 2>/dev/null; then
        echo "Error fetching comments:" >&2
        python3 -m json.tool "$tmpfile" >&2
        return 1
    fi

    if [ -n "$output" ]; then
        python3 -m json.tool "$tmpfile" > "$output"
        echo "Comments saved to: $output" >&2
    fi

    # Display readable format
    python3 - "$tmpfile" <<'PYEOF'
import json, sys

data = json.load(open(sys.argv[1]))
comments = data.get('comments', [])
print(f'Found {len(comments)} comments\n')

for i, c in enumerate(comments, 1):
    author = c.get('author', {}).get('displayName', 'Unknown')
    content = c.get('content', '')
    quoted = c.get('quotedFileContent', {}).get('value', '')
    created = c.get('createdTime', '')
    resolved = c.get('resolved', False)
    status = ' [RESOLVED]' if resolved else ''

    print(f'--- Comment {i}{status} ---')
    print(f'Author: {author}')
    print(f'Date: {created}')
    if quoted:
        print(f'Quoted text: "{quoted}"')
    print(f'Comment: {content}')

    for r in c.get('replies', []):
        r_author = r.get('author', {}).get('displayName', 'Unknown')
        r_content = r.get('content', '')
        r_date = r.get('createdTime', '')
        print(f'  Reply by {r_author} ({r_date}): {r_content}')
    print()
PYEOF
}

# --- Fetch document content via gdrive ---
fetch_content() {
    local file_id="$1"
    local output="$2"

    echo "Fetching Google Doc content: $file_id" >&2
    gdrive files export "$file_id" "$output" --overwrite

    if [ $? -eq 0 ]; then
        echo "Content saved to: $output" >&2
    else
        echo "Error fetching document. Make sure you're authenticated:" >&2
        echo "  gdrive account list" >&2
        echo "  gdrive account add  # if no accounts found" >&2
        return 1
    fi
}

# --- Main ---
show_usage() {
    echo "Usage:"
    echo "  $0 <FILE_ID> [output_file.txt]           Fetch document content"
    echo "  $0 --comments <FILE_ID> [output.json]     Fetch comments only"
    echo "  $0 --all <FILE_ID> [output_dir]            Fetch content + comments"
    echo ""
    echo "Example:"
    echo "  $0 1fHS4a44Erhy6vL-_RAGFPtllv87DNI1eHS0oXKnphQI doc.txt"
    echo "  $0 --comments 1fHS4a44Erhy6vL-_RAGFPtllv87DNI1eHS0oXKnphQI"
    echo "  $0 --all 1fHS4a44Erhy6vL-_RAGFPtllv87DNI1eHS0oXKnphQI ./output"
}

MODE="content"
if [ "$1" = "--comments" ]; then
    MODE="comments"
    shift
elif [ "$1" = "--all" ]; then
    MODE="all"
    shift
elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_usage
    exit 0
fi

if [ -z "$1" ]; then
    show_usage
    exit 1
fi

FILE_ID="$1"

case "$MODE" in
    content)
        OUTPUT="${2:-${FILE_ID}.txt}"
        fetch_content "$FILE_ID" "$OUTPUT"
        ;;
    comments)
        OUTPUT="${2:-}"
        fetch_comments "$FILE_ID" "$OUTPUT"
        ;;
    all)
        OUTPUT_DIR="${2:-.}"
        mkdir -p "$OUTPUT_DIR"
        echo "=== Document Content ==="
        fetch_content "$FILE_ID" "$OUTPUT_DIR/${FILE_ID}.txt"
        echo ""
        echo "=== Comments ==="
        fetch_comments "$FILE_ID" "$OUTPUT_DIR/${FILE_ID}_comments.json"
        ;;
esac
