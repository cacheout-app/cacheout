#!/bin/zsh
# Measure the window between handing a worktree to a remover and the first
# file inside it being gone (PR #460 codex r5, D1).
#
#   cc -O2 -o scripts/measure/worktree-removal-window \
#          scripts/measure/worktree-removal-window.c
#   scripts/measure/worktree-removal-window.sh git 0    10
#   scripts/measure/worktree-removal-window.sh fs  0    10
#   scripts/measure/worktree-removal-window.sh git 2000 5
#   scripts/measure/worktree-removal-window.sh fs  2000 5
#
# Prints one elapsed-milliseconds figure per iteration. `git` execs
# `git worktree remove`; `fs` calls `removefile(3)` directly, the shape
# WorktreeReclaimPerformer uses through DepthSafeRemoval.
#
# READ-ONLY OUTSIDE ITS OWN FIXTURE: everything it creates and destroys is
# under $BASE, which it rm -rf's at the start of every iteration.
# usage: run.sh <mode git|fs> <nfiles> <iterations>
# Endpoint measured: t0 = the instant control is handed to the remover;
# t1 = the first instant the SENTINEL tracked file is gone (ENOENT).
# With nfiles=0 the sentinel is the ONLY tracked file, so t1 IS the first
# destruction and no walk-order question arises.
set -e
MODE=$1; N=$2; ITERS=$3
BASE=${TMPDIR:-/tmp}/cacheout-removal-window
WIN=${WIN:-$(dirname "$0")/worktree-removal-window}
for i in $(seq 1 $ITERS); do
  rm -rf "$BASE"
  mkdir -p "$BASE/parent"
  git -C "$BASE/parent" init -q
  git -C "$BASE/parent" config user.email t@t; git -C "$BASE/parent" config user.name t
  echo seed > "$BASE/parent/seed.txt"
  git -C "$BASE/parent" add -A >/dev/null; git -C "$BASE/parent" commit -qm seed
  git -C "$BASE/parent" worktree add -q "$BASE/wt" -b "b$i" >/dev/null 2>&1
  if [ "$N" -gt 0 ]; then
    for k in $(seq 1 $N); do printf 'xxxxxxxxxxxxxxxx' > "$BASE/wt/f$k.txt"; done
  fi
  printf 'sentinel' > "$BASE/wt/0_sentinel.txt"
  git -C "$BASE/wt" add -A >/dev/null; git -C "$BASE/wt" commit -qm files
  sync
  "$WIN" "$MODE" "$BASE/parent" "$BASE/wt" "$BASE/wt/0_sentinel.txt"
done
rm -rf "$BASE"
