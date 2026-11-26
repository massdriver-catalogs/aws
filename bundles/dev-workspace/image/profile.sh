# shellcheck shell=bash
if [ -z "${WORKSPACE_PROFILE_LOADED:-}" ]; then
  WORKSPACE_PROFILE_LOADED=1
  [ -r /run/workspace/env ] && . /run/workspace/env
  export PATH="$HOME/.local/bin:$PATH"
  if [ -n "${BASH_VERSION:-}" ] && command -v mise >/dev/null; then
    eval "$(mise activate bash)"
  fi
fi
