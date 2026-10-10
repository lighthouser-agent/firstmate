#!/usr/bin/env bash
# Machine admission and heartbeat sampling, shared by spawn and watch.
# config/machine-limit in fm_project_capacity_config_dir's local root is the
# single declaration for all registered local homes (remote homes excluded).
# Lines are <key> <unsigned integer>, comments/blank lines allowed, no repeats.
# Defaults: workers=4, free_mb=256, swap_mb=3072, load=16, samples=2, enabled=1.
# enabled=0 disables admission and alarms; zero disables an individual metric.
# load is the one-minute load average; free_mb uses Linux MemAvailable or macOS
# free+inactive+speculative pages. swap_mb is used swap, not allocated capacity.
# Unknown keys, invalid declarations or unavailable admission metrics refuse.
# Occupancy conservatively counts every non-secondmate local task record until
# cleanup, including paused/review-ready/stale records; never probes or claims
# another home's endpoints. This avoids vendor/harness-dependent process names.
# Spawn holds .machine-admission.lock in the local root through publication,
# in addition to the project lock. Deferral exits 75 before moving the backlog.
# Heartbeat remembers successive bad samples per observing home; one check wake
# per overload episode across local homes, reset by a healthy sample. Admission uses the same
# thresholds immediately, so it need not wait for an alarm to pause launches.
# Dependencies: fm-project-capacity-lib, fm-wake-lib, fm-backend, registry, locks
# and fm-timeout-lib. No mutation on source; no daemon and no endpoint sweeps.
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-secondmate-registry-lib.sh"

fm_machine_limit_read() {  # <root-config>
  local line key value extra seen='|' file="$1/machine-limit"
  FM_MACHINE_ENABLED=1 FM_MACHINE_WORKERS=4 FM_MACHINE_FREE_MB=256
  FM_MACHINE_SWAP_MB=3072 FM_MACHINE_LOAD=16 FM_MACHINE_SAMPLES=2
  FM_MACHINE_ERROR=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || { FM_MACHINE_ERROR="unreadable $file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    read -r key value extra <<< "$line"
    case "$key" in ''|'#'*) continue ;; esac
    case "$value" in ''|*[!0-9]*|????????*) FM_MACHINE_ERROR="invalid value in $file: $line"; return 1 ;; esac
    [ -z "$extra" ] || { FM_MACHINE_ERROR="extra fields in $file: $line"; return 1; }
    case "$seen" in *"|$key|"*) FM_MACHINE_ERROR="duplicate $key in $file"; return 1 ;; esac
    seen="$seen$key|"
    value=$((10#$value))
    case "$key" in
      enabled) [ "$value" -le 1 ] || return 1; FM_MACHINE_ENABLED=$value ;;
      workers) FM_MACHINE_WORKERS=$value ;;
      free_mb) FM_MACHINE_FREE_MB=$value ;;
      swap_mb) FM_MACHINE_SWAP_MB=$value ;;
      load) FM_MACHINE_LOAD=$value ;;
      samples) [ "$value" -gt 0 ] || return 1; FM_MACHINE_SAMPLES=$value ;;
      *) FM_MACHINE_ERROR="unknown key $key in $file"; return 1 ;;
    esac
  done < "$file"
}

fm_machine_sample() {
  local pages swap
  case "$(uname -s)" in
    Linux)
      FM_MACHINE_LOAD_NOW=$(awk '{print $1}' /proc/loadavg) || return 1
      read -r FM_MACHINE_FREE_NOW FM_MACHINE_SWAP_NOW < <(awk '
        /MemAvailable:/ {free=$2} /SwapTotal:/ {total=$2} /SwapFree:/ {unused=$2}
        END {if (free == "" || total == "" || unused == "") exit 1;
          printf "%d %d\n", free/1024, (total-unused)/1024}' /proc/meminfo)
      ;;
    Darwin)
      FM_MACHINE_LOAD_NOW=$(sysctl -n vm.loadavg | awk '{print $2}') || return 1
      pages=$(vm_stat) || return 1
      FM_MACHINE_FREE_NOW=$(printf '%s\n' "$pages" | awk '
        NR==1 {size=$8+0} /Pages (free|inactive|speculative):/ {gsub(/\./,"",$NF); count+=$NF}
        END {if (size <= 0) exit 1; printf "%d\n", size*count/1048576}') || return 1
      swap=$(sysctl -n vm.swapusage) || return 1
      FM_MACHINE_SWAP_NOW=$(printf '%s\n' "$swap" | awk '
        {for(i=1;i<=NF;i++) if($i=="used") {v=$(i+2); n=v+0;
          if(v ~ /G$/) n*=1024; else if(v ~ /K$/) n/=1024; else if(v !~ /M$/) exit 1;
          printf "%d\n",n; found=1}} END {if(!found) exit 1}') || return 1
      ;;
    *) return 1 ;;
  esac
  case "$FM_MACHINE_FREE_NOW" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_MACHINE_SWAP_NOW" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$FM_MACHINE_LOAD_NOW" | grep -Eq '^[0-9]+([.][0-9]+)?$'
}

fm_machine_pressure() {
  FM_MACHINE_REASON=
  if [ "$FM_MACHINE_FREE_MB" -gt 0 ] && [ "$FM_MACHINE_FREE_NOW" -lt "$FM_MACHINE_FREE_MB" ]; then
    FM_MACHINE_REASON="available memory ${FM_MACHINE_FREE_NOW} MB < ${FM_MACHINE_FREE_MB} MB"
  elif [ "$FM_MACHINE_SWAP_MB" -gt 0 ] && [ "$FM_MACHINE_SWAP_NOW" -ge "$FM_MACHINE_SWAP_MB" ]; then
    FM_MACHINE_REASON="used swap ${FM_MACHINE_SWAP_NOW} MB >= ${FM_MACHINE_SWAP_MB} MB"
  elif [ "$FM_MACHINE_LOAD" -gt 0 ] && awk -v n="$FM_MACHINE_LOAD_NOW" -v cap="$FM_MACHINE_LOAD" 'BEGIN {exit !(n >= cap)}'; then
    FM_MACHINE_REASON="load $FM_MACHINE_LOAD_NOW >= $FM_MACHINE_LOAD"
  fi
  [ -n "$FM_MACHINE_REASON" ]
}

fm_machine_occupants() {  # <first-state> <self-id>
  local state meta
  FM_MACHINE_COUNT=0
  fm_local_firstmate_state_dirs "$1" || { FM_MACHINE_ERROR=$FM_LOCAL_FIRSTMATE_ERROR; return 1; }
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    [ ! -e "$state" ] || { [ -d "$state" ] && [ -r "$state" ] && [ -x "$state" ]; } || return 1
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
      [ "$meta" != "$1/$2.meta" ] || continue
      [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
      FM_MACHINE_COUNT=$((FM_MACHINE_COUNT + 1))
    done
  done
}

fm_machine_admit() {  # <state> <id>
  [ "$FM_MACHINE_ENABLED" = 1 ] || return 0
  fm_machine_occupants "$1" "$2" || return 1
  # shellcheck disable=SC2034 # Returned diagnostic consumed by fm-spawn.sh.
  fm_machine_sample || { FM_MACHINE_ERROR='cannot read machine load/memory/swap'; return 1; }
  if [ "$FM_MACHINE_WORKERS" -gt 0 ] && [ "$FM_MACHINE_COUNT" -ge "$FM_MACHINE_WORKERS" ]; then
    FM_MACHINE_REASON="$FM_MACHINE_COUNT local worker records occupy the machine limit of $FM_MACHINE_WORKERS (including paused workers until cleanup)"
    return 75
  fi
  if fm_machine_pressure; then return 75; fi
  return 0
}

# Only on an alarm: one ps snapshot and one cwd scan, grouped by registered
# local home. Unattributed processes are shown separately (Docker/user apps).
fm_machine_top() {  # <state>
  local state meta wt rows cwd
  rows=$(LC_ALL=C ps -axo pid=,rss=,command= 2>/dev/null) || return 1
  cwd=$(lsof -a -d cwd -Fpn 2>/dev/null) || cwd=
  fm_local_firstmate_state_dirs "$1" || return 1
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    printf 'Home %s\n' "${state%/state}"
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      wt=$(fm_meta_get "$meta" worktree)
      [ -n "$wt" ] || continue
      printf '%s\n' "$cwd" | awk -v root="$wt" '/^p/ {pid=substr($0,2)}
        /^n/ {path=substr($0,2); if(path==root || index(path,root"/")==1) print pid}'
    done | sort -u | awk 'NR==FNR {wanted[$1]=1;next} $1 in wanted' - <(printf '%s\n' "$rows") | sort -k2,2nr | head -5
  done
  printf 'Machine top RSS (KB), including unattributed processes:\n'
  printf '%s\n' "$rows" | sort -k2,2nr | head -5
}

# Returns 0 with an alarm body only when a new episode should be enqueued.
# Caller uses fm_machine_notify to enqueue and mark atomically across homes.
fm_machine_heartbeat() {  # <home> <config> <state>
  local config count=0 docker_ids docker_info root
  config=$(fm_project_capacity_config_dir "$1" "$2") || return 1
  fm_machine_limit_read "$config" || return 1
  [ "$FM_MACHINE_ENABLED" = 1 ] || return 1
  root=$(fm_firstmate_root_home "$1") || return 1
  fm_machine_sample || return 1
  docker_info='Docker unavailable'
  if command -v docker >/dev/null 2>&1; then
    if docker_ids=$(fm_run_timed 2 docker ps -q 2>/dev/null); then
      docker_info='Docker has running containers'
      [ -n "$docker_ids" ] || docker_info='Docker idle: zero running containers (daemon not stopped)'
    fi
  fi
  printf 'load=%s swap_mb=%s free_mb=%s; %s\n' "$FM_MACHINE_LOAD_NOW" "$FM_MACHINE_SWAP_NOW" "$FM_MACHINE_FREE_NOW" "$docker_info" > "$3/.machine-sample"
  if ! fm_machine_pressure; then
    rm -f "$3/.machine-streak"
    if fm_lock_try_acquire "$root/state/.machine-health.lock"; then
      rm -f "$root/state/.machine-alarm" "$3/.machine-alarm"
      fm_lock_release "$root/state/.machine-health.lock"
    fi
    return 1
  fi
  [ ! -f "$3/.machine-streak" ] || read -r count < "$3/.machine-streak"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  printf '%s\n' "$count" > "$3/.machine-streak"
  [ "$count" -ge "$FM_MACHINE_SAMPLES" ] && [ ! -f "$root/state/.machine-alarm" ] || return 1
  printf 'Machine overload: %s; new dispatch deferred. %s\n' "$FM_MACHINE_REASON" "$docker_info"
  fm_machine_top "$3" || printf 'Top memory attribution unavailable\n'
}

# One notification across observing homes, enqueue before suppressing retries.
fm_machine_notify() {  # <home> <body>
  local root lock rc=1
  root=$(fm_firstmate_root_home "$1") || return 1
  lock="$root/state/.machine-health.lock"
  fm_lock_try_acquire "$lock" || return 1
  if [ ! -f "$root/state/.machine-alarm" ]; then
    if fm_wake_append check machine-load "$2"; then
      touch "$root/state/.machine-alarm"
      rc=0
    fi
  fi
  fm_lock_release "$lock"
  return "$rc"
}
