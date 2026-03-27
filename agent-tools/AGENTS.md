# Global Claude Code Settings

## Agent Tools

Standalone CLI scripts in `~/.dotfiles/agent-tools/` symlinked into `~/Bin/` (on PATH). Each script is self-contained and requires only `curl`, `jq`, and `python3`. All required env vars are set in `~/.zshrc`.

## Scripts

### jira.sh
View, create, and update Jira issues.

```
jira.sh view <ISSUE_KEY>
jira.sh create <summary> <description_file> [parent_key] [options]
jira.sh comment <ISSUE_KEY> <comment_text>
jira.sh edit-comment <ISSUE_KEY> <COMMENT_ID> <comment_text>
jira.sh list-comments <ISSUE_KEY> [--json]
jira.sh transition <ISSUE_KEY> <status_name>
jira.sh transitions <ISSUE_KEY>
jira.sh link <blocker_key> <blocked_key>
jira.sh relate <key_a> <key_b>
jira.sh update-desc <ISSUE_KEY> <description_file>
jira.sh <ISSUE_KEY>                # shortcut for view
```

Create options (defaults in parens):
- `--project KEY` — Jira project key (PDC)
- `--type NAME` — issue type (Task)
- `--priority NAME` — priority level (Medium)
- `--label LABEL` — add a label (repeatable, no default)

**Required env:** `JIRA_API_TOKEN`, `JIRA_EMAIL`, `JIRA_BASE_URL`

### confluence.sh
Fetch and search Confluence pages.

```
confluence.sh page <ID> [--raw]
confluence.sh search <QUERY> [SPACE_KEY] [--excerpts]
confluence.sh spaces
confluence.sh children <ID>
confluence.sh url <URL> [--raw]
confluence.sh <ID>                  # shortcut for page view
confluence.sh <URL>                 # shortcut for URL view
```

**Required env:** `JIRA_API_TOKEN`, `JIRA_EMAIL`, `CONFLUENCE_BASE_URL`

### gdoc.sh
Fetch Google Docs content and comments via gdrive OAuth.

```
gdoc.sh <FILE_ID> [output_file.txt]
gdoc.sh --comments <FILE_ID> [output.json]
gdoc.sh --all <FILE_ID> [output_dir]
```

**Required env:** `GDRIVE_ACCOUNT`
**Requires:** `gdrive` CLI with authenticated account

### slack.sh
Search and read Slack messages using browser session tokens.

```
slack.sh "from:user keyword"
slack.sh https://myco.slack.com/archives/CHANNEL_ID
slack.sh https://myco.slack.com/archives/CHANNEL_ID/pTIMESTAMP
slack.sh --setup                    # extract creds from Chrome (print exports)
slack.sh --setup-pass               # extract creds from Chrome → store in pass
slack.sh --update-creds             # extract creds from pasted cURL (print exports)
slack.sh --update-creds-pass        # extract creds from pasted cURL → store in pass
```

Options:
- `-n, --count NUM` — number of search results (default: 30)
- `-p, --max-pages NUM` — max pages for channel history (default: 5)
- `-s, --page-size NUM` — messages per page for channel history (default: 200)
- `--raw` — output raw JSON instead of formatted text

**Required env:** `SLACK_TOKEN`, `SLACK_COOKIE`, `SLACK_WORKSPACE`
Credentials in pass auto-refresh on expired session.

## Git Workflow

### Starting new work

When creating a new branch for any new piece of work, ALWAYS:
1. Determine the repo's stable default branch (`main` or `master`) — check with `git remote show origin | grep 'HEAD branch'` or look at existing branches
2. Fetch the latest: `git fetch origin <default-branch>`
3. Create the branch from the remote ref, not the local one: `git checkout -b <new-branch> origin/<default-branch>`

**Never** base a new branch off your local `HEAD` or local `main`/`master` without fetching first — they may be stale.

```bash
# CORRECT
git fetch origin main
git checkout -b my-feature origin/main

# WRONG — local main may be stale
git checkout -b my-feature
git checkout -b my-feature main
```

### Exceptions
- **Stacked PRs:** branch off the parent feature branch (still fetch it first from origin)
- **No remote / local-only repo:** raw `git checkout -b` is fine
- **Explicit instruction to branch from a specific commit:** follow those instructions, noting the deviation
