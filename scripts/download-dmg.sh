#!/usr/bin/env bash
# download-dmg.sh
#
# Downloads the latest Strata .dmg release from this private GitHub repo
# using a personal access token (a fine-grained PAT scoped to just this
# repo works fine -- you do not need to be a collaborator on the repo).
#
# Usage:
#   GITHUB_TOKEN=<your token> ./scripts/download-dmg.sh
# or just run it with no token set and it will prompt for one (input is
# hidden). Requires curl and python3, both of which ship with macOS /
# the Xcode Command Line Tools.

set -euo pipefail

REPO="mbuckingham74/strata"
DEST="${DEST:-$HOME/Downloads}"
mkdir -p "$DEST"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  read -rsp "GitHub token: " GITHUB_TOKEN
  echo
fi

echo "==> Looking up latest release..."
release_json="$(curl -sf \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases/latest")"

read -r asset_id asset_name <<PYEOF
$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
dmgs = [a for a in d["assets"] if a["name"].endswith(".dmg")]
if not dmgs:
    sys.exit("no .dmg asset found on the latest release")
a = dmgs[0]
print(a["id"], a["name"])
' "$release_json")
PYEOF

dest_path="$DEST/$asset_name"
echo "==> Downloading $asset_name -> $dest_path"
curl -sfL \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/octet-stream" \
  "https://api.github.com/repos/$REPO/releases/assets/$asset_id" \
  -o "$dest_path"

echo "==> Done: $dest_path"
echo ""
echo "Next steps:"
echo "  1. Open $asset_name and drag Strata.app to Applications."
echo "  2. In Terminal: xattr -cr /Applications/Strata.app"
echo "  3. Launch Strata from Applications."
