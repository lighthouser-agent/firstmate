#!/usr/bin/env bash
# Per-secondmate captain-direct switch: presence of
# <parent-home>/config/secondmate-captain-direct/<id> suppresses parent traffic.
# Identity comes from the registry (parent) or the local parent binding (mate).
# No endpoint or liveness policy is changed.

fm_secondmate_captain_direct() { # <parent-home> <id>
  local home=$1 id=$2
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$home/config/secondmate-captain-direct/$id" ]
}

fm_secondmate_direct_status() { # <state> <status-or-turn-ended-path>
  local state=$1 path=$2 id
  [ -d "${state%/*}/config/secondmate-captain-direct" ] || return 1
  id=${path##*/}
  id=${id%.status}
  id=${id%.turn-ended}
  [ "$(awk -F= '$1 == "kind" {print $2; exit}' "$state/$id.meta" 2>/dev/null)" = secondmate ] || return 1
  fm_secondmate_captain_direct "${state%/*}" "$id"
}

fm_secondmate_direct_home() { # <mate-home>
  local home=$1 id
  id=$(fm_parent_channel_home_id "$home") || return 1
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 1
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local) fm_secondmate_captain_direct "$FM_SECONDMATE_PARENT_HOME" "$id" ;;
    remote) [ -f "$home/config/parent-captain-direct" ] ;;
    *) return 1 ;;
  esac
}
