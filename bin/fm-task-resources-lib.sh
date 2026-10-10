#!/usr/bin/env bash
# Task-local resource discovery/cleanup, called only AFTER teardown proves it
# owns this isolated worktree and all landed-work/dirty-copy checks pass.
# Process ownership is cwd (existing teardown scanner), or an absolute
# --user-data-dir argv value below the canonical worktree. No global browser
# stop: it might stop another task's daemon. Identity/recheck/TERM/KILL remain
# owned by fm-teardown.sh. This module never signals a process itself.
# Docker ownership is an absolute bind source or Compose working_dir under the
# isolated worktree. Only stop running containers, never remove them/images or
# stop Docker Desktop. Record successful stops in the caller's cleanup log.
# Docker probes are bounded; an unresponsive local socket refuses cleanup,
# rather than silently deleting an unverifiable container owner. Absent sockets
# and non-local endpoints are skipped without contacting another machine.
# Requires fm-timeout-lib.sh. No effects on source.

fm_task_profile_pids() {  # <canonical-root>
  python3 - "$1" <<'PY'
import ctypes, os, subprocess, sys
root = os.path.realpath(sys.argv[1])

def argv(pid):
    if sys.platform.startswith('linux'):
        with open('/proc/' + pid + '/cmdline', 'rb') as f:
            return f.read().decode(errors='replace').rstrip('\0').split('\0')
    # macOS ps does not quote argv values containing spaces. Read the kernel's
    # NUL-delimited KERN_PROCARGS2 instead of guessing from rendered text.
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, int(pid))
    size = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        raise OSError(ctypes.get_errno())
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        raise OSError(ctypes.get_errno())
    data = buf.raw[:size.value]
    argc = int.from_bytes(data[:4], sys.byteorder)
    rest = data[4:].split(b'\0', 1)[1].lstrip(b'\0')
    return [a.decode(errors='replace') for a in rest.split(b'\0')[:argc]]
rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
for row in rows.splitlines():
    fields = row.strip().split(None, 1)
    if len(fields) != 2:
        continue
    pid, command = fields
    if '--user-data-dir' not in command:
        continue
    try:
        args = argv(pid)
    except (OSError, ValueError, IndexError):
        continue
    for i, arg in enumerate(args):
        value = None
        if arg.startswith('--user-data-dir='):
            value = arg.split('=', 1)[1]
        elif arg == '--user-data-dir' and i+1 < len(args):
            value = args[i+1]
        if value and os.path.isabs(value):
            path = os.path.realpath(value)
            if path == root or path.startswith(root + os.sep):
                print(pid)
                break
PY
}

fm_task_container_ids() {  # <canonical-root> <docker-inspect-json>
  python3 - "$1" "$2" <<'PY'
import json, os, sys
root = os.path.realpath(sys.argv[1])
for item in json.loads(sys.argv[2]):
    if not item.get('State', {}).get('Running'):
        continue
    paths = [m.get('Source', '') for m in item.get('Mounts', []) if m.get('Type') == 'bind']
    paths.append((item.get('Config', {}).get('Labels') or {}).get('com.docker.compose.project.working_dir', ''))
    for path in paths:
        if not os.path.isabs(path):
            continue
        path = os.path.realpath(path)
        if path == root or path.startswith(root + os.sep):
            print(item['Id'])
            break
PY
}

fm_task_stop_containers() {  # <worktree> <cleanup-log>
  local root=$1 log=$2 ids inspection owned id recheck endpoint
  [ -n "$root" ] && [ -d "$root" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  root=$(cd "$root" && pwd -P) || return 1
  endpoint=${DOCKER_HOST:-}
  if [ -z "$endpoint" ]; then
    endpoint=$(fm_run_timed 3 docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || return 1
  fi
  case "$endpoint" in
    unix://*) [ -S "${endpoint#unix://}" ] || return 0 ;;
    *) printf 'skipped non-local Docker endpoint %s\n' "$endpoint" >> "$log"; return 0 ;;
  esac
  if ! ids=$(fm_run_timed 3 docker ps -q --no-trunc 2>/dev/null); then
    echo 'REFUSED: cannot inspect Docker task containers; retry after Docker responds or remove the unavailable CLI from PATH' >&2
    return 1
  fi
  [ -n "$ids" ] || return 0
  local -a all_ids
  while IFS= read -r id; do all_ids+=("$id"); done <<< "$ids"
  inspection=$(fm_run_timed 3 docker inspect "${all_ids[@]}" 2>/dev/null) || return 1
  owned=$(fm_task_container_ids "$root" "$inspection") || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # Recheck the exact immutable container ID immediately before stopping.
    recheck=$(fm_run_timed 3 docker inspect "$id" 2>/dev/null) || return 1
    [ "$(fm_task_container_ids "$root" "$recheck")" = "$id" ] || continue
    fm_run_timed 15 docker stop --time 5 "$id" >/dev/null || return 1
    printf 'stopped container %s (root %s)\n' "$id" "$root" >> "$log"
  done <<< "$owned"
}
