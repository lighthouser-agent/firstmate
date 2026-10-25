#!/usr/bin/env bash
# Toggle captain-direct communication for a registered secondmate.
# Usage: FM_HOME=<parent-home> bin/fm-secondmate-direct.sh <id> on|off|show
# The parent owns config/secondmate-captain-direct/<id>; presence means on.
# This never stops or restarts an endpoint, changes routing, or answers decisions.
# Auto-relaunch remains enabled. Existing receipts and queued work are preserved.
# After changing a live home, paste the printed instruction into the mate pane;
# new sessions discover the same instruction in their session-start digest.
# Remote routes mirror the switch through fm-on; a failed on leaves parent
# suppression enabled for safety. Retry the same command to converge.
# Off restores the remote publisher before clearing parent suppression.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
case "${1:-}" in -h|--help) head -n 11 "$0"; exit 0 ;; esac
[ "$#" -eq 2 ] || { echo 'usage: fm-secondmate-direct.sh <id> on|off|show' >&2; exit 2; }
HOME_DIR=${FM_HOME:?FM_HOME must name the parent home}
ID=$1
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) echo 'invalid secondmate id' >&2; exit 2 ;; esac
secondmate_registry_line_for_id "$HOME_DIR/data/secondmates.md" "$ID" || { echo 'secondmate is not registered' >&2; exit 1; }
REMOTE=$SECONDMATE_REGISTRY_REMOTE
case "$2" in on|off|show) ;; *) echo 'expected on, off, or show' >&2; exit 2 ;; esac
FLAG="$HOME_DIR/config/secondmate-captain-direct/$ID"
[ ! -L "$HOME_DIR/config/secondmate-captain-direct" ] && [ ! -L "$FLAG" ] || { echo 'unsafe captain-direct config path' >&2; exit 1; }
case "$2" in
  on) mkdir -p "$(dirname "$FLAG")"; : > "$FLAG" ;;
  off)
    if [ "$REMOTE" -eq 1 ]; then
      "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh captain-direct "$ID" off </dev/null
    fi
    rm -f "$FLAG"
    ;;
  show) ;;
esac
if [ "$REMOTE" -eq 1 ] && [ "$2" = on ]; then
  "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh captain-direct "$ID" on </dev/null
fi
if [ -f "$FLAG" ]; then
  printf '%s: captain-direct on\n' "$ID"
  printf '%s\n' 'Instruction for the secondmate: communicate directly in this pane; do not append outcomes, judgement, or replies to the parent channel. Explicitly routed work is still accepted. This overrides the charter parent-channel instructions while captain-direct is on.'
else
  printf '%s: captain-direct off; resume the charter parent-channel instructions.\n' "$ID"
fi
