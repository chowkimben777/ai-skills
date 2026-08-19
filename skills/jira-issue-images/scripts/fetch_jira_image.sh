#!/usr/bin/env bash

set -euo pipefail
umask 077

JIRA_URL="https://jira.p.it"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 ATTACHMENT_URL OUTPUT_PATH" >&2
}

fail() {
  echo "jira-image-fetch: $*" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

attachment_url="$1"
output_path="$2"

case "$attachment_url" in
  /*)
    attachment_url="${JIRA_URL}${attachment_url}"
    ;;
esac

is_allowed_attachment_url() {
  case "$1" in
    "${JIRA_URL}"/secure/attachment/* | \
    "${JIRA_URL}"/rest/api/*/attachment/content/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_allowed_attachment_url "$attachment_url" || \
  fail "refusing URL outside the allowed Jira attachment paths"

if [[ -e "$output_path" && "${JIRA_OVERWRITE:-false}" != "true" ]]; then
  fail "output already exists: $output_path (set JIRA_OVERWRITE=true to replace it)"
fi

output_dir="$(dirname "$output_path")"
mkdir -p -- "$output_dir"

command -v python3 >/dev/null 2>&1 || fail "python3 is required to create the Jira login request safely"

config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"
credentials_file="${JIRA_CREDENTIALS_FILE:-${config_home}/jira-issue-images/credentials.json}"
env_username="${JIRA_SESSION_USERNAME:-}"
env_password="${JIRA_SESSION_PASSWORD:-}"

if [[ -n "$env_username" && -z "$env_password" ]] || \
   [[ -z "$env_username" && -n "$env_password" ]]; then
  fail "set both JIRA_SESSION_USERNAME and JIRA_SESSION_PASSWORD, or set neither"
fi

if [[ -z "$env_username" ]]; then
  [[ -f "$credentials_file" && -r "$credentials_file" ]] || \
    fail "credentials are not configured; run ${script_dir}/configure_credentials.sh once"

  if ! python3 -c \
      'import os, stat, sys; s=os.stat(sys.argv[1]); sys.exit(0 if s.st_uid == os.getuid() and stat.S_IMODE(s.st_mode) & 0o077 == 0 else 1)' \
      "$credentials_file"; then
    fail "credentials file must be owned by the current user and inaccessible to group/others: $credentials_file"
  fi
fi

tmp_root="${TMPDIR:-/tmp}"
cookie_mode="persistent"
ephemeral_cookie_dir=""

if [[ -n "${JIRA_COOKIE_FILE:-}" ]]; then
  cookie_file="$JIRA_COOKIE_FILE"
  cookie_dir="$(dirname "$cookie_file")"
  mkdir -p -- "$cookie_dir" || fail "could not create the configured cookie directory: $cookie_dir"
else
  state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
  state_dir="${state_home}/jira-issue-images"
  cookie_file="${state_dir}/cookies.txt"
  cookie_dir="$state_dir"
  state_write_probe=""

  if mkdir -p -- "$cookie_dir" 2>/dev/null && \
     state_write_probe="$(mktemp "${cookie_dir}/.write-test.XXXXXX" 2>/dev/null)"; then
    rm -f -- "$state_write_probe"
  else
    [[ -n "$state_write_probe" && -e "$state_write_probe" ]] && rm -f -- "$state_write_probe"
    ephemeral_cookie_dir="$(mktemp -d "${tmp_root%/}/jira-image-session.XXXXXX")" || \
      fail "persistent cookie cache is unavailable and a temporary session directory could not be created"
    chmod 700 "$ephemeral_cookie_dir"
    cookie_dir="$ephemeral_cookie_dir"
    cookie_file="${cookie_dir}/cookies.txt"
    cookie_mode="ephemeral"
    echo "jira-image-fetch: persistent cookie cache unavailable; using a private temporary session for this run" >&2
  fi
fi

body_tmp="$(mktemp "${tmp_root%/}/jira-image-body.XXXXXX")"
login_body_tmp="$(mktemp "${tmp_root%/}/jira-image-login.XXXXXX")"
session_check_tmp="$(mktemp "${tmp_root%/}/jira-image-session-check.XXXXXX")"
login_cookie_tmp=""

cleanup() {
  [[ -n "${body_tmp:-}" && -e "$body_tmp" ]] && rm -f -- "$body_tmp"
  [[ -n "${login_body_tmp:-}" && -e "$login_body_tmp" ]] && rm -f -- "$login_body_tmp"
  [[ -n "${session_check_tmp:-}" && -e "$session_check_tmp" ]] && rm -f -- "$session_check_tmp"
  [[ -n "${login_cookie_tmp:-}" && -e "$login_cookie_tmp" ]] && rm -f -- "$login_cookie_tmp"
  if [[ "${cookie_mode:-persistent}" == "ephemeral" ]]; then
    [[ -n "${cookie_file:-}" && -e "$cookie_file" ]] && rm -f -- "$cookie_file"
    [[ -n "${ephemeral_cookie_dir:-}" && -d "$ephemeral_cookie_dir" ]] && rmdir -- "$ephemeral_cookie_dir" 2>/dev/null || true
  fi
  unset env_password JIRA_SESSION_PASSWORD
}
trap cleanup EXIT HUP INT TERM

chmod 600 "$body_tmp" "$login_body_tmp" "$session_check_tmp"
if [[ -n "$env_username" ]]; then
  python3 -c \
    'import json, os, sys; json.dump({"username": os.environ["JIRA_SESSION_USERNAME"], "password": os.environ["JIRA_SESSION_PASSWORD"]}, sys.stdout)' \
    > "$login_body_tmp"
else
  if ! python3 -c \
      'import json, sys; data=json.load(open(sys.argv[1], encoding="utf-8")); username=data.get("username"); password=data.get("password"); assert isinstance(username, str) and username; assert isinstance(password, str) and password; json.dump({"username": username, "password": password}, sys.stdout)' \
      "$credentials_file" > "$login_body_tmp"; then
    fail "credentials file is not valid JSON with non-empty username and password fields"
  fi
fi
unset env_password JIRA_SESSION_PASSWORD

curl_common=(
  --silent
  --show-error
  --connect-timeout 15
  --max-time 120
  --proto '=https'
  --proto-redir '=https'
)

if [[ -n "${JIRA_CA_CERT:-}" ]]; then
  curl_common+=(--cacert "$JIRA_CA_CERT")
elif [[ "${JIRA_SSL_VERIFY:-false}" != "true" ]]; then
  curl_common+=(--insecure)
fi

cookie_has_session() {
  [[ -r "$1" ]] || return 1
  awk -F '\t' '$6 == "JSESSIONID" && length($7) > 0 { found=1 } END { exit !found }' "$1"
}

login_session() {
  local login_status check_status
  login_cookie_tmp="$(mktemp "${cookie_dir}/cookies.tmp.XXXXXX")"
  chmod 600 "$login_cookie_tmp"
  : > "$session_check_tmp"

  if ! login_status="$(curl "${curl_common[@]}" \
      --request POST \
      --header 'Content-Type: application/json' \
      --data-binary "@${login_body_tmp}" \
      --cookie-jar "$login_cookie_tmp" \
      --output "$session_check_tmp" \
      --write-out '%{http_code}' \
      "${JIRA_URL}/rest/auth/1/session")"; then
    return 1
  fi

  case "$login_status" in
    2??) ;;
    *)
      echo "jira-image-fetch: Jira login returned HTTP $login_status" >&2
      return 1
      ;;
  esac

  if ! cookie_has_session "$login_cookie_tmp"; then
    echo "jira-image-fetch: Jira login did not return JSESSIONID" >&2
    return 1
  fi

  : > "$session_check_tmp"
  if ! check_status="$(curl "${curl_common[@]}" \
      --cookie "$login_cookie_tmp" \
      --cookie-jar "$login_cookie_tmp" \
      --output "$session_check_tmp" \
      --write-out '%{http_code}' \
      "${JIRA_URL}/rest/auth/1/session")"; then
    return 1
  fi

  case "$check_status" in
    2??) ;;
    *)
      echo "jira-image-fetch: Jira session verification returned HTTP $check_status" >&2
      return 1
      ;;
  esac

  if ! python3 -c \
      'import json, sys; data=json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if data.get("name") or data.get("username") else 1)' \
      "$session_check_tmp"; then
    echo "jira-image-fetch: Jira session verification did not identify an authenticated user" >&2
    return 1
  fi

  mv -f -- "$login_cookie_tmp" "$cookie_file"
  login_cookie_tmp=""
  chmod 600 "$cookie_file"
}

last_http_code=""
last_content_type=""
last_final_url=""
last_detected_type=""

download_once() {
  local metadata

  : > "$body_tmp"
  if ! metadata="$(curl "${curl_common[@]}" \
      --location \
      --max-redirs 3 \
      --cookie "$cookie_file" \
      --cookie-jar "$cookie_file" \
      --output "$body_tmp" \
      --write-out $'%{http_code}\n%{content_type}\n%{url_effective}' \
      "$attachment_url")"; then
    return 1
  fi

  chmod 600 "$cookie_file" 2>/dev/null || true
  last_http_code="$(printf '%s\n' "$metadata" | sed -n '1p')"
  last_content_type="$(printf '%s\n' "$metadata" | sed -n '2p')"
  last_final_url="$(printf '%s\n' "$metadata" | sed -n '3p')"
  last_detected_type="$(file --brief --mime-type "$body_tmp" 2>/dev/null || true)"

  case "$last_http_code" in
    2??) ;;
    *) return 1 ;;
  esac

  is_allowed_attachment_url "$last_final_url" || return 1

  case "$last_detected_type" in
    image/*) ;;
    *) return 1 ;;
  esac

  return 0
}

refreshed=0
if ! cookie_has_session "$cookie_file"; then
  echo "jira-image-fetch: no cached session found; authenticating with Jira" >&2
  login_session || fail "could not create an authenticated Jira session"
  refreshed=1
fi

if ! download_once; then
  if [[ "$refreshed" -eq 0 ]]; then
    echo "jira-image-fetch: cached session expired; re-authenticating and retrying once" >&2
    login_session || fail "could not refresh the authenticated Jira session"
    refreshed=1
  fi

  if [[ "$refreshed" -eq 0 ]] || ! download_once; then
    fail "response was not a valid image after session refresh (http=${last_http_code:-unknown}, content_type=${last_content_type:-unknown}, detected_type=${last_detected_type:-unknown}, final_url=${last_final_url:-unknown})"
  fi
fi

if [[ -e "$output_path" && "${JIRA_OVERWRITE:-false}" != "true" ]]; then
  fail "output appeared during download and will not be overwritten: $output_path"
fi

mv -f -- "$body_tmp" "$output_path"
body_tmp=""
chmod 600 "$output_path"

printf '%s\n' "jira-image-fetch: download succeeded" >&2
printf '%s\n' "$output_path"
