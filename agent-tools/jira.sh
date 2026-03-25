#!/bin/bash
# Helper script to fetch and create Jira issues
# Usage:
#   ./jira.sh view <ISSUE_KEY>                            - View an issue (also: ./jira.sh <ISSUE_KEY>)
#   ./jira.sh create <summary> <description_file> [parent_key] [options] - Create a task
#     Options: --project KEY  --type NAME  --priority NAME  --label LABEL (repeatable)
#   ./jira.sh comment <ISSUE_KEY> <comment_text>          - Add a comment
#   ./jira.sh edit-comment <ISSUE_KEY> <COMMENT_ID> <text> - Edit an existing comment
#   ./jira.sh list-comments <ISSUE_KEY>                    - List comments (id + preview)
#   ./jira.sh transition <ISSUE_KEY> <status_name>        - Transition issue (e.g. "Done", "In Progress")
#   ./jira.sh transitions <ISSUE_KEY>                     - List available transitions
#   ./jira.sh link <blocker_key> <blocked_key>            - A blocks B
#   ./jira.sh relate <key_a> <key_b>                      - Relate two issues
#   ./jira.sh update-desc <ISSUE_KEY> <description_file>  - Update description

: "${JIRA_API_TOKEN:?}" "${JIRA_EMAIL:?}" "${JIRA_BASE_URL:?}"

create_issue() {
    local summary=""
    local desc_file=""
    local parent_key=""
    local project="PDC"
    local issue_type="Task"
    local priority="Medium"
    local labels=()

    # Parse positional args first, then flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --project)  project="$2"; shift 2 ;;
            --type)     issue_type="$2"; shift 2 ;;
            --priority) priority="$2"; shift 2 ;;
            --label)    labels+=("$2"); shift 2 ;;
            *)
                if [ -z "$summary" ]; then
                    summary="$1"
                elif [ -z "$desc_file" ]; then
                    desc_file="$1"
                elif [ -z "$parent_key" ]; then
                    parent_key="$1"
                else
                    echo "Error: Unrecognized argument: $1" >&2; exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$summary" ] || [ -z "$desc_file" ]; then
        echo "Usage: $0 create <summary> <description_file> [parent_key] [--project KEY] [--type NAME] [--priority NAME] [--label LABEL ...]"
        exit 1
    fi

    if [ ! -f "$desc_file" ]; then
        echo "Error: Description file not found: $desc_file"
        exit 1
    fi

    local description
    description=$(cat "$desc_file")

    # Build labels JSON array
    local labels_json="[]"
    if [ ${#labels[@]} -gt 0 ]; then
        labels_json=$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s .)
    fi

    # Build JSON payload using jq
    local payload
    payload=$(jq -n \
        --arg summary "$summary" \
        --arg description "$description" \
        --arg project "$project" \
        --arg issue_type "$issue_type" \
        --arg priority "$priority" \
        --argjson labels "$labels_json" \
        '{
            fields: {
                project: { key: $project },
                issuetype: { name: $issue_type },
                priority: { name: $priority },
                summary: $summary,
                description: $description,
                labels: $labels,
                customfield_10910: [{ value: "SHERPA", id: "15044" }]
            }
        }')

    if [ -n "$parent_key" ]; then
        payload=$(echo "$payload" | jq --arg parent "$parent_key" '.fields.parent = { key: $parent }')
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        -d "$payload" \
        "${JIRA_BASE_URL}/rest/api/2/issue")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "201" ]; then
        local issue_key
        issue_key=$(echo "$body" | jq -r '.key')
        echo "$issue_key"
    else
        echo "Error creating issue (HTTP $http_code):" >&2
        echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
        exit 1
    fi
}

add_link() {
    local link_type="${1:-Blocks}"
    local from_key="$2"
    local to_key="$3"

    # Jira's link API: the inwardIssue's page shows the "outward" label.
    # So to make from_key's page show "blocks to_key":
    #   inwardIssue = from_key (blocker), outwardIssue = to_key (blocked)
    local payload
    payload=$(jq -n \
        --arg type "$link_type" \
        --arg inward "$from_key" \
        --arg outward "$to_key" \
        '{
            type: { name: $type },
            inwardIssue: { key: $inward },
            outwardIssue: { key: $outward }
        }')

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        -d "$payload" \
        "${JIRA_BASE_URL}/rest/api/2/issueLink")

    local http_code
    http_code=$(echo "$response" | tail -1)

    if [ "$http_code" = "201" ]; then
        echo "Linked ($link_type): $from_key → $to_key"
    else
        local body
        body=$(echo "$response" | sed '$d')
        echo "Error creating link (HTTP $http_code):" >&2
        echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
    fi
}

update_description() {
    local issue_key="$1"
    local desc_file="$2"

    if [ -z "$issue_key" ] || [ -z "$desc_file" ]; then
        echo "Usage: $0 update-desc <ISSUE_KEY> <description_file>"
        exit 1
    fi

    if [ ! -f "$desc_file" ]; then
        echo "Error: Description file not found: $desc_file"
        exit 1
    fi

    local description
    description=$(cat "$desc_file")

    local payload
    payload=$(jq -n --arg description "$description" '{ fields: { description: $description } }')

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X PUT \
        -H "Content-Type: application/json" \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        -d "$payload" \
        "${JIRA_BASE_URL}/rest/api/2/issue/${issue_key}")

    local http_code
    http_code=$(echo "$response" | tail -1)

    if [ "$http_code" = "204" ]; then
        echo "Updated description for $issue_key"
    else
        local body
        body=$(echo "$response" | sed '$d')
        echo "Error updating issue (HTTP $http_code):" >&2
        echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
        exit 1
    fi
}

add_comment() {
    local issue_key="$1"
    local comment_text="$2"

    if [ -z "$issue_key" ] || [ -z "$comment_text" ]; then
        echo "Usage: $0 comment <ISSUE_KEY> <comment_text>"
        exit 1
    fi

    local payload
    payload=$(jq -n --arg body "$comment_text" '{ body: $body }')

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        -d "$payload" \
        "${JIRA_BASE_URL}/rest/api/2/issue/${issue_key}/comment")

    local http_code
    http_code=$(echo "$response" | tail -1)

    if [ "$http_code" = "201" ]; then
        echo "Comment added to $issue_key"
    else
        local body
        body=$(echo "$response" | sed '$d')
        echo "Error adding comment (HTTP $http_code):" >&2
        echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
        exit 1
    fi
}

edit_comment() {
    local issue_key="$1"
    local comment_id="$2"
    local comment_text="$3"

    if [ -z "$issue_key" ] || [ -z "$comment_id" ] || [ -z "$comment_text" ]; then
        echo "Usage: $0 edit-comment <ISSUE_KEY> <COMMENT_ID> <comment_text>"
        exit 1
    fi

    local payload
    payload=$(jq -n --arg body "$comment_text" '{ body: $body }')

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X PUT \
        -H "Content-Type: application/json" \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        -d "$payload" \
        "${JIRA_BASE_URL}/rest/api/2/issue/${issue_key}/comment/${comment_id}")

    local http_code
    http_code=$(echo "$response" | tail -1)

    if [ "$http_code" = "200" ]; then
        echo "Comment $comment_id updated on $issue_key"
    else
        local body
        body=$(echo "$response" | sed '$d')
        echo "Error updating comment (HTTP $http_code):" >&2
        echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
        exit 1
    fi
}

list_comments() {
    local issue_key="$1"
    local output_json=false

    if [ "$1" = "--json" ]; then output_json=true; shift; issue_key="$1"; fi
    if [ "$2" = "--json" ]; then output_json=true; fi

    if [ -z "$issue_key" ]; then
        echo "Usage: $0 list-comments <ISSUE_KEY> [--json]"
        exit 1
    fi

    local response
    response=$(curl -s \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        "${JIRA_BASE_URL}/rest/api/2/issue/${issue_key}/comment")

    if [ "$output_json" = true ]; then
        echo "$response" | jq '.comments[] | {id, author: .author.displayName, created: (.created | split("T")[0]), body}'
    else
        echo "$response" | jq -r '.comments[] | "--- comment \(.id) | \(.author.displayName) | \(.created | split("T")[0]) ---\n\(.body)\n"'
    fi
}

list_transitions() {
    local issue_key="$1"

    if [ -z "$issue_key" ]; then
        echo "Usage: $0 transitions <ISSUE_KEY>"
        exit 1
    fi

    curl -s \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        "${JIRA_BASE_URL}/rest/api/2/issue/${issue_key}/transitions" \
        | jq -r '.transitions[] | "\(.id)\t\(.name)\t(\(.to.statusCategory.name))"'
}

transition_issue() {
    local issue_key="$1"
    local target_status="$2"

    if [ -z "$issue_key" ] || [ -z "$target_status" ]; then
        echo "Usage: $0 transition <ISSUE_KEY> <status_name>"
        exit 1
    fi

    # Look up the transition ID by name (case-insensitive)
    local transitions_json
    transitions_json=$(curl -s \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        "${JIRA_BASE_URL}/rest/api/2/issue/${issue_key}/transitions")

    local transition_id
    transition_id=$(echo "$transitions_json" | jq -r \
        --arg name "$target_status" \
        '.transitions[] | select(.name | ascii_downcase == ($name | ascii_downcase)) | .id')

    if [ -z "$transition_id" ]; then
        echo "Error: No transition found matching '$target_status'" >&2
        echo "Available transitions:" >&2
        echo "$transitions_json" | jq -r '.transitions[] | "  \(.name)"' >&2
        exit 1
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        -d "{\"transition\": {\"id\": \"$transition_id\"}}" \
        "${JIRA_BASE_URL}/rest/api/2/issue/${issue_key}/transitions")

    local http_code
    http_code=$(echo "$response" | tail -1)

    if [ "$http_code" = "204" ]; then
        echo "Transitioned $issue_key → $target_status"
    else
        local body
        body=$(echo "$response" | sed '$d')
        echo "Error transitioning issue (HTTP $http_code):" >&2
        echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
        exit 1
    fi
}

case "${1:-}" in
    create)
        shift
        create_issue "$@"
        ;;
    link)
        shift
        add_link "20 Blocks" "$@"
        ;;
    relate)
        shift
        add_link "01 Relates To (Named 01 to be at top of list for generic linking)" "$@"
        ;;
    comment)
        shift
        add_comment "$@"
        ;;
    edit-comment)
        shift
        edit_comment "$@"
        ;;
    list-comments)
        shift
        list_comments "$@"
        ;;
    transition)
        shift
        transition_issue "$@"
        ;;
    transitions)
        shift
        list_transitions "$@"
        ;;
    update-desc)
        shift
        update_description "$@"
        ;;
    view)
        shift
        if [ -z "$1" ]; then
            echo "Usage: $0 view <ISSUE_KEY>"
            exit 1
        fi
        jira view "$1"
        ;;
    "")
        echo "Usage:"
        echo "  $0 view <ISSUE_KEY>"
        echo "  $0 create <summary> <description_file> [parent_key] [--project KEY] [--type NAME] [--priority NAME] [--label LABEL ...]"
        echo "  $0 comment <ISSUE_KEY> <comment_text>"
        echo "  $0 edit-comment <ISSUE_KEY> <COMMENT_ID> <comment_text>"
        echo "  $0 list-comments <ISSUE_KEY>"
        echo "  $0 transition <ISSUE_KEY> <status_name>"
        echo "  $0 transitions <ISSUE_KEY>"
        echo "  $0 link <blocker_key> <blocked_key>"
        echo "  $0 relate <key_a> <key_b>"
        echo "  $0 update-desc <ISSUE_KEY> <description_file>"
        exit 1
        ;;
    *)
        # Backwards compatible: treat bare argument as view
        jira view "$1"
        ;;
esac
