#!/usr/bin/env bash
# Shared pre-launch model policy for fm-spawn and fm-control's pre-stop check.
# Schema and matching contract: docs/configuration.md "Captain-only models".
# fm_captain_model_check <config-dir> <resolved-model> <raw-launch-0-or-1> <quoted-words>
# Returns nonzero before provisioning or stopping an agent on an unsafe selection.
# Authorization belongs to this invocation, never to an earlier task record.

fm_captain_model_words_check() {
  local words=${1:-}
  if [[ "$words" = *$'\n'* ]] ||
    ! printf '%s' "$words" | LC_ALL=C grep -q '[^[:space:]]' ||
    printf '%s' "$words" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo "error: --captain-model-authorization requires non-empty, single-line quoted captain words without control characters" >&2
    return 1
  fi
}

fm_captain_model_check() {
  local config=$1 model=$2 raw=$3 words=${4:-}
  local policy="$config/captain-only-models" contents entry active=0 restricted=0
  if [ -n "$words" ]; then
    fm_captain_model_words_check "$words" || return 1
  fi
  if [ ! -e "$policy" ] && [ ! -L "$policy" ]; then
    return 0
  fi
  if [ ! -f "$policy" ] || [ ! -r "$policy" ] || ! contents=$(cat "$policy"); then
    echo "error: cannot read config/captain-only-models; launch refused" >&2
    return 1
  fi
  while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in
    '' | \#*) continue ;;
    *[!a-zA-Z0-9_./:@+-]*)
      echo "error: config/captain-only-models requires one literal model per line (or a blank/comment line)" >&2
      return 1
      ;;
    esac
    active=1
    if [ "$model" = "$entry" ] || [ "${model##*/}" = "$entry" ]; then
      restricted=1
    fi
  done <<<"$contents"
  [ "$active" -eq 1 ] || return 0
  if [ "$raw" -ne 0 ]; then
    echo "error: config/captain-only-models requires a canonical --harness and explicit model, not a raw launch command" >&2
    return 1
  fi
  case "$model" in
  '' | default | -)
    echo "error: config/captain-only-models requires an explicit model; an implicit default cannot be checked" >&2
    return 1
    ;;
  esac
  if [ "$restricted" -eq 1 ] && [ -z "$words" ]; then
    echo "error: model '$model' is captain-only; pass --captain-model-authorization with the captain's quoted words for this launch" >&2
    return 1
  fi
}
