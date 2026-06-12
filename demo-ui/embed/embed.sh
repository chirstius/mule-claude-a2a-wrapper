#!/usr/bin/env bash
# Build the demo UI and embed it into the A2A wrapper (served at the app root).
#   1. npm run build                -> dist/
#   2. copy dist/ -> <wrapper>/src/main/resources/dist/   (-> ${app.home}/dist at deploy)
#   3. copy a2a-ui.xml -> <wrapper>/src/main/mule/        (static-SPA serving flow)
# Then rebuild/redeploy the wrapper and browse / .
# TO REMOVE: delete <wrapper>/src/main/mule/a2a-ui.xml and <wrapper>/src/main/resources/dist/.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ui_root="$(cd "$here/.." && pwd)"
wrapper="${1:-$(cd "$here/../../claude-a2a-adapter" && pwd)}"
[ -f "$wrapper/pom.xml" ] || { echo "wrapper not found at $wrapper" >&2; exit 1; }

# Bake the configured A2A path into the build (the UI's default endpoint = browser host + this path).
common="$wrapper/src/main/resources/config/common.yaml"
a2a_path="/a2a"
if [ -f "$common" ]; then
  p=$(grep -oE '^[[:space:]]*path:[[:space:]]*"[^"]+"' "$common" | head -1 | grep -oE '"[^"]+"' | tr -d '"')
  [ -n "$p" ] && a2a_path="$p"
fi
echo "==> npm run build (VITE_A2A_PATH=$a2a_path)"
# MSYS2_ENV_CONV_EXCL stops Git-Bash/MSYS from rewriting the "/a2a" env value into
# a Windows path (e.g. "C:/Program Files/Git/a2a") when it launches native npm/node.
( cd "$ui_root" && MSYS2_ENV_CONV_EXCL='VITE_A2A_PATH' VITE_A2A_PATH="$a2a_path" npm run build )

dist="$ui_root/dist"
[ -f "$dist/index.html" ] || { echo "build did not produce $dist/index.html" >&2; exit 1; }

target="$wrapper/src/main/resources/dist"
rm -rf "$target"
mkdir -p "$target"
cp -R "$dist/." "$target/"
cp "$here/a2a-ui.xml" "$wrapper/src/main/mule/a2a-ui.xml"

echo "==> embedded $(find "$target" -type f | wc -l | tr -d ' ') file(s) into $target"
echo "    rebuild/redeploy the wrapper, then open /"
