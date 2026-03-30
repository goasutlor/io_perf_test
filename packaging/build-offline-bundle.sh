#!/usr/bin/env bash
# Build io-perf-offline-<stamp>.tar.gz with project files + vendored AWS CLI (if present).
# For air-gapped targets: run packaging/vendor-aws-cli.sh first on a connected host.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/dist}"
mkdir -p "$OUT"
STAMP=$(date +%Y%m%d%H%M)
REV=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)
NAME="io-perf-offline-${STAMP}-${REV}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$NAME"
rsync -a \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='dist' \
  --exclude='__pycache__' \
  "$ROOT/" "$STAGE/$NAME/"

cat > "$STAGE/$NAME/packaging/env.sh" << 'ENVF'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/vendor/aws-cli/bin:$PATH"
ENVF
chmod +x "$STAGE/$NAME/packaging/env.sh"

if [[ ! -d "$STAGE/$NAME/vendor/aws-cli/bin" ]]; then
  echo "Note: vendor/aws-cli not found under project. Tarball will not include AWS CLI."
  echo "      Run:  bash packaging/vendor-aws-cli.sh"
  echo "      Then re-run this script."
fi

TAR="$OUT/${NAME}.tar.gz"
( cd "$STAGE" && tar -czf "$TAR" "$NAME" )
echo "Wrote $TAR"
ls -la "$TAR"
