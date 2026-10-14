# AGENTS.md

## Repository and worktrees

This directory is the independent GitHub repository `deLiseLINO/tern-todo`, even when checked out as the `tern-todo` submodule of `slop`.
Run Git commands from this repository or its own worktree. Never create GitLab merge requests for tern-todo code.
Before editing, fetch `origin` and create a worktree from `origin/main` under `~/.omp/wt/`. Do not edit the primary checkout or create a worktree of the parent `slop` repository for this project's code.
Preserve unrelated and uncommitted user changes. Do not force-push published branches.

## GitHub publication

Use `https://github.com/deLiseLINO/tern-todo` for all branches and pull requests. Use `gh` with `--repo deLiseLINO/tern-todo` for pull request operations.
Use `deLiseLINO <52623978+deLiseLINO@users.noreply.github.com>` for commits and disable commit signing. Check the configured identity before the first commit.
Write commit messages, pull request titles, descriptions, and GitHub comments in English. Titles use `type(scope): subject`, with an imperative subject and no trailing period. Reply to the user in Russian.
After each task that changes this repository, open a ready pull request into `main` using the poteto `opening-a-pr` playbook. Use the sections `## Why`, `## Scope`, `## Blast Radius`, and `## Verification`. Report only verification that actually ran.
Merge with `gh pr merge <number> --repo deLiseLINO/tern-todo --squash --auto`. After the merge, update the primary tern-todo checkout from `origin/main` without discarding local changes, then remove the task worktree.
Take every UI screenshot for a pull request in the dark theme. In an isolated live Tern window `appearance dark` has no effect, so run `tern ctl --control EP theme light '"dark-github"'`. Crop to the changed card. Commit the images to a separate `pr-assets-*` branch, not to the pull request branch, and link them by commit SHA.

## Parent repository

The parent `slop` repository remains in GitLab. Changes to its `.gitmodules` file and recorded submodule commit belong in a separate GitLab merge request. Do not publish tern-todo code through that merge request.
