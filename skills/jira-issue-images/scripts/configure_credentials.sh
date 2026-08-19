#!/usr/bin/env bash

set -euo pipefail
umask 077

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

if [[ ! -t 0 ]]; then
  echo "Run this command in an interactive terminal so the password can be entered securely." >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required." >&2
  exit 1
}

read -r -p "Jira username [jiraRobot]: " jira_username
jira_username="${jira_username:-jiraRobot}"
read -r -s -p "Jira password: " jira_password
printf '\n' >&2

if [[ -z "$jira_password" ]]; then
  echo "Password was empty; nothing was saved." >&2
  exit 1
fi

config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"
credentials_file="${JIRA_CREDENTIALS_FILE:-${config_home}/jira-issue-images/credentials.json}"
credentials_dir="$(dirname "$credentials_file")"
mkdir -p -- "$credentials_dir"
chmod 700 "$credentials_dir"

tmp_file="$(mktemp "${credentials_file}.tmp.XXXXXX")"
cleanup() {
  [[ -n "${tmp_file:-}" && -e "$tmp_file" ]] && rm -f -- "$tmp_file"
  unset jira_password JIRA_CONFIG_PASSWORD
}
trap cleanup EXIT HUP INT TERM

chmod 600 "$tmp_file"
JIRA_CONFIG_USERNAME="$jira_username" JIRA_CONFIG_PASSWORD="$jira_password" \
  python3 -c \
    'import json, os, sys; json.dump({"username": os.environ["JIRA_CONFIG_USERNAME"], "password": os.environ["JIRA_CONFIG_PASSWORD"]}, sys.stdout)' \
    > "$tmp_file"
unset jira_password JIRA_CONFIG_PASSWORD

mv -f -- "$tmp_file" "$credentials_file"
tmp_file=""
chmod 600 "$credentials_file"

echo "Jira credentials saved for this OS user at: $credentials_file"
echo "The file persists after the terminal closes. Do not distribute or commit it."
