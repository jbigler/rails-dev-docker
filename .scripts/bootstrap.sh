#!/usr/bin/env sh
set -eu

usage() {
  cat >&2 <<'EOF'
Usage: bootstrap.sh [-p <project-prefix>] <user/repo | git-url>

  -p  project prefix used for the workspace folder name, PROJECT_PREFIX
      in mise.local.toml, and docker volume/network names
      (default: <repo> basename)

Bootstraps a new rails-dev-docker workspace:
  1. Clones rails-dev-docker into ./<prefix>/
  2. Writes ./<prefix>/mise.local.toml with PROJECT_PREFIX et al.
  3. Creates the external docker volumes
  4. Invokes .scripts/init-repo.sh to clone the rails project into
     a default-branch-named subfolder
EOF
  exit 1
}

missing=""
command -v docker >/dev/null 2>&1 || missing="${missing}\n  - docker:    https://docs.docker.com/engine/install/"
command -v mise   >/dev/null 2>&1 || missing="${missing}\n  - mise:      https://mise.jdx.dev/getting-started.html  (or: curl https://mise.run | sh)"
command -v git    >/dev/null 2>&1 || missing="${missing}\n  - git:       install via your system package manager"
if [ -n "$missing" ]; then
  printf "Missing required tools:%b\n" "$missing" >&2
  exit 1
fi

prefix=""
while getopts ":p:h" opt; do
  case "$opt" in
    p) prefix="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

input="${1:-}"
[ -z "$input" ] && usage

prefix="${prefix:-$(basename "$input" .git)}"
dest="$(pwd)/$prefix"

if [ -e "$dest" ]; then
  echo "Error: $dest already exists" >&2
  exit 1
fi

echo "Cloning rails-dev-docker into $dest..."
git clone https://github.com/jbigler/rails-dev-docker.git "$dest"

echo "Writing $dest/mise.local.toml (PROJECT_PREFIX=$prefix)..."
cat > "$dest/mise.local.toml" <<EOF
[env]
PROJECT_PREFIX = "$prefix"
GEM_VOLUME_BASE = "${prefix}_shared_gems"
NODE_MODULES_VOLUME = "${prefix}_shared_node_modules"
EOF

ensure_volume() {
  if docker volume inspect "$1" >/dev/null 2>&1; then
    echo "  volume $1 (exists)"
  else
    docker volume create "$1" >/dev/null
    echo "  volume $1 (created)"
  fi
}

echo "Provisioning external docker volumes..."
ensure_volume "${prefix}_shared_node_modules"

echo "Running init-repo.sh for $input..."
"$dest/.scripts/init-repo.sh" "$input"

echo ""
echo "Bootstrap complete."
echo "Next steps:"
echo "  cd $dest && mise trust && mise install"
echo "  cd <branch-folder> && mise trust && mise install && mise run up"
