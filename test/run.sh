#!/usr/bin/env sh
# Runs window.luau unchanged against the stubs in test/stub.luau.
# Needs the Luau CLI (https://github.com/luau-lang/luau/releases): `luau` on
# PATH, or wherever $LUAU points.
set -eu

dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
luau=${LUAU:-luau}
if ! command -v "$luau" >/dev/null 2>&1; then
	echo "luau not found: install the Luau CLI or set LUAU=/path/to/luau" >&2
	exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat "$dir/test/stub.luau" "$dir/window.luau" "$dir/test/scenarios.luau" >"$work/run.luau"
"$luau" "$work/run.luau"
