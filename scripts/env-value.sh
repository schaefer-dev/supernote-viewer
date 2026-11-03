# Sourced by the release scripts. Reads single KEY=value lines from the repository's .env as data;
# the file is never executed. Environment variables that are already set take precedence.
env_value() {
    local key="$1" file="${ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env}"
    if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; return; fi
    [ -f "$file" ] || return 0
    sed -nE "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*['\"]?([^'\"]*)['\"]?[[:space:]]*$/\2/p" "$file" | tail -1
}

# Expands a leading ~ and resolves relative paths against the repository root.
resolve_path() {
    local path="${1/#\~/$HOME}" root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    case "$path" in /*) printf '%s' "$path" ;; *) printf '%s/%s' "$root" "$path" ;; esac
}
