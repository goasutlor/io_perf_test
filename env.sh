#!/usr/bin/env bash
# Optional: source this file if you run aws/s3 scripts outside universal_io_test.sh
#   source ./env.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$ROOT/vendor/aws-cli/bin:$PATH"
