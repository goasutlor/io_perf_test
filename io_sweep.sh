#!/usr/bin/env bash
# ==============================================================================
#  io_sweep.sh v3.0 — IO Performance Sweep  |  Standard + Spark IO Profiles
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
#
#  libaio        Async IO engine for fio  yum install libaio libaio-devel
#  (optional)    Best perf. Auto-fallback apt install libaio1 libaio-dev
#                to psync if unavailable. modprobe libaio  (load kernel module)
#
#  sysstat       iostat for disk util%    yum install sysstat
#  (optional)    fio reports util natively apt install sysstat
#
#  tput          Terminal width detect    pre-installed (ncurses)
#
#  QUICK INSTALL:
#  ─────────────────────────────────────────────────────────────────────────────
#  RHEL/CentOS/Rocky/AlmaLinux:
#    yum install -y fio python3 libaio libaio-devel sysstat
#
#  Ubuntu/Debian:
#    apt install -y fio python3 libaio1 libaio-dev sysstat
#
#  SUSE/openSUSE:
#    zypper install -y fio python3 libaio sysstat
#
#  macOS (Homebrew — psync engine, no libaio):
#    brew install fio python3
#
#  USAGE:
#  ─────────────────────────────────────────────────────────────────────────────
#    chmod +x io_sweep.sh
#    sudo ./io_sweep.sh          # recommended: root enables drop_caches
#    ./io_sweep.sh               # non-root: no cache drop between steps
#
#  MODES:
#    1. Standard Sweep  — classic Jobs 1→N sweep, single workload profile
#    2. Spark Profiles  — simulate Apache Spark IO operations:
#         • Read      : large sequential reads  (Parquet/ORC scan)
#         • Write     : large sequential writes (task output)
#         • Shuffle   : random read+write mix   (sort/join/groupBy)
#         • HEAD      : tiny random reads       (metadata/schema lookup)
#         • MOVE      : mixed rw 70/30          (task commit/rename)
#         • Full Suite: all 5 profiles in sequence
#
#  ANTI-CACHE GUARANTEES (per step):
#    1. Unique filename per step  → no file reuse across steps
#    2. --direct=1 (O_DIRECT)    → bypasses OS page cache
#    3. --invalidate=1           → fio flushes internal buffer
#    4. drop_caches (root only)  → echo 3 > /proc/sys/vm/drop_caches
#    5. 1s settle after drop     → allows cache pressure to clear
#    6. Auto file cleanup        → test files removed after each step
#
#  OUTPUT:
#    sweep_results.csv  (standard) or  spark_results.csv  (spark mode)
#    → Upload to io_compare.html for charts and analysis
#
#  AUTHOR / CREDIT — idea & context: Sontas Jiamsripong
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
BRED='\033[1;31m'; BGRN='\033[1;32m'; BYEL='\033[1;33m'
BCYA='\033[1;36m'; BBLU='\033[1;34m'; BMAG='\033[1;35m'; BWHT='\033[1;37m'
BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
EL='\033[2K'; HC='\033[1G'; HIDE='\033[?25l'; SHOW='\033[?25h'

VERSION="4.0"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TERM_W=80

# Globals
TEST_PATH=""
TEST_DIR=""
CSV_FILE=""
MODE_TYPE=""     # "standard" or "spark"
RW="randwrite"
BS="4k"
MAX_JOBS=8
IODEPTH=32
DURATION=30
FILE_SIZE="1g"
DIRECT_IO=1
IO_ENGINE="libaio"

# ==============================================================================
# IO Profile Definitions
# Format: NAME|RW|BS|IODEPTH|RWMIX|GROUP|COLOR_CODE|DESCRIPTION
# RWMIX: rwmixread value for randrw (empty = not used)
# GROUP: spark | database | vm | streaming | backup | container
# COLOR_CODE: terminal color escape (without [)
# ==============================================================================

# ── Spark profiles ─────────────────────────────────────────────────────────────
declare -a PROFILES_SPARK=(
  "spark_read|read|128k|16||spark|1;34|Sequential Read — Parquet/ORC scan"
  "spark_write|write|128k|16||spark|1;32|Sequential Write — task partition output"
  "spark_shuffle|randrw|32k|32|50|spark|1;33|Shuffle — Sort/Join/GroupBy (50R/50W)"
  "spark_head|randread|4k|64||spark|1;35|HEAD/Metadata — schema lookup, file exist"
  "spark_move|randrw|128k|8|70|spark|1;36|MOVE/Commit — task commit rename (70R/30W)"
)

# ── Database profiles ──────────────────────────────────────────────────────────
declare -a PROFILES_DB=(
  "db_oltp|randrw|8k|32|70|database|0;32|OLTP Random — MySQL/PostgreSQL (70R/30W)"
  "db_olap|read|512k|8||database|0;32|OLAP Scan — Analytics full table sequential read"
  "db_wal|write|4k|1||database|0;32|WAL/Redo Log — Sync write qd=1 (fsync per op)"
  "db_index|randread|4k|64||database|0;32|Index Lookup — B-tree random read high IOPS"
)

# ── VM / Virtualization profiles ───────────────────────────────────────────────
declare -a PROFILES_VM=(
  "vm_guest|randrw|16k|32|60|vm|0;33|VM Disk — General guest OS IO (60R/40W)"
  "vm_clone|read|256k|16||vm|0;33|VM Clone/Snapshot — live migration read"
  "vm_vdi|randread|8k|128||vm|0;33|VDI Boot Storm — many VMs booting (high concurrency)"
)

# ── Streaming / Media profiles ─────────────────────────────────────────────────
declare -a PROFILES_STREAM=(
  "stream_ingest|write|1m|4||streaming|0;36|Video Ingest — camera/encoder large write"
  "stream_play|read|512k|8||streaming|0;36|Video Playback — multi-stream sequential read"
  "stream_log|write|64k|8||streaming|0;36|Log Streaming — Kafka/Fluentd append write"
)

# ── Backup / Archive profiles ──────────────────────────────────────────────────
declare -a PROFILES_BACKUP=(
  "bkp_read|read|512k|4||backup|0;31|Backup Read — full backup source max throughput"
  "bkp_write|write|512k|4||backup|0;31|Restore Write — restore target max throughput"
  "bkp_dedup|randrw|8k|16|50|backup|0;31|Dedup/Compress — read-compare-write mixed IO"
)

# ── Container / K8s profiles ──────────────────────────────────────────────────
declare -a PROFILES_CONTAINER=(
  "k8s_pull|read|128k|32||container|1;35|Container Image Pull — layer extract parallel read"
  "k8s_pvc|randrw|64k|16|50|container|1;35|PVC Mixed — StatefulSet DB/queue (50R/50W)"
  "k8s_etcd|write|4k|1||container|1;35|etcd WAL — fsync write qd=1 latency critical"
)

# Placeholder for Full Universal menu (array name must exist for nameref)
declare -a PROFILES_ALL_DUMMY=()

# ── Helpers ───────────────────────────────────────────────────────────────────
get_tw()  { TERM_W=$(tput cols 2>/dev/null || echo 80); }
banner() {
  get_tw; clear 2>/dev/null || true; echo -e "${BCYA}"
  local w=$TERM_W
  printf "╔%s╗\n" "$(printf '═%.0s' $(seq 1 $((w-2))))"
  local t="  IO PERFORMANCE SWEEP  v${VERSION}  |  Universal IO Testing Tool  "
  printf "║%*s%s%*s║\n" $(( (w-2-${#t})/2 )) "" "$t" $(( (w-1-${#t})/2 )) ""
  local s="  Standard | Database | VM | Streaming | Backup | Container | Spark  "
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
      info "Page cache dropped" || \
      warn "Could not drop caches (non-critical)"
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
    warn "Install: yum install libaio libaio-devel  |  apt install libaio1 libaio-dev"
  fi
}

# ── Prerequisites check ────────────────────────────────────────────────────────
check_prerequisites() {
  step "Checking prerequisites"; echo
  local all_ok=true

  if command -v fio &>/dev/null; then
    local fver; fver=$(fio --version 2>/dev/null | head -1 || echo "unknown")
    ok "fio         : ${BLD}${fver}${RST}"
  else
    err "fio         : NOT FOUND  (required)"
    err "  Install   : yum install fio  |  apt install fio  |  brew install fio"
    all_ok=false
  fi

  if command -v python3 &>/dev/null; then
    local pyver; pyver=$(python3 --version 2>&1 | head -1 || echo "unknown")
    ok "python3     : ${BLD}${pyver}${RST}"
  else
    err "python3     : NOT FOUND  (required)"
    err "  Install   : yum install python3  |  apt install python3"
    all_ok=false
  fi

  if ldconfig -p 2>/dev/null | grep -q libaio || \
     [[ -f /lib/libaio.so.1 ]] || [[ -f /lib64/libaio.so.1 ]] || \
     [[ -f /usr/lib/libaio.so.1 ]] || [[ -f /usr/lib64/libaio.so.1 ]]; then
    ok "libaio      : ${BLD}found${RST}  (async IO — best performance)"
  else
    warn "libaio      : not found  (psync fallback — lower performance)"
    warn "  Install   : yum install libaio libaio-devel  |  apt install libaio1 libaio-dev"
  fi

  if command -v iostat &>/dev/null; then
    ok "sysstat     : ${BLD}found${RST}  (iostat available)"
  else
    warn "sysstat     : not found  (optional)"
    warn "  Install   : yum install sysstat  |  apt install sysstat"
  fi

  command -v tput &>/dev/null && ok "tput        : found" || warn "tput        : not found (terminal width defaults to 80)"

  echo
  if [[ $EUID -eq 0 ]]; then
    ok "Privilege   : ${BLD}root${RST}  (drop_caches enabled)"
  else
    warn "Privilege   : non-root  (drop_caches DISABLED)"
    warn "  Recommend : sudo ./io_sweep.sh"
  fi

  if [[ -f /etc/os-release ]]; then
    local os; os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
    info "OS          : ${os}"
  fi
  info "Kernel      : $(uname -r 2>/dev/null || echo unknown)"
  info "Architecture: $(uname -m 2>/dev/null || echo unknown)"

  echo
  if ! $all_ok; then
    err "Missing required packages. Please install and re-run."
    echo; thick
    echo -e "  ${BLD}Quick install:${RST}"
    echo -e "  ${GRN}RHEL/Rocky/AlmaLinux:${RST}  yum install -y fio python3 libaio libaio-devel sysstat"
    echo -e "  ${GRN}Ubuntu/Debian:${RST}         apt install -y fio python3 libaio1 libaio-dev sysstat"
    echo -e "  ${GRN}SUSE/openSUSE:${RST}         zypper install -y fio python3 libaio sysstat"
    echo -e "  ${GRN}macOS:${RST}                 brew install fio python3"
    thick; echo; exit 1
  fi
  ok "All required packages OK"
  pause
}

# ── Mode selection ─────────────────────────────────────────────────────────────
select_mode() {
  banner; step "Select Test Mode"; echo
  echo -e "   ${BLD}1) Standard Sweep${RST}"
  echo -e "      Custom workload, single profile, jobs 1→N."
  echo -e "      ${DIM}Best for: baseline, capacity planning, hardware comparison.${RST}"
  echo
  echo -e "   ${BLD}2) Database Profiles${RST}  ${DIM}(OLTP, OLAP, WAL, Index Lookup)${RST}"
  echo -e "      ${DIM}Best for: MySQL, PostgreSQL, Oracle, SQL Server storage validation.${RST}"
  echo
  echo -e "   ${BLD}3) VM / Virtualization Profiles${RST}  ${DIM}(Guest, Clone, VDI Boot Storm)${RST}"
  echo -e "      ${DIM}Best for: VMware vSAN, Nutanix, OpenStack Cinder, Proxmox.${RST}"
  echo
  echo -e "   ${BLD}4) Streaming / Media Profiles${RST}  ${DIM}(Video Ingest, Playback, Log Stream)${RST}"
  echo -e "      ${DIM}Best for: media servers, Kafka, Fluentd, camera ingest.${RST}"
  echo
  echo -e "   ${BLD}5) Backup / Archive Profiles${RST}  ${DIM}(Backup Read, Restore Write, Dedup)${RST}"
  echo -e "      ${DIM}Best for: Veeam, Commvault, NetBackup, dedup storage validation.${RST}"
  echo
  echo -e "   ${BLD}6) Container / K8s Profiles${RST}  ${DIM}(Image Pull, PVC, etcd WAL)${RST}"
  echo -e "      ${DIM}Best for: Kubernetes PV/PVC, etcd, container registry storage.${RST}"
  echo
  echo -e "   ${BLD}7) Spark IO Profiles${RST}  ${DIM}(Read, Write, Shuffle, HEAD, MOVE)${RST}"
  echo -e "      ${DIM}Best for: Apache Spark, Hadoop, data lake storage validation.${RST}"
  echo
  echo -e "   ${BLD}8) Full Universal Suite${RST}  ${DIM}(all profiles from all groups)${RST}"
  echo -e "      ${DIM}Best for: comprehensive storage acceptance testing.${RST}"
  echo
  local c; read -rp "  Select mode [1-8, default=1]: " c || c="1"
  case "${c:-1}" in
    2) MODE_TYPE="database"  ;;
    3) MODE_TYPE="vm"        ;;
    4) MODE_TYPE="streaming" ;;
    5) MODE_TYPE="backup"    ;;
    6) MODE_TYPE="container" ;;
    7) MODE_TYPE="spark"     ;;
    8) MODE_TYPE="full"      ;;
    *) MODE_TYPE="standard"  ;;
  esac
  ok "Mode: ${BLD}${MODE_TYPE}${RST}"
}

# ── Common path/config menu ────────────────────────────────────────────────────
select_path() {
  echo
  echo -e "  ${BLD}Test path${RST} (mount point or directory to test)"
  echo -e "  e.g. ${GRN}/mnt/iscsi01${RST}  ${GRN}/mnt/nfs01${RST}  ${GRN}/data${RST}  ${GRN}/app/testperf${RST}"
  echo
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
}

select_jobs_duration() {
  echo
  read -rp "  Max jobs to sweep to [default=8]: " mj || mj="8"
  MAX_JOBS="${mj:-8}"

  echo
  read -rp "  iodepth per job [default=32]: " qd || qd="32"
  IODEPTH="${qd:-32}"

  echo
  echo -e "  ${BLD}Duration${RST} per step: 1)10s  2)30s  3)60s  4)120s"
  local dur; read -rp "  Select [default=2]: " dur || dur="2"
  case "${dur:-2}" in
    1)DURATION=10;;2)DURATION=30;;3)DURATION=60;;4)DURATION=120;;*) DURATION=30;;
  esac

  echo
  echo -e "  ${BLD}File size${RST} per job  (use > RAM to guarantee no cache inflation)"
  echo "   1)256m  2)1g  3)4g ← recommended for iSCSI/NFS  4)10g  5)Custom"
  local sz; read -rp "  Select [default=2]: " sz || sz="2"
  case "${sz:-2}" in
    1)FILE_SIZE="256m";;2)FILE_SIZE="1g";;3)FILE_SIZE="4g";;4)FILE_SIZE="10g";;
    5)read -rp "  Size: " FILE_SIZE||FILE_SIZE="1g";;*) FILE_SIZE="1g";;
  esac

  echo
  echo -e "  ${BLD}Direct IO${RST} (O_DIRECT) — bypasses OS page cache"
  echo -e "  ${DIM}Always recommended. Disable ONLY if filesystem doesn't support O_DIRECT${RST}"
  local di; read -rp "  Enable? [Y/n]: " di || di="Y"
  [[ "${di:-Y}" =~ ^[Nn]$ ]] && DIRECT_IO=0 || DIRECT_IO=1
}

# ── Standard sweep menu ────────────────────────────────────────────────────────
menu_standard() {
  banner; step "Standard Sweep Configuration"; echo

  select_path

  echo
  echo -e "  ${BLD}Workload type${RST}  ${DIM}(fio rw= pattern — Standard Sweep only)${RST}"
  echo -e "  ${DIM}Other modes (2–8) pick ready-made profiles: Database, VM, Streaming, Backup, K8s, Spark, or full suite — not this list.${RST}"
  echo
  echo "   1) randwrite   Random write ← recommended (DB/VM worst case)"
  echo "   2) randread    Random read  (DB query pattern)"
  echo "   3) read        Sequential read  (throughput test)"
  echo "   4) write       Sequential write (throughput test)"
  echo "   5) randrw      Mixed 70R/30W (OLTP simulation)"
  local wl; read -rp "  Select fio rw [default=1]: " wl || wl="1"
  case "${wl:-1}" in
    1)RW="randwrite";;2)RW="randread";;3)RW="read";;
    4)RW="write";;5)RW="randrw";;*) RW="randwrite";;
  esac

  echo
  echo -e "  ${BLD}Block size${RST}"
  echo "   1)4k  2)8k  3)16k  4)32k  5)64k  6)128k  7)512k  8)1m  9)Custom"
  local bs; read -rp "  Select [default=1]: " bs || bs="1"
  case "${bs:-1}" in
    1)BS="4k";;2)BS="8k";;3)BS="16k";;4)BS="32k";;
    5)BS="64k";;6)BS="128k";;7)BS="512k";;8)BS="1m";;
    9)read -rp "  Enter: " BS||BS="4k";;*) BS="4k";;
  esac

  select_jobs_duration

  TEST_DIR="${TEST_PATH}/io_sweep_${TIMESTAMP}"
  CSV_FILE="${TEST_DIR}/sweep_results.csv"

  echo; thick; echo
  info "Mode         : ${BLD}Standard Sweep${RST}"
  info "Test Path    : ${BLD}${TEST_DIR}${RST}"
  info "Workload     : ${BLD}${RW}${RST}   bs=${BLD}${BS}${RST}"
  info "Sweep        : ${BLD}1 → ${MAX_JOBS} jobs${RST}"
  info "iodepth/job  : ${BLD}${IODEPTH}${RST}"
  info "Duration/step: ${BLD}${DURATION}s${RST}"
  info "File size    : ${BLD}${FILE_SIZE}${RST} per job"
  info "Direct IO    : ${BLD}${DIRECT_IO}${RST}  (O_DIRECT)"
  info "IO Engine    : ${BLD}${IO_ENGINE}${RST}"
  info "CSV output   : ${BLD}${CSV_FILE}${RST}"
  echo
  [[ $EUID -eq 0 ]] && ok "Root — drop_caches enabled" || warn "Not root — drop_caches disabled"
  echo; thick; echo
  local c; read -rp "  Start sweep? [Y/n]: " c || c="Y"
  [[ "${c:-Y}" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }
}

# ── Generic profile group menu ────────────────────────────────────────────────
# Usage: menu_profile_group <GroupLabel> <profiles_array_name> <csv_prefix>
menu_profile_group() {
  local group_label="$1"
  local arr_name="$2"
  local csv_prefix="$3"
  local -n prof_arr="$arr_name"

  banner; step "${group_label} Configuration"; echo
  select_path; echo

  local count="${#prof_arr[@]}"
  local full_num=$(( count + 1 ))

  echo -e "  ${BLD}Select profile to run${RST}"
  echo
  printf "   %-4s  %-20s  %-10s  %-8s  %-8s  %s\n" "#" "Name" "Pattern" "BS" "iodepth" "Description"
  divider
  local i=1
  for prof in "${prof_arr[@]}"; do
    IFS='|' read -r pname prw pbs pqd pmix pgrp pcol pdesc <<< "$prof"
    printf "   ${BLD}%d)${RST}  \033[${pcol}m%-20s\033[0m  %-10s  %-8s  %-8s  %s\n"       "$i" "$pname" "$prw" "$pbs" "$pqd" "$pdesc"
    i=$(( i + 1 ))
  done
  echo
  printf "   ${BLD}%d)${RST}  %-20s  %s\n" "$full_num" "Full Suite" "Run ALL ${count} profiles in sequence"
  echo

  local pc; read -rp "  Select [1-${full_num}, default=${full_num}]: " pc || pc="$full_num"
  PROFILE_SEL="${pc:-$full_num}"

  # Single profile override
  if [[ "$PROFILE_SEL" -ge 1 ]] && [[ "$PROFILE_SEL" -le "$count" ]]; then
    local idx=$(( PROFILE_SEL - 1 ))
    IFS='|' read -r pname prw pbs pqd pmix pgrp pcol pdesc <<< "${prof_arr[$idx]}"
    echo
    info "Default for ${BLD}${pname}${RST}: bs=${BLD}${pbs}${RST}  iodepth=${BLD}${pqd}${RST}${pmix:+  rwmix_read=${pmix}%}"
    local obss; read -rp "  Override block size? [Enter to keep ${pbs}]: " obss || obss=""
    [[ -n "$obss" ]] && PROFILE_BS_OVERRIDE="$obss" || PROFILE_BS_OVERRIDE=""
    local oqd;  read -rp "  Override iodepth?   [Enter to keep ${pqd}]:  " oqd  || oqd=""
    [[ -n "$oqd"  ]] && PROFILE_QD_OVERRIDE="$oqd"  || PROFILE_QD_OVERRIDE=""
  else
    PROFILE_BS_OVERRIDE=""
    PROFILE_QD_OVERRIDE=""
  fi

  select_jobs_duration

  TEST_DIR="${TEST_PATH}/${csv_prefix}_sweep_${TIMESTAMP}"
  CSV_FILE="${TEST_DIR}/${csv_prefix}_results.csv"

  echo; thick; echo
  info "Mode         : ${BLD}${group_label}${RST}"
  info "Test Path    : ${BLD}${TEST_DIR}${RST}"
  info "Sweep        : ${BLD}1 → ${MAX_JOBS} jobs${RST} per profile"
  info "Duration/step: ${BLD}${DURATION}s${RST}"
  info "File size    : ${BLD}${FILE_SIZE}${RST} per job"
  info "Direct IO    : ${BLD}${DIRECT_IO}${RST}"
  info "IO Engine    : ${BLD}${IO_ENGINE}${RST}"
  info "CSV output   : ${BLD}${CSV_FILE}${RST}"
  echo
  [[ $EUID -eq 0 ]] && ok "Root — drop_caches enabled" || warn "Not root — drop_caches disabled"
  echo; thick; echo
  local c; read -rp "  Start? [Y/n]: " c || c="Y"
  [[ "${c:-Y}" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }
}

# ── Generic profile sweep runner ──────────────────────────────────────────────
# Optional $2: if "1", skip write_csv_header (append to existing CSV — used by run_full_suite)
run_profile_group_sweep() {
  local arr_name="$1"
  local skip_header="${2:-0}"
  local -n rprof_arr="$arr_name"
  local count="${#rprof_arr[@]}"
  local full_num=$(( count + 1 ))

  mkdir -p "${TEST_DIR}"
  if [[ "$skip_header" != "1" ]]; then
    write_csv_header
  fi

  # Build list of profiles to execute
  local -a to_run=()
  if [[ "$PROFILE_SEL" -ge "$full_num" ]] || [[ "$PROFILE_SEL" -eq "$full_num" ]]; then
    to_run=("${rprof_arr[@]}")
  elif [[ "$PROFILE_SEL" -ge 1 ]] && [[ "$PROFILE_SEL" -le "$count" ]]; then
    to_run=("${rprof_arr[$((PROFILE_SEL-1))]}")
  else
    to_run=("${rprof_arr[@]}")
  fi

  local total_steps=$(( ${#to_run[@]} * MAX_JOBS ))
  local est=$(( total_steps * (DURATION + 5) ))
  info "Profiles: ${#to_run[@]}  ×  jobs 1→${MAX_JOBS} = ${total_steps} steps  |  est ~$((est/60))m$((est%60))s"
  info "CSV: ${CSV_FILE}"; echo

  for prof in "${to_run[@]}"; do
    IFS='|' read -r pname prw pbs pqd pmix pgrp pcol pdesc <<< "$prof"

    # Apply overrides if single-profile run
    local use_bs="$pbs" use_qd="$pqd"
    [[ "${#to_run[@]}" -eq 1 && -n "${PROFILE_BS_OVERRIDE:-}" ]] && use_bs="$PROFILE_BS_OVERRIDE"
    [[ "${#to_run[@]}" -eq 1 && -n "${PROFILE_QD_OVERRIDE:-}" ]] && use_qd="$PROFILE_QD_OVERRIDE"

    echo; thick
    printf "  \033[${pcol}m★ [%-10s] %-20s${RST}  %s\n" "${pgrp^^}" "$pname" "$pdesc"
    info "rw=${prw}  bs=${use_bs}  iodepth=${use_qd}${pmix:+  rwmixread=${pmix}%}  jobs 1→${MAX_JOBS}"
    thick; echo

    for (( j=1; j<=MAX_JOBS; j++ )); do
      run_one_step "$j" "$prw" "$use_bs" "$use_qd" "$pname" "$pgrp" "$pmix"
    done
  done
}

# ── fio JSON parser ────────────────────────────────────────────────────────────
parse_json_rich() {
  local jfile="$1" rw="$2"
  [[ ! -s "$jfile" ]] && { printf '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0'; return; }
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
def pct(o,sec,p): return g(o,sec,'clat_ns','percentile',p)
is_m=rw in('rw','randrw'); is_r=rw in('read','randread')
if is_m:
    bw=g(j,'read','bw_bytes')+g(j,'write','bw_bytes')
    iops=g(j,'read','iops')+g(j,'write','iops')
    bmin=g(j,'read','bw_min')+g(j,'write','bw_min')
    bmax=g(j,'read','bw_max')+g(j,'write','bw_max')
    bstd=g(j,'read','bw_dev')+g(j,'write','bw_dev')
    lat=max(g(j,'read','lat_ns','mean'),g(j,'write','lat_ns','mean'))
    lmax=max(g(j,'read','lat_ns','max'),g(j,'write','lat_ns','max'))
    lstd=max(g(j,'read','lat_ns','stddev'),g(j,'write','lat_ns','stddev'))
    p50=max(pct(j,'read','50.000000'),pct(j,'write','50.000000'))
    p95=max(pct(j,'read','95.000000'),pct(j,'write','95.000000'))
    p99=max(pct(j,'read','99.000000'),pct(j,'write','99.000000'))
    p999=max(pct(j,'read','99.900000'),pct(j,'write','99.900000'))
    slat=max(g(j,'read','slat_ns','mean'),g(j,'write','slat_ns','mean'))
    clat=max(g(j,'read','clat_ns','mean'),g(j,'write','clat_ns','mean'))
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
cu=g(j,'usr_cpu'); cs=g(j,'sys_cpu'); ctx=g(j,'ctx')
util=g(d.get('disk_util',[{}])[0],'util') if d.get('disk_util') else 0
def ms(ns): return round(ns/1e6,4)
def mbs(b):  return round(b/1048576,2)
def kmbs(k): return round(k/1024,2)
print(f"{mbs(bw)} {int(iops)} {kmbs(bmin)} {kmbs(bmax)} {kmbs(bstd)} "
      f"{ms(lat)} {ms(p50)} {ms(p95)} {ms(p99)} {ms(p999)} {ms(lmax)} {ms(lstd)} "
      f"{round(slat/1000,3)} {round(clat/1000,3)} "
      f"{round(cu,2)} {round(cs,2)} {round(util,2)} {int(ctx)}")
PYEOF
}

# ── Single fio step ────────────────────────────────────────────────────────────
run_one_step() {
  local jobs=$1 step_rw=$2 step_bs=$3 step_qd=$4 step_label=$5 step_group="${6:-}"
  local step_rwmix="${7:-}"
  local total_qd=$(( jobs * step_qd ))
  local step_ts; step_ts=$(date +"%Y%m%dT%H%M%S")
  local safe_label; safe_label=$(echo "$step_label" | tr ' /()' '_')
  local testfile="${TEST_DIR}/testfile_${safe_label}_j${jobs}_${step_ts}"
  local jfile="${TEST_DIR}/${safe_label}_j${jobs}.json"
  local logfile="${TEST_DIR}/${safe_label}_j${jobs}.log"

  get_tw
  local bar_w=$(( TERM_W - 36 )); [[ $bar_w -lt 15 ]] && bar_w=15
  local bar_col="${BCYA}"
  case "${step_group}" in
    spark)     bar_col="${BBLU}"  ;;
    database)  bar_col="${BGRN}"  ;;
    vm)        bar_col="${BYEL}"  ;;
    streaming) bar_col="${BCYA}"  ;;
    backup)    bar_col="${BRED}"  ;;
    container) bar_col="${BMAG}"  ;;
  esac

  echo; thick
  if [[ -n "$step_group" ]]; then
    printf "  ${bar_col}[%-10s]${RST}  ${BLD}%s${RST}  jobs=%-3s  qd_total=%-5s  bs=%-8s  rw=%s\n" \
      "${step_group^^}" "$step_label" "$jobs" "$total_qd" "$step_bs" "$step_rw"
  else
    printf "  ${BMAG}STEP %d/%d${RST}  jobs=%-3s  qd_total=%-5s  bs=%-6s  rw=%s\n" \
      "$jobs" "$MAX_JOBS" "$jobs" "$total_qd" "$step_bs" "$step_rw"
  fi
  thick

  # Add rwmixread for mixed profiles
  local extra_args=""
  if [[ "$step_rw" == "randrw" ]]; then
    local mix="${step_rwmix:-70}"
    extra_args="--rwmixread=${mix}"
  fi

  drop_caches
  sleep 1

  fio \
    --name="${safe_label}_j${jobs}" \
    --filename="${testfile}" \
    --rw="${step_rw}" \
    --bs="${step_bs}" \
    --size="${FILE_SIZE}" \
    --numjobs="${jobs}" \
    --iodepth="${step_qd}" \
    --direct="${DIRECT_IO}" \
    --runtime="${DURATION}" \
    --time_based \
    --group_reporting \
    --ioengine="${IO_ENGINE}" \
    --invalidate=1 \
    --output-format=json \
    --output="${jfile}" \
    ${extra_args} \
    2>"${logfile}" &
  local fio_pid=$!

  # Progress bar
  local DLINES=6; for ((i=0;i<DLINES;i++)); do echo; done
  local elapsed=0
  printf "${HIDE}"
  while kill -0 "${fio_pid}" 2>/dev/null; do
    sleep 1; elapsed=$(( elapsed + 1 ))
    local pct=$(( elapsed * 100 / DURATION ))
    [[ $pct -gt 100 ]] && pct=100
    local eta=$(( DURATION - elapsed )); [[ $eta -lt 0 ]] && eta=0
    local sp; sp=$(spin_next)
    printf "\033[%dA" $DLINES
    printf "${EL}${HC}  ${bar_col}%s${RST} [$(draw_bar $elapsed $DURATION $bar_w ${bar_col})] ${bar_col}%3d%%${RST}  ${DIM}%ds/%ds${RST}\n" \
      "$sp" "$pct" "$elapsed" "$DURATION"
    printf "${EL}${HC}  ${DIM}jobs=%-4s  iodepth/job=%-5s  total_QD=%-5s  bs=%-8s  rw=%s${RST}\n" \
      "$jobs" "$step_qd" "$total_qd" "$step_bs" "$step_rw"
    printf "${EL}${HC}  ${DIM}file: %s${RST}\n" "$(basename $testfile)"
    printf "${EL}${HC}  ${DIM}Elapsed: ${BWHT}%ds${RST}  ${DIM}Remaining: ${BWHT}%ds${RST}  ${DIM}size/job: ${BWHT}%s${RST}\n" \
      "$elapsed" "$eta" "$FILE_SIZE"
    printf "${EL}${HC}  ${DIM}Cache guard: O_DIRECT=%s  unique_file=YES  drop_caches=$([[ $EUID -eq 0 ]] && echo YES || echo NO)${RST}\n" \
      "$DIRECT_IO"
    printf "${EL}${HC}\n"
  done
  wait "${fio_pid}" 2>/dev/null || true
  printf "${SHOW}"

  printf "\033[%dA" $DLINES
  printf "${EL}${HC}  ${BGRN}✔${RST} [$(draw_bar 1 1 $bar_w ${BGRN})] ${BGRN}100%% — Done${RST}\n"
  for ((i=1; i<DLINES; i++)); do printf "${EL}${HC}\n"; done

  rm -f "${testfile}"* 2>/dev/null || true

  local parsed; parsed=$(parse_json_rich "${jfile}" "${step_rw}") || parsed=""
  if [[ -z "$parsed" ]]; then
    err "Parse failed. See: ${logfile}"; return
  fi

  local bw iops bmin bmax bstd lat_avg lat_p50 lat_p95 lat_p99 lat_p999 lat_max lat_stdev
  local slat clat cpu_usr cpu_sys io_util ctx_sw
  read -r bw iops bmin bmax bstd lat_avg lat_p50 lat_p95 lat_p99 lat_p999 lat_max lat_stdev \
           slat clat cpu_usr cpu_sys io_util ctx_sw <<< "$parsed"

  printf "  ${BGRN}%-22s${RST}${BWHT}%10s MB/s${RST}   ${DIM}min=%-8s max=%s${RST}\n" \
    "Throughput" "${bw}" "${bmin}" "${bmax}"
  printf "  ${BBLU}%-22s${RST}${BWHT}%10s${RST}\n" "IOPS" "${iops}"
  printf "  ${BCYA}%-22s${RST}${BWHT}%10s ms${RST}   ${DIM}p50=%-8s p95=%-8s p99=%-8s p999=%s${RST}\n" \
    "Avg Latency" "${lat_avg}" "${lat_p50}" "${lat_p95}" "${lat_p99}" "${lat_p999}"
  printf "  ${DIM}%-22s%10s ms${RST}   ${DIM}stdev=%s ms${RST}\n" "Max Latency" "${lat_max}" "${lat_stdev}"
  printf "  ${DIM}%-22s  usr=%-6s sys=%-6s util=%-6s ctx=%s${RST}\n" \
    "CPU / IO" "${cpu_usr}%" "${cpu_sys}%" "${io_util}%" "${ctx_sw}"
  echo

  local profile_str="rw=${step_rw} bs=${step_bs} iodepth=${step_qd} direct=${DIRECT_IO} dur=${DURATION}s${step_rwmix:+ rwmix=${step_rwmix}}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s
'     "$jobs" "$total_qd"     "$bw" "$iops" "$bmin" "$bmax" "$bstd"     "$lat_avg" "$lat_p50" "$lat_p95" "$lat_p99" "$lat_p999" "$lat_max" "$lat_stdev"     "$slat" "$clat"     "$cpu_usr" "$cpu_sys" "$io_util" "$ctx_sw"     "$profile_str" "$IO_ENGINE" "$FILE_SIZE" "$step_ts"     "$step_label" "$step_group"     >> "${CSV_FILE}"
}

# ── CSV header ─────────────────────────────────────────────────────────────────
write_csv_header() {
  cat > "${CSV_FILE}" << 'CSVHDR'
jobs,total_qd,bw_mbs,iops,bw_min_mbs,bw_max_mbs,bw_stdev_mbs,lat_avg_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_p999_ms,lat_max_ms,lat_stdev_ms,slat_avg_us,clat_avg_us,cpu_usr_pct,cpu_sys_pct,io_util_pct,ctx_switches,profile,engine,file_size,timestamp,profile_name,profile_group
CSVHDR
}

# ── Standard sweep runner ──────────────────────────────────────────────────────
run_standard_sweep() {
  mkdir -p "${TEST_DIR}"; write_csv_header
  local est=$(( MAX_JOBS * (DURATION + 5) ))
  info "Standard sweep: jobs 1→${MAX_JOBS}  |  est. ~$((est/60))m$((est%60))s"
  info "CSV: ${CSV_FILE}"; echo

  for (( j=1; j<=MAX_JOBS; j++ )); do
    run_one_step "$j" "$RW" "$BS" "$IODEPTH" "sweep" ""
  done
}

# ── Full universal suite — runs all profile groups ─────────────────────────────
run_full_suite() {
  mkdir -p "${TEST_DIR}"; write_csv_header
  local all_groups=(PROFILES_DB PROFILES_VM PROFILES_STREAM PROFILES_BACKUP PROFILES_CONTAINER PROFILES_SPARK)
  local all_names=("Database" "VM/Virtualization" "Streaming" "Backup" "Container/K8s" "Spark")

  # Count total steps
  local total_profs=0
  for arr in "${all_groups[@]}"; do
    local -n tmp="$arr"
    total_profs=$(( total_profs + ${#tmp[@]} ))
  done
  local total_steps=$(( total_profs * MAX_JOBS ))
  local est=$(( total_steps * (DURATION + 5) ))
  info "Full Universal Suite: ${total_profs} profiles × jobs 1→${MAX_JOBS} = ${total_steps} steps"
  info "Estimated time: ~$((est/60))m$((est%60))s"
  info "CSV: ${CSV_FILE}"; echo

  PROFILE_SEL=99  # run all in each group
  for i in "${!all_groups[@]}"; do
    echo; thick
    printf "  ${BCYA}★★ GROUP: %-20s${RST}
" "${all_names[$i]}"
    thick; echo
    # First group writes CSV header; later groups append only (do not truncate CSV)
    if [[ "$i" -eq 0 ]]; then
      run_profile_group_sweep "${all_groups[$i]}"
    else
      run_profile_group_sweep "${all_groups[$i]}" "1"
    fi
  done
}

# ── Terminal summary (csv.DictReader — safe with commas in fields) ─────────────
print_summary() {
  get_tw; echo; thick
  printf "${BCYA}%*s${RST}\n" $(( (TERM_W+14)/2 )) "SWEEP COMPLETE"
  thick; echo

  python3 - "${CSV_FILE}" <<'PYEOF'
import csv, sys
from collections import defaultdict

path = sys.argv[1]
G = "\033[1;32m"
R = "\033[1;31m"
Y = "\033[1;33m"
N = "\033[0m"
B = "\033[1;34m"
GRN = "\033[0;32m"
W = "\033[1;37m"

rows = []
try:
    with open(path, newline="", encoding="utf-8-sig") as f:
        rdr = csv.DictReader(f)
        fn = rdr.fieldnames or []
        has_pn = "profile_name" in fn
        for r in rdr:
            try:
                pn = (r.get("profile_name") or "").strip() or "sweep"
                if not has_pn:
                    pn = "sweep"
                pg = (r.get("profile_group") or "").strip() or "standard"
                rows.append(
                    {
                        "jobs": int(r["jobs"]),
                        "iops": int(r["iops"]),
                        "bw": float(r["bw_mbs"]),
                        "lat": float(r["lat_avg_ms"]),
                        "profile_name": pn,
                        "profile_group": pg,
                    }
                )
            except Exception:
                continue
except Exception as e:
    print(f"  {R}Could not read CSV: {e}{N}")
    sys.exit(0)

if not rows:
    print("  [No data rows in CSV]")
    sys.exit(0)


def sweet_spot(sub):
    if not sub:
        return None
    ml = min(x["lat"] for x in sub)
    best = sub[0]
    for x in sub:
        if x["lat"] <= ml * 2 and x["iops"] >= best["iops"]:
            best = x
    return best


by = defaultdict(list)
for r in rows:
    by[r["profile_name"]].append(r)

profiles = sorted(by.keys(), key=lambda p: (by[p][0]["profile_group"], p))


def status_for(x, best, sweet_ref):
    if x["jobs"] == best["jobs"]:
        return G, "★ SWEET"
    if x["lat"] > sweet_ref * 2.5:
        return R, "SATURATED"
    if x["lat"] > sweet_ref * 2.0:
        return Y, "HIGH LAT"
    return GRN, "OK"


for pname in profiles:
    sub = sorted(by[pname], key=lambda x: x["jobs"])
    best = sweet_spot(sub)
    if not best:
        continue
    sweet_ref = best["lat"]
    multi = len(profiles) > 1 or (len(profiles) == 1 and pname != "sweep")
    if multi:
        print(f"\n  {B}▶ {pname}  ({sub[0]['profile_group']}){N}")
    print(f"  {'Jobs':<12} {'IOPS':<10} {'BW(MB/s)':<10} {'AvgLat':<10} {'Status':<10}")
    print("  " + "-" * 56)
    for x in sub:
        col, st = status_for(x, best, sweet_ref)
        print(
            f"  {col}{x['jobs']:<12} {x['iops']:<10} {x['bw']:<10.1f} "
            f"{x['lat']:<10.3f}ms {st}{N}"
        )
    print(
        f"\n  {G}★ Sweet spot ({pname}): {W}{best['jobs']} jobs{N}  "
        f"IOPS: {W}{best['iops']}{N}  AvgLat: {W}{best['lat']:.4f} ms{N}"
    )
PYEOF

  thick; echo
  info "CSV: ${BLD}${CSV_FILE}${RST}"
  info "Upload to io_compare.html for full charts and analysis"
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
main() {
  if ! command -v fio &>/dev/null; then
    banner; err "fio not found."; exit 1
  fi
  if ! command -v python3 &>/dev/null; then
    banner; err "python3 not found."; exit 1
  fi

  banner
  check_prerequisites
  detect_ioengine
  select_mode

  # Global for profile selection within group menu
  PROFILE_SEL="99"
  PROFILE_BS_OVERRIDE=""
  PROFILE_QD_OVERRIDE=""

  case "$MODE_TYPE" in
    standard)  menu_standard ;;
    database)  menu_profile_group "Database Profiles"    PROFILES_DB        "database" ;;
    vm)        menu_profile_group "VM/Virtualization"    PROFILES_VM        "vm"       ;;
    streaming) menu_profile_group "Streaming/Media"      PROFILES_STREAM    "stream"   ;;
    backup)    menu_profile_group "Backup/Archive"       PROFILES_BACKUP    "backup"   ;;
    container) menu_profile_group "Container/K8s"        PROFILES_CONTAINER "k8s"      ;;
    spark)     menu_profile_group "Spark IO Profiles"    PROFILES_SPARK     "spark"    ;;
    full)      menu_profile_group "Full Universal Suite" PROFILES_ALL_DUMMY "universal" ;;
  esac

  echo; info "Started at $(date)"; echo

  case "$MODE_TYPE" in
    standard)  run_standard_sweep ;;
    database)  run_profile_group_sweep PROFILES_DB        ;;
    vm)        run_profile_group_sweep PROFILES_VM        ;;
    streaming) run_profile_group_sweep PROFILES_STREAM    ;;
    backup)    run_profile_group_sweep PROFILES_BACKUP    ;;
    container) run_profile_group_sweep PROFILES_CONTAINER ;;
    spark)     run_profile_group_sweep PROFILES_SPARK     ;;
    full)      run_full_suite ;;
  esac

  print_summary
  echo -e "  ${BGRN}${BLD}Done.${RST}  CSV: ${CSV_FILE}"; echo
}

main "$@"
