#!/bin/zsh
# Measure the window between handing a worktree to a remover and the first
# file inside it being gone (PR #460 codex r5, D1).
#
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
HERE=$(dirname "$0")
WIN=${WIN:-$HERE/worktree-removal-window}

# BUILD IT, OR SAY WHY NOT (PR #460 codex r7, D7). Through r6 this script
# printed a `cc -O2 …` recipe in a comment and then ran $WIN regardless: on a
# machine with no `cc` on PATH — the Xcode-only macOS default, where the
# compiler is `xcrun clang` — the recipe failed, the binary was never built,
# and the script died with a bare "no such file or directory" that named
# neither cause. A checked-in harness whose own instructions do not run is not
# a reproducible measurement.
if [ ! -x "$WIN" ] || [ "$HERE/worktree-removal-window.c" -nt "$WIN" ]; then
  # An ARRAY, because the working spelling on a stock macOS is TWO words
  # (`xcrun clang`) and this script's shell is zsh, which does not word-split
  # an unquoted scalar. `$CC="xcrun clang"` split as one word is exactly how
  # the first attempt at this fix failed.
  local -a COMPILER
  if [ -n "${CC:-}" ]; then
    COMPILER=( ${=CC} )
  elif command -v cc >/dev/null 2>&1; then
    COMPILER=( cc )
  elif command -v xcrun >/dev/null 2>&1 && xcrun -f clang >/dev/null 2>&1; then
    COMPILER=( xcrun clang )
  else
    echo "worktree-removal-window: no C compiler found. Install the Xcode" >&2
    echo "command line tools (xcode-select --install), or set CC=<compiler>." >&2
    exit 127
  fi
  echo "worktree-removal-window: building with ${COMPILER[*]}" >&2
  "${COMPILER[@]}" -O2 -o "$WIN" "$HERE/worktree-removal-window.c" || {
    echo "worktree-removal-window: build FAILED with ${COMPILER[*]}" >&2
    exit 1
  }
fi
if [ ! -x "$WIN" ]; then
  echo "worktree-removal-window: $WIN is missing or not executable" >&2
  exit 1
fi
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
