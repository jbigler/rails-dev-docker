#!/usr/bin/env bash
# Remove podman artifacts belonging to worktrees that no longer exist on disk,
# plus image tags no live worktree references any more.
#
# `mise run wt:rm` already tears a worktree down, so orphans accumulate only
# when one leaves some other way: removed by hand with rm -rf, a wt:rm that died
# partway, or a worktree predating remove-worktree.sh.
#
# This is a redesign of the docker version, not a translation, for two reasons.
#
# Attribution. Compose stamped com.docker.compose.project on containers,
# networks and volumes, so they were per-project by construction. Quadlet stamps
# nothing of the kind, so the only attribution available is the name -- and the
# names have the shape <prefix>-<worktree>-<service>, where BOTH the worktree
# ("claude-dosespot-backfill-after-patient-s") and the service ("rustfs-init")
# contain dashes. Splitting from the left is therefore ambiguous and a prefix
# match is dangerous: "^<prefix>-api-" also matches worktree "api-v2". Every
# parse here works from the RIGHT against the closed set of service and volume
# suffixes the templates define, longest suffix first, which is exact.
#
# Images. Compose built one image per project (filial-master-app), so a dead
# project's images were dead too, and the whole qualifies_as_project_image dance
# existed to keep the shared bases out of the sweep. Under podman the tags are
# keyed by the runtime versions instead -- localhost/<prefix>/rails:ruby4.0.3-
# node24.19.0 -- so one image deliberately serves every worktree on that
# ruby/node pair and no image belongs to a worktree at all. The useful question
# became a different one: which tags does no live worktree reference? Those are
# what a ruby or node bump leaves behind, and they are what this reclaims.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
root=$(find_project_root)
git_dir=$(find_git_dir)

: "${PROJECT_PREFIX:?PROJECT_PREFIX is unset — run via 'mise run clean' so the mise env is loaded}"
P="$PROJECT_PREFIX"

# Safety: refuse when git's worktree view is incomplete. Inside the claude
# container the sibling worktrees are not mounted at their registered host
# paths, so every live worktree would look dead and this would delete the entire
# project's state. Same guard as remove-worktree.sh.
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

# Closed sets, longest first so "rustfs-init" is tried before "rustfs" and
# "db-data" before "db". Anything not ending in one of these is not ours.
SERVICES="rustfs-init playwright claude rails redis nvim rustfs db"
VOL_SUFFIXES="rustfs-data node-modules db-data"
NET_SUFFIXES="dev"
# The shared proxy containers are <prefix>-traefik|dozzle|home -- one segment
# after the prefix, no worktree -- and every shared volume and network is
# underscore-separated (<prefix>_npm_cache, <prefix>_proxy). Neither shape can
# produce a worktree name below, so both are structurally excluded rather than
# needing a reserved-name list.

# Strip the prefix and one known suffix; whatever is between them is the
# worktree. Empty output means "not one of ours", never a guess.
worktree_of() {
  local name="$1" suffixes="$2" rest sfx
  case "$name" in "${P}-"*) rest="${name#"${P}-"}" ;; *) return 0 ;; esac
  for sfx in $suffixes; do
    case "$rest" in
      *"-${sfx}") printf '%s' "${rest%"-${sfx}"}"; return 0 ;;
    esac
  done
}

is_orphan() {
  local wt="$1"
  [ -n "$wt" ] || return 1
  [ -d "${root}/${wt}" ] && return 1
  return 0
}

human_size() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# Collected as "worktree<TAB>id<TAB>display<TAB>extra" lines, one file per type.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: >"$work/containers" >"$work/networks" >"$work/volumes" >"$work/images" >"$work/units"

while IFS=$'\t' read -r name state; do
  [ -n "$name" ] || continue
  wt="$(worktree_of "$name" "$SERVICES")"
  is_orphan "$wt" || continue
  printf '%s\t%s\t%s\t0\n' "$wt" "$name" "${name} (${state})" >>"$work/containers"
done < <(podman ps -a --format '{{.Names}}\t{{.State}}' 2>/dev/null || true)

while read -r name; do
  [ -n "$name" ] || continue
  wt="$(worktree_of "$name" "$NET_SUFFIXES")"
  is_orphan "$wt" || continue
  printf '%s\t%s\t%s\t0\n' "$wt" "$name" "$name" >>"$work/networks"
done < <(podman network ls --format '{{.Name}}' 2>/dev/null || true)

while read -r name; do
  [ -n "$name" ] || continue
  wt="$(worktree_of "$name" "$VOL_SUFFIXES")"
  is_orphan "$wt" || continue
  printf '%s\t%s\t%s\t0\n' "$wt" "$name" "$name" >>"$work/volumes"
done < <(podman volume ls --format '{{.Name}}' 2>/dev/null || true)

# Template units instantiated for a worktree that is gone. They are not files --
# <prefix>-rails@.container serves every worktree -- so there is nothing to
# delete, but an active instance holds the containers above and has to be
# stopped before they can be removed.
while read -r unit; do
  [ -n "$unit" ] || continue
  case "$unit" in *"@"*) wt="${unit##*@}"; wt="${wt%.service}" ;; *) continue ;; esac
  is_orphan "$wt" || continue
  printf '%s\t%s\t%s\t0\n' "$wt" "$unit" "$unit" >>"$work/units"
done < <(systemctl --user list-units --all --plain --no-legend "${P}-*@*.service" 2>/dev/null | awk '{print $1}' || true)

# Image tags no live worktree references. The reference set is every image tag
# named in a live worktree's env file -- which is generated from that worktree's
# .ruby-version, .nvmrc and Gemfile.lock, so it is the authority on what that
# worktree will actually run.
# A live worktree with no env file contributes nothing to the reference set,
# which would make its images look unreferenced and offer them for deletion.
# That is the one way this could delete something in use, so any such worktree
# disables the image sweep entirely rather than being skipped quietly.
referenced="$work/referenced"
: >"$referenced"
unknown=""
for d in "$root"/*/; do
  wt="$(basename "$d")"
  [ -d "$root/$wt/.git" ] || [ -f "$root/$wt/.git" ] || continue
  env_file="$root/.unit-env/$wt.env"
  if [ ! -f "$env_file" ]; then
    unknown="${unknown} ${wt}"
    continue
  fi
  sed -n 's/^\(RAILS\|NVIM\|CLAUDE\|PLAYWRIGHT\)_IMAGE=//p' "$env_file" >>"$referenced"
done
sort -u -o "$referenced" "$referenced"

if [ -n "$unknown" ]; then
  echo "Not touching any images: these live worktrees have no env file, so their" >&2
  echo "image tags are unknown and could not be told apart from stale ones:" >&2
  for wt in $unknown; do echo "  ${wt}   (fix: cd ${wt} && mise run units:env)" >&2; done
  echo "" >&2
fi
while IFS=$'\t' read -r repotag size; do
  [ -z "$unknown" ] || break
  [ -n "$repotag" ] && [ "$repotag" != "<none>:<none>" ] || continue
  case "$repotag" in "localhost/${P}/"*) ;; *) continue ;; esac
  grep -qxF "$repotag" "$referenced" && continue
  printf '%s\t%s\t%s\t%s\n' "(unreferenced)" "$repotag" "$repotag" "$(human_size "$size")" >>"$work/images"
done < <(podman images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null || true)

if [ ! -s "$work/containers" ] && [ ! -s "$work/networks" ] &&
   [ ! -s "$work/volumes" ] && [ ! -s "$work/images" ] && [ ! -s "$work/units" ]; then
  echo "No orphaned artifacts."
  exit 0
fi

if [ -s "$referenced" ]; then
  echo "Image tags in use by live worktrees:"
  sed 's/^/  /' "$referenced"
  echo ""
fi

groups=$(cut -f1 "$work"/containers "$work"/networks "$work"/volumes "$work"/images "$work"/units | sort -u)

echo "Orphaned podman artifacts:"
echo ""
for g in $groups; do
  echo "  ${g}"
  for type in units containers networks volumes images; do
    entries=$(awk -F'\t' -v p="$g" '$1 == p {
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
printf '%s groups, %s units, %s containers, %s networks, %s volumes, %s images\n' \
  "$(wc -w <<<"$groups" | tr -d ' ')" "$(count units)" "$(count containers)" \
  "$(count networks)" "$(count volumes)" "$(count images)"
echo ""
echo "Volumes include database data. This cannot be undone."
echo "Image sizes above are nominal — shared layers mean actual reclaim is lower."
printf "Continue? [y/N] "
read -r confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 1 ;;
esac

# Units first: they own the containers, and Restart=on-failure would race the
# removal otherwise. Then containers, then the networks and volumes they hold.
# Failures are reported but never abort the sweep, so one wedged artifact cannot
# strand the rest.
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

remove_all units systemctl --user stop
remove_all containers podman rm -f
remove_all networks podman network rm
remove_all volumes podman volume rm
remove_all images podman rmi

echo ""
echo "Done."
