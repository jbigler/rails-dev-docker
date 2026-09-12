# `mise run clean` — remove docker artifacts for worktrees that no longer exist

Date: 2026-08-10

## Problem

Docker artifacts for deleted worktrees accumulate indefinitely. A sweep on
2026-08-10 found 56 orphaned volumes belonging to 30 worktrees that no longer
exist on disk (13.17 GB), plus built images for 5 more (`6787-patient-portal`,
`7821-save-rasterized-pdf-metadata`, `7857-gender-reveal-enable-pdf-link`,
`7916-convert-unsupported-images-pdf`, `bugfix-workup-order-without-result`).

Nothing surfaces them. `docker volume prune` does not help: since Docker 23.0 it
skips *named* volumes unless given `-a`, and every compose volume is named
(`<project>_db_data`). `docker volume prune -a` would work but is daemon-wide —
it would also delete unrelated projects' data.

## Root cause

`wt:rm` already tears down a worktree's docker state thoroughly
(`.scripts/remove-worktree.sh:88-116`): `docker compose down -v --rmi local`,
then a per-project sweep of lingering containers, volumes, networks, and images.

Orphans therefore only accumulate when a worktree leaves some *other* way:

- removed by hand with `rm -rf` instead of `mise run wt:rm`
- a `wt:rm` that died partway through
- worktrees predating `remove-worktree.sh`

## Verified hazard: shared base images carry a worktree's project label

Compose stamps `com.docker.compose.project` on containers, volumes, networks,
**and built images**. For images this is unsafe as an ownership signal, because
the shared base images are stamped with whichever project built them last:

```
$ docker image inspect filial/rails:ruby4.0.3-node24.14.0 \
    --format '{{index .Config.Labels "com.docker.compose.project"}}'
filial-master

$ docker images --filter label=com.docker.compose.project=filial-master \
    --format '{{.Repository}}:{{.Tag}}'
filial/claude:latest
filial/nvim:ruby4.0.3-node24.14.0
filial/rails:ruby4.0.3-node24.14.0
filial/playwright:v1.61.0
filial-master-nvim:latest
filial-master-playwright:latest
filial/playwright:latest
filial-master-app:latest
rails_dev_docker/claude:latest
```

Nine images, only three of which belong to `filial-master`. This is also a latent
bug in `remove-worktree.sh:112-116`, which deletes by that label alone: removing
a worktree that last built the bases would delete `filial/rails`, `filial/nvim`,
`filial/playwright`, and `filial/claude` out from under every other worktree.
Not yet triggered only because `master` happens to hold the label today.

## Design

New task `clean` in `.mise/config.toml`, delegating to
`.scripts/clean-orphan-docker-artifacts.sh`. Logic lives in `.scripts/` to match
`create-worktree.sh` / `remove-worktree.sh` / `prune-stale-containers.sh`
rather than inline like `destroy`. It sources `lib.sh` for `find_project_root` and
`find_git_dir` so root detection is identical to `wt:rm`.

### 1. Live worktree set

Directories at the project root, cross-checked against `git worktree list`.

### 2. Attribution, per artifact type

| Type | Selector | Why |
| --- | --- | --- |
| Containers | `com.docker.compose.project` label | Per-project by construction, never shared |
| Volumes | `com.docker.compose.project` label | Same |
| Networks | `com.docker.compose.project` label | Same |
| Images | label **and** repo `== <project>-<service>` | Label alone matches the shared bases |

The image rule is the safety mechanism. An image qualifies only when its own
`com.docker.compose.project` and `com.docker.compose.service` labels reconstruct
its repository name:

- `filial-master-app` = `filial-master` + `-` + `app` — qualifies
- `filial/rails:ruby4.0.3-node24.14.0`, labeled `filial-master`, does not
  reconstruct — skipped

Exact, requires no name parsing, and structurally cannot match a shared base.

An artifact is an orphan when its project is `filial-<name>` and `<name>/` does
not exist at the project root. Ambiguity errs toward keeping: a dead worktree
whose name extends a live one is retained.

Out of scope, deliberately:

- dangling images and build cache — not attributable to any worktree;
  `docker image prune` / `docker builder prune` already cover them
- underscore-scheme legacy artifacts (`filial_rails-core-*`) and bare names
  (`master-app`) — no worktree ever mapped to them under the current scheme
- `filial_shared_gems*`, `filial_shared_npm`, `filial_shared_node` — shared
  across all worktrees
- the `filial_proxy` stack — shared infrastructure

### 3. Guards, before any enumeration

1. **`PROJECT_PREFIX` unset → refuse.** Same as `destroy`. Without it every
   pattern is wrong.
2. **Incomplete git worktree view → refuse.** Ported from
   `remove-worktree.sh:41-58`. Inside the claude container the sibling worktrees
   are not mounted at their registered host paths, so every live worktree would
   look dead and the task would try to delete the entire project's docker state.
   Abort unless every path in `git worktree list --porcelain` exists on disk.

### 4. Output and confirmation

Group by dead worktree, with sizes, then prompt once:

```
Orphaned docker artifacts (no worktree folder):

  filial-7821-save-rasterized-pdf-metadata
    volumes:    _db_data (144MB), _rustfs_data (10MB)
    images:     -app, -nvim (2.5GB)
  filial-bugfix-workup-order-without-result
    containers: -rails-1, -db-1 (stopped)
    networks:   _dev
    volumes:    _db_data (620MB), _rustfs_data (11MB)

3 worktrees, 2 containers, 1 network, 6 volumes, 2 images — ~3.3GB

Volumes include database data. This cannot be undone.
Continue? [y/N]
```

Nothing found → print `No orphaned artifacts.`, exit 0, no prompt.

Volume sizes from `docker system df -v`; image sizes from `docker image inspect`.
The output notes that image totals are nominal, because shared layers mean actual
reclaim is lower — on 2026-08-10, 12.9 GB of image tags freed 3.0 GB.

### 5. Deletion order

Containers → networks → volumes → images. A network or volume will not release
while a container still references it. Each step reports what it removed. A
failure on one artifact does not abort the sweep; it is reported and the run
continues, matching the `|| true` per-step style of `remove-worktree.sh`.

### 6. Fix `remove-worktree.sh:112-116`

Apply the same `<project>-<service>` reconstruction rule so `wt:rm` can only
delete images it actually built. Without this, the bug above stays live.

## Trade-offs

- **Folder presence is the source of truth.** A worktree whose directory is
  temporarily absent (unmounted, mid-move) reads as dead. The git-view guard
  covers the container case; a bind-mount gone missing on the host would not be
  caught.
- **Strict scheme only.** Legacy underscore-scheme artifacts are never swept, so
  anything from before the current naming needs manual removal. Accepted: those
  are already gone, and a wider net risks deleting on a misparse.
- **Nominal image sizes.** Reported totals overstate reclaim because of shared
  layers. Called out in the output rather than solved.
- **No dry-run flag.** Preview plus `[y/N]` in one run covers it; a separate mode
  would be a second path to keep correct.

## Alternative considered and rejected

Scope by name prefix instead of compose labels — for each `filial-*` artifact,
strip the prefix and check whether the remainder starts with a live worktree
name. This is what the manual 2026-08-10 sweep did, and it worked.

Rejected because worktree names contain dashes, so `filial-master-app` is
ambiguous by name alone: worktree `master` service `app`, or worktree
`master-app`. The label pair resolves it exactly with no parsing. Name matching
is retained only implicitly, via the repo-reconstruction check.

## Verification

1. Run against the current (already-swept) state — must report
   `No orphaned artifacts.` and exit 0.
2. Synthetic orphan: create a throwaway compose project `filial-does-not-exist`
   with a volume and a network; confirm the task lists both, prompts, and removes
   exactly those.
3. Negative controls in the same run: `filial-master`'s containers, volumes, and
   images are untouched; the shared `filial/*` bases are untouched; the five
   stopped-but-live worktrees keep their volumes.
4. Guard test: with a fabricated missing path in git's worktree view, the task
   refuses and deletes nothing.
5. Guard test: with `PROJECT_PREFIX` unset, the task refuses.
6. Answering `n` at the prompt deletes nothing.
7. `remove-worktree.sh` fix: with a dead worktree's project label applied to a
   shared base image, `wt:rm` leaves that base image in place.
