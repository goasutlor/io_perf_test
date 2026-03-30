#!/usr/bin/env bash
# Download AWS CLI v2 (Linux x86_64) and install into ../vendor/aws-cli (offline-friendly).
# Run on a machine with internet once; include vendor/ in the tarball for air-gapped hosts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VEND="$ROOT/vendor"
ZIP_URL="${AWS_CLI_ZIP_URL:-https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$VEND/cache"
ZIP="$VEND/cache/awscliv2-linux-x86_64.zip"
if [[ ! -f "$ZIP" ]]; then
  echo "Downloading $ZIP_URL ..."
  curl -fsSL -o "$ZIP" "$ZIP_URL"
fi
unzip -q -o "$ZIP" -d "$STAGE"
rm -rf "$VEND/aws-cli"
"$STAGE/aws/install" -i "$VEND/aws-cli" -b "$VEND/aws-cli/bin"
echo "Installed: $VEND/aws-cli/bin/aws"
"$VEND/aws-cli/bin/aws" --version
