#!/bin/bash
# Helper script to fetch and search Confluence pages
# Usage:
#   confluence.sh page <ID> [--raw]                    - View page by ID
#   confluence.sh search <QUERY> [SPACE_KEY] [--excerpts] - Full-text search
#   confluence.sh spaces                               - List all spaces
#   confluence.sh children <ID>                        - List child pages
#   confluence.sh url <URL> [--raw]                    - View page from URL
#   confluence.sh <ID>                                 - Shortcut for page view
#   confluence.sh <URL>                                - Shortcut for URL view
#
# Flags:
#   --raw       Show raw XHTML storage format (page/url commands)
#   --excerpts  Show search result excerpts (search command)

: "${JIRA_API_TOKEN:?}" "${JIRA_EMAIL:?}" "${CONFLUENCE_BASE_URL:?}"

RAW_MODE=false
SHOW_EXCERPTS=false

confluence_curl() {
    local endpoint="$1"
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        "${CONFLUENCE_BASE_URL}${endpoint}")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        echo "$body"
    else
        echo "Error (HTTP $http_code):" >&2
        echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
        exit 1
    fi
}

strip_html() {
    sed \
        -e 's/<br[^>]*>/\n/gi' \
        -e 's/<\/p>/\n\n/gi' \
        -e 's/<\/h[1-6]>/\n\n/gi' \
        -e 's/<\/tr>/\n/gi' \
        -e 's/<\/li>/\n/gi' \
        -e 's/<li[^>]*>/  - /gi' \
        -e 's/<\/td>/ | /gi' \
        -e 's/<[^>]*>//g' \
        -e 's/&amp;/\&/g' \
        -e 's/&lt;/</g' \
        -e 's/&gt;/>/g' \
        -e 's/&quot;/"/g' \
        -e "s/&#39;/'/g" \
        -e 's/&nbsp;/ /g' \
        -e 's/&#[0-9]*;//g' \
        -e '/^[[:space:]]*$/{ N; /^\n[[:space:]]*$/d; }' \
    | cat -s
}

view_page() {
    local page_id="$1"

    if [ -z "$page_id" ]; then
        echo "Usage: $0 page <PAGE_ID> [--raw]"
        exit 1
    fi

    local body
    body=$(confluence_curl "/wiki/rest/api/content/${page_id}?expand=body.storage,version,space")

    local title space_key space_name version page_url
    title=$(echo "$body" | jq -r '.title')
    space_key=$(echo "$body" | jq -r '.space.key')
    space_name=$(echo "$body" | jq -r '.space.name')
    version=$(echo "$body" | jq -r '.version.number')
    page_url="${CONFLUENCE_BASE_URL}/wiki/spaces/${space_key}/pages/${page_id}"

    echo "=== $title ==="
    echo "Space:   ${space_name} (${space_key})"
    echo "Version: ${version}"
    echo "URL:     ${page_url}"
    echo "ID:      ${page_id}"
    echo "---"

    local content
    content=$(echo "$body" | jq -r '.body.storage.value // ""')

    if [ "$RAW_MODE" = true ]; then
        echo "$content"
    else
        echo "$content" | strip_html
    fi
}

search_pages() {
    local query="$1"
    local space_key="$2"

    if [ -z "$query" ]; then
        echo "Usage: $0 search <QUERY> [SPACE_KEY]"
        exit 1
    fi

    # siteSearch matches the web UI's full-text search; text~ does strict phrase matching
    local cql
    if [ -n "$space_key" ]; then
        cql="siteSearch ~ \"${query}\" AND space = \"${space_key}\""
    else
        cql="siteSearch ~ \"${query}\""
    fi
    local encoded_cql
    encoded_cql=$(jq -rn --arg q "$cql" '$q | @uri')

    local body
    body=$(confluence_curl "/wiki/rest/api/search?cql=${encoded_cql}&limit=25")

    local count
    count=$(echo "$body" | jq '.results | length')

    local total
    total=$(echo "$body" | jq '.totalSize // .size // 0')

    echo "=== Search: \"$query\"${space_key:+ in space $space_key} ==="
    echo "Showing ${count} of ${total} results"
    echo ""

    if [ "$SHOW_EXCERPTS" = true ]; then
        echo "$body" | jq -r --arg base "$CONFLUENCE_BASE_URL" '.results[] |
            (.content.title // .title | gsub("@@@hl@@@"; "") | gsub("@@@endhl@@@"; "")) as $title |
            (.resultGlobalContainer.title // "?") as $space |
            ($base + .url) as $url |
            (.friendlyLastModified // "") as $modified |
            (.excerpt // "" | gsub("@@@hl@@@"; "**") | gsub("@@@endhl@@@"; "**") | gsub("<[^>]*>"; "") | gsub("&amp;"; "&") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"") | gsub("&#39;"; "'"'"'") | gsub("&nbsp;"; " ") | gsub("\\n"; " ") | gsub("  +"; " ") | ltrimstr(" ") | if length > 160 then .[:160] + "..." else . end) as $excerpt |
            "\($title)  (\($space), \($modified))\n  \($url)\n  \($excerpt)\n"'
    else
        echo "$body" | jq -r --arg base "$CONFLUENCE_BASE_URL" '.results[] |
            (.content.title // .title | gsub("@@@hl@@@"; "") | gsub("@@@endhl@@@"; "")) as $title |
            (.resultGlobalContainer.title // "?") as $space |
            ($base + .url) as $url |
            (.friendlyLastModified // "") as $modified |
            "\($title)  (\($space), \($modified))\n  \($url)\n"'
    fi
}

list_spaces() {
    local body
    body=$(confluence_curl "/wiki/rest/api/space?limit=100")

    local count
    count=$(echo "$body" | jq '.results | length')

    echo "=== Confluence Spaces (${count}) ==="
    echo ""
    echo "$body" | jq -r '.results[] | "\(.key)\t\(.name)\t(\(.type))"' | column -t -s $'\t'
}

list_children() {
    local page_id="$1"

    if [ -z "$page_id" ]; then
        echo "Usage: $0 children <PAGE_ID>"
        exit 1
    fi

    local body
    body=$(confluence_curl "/wiki/rest/api/content/${page_id}/child/page?limit=100")

    local count
    count=$(echo "$body" | jq '.results | length')

    # Get parent title for context
    local parent
    parent=$(confluence_curl "/wiki/rest/api/content/${page_id}?expand=space")
    local parent_title
    parent_title=$(echo "$parent" | jq -r '.title')

    echo "=== Children of: ${parent_title} (${count}) ==="
    echo ""
    echo "$body" | jq -r '.results[] | "  \(.id)\t\(.title)"' | column -t -s $'\t'
}

view_from_url() {
    local url="$1"

    if [ -z "$url" ]; then
        echo "Usage: $0 url <CONFLUENCE_URL> [--raw]"
        exit 1
    fi

    # Handle search URLs: /wiki/search?text=...&spaces=...
    if echo "$url" | grep -qE '/wiki/search'; then
        local search_text space_param
        search_text=$(echo "$url" | grep -oE '[?&]text=[^&]*' | sed 's/^[?&]text=//' | sed 's/+/ /g; s/%20/ /g; s/%22/"/g')
        space_param=$(echo "$url" | grep -oE '[?&]spaces=[^&]*' | sed 's/^[?&]spaces=//')
        if [ -n "$search_text" ]; then
            search_pages "$search_text" "$space_param"
            return
        fi
    fi

    local page_id
    page_id=$(echo "$url" | grep -oE '/pages/[0-9]+' | grep -oE '[0-9]+')

    if [ -z "$page_id" ]; then
        echo "Error: Could not extract page ID from URL: $url" >&2
        exit 1
    fi

    view_page "$page_id"
}

# Parse flags from arguments
args=()
for arg in "$@"; do
    case "$arg" in
        --raw) RAW_MODE=true ;;
        --excerpts) SHOW_EXCERPTS=true ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]}"

case "${1:-}" in
    page)
        shift
        view_page "$@"
        ;;
    search)
        shift
        search_pages "$@"
        ;;
    spaces)
        list_spaces
        ;;
    children)
        shift
        list_children "$@"
        ;;
    url)
        shift
        view_from_url "$@"
        ;;
    "")
        echo "Usage:"
        echo "  $0 page <ID> [--raw]                    - View page by ID"
        echo "  $0 search <QUERY> [SPACE_KEY] [--excerpts] - Full-text search"
        echo "  $0 spaces                               - List all spaces"
        echo "  $0 children <ID>                        - List child pages"
        echo "  $0 url <URL> [--raw]                    - View page from URL"
        echo "  $0 <ID>                                 - Shortcut for page view"
        echo "  $0 <URL>                                - Shortcut for URL view"
        echo ""
        echo "Flags:"
        echo "  --raw       Show raw XHTML storage format (page/url commands)"
        echo "  --excerpts  Show search result excerpts (search command)"
        exit 1
        ;;
    *)
        # Bare argument: detect URL vs page ID
        if echo "$1" | grep -qE '^https?://'; then
            view_from_url "$1"
        elif echo "$1" | grep -qE '^[0-9]+$'; then
            view_page "$1"
        else
            echo "Error: Unrecognized command or argument: $1" >&2
            echo "Run '$0' with no arguments for usage." >&2
            exit 1
        fi
        ;;
esac
