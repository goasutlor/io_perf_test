#!/usr/bin/env bash
# Unified Spark-oriented sweep: choose Filesystem (fio), HDFS, or S3, then Spark profile(s).
# CSV matches io_sweep.sh (profile_group=spark, storage_backend=fio|hdfs|s3) for io_compare.html.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/packaging/bootstrap-aws-cli.sh" 2>/dev/null || true
prepend_bundled_aws_cli "$SCRIPT_DIR" || true
VERSION="1.0"

RED='\033[0;31m'; GRN='\033[0;32m'; BLD='\033[1m'; BCYA='\033[1;36m'; RST='\033[0m'
info() { echo -e "  ${BCYA}[INFO]${RST} $*"; }
err()  { echo -e "  ${RED}[FAIL]${RST} $*" >&2; }

have(){ command -v "$1" >/dev/null 2>&1; }

write_csv_header() {
  cat > "${CSV_FILE}" << 'HDR'
jobs,total_qd,bw_mbs,iops,bw_min_mbs,bw_max_mbs,bw_stdev_mbs,lat_avg_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_p999_ms,lat_max_ms,lat_stdev_ms,slat_avg_us,clat_avg_us,cpu_usr_pct,cpu_sys_pct,io_util_pct,ctx_switches,profile,engine,file_size,timestamp,profile_name,profile_group,storage_backend
HDR
}

# shellcheck disable=SC2059
append_csv_row() {
  local jobs="$1" total_qd="$2" bw="$3" iops="$4" lat="$5" prof="$6" engine="$7" fsize="$8" ts="$9" pname="${10}" sbe="${11}"
  local bmin="$bw" bmax="$bw" bstd="0"
  local lat50="$lat" lat95="$lat" lat99="$lat" lat999="$lat" latmax="$lat" latstd="0"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$jobs" "$total_qd" "$bw" "$iops" "$bmin" "$bmax" "$bstd" \
    "$lat" "$lat50" "$lat95" "$lat99" "$lat999" "$latmax" "$latstd" \
    "0" "0" "0" "0" "0" "0" \
    "$prof" "$engine" "$fsize" "$ts" "$pname" "spark" "$sbe" >> "${CSV_FILE}"
}

t0() { python3 -c "import time; print(time.perf_counter())"; }
calc_elapsed() { python3 -c "print(max(float('$2')-float('$1'), 1e-9))"; }
calc_metrics() {
  local elapsed="$1" jobs="$2" mb_per_op="$3"
  python3 -c "
e=float('$elapsed'); j=int('$jobs'); mb=float('$mb_per_op')
bw=j*mb/e
iops=int(j/e+0.5)
lat=e*1000.0/max(j,1)
print(f'{bw:.6f} {iops} {lat:.6f}')
" 2>/dev/null || echo "0 0 0"
}

banner() {
  clear 2>/dev/null || true
  echo -e "${BCYA}╔════════════════════════════════════════════════════════════════╗${RST}"
  echo -e "${BCYA}║  Unified Spark Storage Sweep  v${VERSION}                           ║${RST}"
  echo -e "${BCYA}║  Filesystem (fio) · HDFS · S3 — same Spark profile names       ║${RST}"
  echo -e "${BCYA}╚════════════════════════════════════════════════════════════════╝${RST}"
  echo
}

menu_storage() {
  echo -e "${BLD}1)${RST} Filesystem — fio Spark profiles (local / SAN / NFS path)"
  echo -e "${BLD}2)${RST} HDFS — API-level Spark-like patterns (needs hdfs/hadoop in PATH)"
  echo -e "${BLD}3)${RST} Object storage (S3) — API-level Spark-like patterns (needs aws CLI)"
  echo
  read -rp "  Select storage [1-3]: " _s || _s="1"
  case "${_s:-1}" in
    2) STORAGE="hdfs" ;;
    3) STORAGE="s3" ;;
    *) STORAGE="fs" ;;
  esac
}

menu_profiles() {
  echo
  echo -e "${BLD}Spark IO profiles${RST} (same names as io_sweep.sh Spark mode):"
  echo "  1) spark_read    — large sequential read (scan)"
  echo "  2) spark_write   — large sequential write (partition output)"
  echo "  3) spark_shuffle — mixed read+write (50/50 style)"
  echo "  4) spark_head    — small random / metadata-heavy"
  echo "  5) spark_move    — mixed read+write (70/30 style)"
  echo "  6) Full suite    — all 5 in sequence"
  echo
  read -rp "  Select profile [1-6, default=6]: " _p || _p="6"
  PROFILE_CHOICE="${_p:-6}"
}

menu_jobs() {
  read -rp "  Max parallel jobs (1→N sweep) [default=8]: " _mj || _mj="8"
  MAX_JOBS="${_mj:-8}"
  [[ "$MAX_JOBS" =~ ^[0-9]+$ ]] && [[ "$MAX_JOBS" -ge 1 ]] || MAX_JOBS=8
}

# Positive integer MiB for dd; fallback if empty/non-numeric
normalize_mib() {
  local v="${1:-64}"
  [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 1 ]] && echo "$v" || echo "64"
}

# ── S3 ─────────────────────────────────────────────────────────────────────────
run_s3() {
  have python3 || { err "python3 required for metrics."; exit 1; }
  have aws || { err "aws CLI not found."; exit 1; }
  [[ -n "${S3_BUCKET:-}" ]] || { read -rp "  S3 bucket name: " S3_BUCKET; }
  [[ -n "$S3_BUCKET" ]] || { err "S3_BUCKET required."; exit 1; }
  read -rp "  S3 prefix [io-perf-spark]: " S3_PREFIX || true
  S3_PREFIX="${S3_PREFIX:-io-perf-spark}"
  read -rp "  Large object size MiB (read/write/move) [64]: " _om || true
  OBJ_MB_L="$(normalize_mib "${_om:-64}")"
  read -rp "  Small object size MiB (head) [1]: " _os || true
  OBJ_MB_S="$(normalize_mib "${_os:-1}")"
  RUN_ID="${RUN_ID:-$(date +%s)}"
  BASE="s3://${S3_BUCKET}/${S3_PREFIX}/${RUN_ID}"
  EV=$(aws --version 2>&1 | head -1 | tr -d '\r')
  ENGINE="aws-cli (${EV})"

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  LARGE="$TMP/large.bin"
  SMALL="$TMP/small.bin"
  dd if=/dev/urandom of="$LARGE" bs=1M count="$OBJ_MB_L" status=none 2>/dev/null || dd if=/dev/zero of="$LARGE" bs=1M count="$OBJ_MB_L" status=none
  dd if=/dev/urandom of="$SMALL" bs=1M count="$OBJ_MB_S" status=none 2>/dev/null || dd if=/dev/zero of="$SMALL" bs=1M count="$OBJ_MB_S" status=none

  mkdir -p "$(dirname "$CSV_FILE")"
  write_csv_header

  local profiles_to_run=()
  case "$PROFILE_CHOICE" in
    1) profiles_to_run=(spark_read) ;;
    2) profiles_to_run=(spark_write) ;;
    3) profiles_to_run=(spark_shuffle) ;;
    4) profiles_to_run=(spark_head) ;;
    5) profiles_to_run=(spark_move) ;;
    *) profiles_to_run=(spark_read spark_write spark_shuffle spark_head spark_move) ;;
  esac

  for pname in "${profiles_to_run[@]}"; do
    info "S3 profile: ${pname}"
    case "$pname" in
      spark_read)
        info "Seeding ${MAX_JOBS} objects for read test..."
        for ((i=1; i<=MAX_JOBS; i++)); do
          aws s3 cp "$LARGE" "${BASE}/seed/read/${i}.bin" --only-show-errors &
        done
        wait || true
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          st=$(t0)
          for ((i=1; i<=j; i++)); do
            aws s3 cp "${BASE}/seed/read/${i}.bin" "$TMP/dl_${i}" --only-show-errors &
          done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(calc_metrics "$el" "$j" "$OBJ_MB_L")" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="s3-spark_read parallel=${j} size=${OBJ_MB_L}MiB GET"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_L}M" "$ts" "spark_read" "s3"
          echo "    jobs=$j  ${bw} MB/s  iops≈$iops"
        done
        ;;
      spark_write)
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          st=$(t0)
          for ((i=1; i<=j; i++)); do
            aws s3 cp "$LARGE" "${BASE}/write/j${j}_${i}.bin" --only-show-errors &
          done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(calc_metrics "$el" "$j" "$OBJ_MB_L")" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="s3-spark_write parallel=${j} size=${OBJ_MB_L}MiB PUT"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_L}M" "$ts" "spark_write" "s3"
          echo "    jobs=$j  ${bw} MB/s  iops≈$iops"
        done
        ;;
      spark_shuffle)
        info "Seeding ${MAX_JOBS} objects for mixed GET/PUT..."
        for ((i=1; i<=MAX_JOBS; i++)); do
          aws s3 cp "$LARGE" "${BASE}/seed/read/${i}.bin" --only-show-errors &
        done
        wait || true
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          n_put=$(( j / 2 ))
          n_get=$(( j - n_put ))
          [[ $n_get -lt 1 ]] && n_get=1 && n_put=$(( j - 1 ))
          st=$(t0)
          for ((i=1; i<=n_get; i++)); do aws s3 cp "${BASE}/seed/read/${i}.bin" "$TMP/sg_${j}_${i}" --only-show-errors & done
          for ((i=1; i<=n_put; i++)); do aws s3 cp "$LARGE" "${BASE}/shuf/j${j}_w${i}.bin" --only-show-errors & done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(python3 -c "
e=float('$el'); j=int('$j'); mb=float('$OBJ_MB_L')
ng=int('$n_get'); np=int('$n_put')
total_mb=(ng+np)*mb
bw=total_mb/e
iops=int(j/e+0.5)
lat=e*1000.0/max(j,1)
print(f'{bw:.6f} {iops} {lat:.6f}')
" 2>/dev/null)" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="s3-spark_shuffle parallel=${j} GETs=${n_get} PUTs=${n_put} size=${OBJ_MB_L}MiB"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_L}M" "$ts" "spark_shuffle" "s3"
          echo "    jobs=$j  ${bw} MB/s  iops≈$iops"
        done
        ;;
      spark_head)
        info "Seeding ${MAX_JOBS} small objects for HEAD..."
        for ((i=1; i<=MAX_JOBS; i++)); do
          aws s3 cp "$SMALL" "${BASE}/seed/head/${i}.bin" --only-show-errors &
        done
        wait || true
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          st=$(t0)
          for ((i=1; i<=j; i++)); do
            aws s3api head-object --bucket "$S3_BUCKET" --key "${S3_PREFIX}/${RUN_ID}/seed/head/${i}.bin" &>/dev/null &
          done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(python3 -c "
e=float('$el'); j=int('$j')
iops=int(j/e+0.5)
lat=e*1000.0/max(j,1)
bw=0.01
print(f'{bw:.6f} {iops} {lat:.6f}')
" 2>/dev/null)" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="s3-spark_head parallel=${j} head-object size=${OBJ_MB_S}MiB"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_S}M" "$ts" "spark_head" "s3"
          echo "    jobs=$j  iops≈$iops  avg_op≈${lat} ms (HEAD-heavy; MB/s not primary)"
        done
        ;;
      spark_move)
        info "Seeding ${MAX_JOBS} read sources for mixed GET/PUT..."
        for ((i=1; i<=MAX_JOBS; i++)); do
          aws s3 cp "$LARGE" "${BASE}/seed/read/${i}.bin" --only-show-errors &
        done
        wait || true
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          n_get=$(( j * 7 / 10 ))
          [[ $n_get -lt 1 ]] && n_get=1
          n_put=$(( j - n_get ))
          st=$(t0)
          for ((i=1; i<=n_get; i++)); do aws s3 cp "${BASE}/seed/read/${i}.bin" "$TMP/mv_r_${j}_${i}" --only-show-errors & done
          for ((i=1; i<=n_put; i++)); do aws s3 cp "$LARGE" "${BASE}/mv/j${j}_${i}.bin" --only-show-errors & done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(python3 -c "
e=float('$el'); j=int('$j'); mb=float('$OBJ_MB_L')
ng=int('$n_get'); np=int('$n_put')
total_mb=(ng+np)*mb
bw=total_mb/e
iops=int(j/e+0.5)
lat=e*1000.0/max(j,1)
print(f'{bw:.6f} {iops} {lat:.6f}')
" 2>/dev/null)" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="s3-spark_move parallel=${j} GET~70%=${n_get} PUT~30%=${n_put}"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_L}M" "$ts" "spark_move" "s3"
          echo "    jobs=$j  ${bw} MB/s  iops≈$iops"
        done
        ;;
    esac
  done
}

# ── HDFS ───────────────────────────────────────────────────────────────────────
run_hdfs() {
  have python3 || { err "python3 required for metrics."; exit 1; }
  local HDFS_BIN=""
  if have hdfs; then HDFS_BIN=hdfs
  elif have hadoop; then HDFS_BIN=hadoop
  else err "hdfs or hadoop not found."; exit 1; fi
  dfs() { $HDFS_BIN dfs "$@"; }

  [[ -n "${HDFS_DEST:-}" ]] || read -rp "  HDFS base path (e.g. /user/\$USER/io-perf): " HDFS_DEST
  [[ -n "$HDFS_DEST" ]] || { err "HDFS_DEST required."; exit 1; }
  read -rp "  Large file MiB (read/write/move) [64]: " _om || true
  OBJ_MB_L="$(normalize_mib "${_om:-64}")"
  read -rp "  Small file MiB (head) [1]: " _os || true
  OBJ_MB_S="$(normalize_mib "${_os:-1}")"
  RUN_ID="${RUN_ID:-$(date +%s)}"
  REMOTE="${HDFS_DEST%/}/${RUN_ID}"
  ENGINE="${HDFS_BIN} $(command -v "${HDFS_BIN}")"

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  LARGE="$TMP/large.bin"
  SMALL="$TMP/small.bin"
  dd if=/dev/urandom of="$LARGE" bs=1M count="$OBJ_MB_L" status=none 2>/dev/null || dd if=/dev/zero of="$LARGE" bs=1M count="$OBJ_MB_L" status=none
  dd if=/dev/urandom of="$SMALL" bs=1M count="$OBJ_MB_S" status=none 2>/dev/null || dd if=/dev/zero of="$SMALL" bs=1M count="$OBJ_MB_S" status=none

  dfs -mkdir -p "$REMOTE/seed/read" "$REMOTE/seed/head" "$REMOTE/shuf" 2>/dev/null || true

  mkdir -p "$(dirname "$CSV_FILE")"
  write_csv_header

  local profiles_to_run=()
  case "$PROFILE_CHOICE" in
    1) profiles_to_run=(spark_read) ;;
    2) profiles_to_run=(spark_write) ;;
    3) profiles_to_run=(spark_shuffle) ;;
    4) profiles_to_run=(spark_head) ;;
    5) profiles_to_run=(spark_move) ;;
    *) profiles_to_run=(spark_read spark_write spark_shuffle spark_head spark_move) ;;
  esac

  for pname in "${profiles_to_run[@]}"; do
    info "HDFS profile: ${pname}"
    case "$pname" in
      spark_read)
        info "Seeding ${MAX_JOBS} files..."
        for ((i=1; i<=MAX_JOBS; i++)); do dfs -put -f "$LARGE" "${REMOTE}/seed/read/${i}.bin" & done
        wait || true
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          st=$(t0)
          for ((i=1; i<=j; i++)); do dfs -cat "${REMOTE}/seed/read/${i}.bin" &>/dev/null & done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(calc_metrics "$el" "$j" "$OBJ_MB_L")" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="hdfs-spark_read parallel=${j} -cat size=${OBJ_MB_L}MiB"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_L}M" "$ts" "spark_read" "hdfs"
          echo "    jobs=$j  ${bw} MB/s  iops≈$iops"
        done
        ;;
      spark_write)
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          st=$(t0)
          for ((i=1; i<=j; i++)); do dfs -put -f "$LARGE" "${REMOTE}/write/j${j}_${i}.bin" & done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(calc_metrics "$el" "$j" "$OBJ_MB_L")" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="hdfs-spark_write parallel=${j} -put size=${OBJ_MB_L}MiB"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_L}M" "$ts" "spark_write" "hdfs"
          echo "    jobs=$j  ${bw} MB/s  iops≈$iops"
        done
        ;;
      spark_shuffle)
        for ((i=1; i<=MAX_JOBS; i++)); do dfs -put -f "$LARGE" "${REMOTE}/seed/read/${i}.bin" & done
        wait || true
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          n_put=$(( j / 2 ))
          n_get=$(( j - n_put ))
          [[ $n_get -lt 1 ]] && n_get=1 && n_put=$(( j - 1 ))
          for ((i=1; i<=n_put; i++)); do dfs -put -f "$LARGE" "${REMOTE}/shuf/j${j}_p${i}.bin" & done
          wait || true
          st=$(t0)
          for ((i=1; i<=n_get; i++)); do dfs -cat "${REMOTE}/seed/read/${i}.bin" &>/dev/null & done
          for ((i=1; i<=n_put; i++)); do dfs -put -f "$LARGE" "${REMOTE}/shuf/j${j}_w${i}.bin" & done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(python3 -c "
e=float('$el'); j=int('$j'); mb=float('$OBJ_MB_L')
ng=int('$n_get'); np=int('$n_put')
total_mb=(ng+np)*mb
bw=total_mb/e
iops=int(j/e+0.5)
lat=e*1000.0/max(j,1)
print(f'{bw:.6f} {iops} {lat:.6f}')
" 2>/dev/null)" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="hdfs-spark_shuffle parallel=${j} GETs=${n_get} PUTs=${n_put}"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_L}M" "$ts" "spark_shuffle" "hdfs"
          echo "    jobs=$j  ${bw} MB/s  iops≈$iops"
        done
        ;;
      spark_head)
        for ((i=1; i<=MAX_JOBS; i++)); do dfs -put -f "$SMALL" "${REMOTE}/seed/head/${i}.bin" & done
        wait || true
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          st=$(t0)
          for ((i=1; i<=j; i++)); do dfs -cat "${REMOTE}/seed/head/${i}.bin" &>/dev/null & done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(python3 -c "
e=float('$el'); j=int('$j'); mb=float('$OBJ_MB_S')
bw=j*mb/e
iops=int(j/e+0.5)
lat=e*1000.0/max(j,1)
print(f'{bw:.6f} {iops} {lat:.6f}')
" 2>/dev/null)" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="hdfs-spark_head parallel=${j} -cat small size=${OBJ_MB_S}MiB"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_S}M" "$ts" "spark_head" "hdfs"
          echo "    jobs=$j  ${bw} MB/s  iops≈$iops"
        done
        ;;
      spark_move)
        for ((i=1; i<=MAX_JOBS; i++)); do dfs -put -f "$LARGE" "${REMOTE}/seed/read/${i}.bin" & done
        wait || true
        for ((j=1; j<=MAX_JOBS; j++)); do
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
          n_get=$(( j * 7 / 10 ))
          [[ $n_get -lt 1 ]] && n_get=1
          n_put=$(( j - n_get ))
          st=$(t0)
          for ((i=1; i<=n_get; i++)); do dfs -cat "${REMOTE}/seed/read/${i}.bin" &>/dev/null & done
          for ((i=1; i<=n_put; i++)); do dfs -put -f "$LARGE" "${REMOTE}/mv/j${j}_${i}.bin" & done
          wait || true
          en=$(t0)
          el=$(calc_elapsed "$st" "$en")
          read -r bw iops lat <<< "$(python3 -c "
e=float('$el'); j=int('$j'); mb=float('$OBJ_MB_L')
ng=int('$n_get'); np=int('$n_put')
total_mb=(ng+np)*mb
bw=total_mb/e
iops=int(j/e+0.5)
lat=e*1000.0/max(j,1)
print(f'{bw:.6f} {iops} {lat:.6f}')
" 2>/dev/null)" || true
          [[ -n "$bw" ]] || { bw=0; iops=0; lat=0; }
          prof="hdfs-spark_move parallel=${j} -cat=${n_get} -put=${n_put}"
          append_csv_row "$j" "$j" "$bw" "$iops" "$lat" "$prof" "$ENGINE" "${OBJ_MB_L}M" "$ts" "spark_move" "hdfs"
          echo "    jobs=$j  ${bw} MB/s  iops≈$iops"
        done
        ;;
    esac
  done
}

# ── Filesystem (fio via io_sweep.sh) ───────────────────────────────────────────
run_fs() {
  export IO_SWEEP_LIB_ONLY=1
  export IO_SWEEP_NO_PAUSE=1
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/io_sweep.sh"

  command -v fio &>/dev/null || { err "fio not found."; exit 1; }
  check_prerequisites
  detect_ioengine

  MODE_TYPE="spark"
  PROFILE_SEL="99"
  case "$PROFILE_CHOICE" in
    1) PROFILE_SEL="1" ;;
    2) PROFILE_SEL="2" ;;
    3) PROFILE_SEL="3" ;;
    4) PROFILE_SEL="4" ;;
    5) PROFILE_SEL="5" ;;
    6) PROFILE_SEL="99" ;;
  esac

  echo; echo -e "${BLD}▶  Filesystem Spark — path & fio settings${RST}"
  for ((i=0; i<60; i++)); do printf '─'; done; echo
  select_path
  echo
  select_jobs_duration

  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  TEST_DIR="${TEST_PATH}/spark_sweep_${TIMESTAMP}"
  CSV_FILE="${TEST_DIR}/spark_results.csv"
  mkdir -p "${TEST_DIR}"

  echo; read -rp "  Start Spark sweep? [Y/n]: " _go || _go="Y"
  [[ "${_go:-Y}" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

  run_profile_group_sweep PROFILES_SPARK
  print_summary
  echo -e "  ${GRN}Done.${RST} CSV: ${CSV_FILE}"
}

run_print_summary() {
  if ! have python3; then
    info "python3 not found — skipped terminal CSV summary. File: ${CSV_FILE}"
    return 0
  fi
  export IO_SWEEP_LIB_ONLY=1
  export IO_SWEEP_NO_PAUSE=1
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/io_sweep.sh"
  print_summary
}

main() {
  banner
  if [[ -n "${UNIVERSAL_FORCE_STORAGE:-}" ]]; then
    case "${UNIVERSAL_FORCE_STORAGE}" in
      fs|hdfs|s3) STORAGE="${UNIVERSAL_FORCE_STORAGE}" ;;
      *) menu_storage ;;
    esac
  else
    menu_storage
  fi
  menu_profiles
  [[ "$STORAGE" != "fs" ]] && menu_jobs

  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  case "$STORAGE" in
    fs)
      run_fs
      exit 0
      ;;
    s3)
      read -rp "  CSV output path [./spark_s3_${TIMESTAMP}.csv]: " _csv || true
      CSV_FILE="${_csv:-./spark_s3_${TIMESTAMP}.csv}"
      echo; read -rp "  Start S3 Spark sweep? [Y/n]: " _go || _go="Y"
      [[ "${_go:-Y}" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }
      run_s3
      run_print_summary
      ;;
    hdfs)
      read -rp "  CSV output path [./spark_hdfs_${TIMESTAMP}.csv]: " _csv || true
      CSV_FILE="${_csv:-./spark_hdfs_${TIMESTAMP}.csv}"
      echo; read -rp "  Start HDFS Spark sweep? [Y/n]: " _go || _go="Y"
      [[ "${_go:-Y}" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }
      run_hdfs
      run_print_summary
      ;;
  esac

  info "Upload ${CSV_FILE} to io_compare.html (profile_group=spark, storage_backend=${STORAGE})."
}

main "$@"
