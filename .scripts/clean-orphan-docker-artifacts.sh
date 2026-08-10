#!/usr/bin/env bash
# Remove docker artifacts belonging to worktrees that no longer exist on disk.
#
# `mise run wt:rm` already tears a worktree's docker state down, so orphans only
# accumulate when a worktree leaves some other way: removed by hand with rm -rf,
# a wt:rm that died partway, or a worktree predating remove-worktree.sh.
#
# Containers, volumes and networks are attributed by their
# com.docker.compose.project label — those are per-project by construction.
# Images are NOT, because compose stamps the same label on the shared base
# images (filial/rails, filial/nvim, ...) using whichever project built them
# last. See qualifies_as_project_image below.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
root=$(find_project_root)
git_dir=$(find_git_dir)

: "${PROJECT_PREFIX:?PROJECT_PREFIX is unset — run via 'mise run clean' so the mise env is loaded}"

# Safety: refuse when git's worktree view is incomplete. Inside the claude
# container the sibling worktrees are not mounted at their registered host
# paths, so every live worktree would look dead and this would delete the
# entire project's docker state. Same guard as remove-worktree.sh.
missing=""
while read -r wt; do
  [ -n "$wt" ] || continue
  [ -d "$wt" ] || missing="${missing}"$'\n'"  ${wt}"
done < <(git -C "$git_dir" worktree list --porcelain | sed -n 's/^worktree //p')
if [ -n "$missing" ]; then
  echo "Error: Refusing to clean — git reports worktrees whose directories are missing:" >&2
  echo "$missing" >&2
  echo "" >&2
  echo "This means you are in a partial filesystem view (e.g. the claude container)." >&2
  echo "Run 'mise run clean' on the host, where all worktrees are present." >&2
  exit 1
fi

# A project is orphaned when it is named "<prefix>-<name>" and "<name>" is not a
# directory at the project root. Names containing dashes make the split
# ambiguous, so this never parses — it only strips the prefix and tests the
# remainder verbatim. A dead worktree whose name extends a live one is therefore
# retained, which is the safe direction to be wrong in.
is_orphan_project() {
  local project="$1" name
  case "$project" in
    "${PROJECT_PREFIX}-"*) name="${project#"${PROJECT_PREFIX}-"}" ;;
    *) return 1 ;;
  esac
  [ -n "$name" ] || return 1
  # The shared proxy stack is named "<prefix>-proxy" (see the proxy:up task) but
  # has no worktree directory, so the folder test alone marks it orphaned —
  # which would delete Traefik and the network every worktree attaches to.
  for reserved in proxy; do
    [ "$name" = "$reserved" ] && return 1
  done
  [ -d "${root}/${name}" ] && return 1
  return 0
}

# An image belongs to its labelled project only when that project plus its
# service label reconstruct the image's own repository name — compose's default
# naming for images it builds. filial-master-app = filial-master + "-" + app,
# so it qualifies; filial/rails:ruby4.0.3-node24.14.0 is labelled filial-master
# but does not reconstruct, so it is skipped. This is what keeps the shared base
# images out of the sweep.
qualifies_as_project_image() {
  local repo="$1" project="$2" service="$3"
  [ -n "$project" ] && [ -n "$service" ] || return 1
  [ "$repo" = "${project}-${service}" ]
}

human_size() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# Collected as "project<TAB>id<TAB>display<TAB>bytes" lines, one file per type.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: >"$work/containers" >"$work/networks" >"$work/volumes" >"$work/images"

while IFS=$'\t' read -r id project name state; do
  [ -n "$project" ] || continue
  is_orphan_project "$project" || continue
  printf '%s\t%s\t%s\t0\n' "$project" "$id" "${name} (${state})" >>"$work/containers"
done < <(docker ps -a --format '{{.ID}}\t{{.Label "com.docker.compose.project"}}\t{{.Names}}\t{{.State}}')

while IFS=$'\t' read -r id project name; do
  [ -n "$project" ] || continue
  is_orphan_project "$project" || continue
  printf '%s\t%s\t%s\t0\n' "$project" "$id" "$name" >>"$work/networks"
done < <(docker network ls --format '{{.ID}}\t{{.Label "com.docker.compose.project"}}\t{{.Name}}')

# `docker volume ls` has no --format field for an arbitrary label, so inspect.
while read -r name; do
  [ -n "$name" ] || continue
  project=$(docker volume inspect "$name" \
    --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null) || continue
  [ -n "$project" ] && [ "$project" != "<no value>" ] || continue
  is_orphan_project "$project" || continue
  printf '%s\t%s\t%s\t0\n' "$project" "$name" "$name" >>"$work/volumes"
done < <(docker volume ls --format '{{.Name}}')

# `docker images --format` exposes no .Labels field (it errors with "can't
# evaluate field Labels in type *formatter.imageContext"), so labels have to
# come from `docker image inspect`. One call over every image id, not one per
# image. An image can carry several tags; each is checked on its own.
image_ids=$(docker images -q | sort -u)
if [ -n "$image_ids" ]; then
  while IFS=$'\t' read -r repotags project service size; do
    [ -n "$project" ] && [ -n "$service" ] || continue
    is_orphan_project "$project" || continue
    for repotag in $repotags; do
      [ -n "$repotag" ] && [ "$repotag" != "<none>:<none>" ] || continue
      qualifies_as_project_image "${repotag%:*}" "$project" "$service" || continue
      printf '%s\t%s\t%s\t%s\n' \
        "$project" "$repotag" "$repotag" "$(human_size "$size")" >>"$work/images"
    done
  done < <(docker image inspect $image_ids --format \
    '{{range .RepoTags}}{{.}} {{end}}	{{index .Config.Labels "com.docker.compose.project"}}	{{index .Config.Labels "com.docker.compose.service"}}	{{.Size}}' 2>/dev/null)
fi

if [ ! -s "$work/containers" ] && [ ! -s "$work/networks" ] &&
   [ ! -s "$work/volumes" ] && [ ! -s "$work/images" ]; then
  echo "No orphaned artifacts."
  exit 0
fi

# Real on-disk volume sizes. `docker system df -v` is one call for all of them,
# unlike `docker volume inspect`, which reports no size at all.
if [ -s "$work/volumes" ]; then
  df_v=$(docker system df -v 2>/dev/null | awk '/^VOLUME NAME/,/^$/' || true)
  while IFS=$'\t' read -r project id display _; do
    bytes=$(awk -v v="$id" '$1 == v {print $NF}' <<<"$df_v" | head -1)
    printf '%s\t%s\t%s\t%s\n' "$project" "$id" "$display" "${bytes:-0}"
  done <"$work/volumes" >"$work/volumes.sized"
  mv "$work/volumes.sized" "$work/volumes"
fi

projects=$(cut -f1 "$work"/containers "$work"/networks "$work"/volumes "$work"/images | sort -u)

echo "Orphaned docker artifacts (no worktree folder):"
echo ""
for project in $projects; do
  echo "  ${project}"
  for type in containers networks volumes images; do
    entries=$(awk -F'\t' -v p="$project" '$1 == p {
      printf "%s%s", sep, $3
      if ($4 != "0" && $4 != "") printf " (%s)", $4
      sep = ", "
    }' "$work/$type")
    [ -n "$entries" ] && printf '    %-11s %s\n' "${type}:" "$entries"
  done
done
echo ""

# wc, not `grep -c .` — grep exits 1 on zero matches, so a `|| echo 0` fallback
# fires *in addition to* the 0 it already printed.
count() { wc -l <"$work/$1" | tr -d ' '; }
printf '%s worktrees, %s containers, %s networks, %s volumes, %s images\n' \
  "$(wc -w <<<"$projects" | tr -d ' ')" "$(count containers)" "$(count networks)" \
  "$(count volumes)" "$(count images)"
echo ""
echo "Volumes include database data. This cannot be undone."
echo "Image sizes above are nominal — shared layers mean actual reclaim is lower."
printf "Continue? [y/N] "
read -r confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 1 ;;
esac

# Containers first, then networks and volumes — neither releases while a
# container still references it. Failures are reported but never abort the
# sweep, so one wedged artifact cannot strand the rest.
remove_all() {
  local type="$1"; shift
  [ -s "$work/$type" ] || return 0
  echo ""
  echo "Removing ${type}:"
  while IFS=$'\t' read -r _ id display _; do
    if "$@" "$id" >/dev/null 2>&1; then
      echo "  ✓ ${display}"
    else
      echo "  ✗ ${display} (failed)" >&2
    fi
  done <"$work/$type"
}

remove_all containers docker rm -f
remove_all networks docker network rm
remove_all volumes docker volume rm
remove_all images docker rmi

echo ""
echo "Done."
