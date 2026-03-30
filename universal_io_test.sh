#!/usr/bin/env bash
# Single entrypoint for deployment:
#   1) choose Storage Type
#   2) choose IO profile flow for that storage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/packaging/bootstrap-aws-cli.sh" 2>/dev/null || true
prepend_bundled_aws_cli "$SCRIPT_DIR" || true

echo "==============================================="
echo " Universal IO Test"
echo "==============================================="
echo
echo "Select Storage Type:"
echo "  1) Filesystem"
echo "  2) HDFS"
echo "  3) Object (S3)"
echo
read -rp "Select [1-3]: " st || st="1"

case "${st:-1}" in
  1)
    echo
    echo "Filesystem selected."
    echo "Launching io_sweep.sh (full profile groups + standard mode)."
    echo
    exec bash "${SCRIPT_DIR}/io_sweep.sh"
    ;;
  2)
    echo
    echo "HDFS selected."
    echo "Launching Spark-like profile flow for HDFS."
    echo
    export UNIVERSAL_FORCE_STORAGE="hdfs"
    exec bash "${SCRIPT_DIR}/storage_spark_sweep.sh"
    ;;
  3)
    echo
    echo "Object (S3) selected."
    echo "Launching Spark-like profile flow for S3."
    echo
    export UNIVERSAL_FORCE_STORAGE="s3"
    exec bash "${SCRIPT_DIR}/storage_spark_sweep.sh"
    ;;
  *)
    echo "Invalid selection: ${st}"
    exit 1
    ;;
esac

