#!/usr/bin/env bash
# ==============================================================================
#  io_sweep.sh v2.0 — IO Performance Sweep  (Jobs 1→N, Cache-Safe, Rich CSV)
#
#  PREREQUISITES (auto-checked at startup):
#  ─────────────────────────────────────────
#  Package       Why needed               Install
#  ──────────────────────────────────────────────────────────────────────────────
#  fio           Core IO benchmark tool   yum install fio
#                                         apt install fio
#                                         brew install fio  (macOS)
#
#  python3       JSON result parsing      yum install python3
#                                         apt install python3
#                (usually pre-installed on modern Linux)
#
#  libaio        Async IO engine for fio  yum install libaio libaio-devel
#  (optional)    Best performance.        apt install libaio1 libaio-dev
#                Falls back to psync      (kernel module — check: modprobe libaio)
#                if not available.
#
#  sysstat       Provides iostat/mpstat   yum install sysstat
#  (optional)    Used for extra disk      apt install sysstat
#                util% verification.      (fio reports util% natively too)
#
#  util-linux    Provides sync, blockdev  Pre-installed on all Linux distros
#  (optional)    Used for cache drop      (part of base system)
#
#  tput          Terminal width detect    Pre-installed (ncurses / ncurses-base)
#
#  QUICK INSTALL (one-liner per distro):
#  ─────────────────────────────────────
#  RHEL/CentOS/Rocky/AlmaLinux:
#    yum install -y fio python3 libaio libaio-devel sysstat
#
#  Ubuntu/Debian:
#    apt install -y fio python3 libaio1 libaio-dev sysstat
#
#  SUSE/openSUSE:
#    zypper install -y fio python3 libaio sysstat
#
#  macOS (Homebrew):
#    brew install fio python3
#    Note: libaio not available on macOS — psync engine used automatically
#
#  USAGE:
#  ──────
#    chmod +x io_sweep.sh
#    sudo ./io_sweep.sh          # recommended: root for drop_caches
#    ./io_sweep.sh               # non-root: works but no cache drop between steps
#
#  OUTPUT:
#    sweep_results.csv           → upload to io_compare.html for charts
#
#  ANTI-CACHE GUARANTEES (per step):
#    1. Unique filename per step  → no file reuse / OS read-ahead warm
#    2. --direct=1 (O_DIRECT)    → bypasses OS page cache on every IO
#    3. --invalidate=1           → fio flushes its own internal buffer
#    4. drop_caches (root only)  → echo 3 > /proc/sys/vm/drop_caches
#    5. 1s settle sleep          → allows cache pressure to clear
#    6. Test files auto-deleted  → no residual data on disk between steps
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
BRED='\033[1;31m'; BGRN='\033[1;32m'; BYEL='\033[1;33m'
BCYA='\033[1;36m'; BBLU='\033[1;34m'; BMAG='\033[1;35m'; BWHT='\033[1;37m'
BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
EL='\033[2K'; HC='\033[1G'; HIDE='\033[?25l'; SHOW='\033[?25h'

VERSION="2.0"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TERM_W=80

TEST_PATH=""
TEST_DIR=""
CSV_FILE=""
RW="randwrite"
BS="4k"
MAX_JOBS=8
IODEPTH=32
DURATION=30
FILE_SIZE="1g"
DIRECT_IO=1
IO_ENGINE="libaio"

# ── Helpers ───────────────────────────────────────────────────────────────────
get_tw()  { TERM_W=$(tput cols 2>/dev/null || echo 80); }
banner() {
  get_tw; clear 2>/dev/null || true; echo -e "${BCYA}"
  local w=$TERM_W
  printf "╔%s╗\n" "$(printf '═%.0s' $(seq 1 $((w-2))))"
  local t="  IO PERFORMANCE SWEEP  v${VERSION}  |  Cache-Safe  |  Rich CSV  "
  printf "║%*s%s%*s║\n" $(( (w-2-${#t})/2 )) "" "$t" $(( (w-1-${#t})/2 )) ""
  local s="  Jobs 1→N  |  O_DIRECT + unique files + drop_caches per step  "
  printf "║%*s%s%*s║\n" $(( (w-2-${#s})/2 )) "" "$s" $(( (w-1-${#s})/2 )) ""
  printf "╚%s╝\n" "$(printf '═%.0s' $(seq 1 $((w-2))))"; echo -e "${RST}"
}
info()    { echo -e "  ${BBLU}[INFO]${RST}  $*"; }
ok()      { echo -e "  ${BGRN}[ OK ]${RST}  $*"; }
warn()    { echo -e "  ${BYEL}[WARN]${RST}  $*"; }
err()     { echo -e "  ${BRED}[FAIL]${RST}  $*"; }
step()    { echo; echo -e "${BLD}${BMAG}▶  $*${RST}"; divider; }
divider() { printf '%.0s─' $(seq 1 $TERM_W); echo; }
thick()   { printf '%.0s═' $(seq 1 $TERM_W); echo; }
pause()   { echo; read -rp "  Press [Enter] to continue..." _x 2>/dev/null || true; }

draw_bar() {
  local cur=$1 tot=$2 w=$3 col="${4:-${GRN}}"
  [[ $tot -le 0 ]] && tot=1
  local filled=$(( cur * w / tot )); [[ $filled -gt $w ]] && filled=$w
  local empty=$(( w - filled )); local fb="" eb="" i
  for ((i=0;i<filled;i++)); do fb+="█"; done
  for ((i=0;i<empty; i++)); do eb+="░"; done
  printf "${col}%s${DIM}%s${RST}" "$fb" "$eb"
}
SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SIDX=0
spin_next() { SIDX=$(( (SIDX+1) % 10 )); printf '%s' "${SPIN[$SIDX]}"; }

# ── Cache control ──────────────────────────────────────────────────────────────
drop_caches() {
  if [[ $EUID -eq 0 ]]; then
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && \
      info "Page cache dropped (echo 3 > /proc/sys/vm/drop_caches)" || \
      warn "Could not drop caches (non-critical)"
  else
    warn "Not root — cannot drop page cache. Results may include cached reads."
    warn "Run with sudo for fully cache-free results."
  fi
}

# ── ioengine detect ────────────────────────────────────────────────────────────
detect_ioengine() {
  if fio --name=_chk --ioengine=libaio --rw=read --bs=4k --size=4k \
         --filename=/dev/null --numjobs=1 --iodepth=1 \
         --output=/dev/null 2>/dev/null; then
    IO_ENGINE="libaio"
  else
    IO_ENGINE="psync"
    warn "libaio unavailable — using psync (lower async performance)"
    warn "Install: yum install libaio | apt install libaio1"
  fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
run_menu() {
  banner; step "Configuration"; echo

  # Path
  echo -e "  ${BLD}Test path${RST} (mount point or directory to test)"
  local p
  while true; do
    read -rp "  Path: " p || exit 1
    p="${p%/}"; [[ -z "$p" ]] && { warn "Empty."; continue; }
    if [[ ! -d "$p" ]]; then
      local yn; read -rp "  Create? [y/N] " yn || yn="n"
      [[ "$yn" =~ ^[Yy]$ ]] && mkdir -p "$p" && { ok "Created."; break; } || continue
    elif [[ ! -w "$p" ]]; then err "Not writable."
    else ok "Path OK."; break; fi
  done
  TEST_PATH="$p"
  TEST_DIR="${p}/io_sweep_${TIMESTAMP}"
  CSV_FILE="${TEST_DIR}/sweep_results.csv"

  # Workload
  echo
  echo -e "  ${BLD}Workload type${RST}"
  echo "   1) randwrite   Random write ← recommended (DB/VM worst case)"
  echo "   2) randread    Random read  (DB query pattern)"
  echo "   3) read        Sequential read  (throughput test)"
  echo "   4) write       Sequential write (throughput test)"
  echo "   5) randrw      Mixed 70R/30W (OLTP simulation)"
  local wl; read -rp "  Select [default=1]: " wl || wl="1"
  case "${wl:-1}" in
    1)RW="randwrite";;2)RW="randread";;3)RW="read";;
    4)RW="write";;5)RW="randrw";;*) RW="randwrite";;
  esac

  # Block size
  echo
  echo -e "  ${BLD}Block size${RST}"
  echo "   1)4k  2)8k  3)16k  4)32k  5)64k  6)128k  7)512k  8)1m  9)Custom"
  local bs; read -rp "  Select [default=1]: " bs || bs="1"
  case "${bs:-1}" in
    1)BS="4k";;2)BS="8k";;3)BS="16k";;4)BS="32k";;
    5)BS="64k";;6)BS="128k";;7)BS="512k";;8)BS="1m";;
    9)read -rp "  Enter: " BS||BS="4k";;*) BS="4k";;
  esac

  # Sweep range
  echo
  local mj; read -rp "  Max jobs to sweep to [default=8]: " mj || mj="8"
  MAX_JOBS="${mj:-8}"

  # iodepth
  echo
  local qd; read -rp "  iodepth per job [default=32]: " qd || qd="32"
  IODEPTH="${qd:-32}"

  # Duration
  echo
  echo -e "  ${BLD}Duration${RST} per step: 1)10s  2)30s  3)60s  4)120s"
  local dur; read -rp "  Select [default=2]: " dur || dur="2"
  case "${dur:-2}" in 1)DURATION=10;;2)DURATION=30;;3)DURATION=60;;4)DURATION=120;;*) DURATION=30;;esac

  # File size
  echo
  echo -e "  ${BLD}File size${RST} per job  (use > RAM to guarantee no cache inflation)"
  echo "   1)256m  2)1g  3)4g ← recommended for iSCSI/NFS  4)10g  5)Custom"
  local sz; read -rp "  Select [default=2]: " sz || sz="2"
  case "${sz:-2}" in
    1)FILE_SIZE="256m";;2)FILE_SIZE="1g";;3)FILE_SIZE="4g";;4)FILE_SIZE="10g";;
    5)read -rp "  Size: " FILE_SIZE||FILE_SIZE="1g";;*) FILE_SIZE="1g";;
  esac

  # Direct IO
  echo
  echo -e "  ${BLD}Direct IO${RST} (O_DIRECT) — bypasses OS page cache"
  echo -e "  ${DIM}Always recommended. Disable ONLY if filesystem doesn't support O_DIRECT${RST}"
  local di; read -rp "  Enable? [Y/n]: " di || di="Y"
  [[ "${di:-Y}" =~ ^[Nn]$ ]] && DIRECT_IO=0 || DIRECT_IO=1

  # Confirm
  echo; thick; echo
  info "Test Path    : ${BLD}${TEST_DIR}${RST}"
  info "Workload     : ${BLD}${RW}${RST}   bs=${BLD}${BS}${RST}"
  info "Sweep        : ${BLD}1 → ${MAX_JOBS} jobs${RST}  (${MAX_JOBS} steps)"
  info "iodepth/job  : ${BLD}${IODEPTH}${RST}"
  info "Duration/step: ${BLD}${DURATION}s${RST}"
  info "File size    : ${BLD}${FILE_SIZE}${RST} per job  (unique file per step)"
  info "Direct IO    : ${BLD}${DIRECT_IO}${RST}  (O_DIRECT — cache bypass)"
  info "IO Engine    : ${BLD}${IO_ENGINE}${RST}"
  info "CSV output   : ${BLD}${CSV_FILE}${RST}"
  echo
  [[ $EUID -ne 0 ]] && warn "Not root — page cache will NOT be dropped between steps"
  [[ $EUID -eq 0 ]] && ok  "Root — page cache will be dropped between each step"
  echo; thick; echo
  local c; read -rp "  Start sweep? [Y/n]: " c || c="Y"
  [[ "${c:-Y}" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }
}

# ── Parse fio JSON → rich metrics ─────────────────────────────────────────────
# Outputs space-separated: bw iops bw_min bw_max bw_stdev
#                          lat_avg lat_p50 lat_p95 lat_p99 lat_p999 lat_max lat_stdev
#                          slat_avg clat_avg
#                          cpu_usr cpu_sys io_util ctx_sw
parse_json_rich() {
  local jfile="$1" rw="$2"
  [[ ! -s "$jfile" ]] && { echo "0 0 0 0 0  0 0 0 0 0 0 0  0 0  0 0 0 0"; return; }
  python3 - "$jfile" "$rw" <<'PYEOF' 2>/dev/null
import json, sys
f=sys.argv[1]; rw=sys.argv[2]
try: d=json.load(open(f))
except: print("0 "*18); sys.exit()
j=d.get('jobs',[{}])[0]
def g(o,*k,dv=0):
    for x in k:
        if isinstance(o,dict): o=o.get(x,dv)
        else: return dv
    return o if o is not None else dv
def pct(o,sec,p):
    return g(o,sec,'clat_ns','percentile',p)

is_m=rw in('rw','randrw'); is_r=rw in('read','randread')

if is_m:
    bw   = g(j,'read','bw_bytes')+g(j,'write','bw_bytes')
    iops = g(j,'read','iops')+g(j,'write','iops')
    bmin = g(j,'read','bw_min')+g(j,'write','bw_min')
    bmax = g(j,'read','bw_max')+g(j,'write','bw_max')
    bstd = g(j,'read','bw_dev')+g(j,'write','bw_dev')
    lat  = max(g(j,'read','lat_ns','mean'),g(j,'write','lat_ns','mean'))
    lmax = max(g(j,'read','lat_ns','max'), g(j,'write','lat_ns','max'))
    lstd = max(g(j,'read','lat_ns','stddev'),g(j,'write','lat_ns','stddev'))
    p50  = max(pct(j,'read','50.000000'),  pct(j,'write','50.000000'))
    p95  = max(pct(j,'read','95.000000'),  pct(j,'write','95.000000'))
    p99  = max(pct(j,'read','99.000000'),  pct(j,'write','99.000000'))
    p999 = max(pct(j,'read','99.900000'),  pct(j,'write','99.900000'))
    slat = max(g(j,'read','slat_ns','mean'),g(j,'write','slat_ns','mean'))
    clat = max(g(j,'read','clat_ns','mean'),g(j,'write','clat_ns','mean'))
elif is_r:
    sec='read'
    bw=g(j,sec,'bw_bytes'); iops=g(j,sec,'iops')
    bmin=g(j,sec,'bw_min'); bmax=g(j,sec,'bw_max'); bstd=g(j,sec,'bw_dev')
    lat=g(j,sec,'lat_ns','mean'); lmax=g(j,sec,'lat_ns','max')
    lstd=g(j,sec,'lat_ns','stddev')
    p50=pct(j,sec,'50.000000'); p95=pct(j,sec,'95.000000')
    p99=pct(j,sec,'99.000000'); p999=pct(j,sec,'99.900000')
    slat=g(j,sec,'slat_ns','mean'); clat=g(j,sec,'clat_ns','mean')
else:
    sec='write'
    bw=g(j,sec,'bw_bytes'); iops=g(j,sec,'iops')
    bmin=g(j,sec,'bw_min'); bmax=g(j,sec,'bw_max'); bstd=g(j,sec,'bw_dev')
    lat=g(j,sec,'lat_ns','mean'); lmax=g(j,sec,'lat_ns','max')
    lstd=g(j,sec,'lat_ns','stddev')
    p50=pct(j,sec,'50.000000'); p95=pct(j,sec,'95.000000')
    p99=pct(j,sec,'99.000000'); p999=pct(j,sec,'99.900000')
    slat=g(j,sec,'slat_ns','mean'); clat=g(j,sec,'clat_ns','mean')

cu=g(j,'usr_cpu'); cs=g(j,'sys_cpu')
ctx=g(j,'ctx')
util=g(d.get('disk_util',[{}])[0],'util') if d.get('disk_util') else 0

def ms(ns): return round(ns/1e6, 4)
def mbs(b):  return round(b/1048576, 2)
def kmbs(k): return round(k/1024, 2)

print(f"{mbs(bw)} {int(iops)} {kmbs(bmin)} {kmbs(bmax)} {kmbs(bstd)} "
      f"{ms(lat)} {ms(p50)} {ms(p95)} {ms(p99)} {ms(p999)} {ms(lmax)} {ms(lstd)} "
      f"{round(slat/1000,3)} {round(clat/1000,3)} "
      f"{round(cu,2)} {round(cs,2)} {round(util,2)} {int(ctx)}")
PYEOF
}

# ── Run one sweep step ─────────────────────────────────────────────────────────
run_one_step() {
  local jobs=$1
  local total_qd=$(( jobs * IODEPTH ))
  local step_ts; step_ts=$(date +"%Y%m%dT%H%M%S")

  # Unique filename per step — prevents ANY file reuse / cache warm
  local testfile="${TEST_DIR}/testfile_j${jobs}_${step_ts}"
  local jfile="${TEST_DIR}/step_j${jobs}.json"
  local logfile="${TEST_DIR}/step_j${jobs}.log"

  get_tw
  local bar_w=$(( TERM_W - 36 )); [[ $bar_w -lt 15 ]] && bar_w=15

  echo; thick
  printf "  ${BMAG}STEP %d/%d${RST}  jobs=%-3s  qd_total=%-5s  bs=%-6s  rw=%s\n" \
    "$jobs" "$MAX_JOBS" "$jobs" "$total_qd" "$BS" "$RW"
  thick

  # Drop caches BEFORE this step
  drop_caches
  sleep 1   # brief settle time after cache drop

  # Build fio command — no --unlink here (we delete manually after parse)
  fio \
    --name="sweep_j${jobs}" \
    --filename="${testfile}" \
    --rw="${RW}" \
    --bs="${BS}" \
    --size="${FILE_SIZE}" \
    --numjobs="${jobs}" \
    --iodepth="${IODEPTH}" \
    --direct="${DIRECT_IO}" \
    --runtime="${DURATION}" \
    --time_based \
    --group_reporting \
    --ioengine="${IO_ENGINE}" \
    --invalidate=1 \
    --output-format=json \
    --output="${jfile}" \
    2>"${logfile}" &
  local fio_pid=$!

  # Progress dashboard
  local DLINES=7
  for ((i=0;i<DLINES;i++)); do echo; done
  local elapsed=0
  printf "${HIDE}"

  while kill -0 "${fio_pid}" 2>/dev/null; do
    sleep 1; elapsed=$(( elapsed + 1 ))
    local pct=$(( elapsed * 100 / DURATION ))
    [[ $pct -gt 100 ]] && pct=100
    local eta=$(( DURATION - elapsed )); [[ $eta -lt 0 ]] && eta=0
    local sp; sp=$(spin_next)

    printf "\033[%dA" $DLINES
    printf "${EL}${HC}  ${BCYA}%s${RST} [$(draw_bar $elapsed $DURATION $bar_w ${BCYA})] ${BCYA}%3d%%${RST}  ${DIM}%ds / %ds${RST}\n" \
      "$sp" "$pct" "$elapsed" "$DURATION"
    printf "${EL}${HC}\n"
    printf "${EL}${HC}  ${DIM}jobs=%-4s  iodepth/job=%-5s  total_QD=%-6s  file=%s${RST}\n" \
      "$jobs" "$IODEPTH" "$total_qd" "$(basename $testfile)"
    printf "${EL}${HC}  ${DIM}rw=%-12s  bs=%-8s  direct=%s  engine=%s${RST}\n" \
      "$RW" "$BS" "$DIRECT_IO" "$IO_ENGINE"
    printf "${EL}${HC}\n"
    printf "${EL}${HC}  ${DIM}Elapsed: ${BWHT}%ds${RST}  ${DIM}Remaining: ${BWHT}%ds${RST}  ${DIM}File size/job: ${BWHT}%s${RST}\n" \
      "$elapsed" "$eta" "$FILE_SIZE"
    printf "${EL}${HC}  ${DIM}Cache: O_DIRECT=%s + drop_caches before step + unique file${RST}\n" \
      "$DIRECT_IO"
  done

  wait "${fio_pid}" 2>/dev/null || true
  printf "${SHOW}"

  printf "\033[%dA" $DLINES
  printf "${EL}${HC}  ${BGRN}✔${RST} [$(draw_bar 1 1 $bar_w ${BGRN})] ${BGRN}100%% — Done${RST}\n"
  for ((i=1; i<DLINES; i++)); do printf "${EL}${HC}\n"; done

  # Cleanup test file
  rm -f "${testfile}"* 2>/dev/null || true

  # Parse results
  local parsed; parsed=$(parse_json_rich "${jfile}" "${RW}") || parsed=""
  if [[ -z "$parsed" ]]; then
    err "Parse failed for step j=${jobs}. See ${logfile}"
    return
  fi

  local bw iops bmin bmax bstd lat_avg lat_p50 lat_p95 lat_p99 lat_p999 lat_max lat_stdev
  local slat clat cpu_usr cpu_sys io_util ctx_sw
  read -r bw iops bmin bmax bstd lat_avg lat_p50 lat_p95 lat_p99 lat_p999 lat_max lat_stdev \
           slat clat cpu_usr cpu_sys io_util ctx_sw <<< "$parsed"

  # Display step summary
  printf "  ${BGRN}%-22s${RST}${BWHT}%10s MB/s${RST}   ${DIM}min=%-8s max=%s${RST}\n" \
    "Throughput" "${bw}" "${bmin}" "${bmax}"
  printf "  ${BBLU}%-22s${RST}${BWHT}%10s${RST}\n" "IOPS" "${iops}"
  printf "  ${BCYA}%-22s${RST}${BWHT}%10s ms${RST}   ${DIM}p50=%-8s p95=%-8s p99=%-8s p999=%s${RST}\n" \
    "Avg Latency" "${lat_avg}" "${lat_p50}" "${lat_p95}" "${lat_p99}" "${lat_p999}"
  printf "  ${DIM}%-22s%10s ms${RST}   ${DIM}stdev=%s ms${RST}\n" "Max Latency" "${lat_max}" "${lat_stdev}"
  printf "  ${DIM}%-22s  usr=%-6s sys=%-6s util=%-6s ctx=%s${RST}\n" \
    "CPU / IO" "${cpu_usr}%" "${cpu_sys}%" "${io_util}%" "${ctx_sw}"
  echo

  # Build profile string
  local profile="rw=${RW} bs=${BS} iodepth=${IODEPTH} direct=${DIRECT_IO} dur=${DURATION}s"

  # Append to CSV
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$jobs" "$total_qd" \
    "$bw" "$iops" "$bmin" "$bmax" "$bstd" \
    "$lat_avg" "$lat_p50" "$lat_p95" "$lat_p99" "$lat_p999" "$lat_max" "$lat_stdev" \
    "$slat" "$clat" \
    "$cpu_usr" "$cpu_sys" "$io_util" "$ctx_sw" \
    "$profile" "$IO_ENGINE" "$FILE_SIZE" "$step_ts" \
    >> "${CSV_FILE}"
}

# ── Sweep loop ─────────────────────────────────────────────────────────────────
run_sweep() {
  mkdir -p "${TEST_DIR}"

  # Write CSV header
  cat > "${CSV_FILE}" << 'CSVHDR'
jobs,total_qd,bw_mbs,iops,bw_min_mbs,bw_max_mbs,bw_stdev_mbs,lat_avg_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_p999_ms,lat_max_ms,lat_stdev_ms,slat_avg_us,clat_avg_us,cpu_usr_pct,cpu_sys_pct,io_util_pct,ctx_switches,profile,engine,file_size,timestamp
CSVHDR

  local est=$(( MAX_JOBS * (DURATION + 5) ))
  info "Sweep: jobs 1 → ${MAX_JOBS}  |  est. ~$((est/60))m$((est%60))s"
  info "CSV  : ${CSV_FILE}"
  info "Cache: O_DIRECT=${DIRECT_IO}  unique_file=YES  drop_caches=$([[ $EUID -eq 0 ]] && echo YES || echo 'NO (not root)')"
  echo

  for (( j=1; j<=MAX_JOBS; j++ )); do
    run_one_step "$j"
  done
}

# ── Terminal summary ───────────────────────────────────────────────────────────
print_summary() {
  get_tw; echo; thick
  printf "${BCYA}%*s${RST}\n" $(( (TERM_W+14)/2 )) "SWEEP COMPLETE"
  thick; echo

  # Find sweet spot
  local sweet_jobs sweet_iops sweet_lat
  read -r sweet_jobs sweet_iops sweet_lat <<< "$(python3 - "${CSV_FILE}" <<'PYEOF' 2>/dev/null
import csv, sys
rows=[]
with open(sys.argv[1]) as f:
    for r in csv.DictReader(f):
        try: rows.append({'j':int(r['jobs']),'iops':int(r['iops']),'lat':float(r['lat_avg_ms'])})
        except: pass
if not rows: print("0 0 0"); sys.exit()
minlat=min(r['lat'] for r in rows)
best=rows[0]
for r in rows:
    if r['lat']<=minlat*2 and r['iops']>=best['iops']: best=r
print(best['j'],best['iops'],best['lat'])
PYEOF
)"

  printf "  %-12s %-10s %-10s %-10s %-10s %-8s\n" "Jobs" "IOPS" "BW(MB/s)" "AvgLat" "P99Lat" "Status"
  divider

  while IFS=',' read -r j qd bw iops bmin bmax bstd lat_avg lat_p50 lat_p95 lat_p99 lat_p999 lat_max lat_stdev \
                          slat clat cu cs util ctx profile eng fsz ts; do
    [[ "$j" == "jobs" || -z "$j" ]] && continue
    local col status
    if [[ "$j" -eq "${sweet_jobs:-0}" ]]; then col="${BGRN}"; status="★ SWEET"
    elif awk "BEGIN{exit !(${lat_avg}+0 > ${sweet_lat:-99}*2.5)}" 2>/dev/null; then col="${BRED}"; status="SATURATED"
    elif awk "BEGIN{exit !(${lat_avg}+0 > ${sweet_lat:-99}*2.0)}" 2>/dev/null; then col="${BYEL}"; status="HIGH LAT"
    else col="${GRN}"; status="OK"; fi
    printf "  ${col}%-12s${RST} %-10s %-10s %-10s %-10s ${col}%s${RST}\n" \
      "${j} jobs" "$iops" "$bw" "${lat_avg}ms" "${lat_p99}ms" "$status"
  done < "${CSV_FILE}"

  echo; thick
  printf "  ${BGRN}★ Sweet spot: ${BWHT}%s jobs${RST}  |  ${BGRN}IOPS: ${BWHT}%s${RST}  |  ${BGRN}AvgLat: ${BWHT}%s ms${RST}\n" \
    "$sweet_jobs" "$sweet_iops" "$sweet_lat"
  thick; echo
  info "CSV: ${BLD}${CSV_FILE}${RST}"
  info "Open io_compare.html in browser and upload this CSV to generate charts"
  echo
}

# ── Trap ───────────────────────────────────────────────────────────────────────
_trap_exit() {
  printf "${SHOW}"; echo; warn "Interrupted."
  [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]] && \
    rm -f "${TEST_DIR}"/testfile_* 2>/dev/null || true
  exit 1
}
trap _trap_exit INT TERM

# ── Main ───────────────────────────────────────────────────────────────────────
check_prerequisites() {
  step "Checking prerequisites"
  echo
  local all_ok=true

  # ── fio (required) ──────────────────────────────────────────────────────────
  if command -v fio &>/dev/null; then
    local fver; fver=$(fio --version 2>/dev/null | head -1 || echo "unknown")
    ok "fio         : ${BLD}${fver}${RST}"
  else
    err "fio         : NOT FOUND  (required)"
    err "  Install   : yum install fio  |  apt install fio  |  brew install fio"
    all_ok=false
  fi

  # ── python3 (required) ──────────────────────────────────────────────────────
  if command -v python3 &>/dev/null; then
    local pyver; pyver=$(python3 --version 2>&1 | head -1 || echo "unknown")
    ok "python3     : ${BLD}${pyver}${RST}"
  else
    err "python3     : NOT FOUND  (required for JSON parsing)"
    err "  Install   : yum install python3  |  apt install python3"
    all_ok=false
  fi

  # ── libaio (optional but recommended) ───────────────────────────────────────
  if python3 -c "import ctypes; ctypes.CDLL('libaio.so.1')" 2>/dev/null ||      ldconfig -p 2>/dev/null | grep -q libaio ||      [[ -f /lib/libaio.so.1 ]] || [[ -f /lib64/libaio.so.1 ]] ||      [[ -f /usr/lib/libaio.so.1 ]] || [[ -f /usr/lib64/libaio.so.1 ]]; then
    ok "libaio      : ${BLD}found${RST}  (async IO engine — best performance)"
  else
    warn "libaio      : not found  (will use psync fallback — lower performance)"
    warn "  Install   : yum install libaio libaio-devel  |  apt install libaio1 libaio-dev"
  fi

  # ── sysstat (optional) ──────────────────────────────────────────────────────
  if command -v iostat &>/dev/null; then
    local ssver; ssver=$(iostat -V 2>&1 | head -1 || echo "unknown")
    ok "sysstat     : ${BLD}${ssver}${RST}  (iostat available)"
  else
    warn "sysstat     : not found  (optional — fio reports util% natively)"
    warn "  Install   : yum install sysstat  |  apt install sysstat"
  fi

  # ── tput (optional) ─────────────────────────────────────────────────────────
  if command -v tput &>/dev/null; then
    ok "tput        : ${BLD}found${RST}  (terminal width detection)"
  else
    warn "tput        : not found  (terminal width defaults to 80)"
  fi

  # ── Root check ───────────────────────────────────────────────────────────────
  echo
  if [[ $EUID -eq 0 ]]; then
    ok "Privilege   : ${BLD}root${RST}  (drop_caches enabled — fully cache-free results)"
  else
    warn "Privilege   : non-root  (drop_caches DISABLED — cache may affect read results)"
    warn "  Recommend : sudo ./io_sweep.sh"
  fi

  # ── OS / kernel ──────────────────────────────────────────────────────────────
  echo
  if [[ -f /proc/version ]]; then
    local kver; kver=$(uname -r 2>/dev/null || echo "unknown")
    info "Kernel      : ${kver}"
  fi
  if [[ -f /etc/os-release ]]; then
    local osname; osname=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
    info "OS          : ${osname}"
  fi
  info "Architecture: $(uname -m 2>/dev/null || echo unknown)"

  echo
  if ! $all_ok; then
    err "Missing required packages. Please install them and re-run."
    echo
    thick
    echo -e "  ${BLD}Quick install:${RST}"
    echo -e "  ${GRN}RHEL/Rocky/AlmaLinux:${RST}  yum install -y fio python3 libaio libaio-devel sysstat"
    echo -e "  ${GRN}Ubuntu/Debian:${RST}         apt install -y fio python3 libaio1 libaio-dev sysstat"
    echo -e "  ${GRN}SUSE/openSUSE:${RST}         zypper install -y fio python3 libaio sysstat"
    echo -e "  ${GRN}macOS:${RST}                 brew install fio python3"
    thick; echo
    exit 1
  fi
  ok "All required packages OK"
  pause
}

main() {
  banner; check_prerequisites; detect_ioengine; run_menu
  echo; info "Started at $(date)"; echo
  run_sweep
  print_summary
  echo -e "  ${BGRN}${BLD}Done.${RST}  CSV: ${CSV_FILE}"; echo
}

main "$@"
