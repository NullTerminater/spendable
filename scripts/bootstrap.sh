#!/bin/sh
# Regenerates the Xcode project from project.yml and enables the repo's git hooks.
# Safe to run any time; it never touches source files.
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)
if [ "$(git rev-parse --show-toplevel)" != "$root" ]; then
  echo "bootstrap: $root is not the root of its git repository" >&2
  exit 1
fi

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "bootstrap: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --quiet
echo "bootstrap: Spendable.xcodeproj generated, git hooks enabled (core.hooksPath=.githooks)"
