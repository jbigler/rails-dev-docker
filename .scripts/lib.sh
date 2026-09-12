# Maximum length for a sanitized worktree name. Keeps DNS labels well under
# the 63-char limit and produces readable browser URLs like
# `worktree-name.localhost` and `s3.worktree-name.localhost`.
WORKTREE_NAME_MAX_LEN=40

# Sanitize a branch/worktree name into a safe directory + hostname slug:
# lowercase, non-alphanumerics → '-', collapse runs of '-', strip leading/
# trailing '-', cap at $WORKTREE_NAME_MAX_LEN chars, then strip any trailing
# '-' that the cap may have left behind.
sanitize_worktree_name() {
  local raw="$1"
  echo "$raw" \
    | sed 's/[^a-zA-Z0-9]/-/g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-"$WORKTREE_NAME_MAX_LEN" \
    | sed 's/-$//'
}

# Returns the absolute path to the orchestration root.
# Resolved from the location of this script file, so it works regardless of $PWD.
find_project_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "$script_dir/.." && pwd)
}

# Returns the absolute path to a directory with app git context.
# Walks up from $PWD (stopping at the project root), then falls back to
# scanning the project root's subdirectories.
# Prefers the base worktree (.git directory) over linked worktrees (.git file).
find_git_dir() {
  local root
  root=$(find_project_root)

  # Walk up from $PWD looking for app git context (skip the project root
  # itself, which has its own unrelated git repo)
  local dir="$PWD"
  while [ "$dir" != "$root" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.git" ] || [ -d "$dir/.git" ]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done

  # Search project root subdirectories — prefer the base worktree
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    if [ -d "${d}.git" ]; then
      echo "${d%/}"
      return
    fi
  done

  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    if [ -f "${d}.git" ]; then
      echo "${d%/}"
      return
    fi
  done

  echo "No app git repository found in $root" >&2
  return 1
}

# Returns the directory name of the base worktree (the one with a .git directory).
find_base_worktree_name() {
  local root
  root=$(find_project_root)

  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    if [ -d "${d}.git" ]; then
      basename "${d%/}"
      return
    fi
  done

  echo "No base worktree found in $root" >&2
  return 1
}

# Regenerate .unit-env/<worktree>.env if it is missing or older than anything it
# is derived from. That file is a cache: NODE_VERSION, RUBY_VERSION, the
# Playwright tag and the image tags built from them are all read out of it
# rather than recomputed, so until now a `.nvmrc` bump on a branch left `build`
# building the old node tag and `up` starting it, with nothing saying why.
# mtime, not content: a checkout that changes the file also touches it, and a
# needless regeneration costs one mise eval.
# Takes no worktree argument on purpose: units-env.sh regenerates whichever
# worktree CURRENT_WORKTREE_NAME names, so a name passed in here could only
# disagree with the file it actually rewrites.
ensure_unit_env() {
  local wt="${CURRENT_WORKTREE_NAME:?not set -- run from inside a worktree}"
  local root out src stale=""
  root="$(find_project_root)"
  out="$root/.unit-env/$wt.env"

  if [[ ! -f "$out" ]]; then
    stale="no env file yet"
  else
    for src in "$root/$wt/.nvmrc" "$root/$wt/.ruby-version" \
               "$root/$wt/Gemfile.lock" "$root/$wt/mise.local.toml" \
               "$root/$wt/config/database.yml" "$root/mise.local.toml" \
               "$root/.mise/local.toml.template" "$root/.scripts/units-env.sh"; do
      [[ -f "$src" && "$src" -nt "$out" ]] || continue
      stale="${src#$root/} changed"
      break
    done
  fi
  [[ -n "$stale" ]] || return 0

  printf '%s; regenerating %s...\n' "$stale" "${out#$root/}" >&2
  "$root/.scripts/units-env.sh" >&2
}
