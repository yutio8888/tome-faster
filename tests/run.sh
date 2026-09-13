#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TOME_ENGINE_ROOT="${1:?pass the path to a local ToME engine Git clone}"
TOME_LUAJIT="${TOME_LUAJIT:-$(command -v luajit)}"
TOME_LUAROCKS_ROOT="${TOME_LUAROCKS_ROOT:-$HOME/.local/share/tome4-luarocks}"
export LUA_PATH="$TOME_LUAROCKS_ROOT/share/lua/5.1/?.lua;$TOME_LUAROCKS_ROOT/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$TOME_LUAROCKS_ROOT/lib/lua/5.1/?.so;;"
"$TOME_LUAJIT" tests/test_existing.lua . "$TOME_ENGINE_ROOT"
"$TOME_LUAJIT" tests/test_save_load.lua . "$TOME_ENGINE_ROOT"
"$TOME_LUAJIT" tests/test_runtime.lua . "$TOME_ENGINE_ROOT" "${2:-}"
"$TOME_LUAJIT" tests/test_profile.lua .
"$TOME_LUAJIT" tests/test_clone.lua . "$TOME_ENGINE_ROOT"
"$TOME_LUAJIT" tests/test_chardump.lua . "$TOME_ENGINE_ROOT"
"$TOME_LUAJIT" tests/test_export_cleanup.lua . "$TOME_ENGINE_ROOT" "${2:-}"
git diff --check
