#!/usr/bin/env bash
# Cross-SDK round trip: Python and TypeScript serialize seeds.json, Dart
# parses and re-serializes their output, and each SDK parses Dart's output
# again. Run from the repository root after `dart pub get`:
#
#   tool/interop/run.sh [WORK_DIR]
#
# Installs the pinned SDKs under WORK_DIR (default: a new temporary
# directory): a virtualenv made with $PYTHON (default python3; 3.11 to
# 3.13, as the pinned pydantic fails on 3.14 and later; CI uses 3.12) and
# an `npm ci` of package.json. The documents each step wrote are left in
# WORK_DIR/out.
set -euo pipefail

here=tool/interop
work=${1:-$(mktemp -d)}
out=$work/out
mkdir -p "$work/node" "$out"

[ -x "$work/venv/bin/python" ] || "${PYTHON:-python3}" -m venv "$work/venv"
"$work/venv/bin/python" -m pip install --quiet --disable-pip-version-check \
  -r "$here/requirements.txt"
cp "$here/package.json" "$here/package-lock.json" "$work/node/"
(cd "$work/node" && npm ci --silent --no-audit --no-fund)
export UTCP_INTEROP_NODE_DIR=$work/node

py() { "$work/venv/bin/python" "$here/python_driver.py" "$@"; }
ts() { node "$here/typescript_driver.mjs" "$@"; }

py serialize "$here/seeds.json" >"$out/python.json"
ts serialize "$here/seeds.json" >"$out/typescript.json"
for sdk in python typescript; do
  dart run "$here/round_trip.dart" <"$out/$sdk.json" >"$out/$sdk.dart.json"
done

status=0
py check "$out/python.json" "$out/python.dart.json" || status=1
ts check "$out/typescript.json" "$out/typescript.dart.json" || status=1
py accept "$out/typescript.dart.json" || status=1
ts accept "$out/python.dart.json" || status=1
exit $status
