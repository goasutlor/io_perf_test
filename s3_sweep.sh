#!/usr/bin/env bash
# Parallel S3 PUT benchmark → CSV compatible with io_compare.html (storage_backend=s3).
# Requires: aws CLI in PATH, credentials with s3:PutObject on the bucket/prefix.
# Does not install AWS CLI (use packaging/env.sh after vendoring).
set -euo pipefail

S3_BUCKET="${S3_BUCKET:?Set env S3_BUCKET (target bucket)}"
S3_PREFIX="${S3_PREFIX:-io-perf-sweep}"
MAX_JOBS="${MAX_JOBS:-16}"
OBJ_MB="${OBJ_MB:-32}"
PROFILE_NAME="${PROFILE_NAME:-s3_put}"
PROFILE_GROUP="${PROFILE_GROUP:-s3}"
CSV_FILE="${CSV_FILE:-./s3_sweep_results.csv}"
RUN_ID="${RUN_ID:-$(date +%s)}"
AWS_EXTRA="${AWS_EXTRA:-}"

have(){ command -v "$1" >/dev/null 2>&1; }

if ! have aws; then
  echo "aws CLI not found. Source packaging/env.sh after extracting the offline bundle, or install AWS CLI v2." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OBJ="$TMP/blob.bin"
dd if=/dev/urandom of="$OBJ" bs=1M count="$OBJ_MB" status=none 2>/dev/null || dd if=/dev/zero of="$OBJ" bs=1M count="$OBJ_MB" status=none

ENGINE="aws-cli"
EV=$(aws --version 2>&1 | head -1 | tr -d '\r' || echo aws-cli)
ENGINE="${ENGINE} (${EV})"

write_header() {
  cat > "${CSV_FILE}" << 'HDR'
jobs,total_qd,bw_mbs,iops,bw_min_mbs,bw_max_mbs,bw_stdev_mbs,lat_avg_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_p999_ms,lat_max_ms,lat_stdev_ms,slat_avg_us,clat_avg_us,cpu_usr_pct,cpu_sys_pct,io_util_pct,ctx_switches,profile,engine,file_size,timestamp,profile_name,profile_group,storage_backend
HDR
}

append_row() {
  local jobs="$1" total_qd="$2" bw="$3" iops="$4" lat="$5" prof="$6" ts="$7"
  local bmin="$bw" bmax="$bw" bstd="0"
  local lat50="$lat" lat95="$lat" lat99="$lat" lat999="$lat" latmax="$lat" latstd="0"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$jobs" "$total_qd" "$bw" "$iops" "$bmin" "$bmax" "$bstd" \
    "$lat" "$lat50" "$lat95" "$lat99" "$lat999" "$latmax" "$latstd" \
    "0" "0" "0" "0" "0" "0" \
    "$prof" "$ENGINE" "${OBJ_MB}M" "$ts" "$PROFILE_NAME" "$PROFILE_GROUP" "s3" >> "${CSV_FILE}"
}

write_header
echo "S3 sweep → ${CSV_FILE}"
echo "  bucket=${S3_BUCKET} prefix=${S3_PREFIX}/${RUN_ID}/  object=${OBJ_MB}MiB  jobs=1..${MAX_JOBS}"
echo

for ((j = 1; j <= MAX_JOBS; j++)); do
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
  prof="s3-cp parallel=${j} size=${OBJ_MB}MiB prefix=${S3_PREFIX}"
  start=$(python3 -c "import time; print(time.perf_counter())")
  for ((i = 1; i <= j; i++)); do
    aws s3 cp "$OBJ" "s3://${S3_BUCKET}/${S3_PREFIX}/${RUN_ID}/j${j}_${i}.bin" --only-show-errors ${AWS_EXTRA} &
  done
  wait || true
  end=$(python3 -c "import time; print(time.perf_counter())")
  elapsed=$(python3 -c "print(max(float('$end')-float('$start'), 1e-9))")
  bw=$(python3 -c "mb=float($j)*float($OBJ_MB)/float($elapsed); print(f'{mb:.6f}')")
  iops=$(python3 -c "print(int(float($j)/float($elapsed)+0.5))")
  lat=$(python3 -c "ms=float($elapsed)*1000.0/float(max($j,1)); print(f'{ms:.6f}')")
  append_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ts"
  echo "  jobs=$j  ${bw} MB/s  iops≈$iops  avg_op≈${lat} ms"
done

echo
echo "Done. Open io_compare.html and upload ${CSV_FILE}"
