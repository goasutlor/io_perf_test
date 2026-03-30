#!/usr/bin/env bash
# Prepend bundled AWS CLI v2 to PATH when <repo>/vendor/aws-cli/bin/aws exists.
# Sourced by universal_io_test.sh, storage_spark_sweep.sh, s3_sweep.sh — no manual source needed on deploy.
prepend_bundled_aws_cli() {
  local root="${1:?}"
  local aws_bin="$root/vendor/aws-cli/bin/aws"
  if [[ -x "$aws_bin" ]]; then
    export PATH="$root/vendor/aws-cli/bin:$PATH"
    return 0
  fi
  return 1
}
