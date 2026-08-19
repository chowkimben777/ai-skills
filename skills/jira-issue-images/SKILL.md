---
name: jira-issue-images
description: Retrieve real image attachments from Jira issues when Jira MCP can read issue metadata but attachment downloads require cookie-based session authentication. Use for Jira issue image viewing or analysis; do not use for non-Jira URLs or attachment uploads.
---

# Jira Issue Images

Use the configured Jira MCP server for issue data and attachment metadata. Use the bundled script only for downloading image bytes; do not call the MCP attachment-download tools because this Jira instance can return a `200` HTML login page that those tools misreport as success.

## Requirements

- A Jira MCP issue-reading tool, such as `jira_get_issue`.
- Bash, curl, awk, `file`, and Python 3 on the local machine.
- Network access to `https://jira.p.it`.
- Jira login credentials configured once in the current OS user's private config directory by `scripts/configure_credentials.sh`. Environment variables are an optional override.

## Workflow

1. Read the requested issue through Jira MCP, including attachment metadata, description, and comments when relevant.
2. Select attachments whose declared MIME type begins with `image/`. Resolve inline image references back to their Jira attachment metadata; never download arbitrary external URLs found in issue text.
3. Choose a local output path with a unique attachment ID or sanitized filename. Do not overwrite an existing file unless the user explicitly asks for it and `JIRA_OVERWRITE=true` is set for the script invocation.
4. Determine this Skill's directory and run:

   ```bash
   bash "$SKILL_DIR/scripts/fetch_jira_image.sh" "$ATTACHMENT_URL" "$OUTPUT_PATH"
   ```

5. Treat progress messages about a missing or expired cached session, or fallback to a private temporary session, as informational behavior rather than failure. The download succeeds only when the script exits with status 0, emits `jira-image-fetch: download succeeded`, and returns the local path on its final stdout line. Then view or analyze the image with the host's available image/file capability.
6. Report the downloaded local paths. If a refresh and retry still fail, report the script error rather than claiming the attachment succeeded.

## Credentials and Session State

- Never ask the user to paste a password, PAT, or session cookie into chat.
- Never read, display, summarize, or log the credentials file, credential environment variables, or cookie jar.
- If credentials are missing, tell the user to run `bash "$SKILL_DIR/scripts/configure_credentials.sh"` once in an interactive terminal. Do not run the interactive setup on the user's behalf.
- The default credentials path is `${XDG_CONFIG_HOME:-$HOME/.config}/jira-issue-images/credentials.json`. It is outside the Skill directory, persists after terminals and AI clients close, and must remain owned by the current OS user with no group/other permissions.
- `JIRA_SESSION_USERNAME` and `JIRA_SESSION_PASSWORD` may jointly override the file for temporary or managed environments. Never require them when the credentials file exists.
- The Jira MCP may continue using its PAT for issue metadata. This Skill's download script does not use that PAT.
- The script submits the username and password to Jira's session-login endpoint without placing the password in curl arguments. It caches the resulting `JSESSIONID` in the user's state directory when that directory is writable. If an agent sandbox blocks state-directory writes, the script automatically uses a private temporary Cookie for that run, authenticates normally, and removes it afterward.
- Do not infer that the Jira account lacks attachment permission merely because a persistent Cookie cache is blocked or an initial attachment response is an HTML login page. Let the script perform its temporary-session fallback and bounded re-authentication; only its final non-zero exit is a failure.

## Invariants

- Accept only HTTPS attachment URLs on `jira.p.it` under Jira attachment-content paths.
- Do not use `curl -v`, shell tracing, or any command that prints credentials or cookies.
- A `2xx` status alone is insufficient. The script also validates the final URL and the downloaded file's detected MIME type, so an HTML login page is never accepted as an image.
- Do not modify or wrap `mcp-atlassian`; this Skill is an agent-side fallback for image downloads only.
