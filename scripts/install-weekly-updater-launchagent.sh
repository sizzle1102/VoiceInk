#!/usr/bin/env bash
set -euo pipefail

LABEL="${VOICEINK_UPDATE_LABEL:-com.voiceink.local-updater}"
INTERVAL_SECONDS="${VOICEINK_UPDATE_INTERVAL_SECONDS:-604800}"
RUN_AT_LOAD="${VOICEINK_UPDATE_RUN_AT_LOAD:-false}"
NO_RELAUNCH="${VOICEINK_UPDATE_NO_RELAUNCH:-true}"
PLIST_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/VoiceInk"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"

usage() {
  cat <<EOF
Usage: $(basename "$0") [install|uninstall|print]

Installs a user LaunchAgent that runs scripts/update-build-sign-install.sh
on a weekly interval. The updater keeps signing local; GitHub only builds the
ad-hoc app artifact.

Environment:
  VOICEINK_UPDATE_INTERVAL_SECONDS  Default: 604800
  VOICEINK_UPDATE_RUN_AT_LOAD       true/false, default: false
  VOICEINK_UPDATE_NO_RELAUNCH       true/false, default: true
  VOICEINK_UPDATE_LABEL             Default: com.voiceink.local-updater
EOF
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

write_plist() {
  local root="$1"
  local updater="$root/scripts/update-build-sign-install.sh"
  local stdout_log="$LOG_DIR/update-build-sign-install.out.log"
  local stderr_log="$LOG_DIR/update-build-sign-install.err.log"
  local -a arguments=("$updater")

  if [[ "$NO_RELAUNCH" == "true" ]]; then
    arguments+=("--no-relaunch")
  fi

  mkdir -p "$PLIST_DIR" "$LOG_DIR"

  PLIST_PATH="$PLIST_PATH" \
  LABEL="$LABEL" \
  ROOT="$root" \
  INTERVAL_SECONDS="$INTERVAL_SECONDS" \
  RUN_AT_LOAD="$RUN_AT_LOAD" \
  STDOUT_LOG="$stdout_log" \
  STDERR_LOG="$stderr_log" \
  python3 - "${arguments[@]}" <<'PY'
import os
import plistlib
import sys

program_arguments = sys.argv[1:]
run_at_load = os.environ["RUN_AT_LOAD"].lower() == "true"

plist = {
    "Label": os.environ["LABEL"],
    "ProgramArguments": program_arguments,
    "WorkingDirectory": os.environ["ROOT"],
    "EnvironmentVariables": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    },
    "StartInterval": int(os.environ["INTERVAL_SECONDS"]),
    "RunAtLoad": run_at_load,
    "StandardOutPath": os.environ["STDOUT_LOG"],
    "StandardErrorPath": os.environ["STDERR_LOG"],
}

with open(os.environ["PLIST_PATH"], "wb") as handle:
    plistlib.dump(plist, handle, sort_keys=False)
PY
}

install_agent() {
  local root
  root="$(repo_root)" || {
    echo "error: run this script inside the VoiceInk git repository" >&2
    exit 1
  }

  write_plist "$root"
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  launchctl enable "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true

  echo "Installed $LABEL"
  echo "Plist: $PLIST_PATH"
  echo "Logs: $LOG_DIR/update-build-sign-install.*.log"
}

uninstall_agent() {
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
  echo "Uninstalled $LABEL"
}

print_agent() {
  if [[ -f "$PLIST_PATH" ]]; then
    plutil -p "$PLIST_PATH"
  else
    echo "No plist installed at $PLIST_PATH"
  fi
}

case "${1:-install}" in
  install)
    install_agent
    ;;
  uninstall)
    uninstall_agent
    ;;
  print)
    print_agent
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac
