#!/usr/bin/env bash
# Symlinks the prr shell command and the prr-review agent skill out of this
# checkout. Safe to re-run (e.g. as lazy.nvim's `build = "./install.sh"`).
#   PRR_BIN_DIR        where `prr` goes          (default: ~/.local/bin)
#   CLAUDE_SKILLS_DIR  where the skill goes      (default: ~/.claude/skills)
set -euo pipefail

src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
bin_dir=${PRR_BIN_DIR:-$HOME/.local/bin}
skills_dir=${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}

link() { # <target> <link path>
  if [[ -e $2 && ! -L $2 ]]; then
    echo "prr install: $2 exists and is not a symlink, skipping" >&2
    return
  fi
  mkdir -p "$(dirname "$2")"
  ln -sfn "$1" "$2"
  echo "$2 -> $1"
}

link "$src/bin/prr" "$bin_dir/prr"
link "$src/skills/prr-review" "$skills_dir/prr-review"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "prr install: $bin_dir is not on your PATH" >&2 ;;
esac
