# IO Performance Sweep & Comparison Report

**v4.0 / v4.0.1 — Universal IO Testing Tool:** a **jobs 1→N** sweep using [fio](https://github.com/axboe/fio), exporting **CSV** with optional **`profile_name`** / **`profile_group`** columns. Open **`io_compare.html`** locally for **single-system** reports, **A/B compare**, or **universal** multi-profile CSVs (tabs follow workload group). No server required.

Repository: [https://github.com/goasutlor/io_perf_test](https://github.com/goasutlor/io_perf_test)

**Author / credit — idea & context:** **Sontas Jiamsripong** — conceptual direction and context for this IO testing workflow and tooling.

**Release notes:** [RELEASE.md](RELEASE.md) · **Web UI walkthrough:** [docs/IO_COMPARE_WEB.md](docs/IO_COMPARE_WEB.md)

---

## Workflow

```mermaid
flowchart LR
  A[Install prerequisites] --> B[Run io_sweep.sh]
  B --> C[sweep_results.csv + JSON/LOG per step]
  C --> D[Open io_compare.html]
  D --> E{Mode}
  E -->|Single| F[One CSV → charts + sweet spot]
  E -->|Compare| G[Two CSVs → delta + analysis]
  E -->|Universal CSV| H[Tabs by profile_group]
```

1. **Linux (root recommended)** — Run `io_sweep.sh` (Standard mode or a profile mode: Database, VM, Spark, Full Universal, …).  
2. **Output** — CSV under `.../io_sweep_<timestamp>/` (or group-specific prefix) including `profile_name` and `profile_group` for universal runs.  
3. **Web report** — Open `io_compare.html` in a browser. Use **Single System** to analyze one CSV, or **Compare 2 Systems** for two. Universal CSVs are detected automatically; tabs match **`profile_group`**.

### Unified Spark storage sweep (recommended for cross-storage comparison)

This flow is intentionally **2-step**:

1. **Select Storage Type** first: `Filesystem` / `HDFS` / `Object (S3)`
2. **Select Spark IO Profile** next: `spark_read`, `spark_write`, `spark_shuffle`, `spark_head`, `spark_move` (or full suite)

For **HDFS** and **S3**, the script focuses on **Spark-like workload behavior** (API-level GET/PUT/HEAD/CAT mixes), not non-Spark profile families.

**`storage_spark_sweep.sh`** — one entry script:

1. Choose **Filesystem (fio)** — same Spark profiles as **`io_sweep.sh`** mode 7 (`spark_read` … `spark_move`, or full suite), via `fio` on a path you pick.  
2. Choose **HDFS** — Spark-*like* API mix (`-get`/`-put`/`-cat`, small vs large objects) per profile name.  
3. Choose **S3** — Spark-*like* API mix (GET/PUT/`head-object`) per profile name.

Then pick **one Spark profile** or **full suite** (all five). CSV uses **`profile_group=spark`** and **`profile_name`** as in the fio catalog (`spark_read`, …) so **`io_compare.html`** groups results under the **Spark** tab; **`storage_backend`** is **`fio`** / **`hdfs`** / **`s3`**.

```bash
chmod +x storage_spark_sweep.sh
./storage_spark_sweep.sh
```

### S3 / HDFS simple sweeps (optional)

| Script | Purpose | Env / notes |
|--------|---------|-------------|
| **`s3_sweep.sh`** | Parallel PUT-only sweep → **`s3_sweep_results.csv`** (`profile_group`=`s3`) | **`S3_BUCKET`**, `S3_PREFIX`, `MAX_JOBS`, `OBJ_MB` |
| **`hdfs_sweep.sh`** | Parallel `-put` sweep → **`hdfs_sweep_results.csv`** (`profile_group`=`hdfs`) | **`HDFS_DEST`**, `MAX_JOBS`, `OBJ_MB` |

CSV columns match **`io_sweep.sh`** (including **`storage_backend`**). Upload into **`io_compare.html`** as usual.

### Offline bundle (AWS CLI on air-gapped Linux hosts)

1. On a connected **Linux x86_64** machine: `bash packaging/vendor-aws-cli.sh` (downloads AWS CLI v2 into `vendor/aws-cli/`).  
2. `bash packaging/build-offline-bundle.sh` → **`dist/io-perf-offline-*.tar.gz`**.  
3. On the target: extract, then **`source packaging/env.sh`** and run **`s3_sweep.sh`** (Hadoop clients for **`hdfs_sweep.sh`** are expected to exist on the host; not bundled).

---

## IO workload profiles (full catalog)

`io_sweep.sh` opens with a **test mode** menu. **Mode 1 (Standard Sweep)** uses a *custom* single workload: you choose an fio **`rw=`** pattern, block size, and jobs 1→N — it does **not** use the named profiles below. **Modes 2–8** run **predefined profiles** (fixed `rw`, `bs`, `iodepth`, and optional `rwmixread` for `randrw`). Each step writes CSV columns **`profile_name`** and **`profile_group`** so `io_compare.html` can group charts. The same names appear in `PROFILE_META` inside `io_compare.html`.

### Main menu modes

| # | Mode | What it runs |
|---|------|----------------|
| **1** | **Standard Sweep** | One fio workload (you pick `rw` below), one `profile` string in CSV, jobs 1→N. |
| **2** | Database | Choose OLTP, OLAP, WAL, Index — or all. |
| **3** | VM / Virtualization | Guest, Clone, VDI — or all. |
| **4** | Streaming / Media | Ingest, Playback, Log — or all. |
| **5** | Backup / Archive | Backup read, restore write, dedup — or all. |
| **6** | Container / K8s | Image pull, PVC mixed, etcd WAL — or all. |
| **7** | Spark | Read, Write, Shuffle, HEAD, MOVE — or all. |
| **8** | Full Universal Suite | Every profile in the tables below, in sequence. |

### Mode 1 only — fio `rw=` patterns (not the named profile catalog)

These five options apply **only** to **Standard Sweep**. They map directly to fio’s `rw=` parameter.

| # | `rw` | Role |
|---|------|------|
| 1 | `randwrite` | Random write — recommended baseline (DB / VM worst-case style) |
| 2 | `randread` | Random read — query-style random I/O |
| 3 | `read` | Sequential read — throughput-oriented |
| 4 | `write` | Sequential write — throughput-oriented |
| 5 | `randrw` | Mixed random 70% read / 30% write — OLTP-style |

### Named profiles (modes 2–8) — `profile_name` in CSV

Each row is defined in `io_sweep.sh` as `NAME|rw|bs|iodepth|rwmixread|…|description`. Empty **rwmix** means N/A (not `randrw` or mix not used). **21** workload profiles total.

#### Spark (`profile_group` → `spark`)

| `profile_name` | fio `rw` | `bs` | `iodepth` | `rwmixread` | Description |
|----------------|----------|------|-----------|-------------|-------------|
| `spark_read` | read | 128k | 16 | — | Sequential read — Parquet/ORC scan |
| `spark_write` | write | 128k | 16 | — | Sequential write — task partition output |
| `spark_shuffle` | randrw | 32k | 32 | 50 | Shuffle — sort/join/groupBy (50R/50W) |
| `spark_head` | randread | 4k | 64 | — | HEAD/metadata — schema lookup, small random reads |
| `spark_move` | randrw | 128k | 8 | 70 | MOVE/commit — task commit rename (70R/30W) |

#### Database (`database`)

| `profile_name` | fio `rw` | `bs` | `iodepth` | `rwmixread` | Description |
|----------------|----------|------|-----------|-------------|-------------|
| `db_oltp` | randrw | 8k | 32 | 70 | OLTP random — MySQL/PostgreSQL style (70R/30W) |
| `db_olap` | read | 512k | 8 | — | OLAP scan — analytics full-table sequential read |
| `db_wal` | write | 4k | 1 | — | WAL/redo — sync write, QD 1 (fsync-sensitive) |
| `db_index` | randread | 4k | 64 | — | Index lookup — B-tree random read, high QD |

#### VM / Virtualization (`vm`)

| `profile_name` | fio `rw` | `bs` | `iodepth` | `rwmixread` | Description |
|----------------|----------|------|-----------|-------------|-------------|
| `vm_guest` | randrw | 16k | 32 | 60 | VM disk — general guest OS I/O (60R/40W) |
| `vm_clone` | read | 256k | 16 | — | VM clone/snapshot — live migration read |
| `vm_vdi` | randread | 8k | 128 | — | VDI boot storm — many VMs booting, high concurrency |

#### Streaming / Media (`streaming`)

| `profile_name` | fio `rw` | `bs` | `iodepth` | `rwmixread` | Description |
|----------------|----------|------|-----------|-------------|-------------|
| `stream_ingest` | write | 1m | 4 | — | Video ingest — large sequential writer (camera/encoder) |
| `stream_play` | read | 512k | 8 | — | Video playback — multi-stream sequential read |
| `stream_log` | write | 64k | 8 | — | Log streaming — Kafka/Fluentd append-style write |

#### Backup / Archive (`backup`)

| `profile_name` | fio `rw` | `bs` | `iodepth` | `rwmixread` | Description |
|----------------|----------|------|-----------|-------------|-------------|
| `bkp_read` | read | 512k | 4 | — | Backup read — full backup source, throughput |
| `bkp_write` | write | 512k | 4 | — | Restore write — restore target, throughput |
| `bkp_dedup` | randrw | 8k | 16 | 50 | Dedup/compress — read-compare-write mixed I/O |

#### Container / Kubernetes (`container`)

| `profile_name` | fio `rw` | `bs` | `iodepth` | `rwmixread` | Description |
|----------------|----------|------|-----------|-------------|-------------|
| `k8s_pull` | read | 128k | 32 | — | Image pull — layer extract, parallel read |
| `k8s_pvc` | randrw | 64k | 16 | 50 | PVC mixed — stateful DB/queue (50R/50W) |
| `k8s_etcd` | write | 4k | 1 | — | etcd WAL — fsync write, QD 1, latency-critical |

---

**Note:** `io_compare.html` also lists these rows on the **landing page** (before you generate a report) and applies colors/labels from the embedded `PROFILE_META` map. For script changes, the source of truth is **`PROFILES_*`** arrays near the top of `io_sweep.sh`.

---

## Prerequisites

The script checks these automatically at startup (`check_prerequisites`).

| Component | Required? | Role | Example install |
|-----------|-----------|------|-----------------|
| **fio** | Yes | IO benchmark | `yum install fio` / `apt install fio` / `brew install fio` |
| **python3** | Yes | Parse fio JSON → CSV columns | `yum install python3` / `apt install python3` |
| **libaio** | Recommended | `libaio` ioengine (async) | `yum install libaio libaio-devel` / `apt install libaio1 libaio-dev` — if missing, the script falls back to `psync` |
| **sysstat** | Optional | Provides `iostat` (fio already reports util% in JSON) | `yum install sysstat` / `apt install sysstat` |
| **util-linux** | Optional | `sync`, `blockdev` (base system) | Usually pre-installed |
| **tput** | Optional | Terminal width | Usually pre-installed (ncurses) |
| **root** | Recommended | `echo 3 > /proc/sys/vm/drop_caches` between steps | Run with `sudo ./io_sweep.sh` |

**One-line installs (examples):**

- RHEL / Rocky / AlmaLinux:  
  `yum install -y fio python3 libaio libaio-devel sysstat`
- Ubuntu / Debian:  
  `apt install -y fio python3 libaio1 libaio-dev sysstat`
- macOS:  
  `brew install fio python3` (no libaio — sync-style ioengine is used automatically)

---

## Features / Functions (from the shell script)

### Main features

- **Jobs 1→N sweep** — Runs one job count at a time from 1 through `MAX_JOBS` to explore throughput/latency vs. concurrency.  
- **Cache mitigation** — Unique test file per step, **O_DIRECT** (`--direct`), `--invalidate=1`, **drop_caches** when root, short settle delay, delete test files after each step.  
- **Interactive menu** — **Mode 1–8** (Standard vs profile groups vs full universal); Standard Sweep uses path + **fio `rw=`** (five patterns) + block size + jobs/iodepth/duration/file size/Direct IO; profile modes pick a named workload from the [IO workload profiles](#io-workload-profiles-full-catalog) catalog.  
- **Rich CSV** — Bandwidth, IOPS, latency (avg, p50–p999, max), CPU, IO util, context switches, profile, engine, timestamp.  
- **End-of-run summary** — Approximate “sweet spot” (Python over CSV) and per-job status (e.g. OK / HIGH LAT / SATURATED).

### Key functions in `io_sweep.sh`

| Function | Purpose |
|----------|---------|
| `check_prerequisites` | Verify fio, python3, libaio, sysstat, tput, and privilege |
| `detect_ioengine` | Choose `libaio` or fallback `psync` |
| `run_menu` | Collect parameters from the user |
| `drop_caches` | `sync` + drop page cache (if root) |
| `parse_json_rich` | Turn fio JSON into one CSV row of numbers |
| `run_one_step` | Run one fio step, progress UI, parse, append CSV |
| `run_sweep` | Create work dir, CSV header, loop jobs 1..N |
| `print_summary` | Print summary and highlight sweet spot |

### Output artifacts

- **`sweep_results.csv`** — Feed directly into `io_compare.html`.  
- **`step_j<N>.json`** — Raw fio JSON per step.  
- **`step_j<N>.log`** — fio stderr per step (debugging).

### CSV header (reference)

```text
jobs,total_qd,bw_mbs,iops,bw_min_mbs,bw_max_mbs,bw_stdev_mbs,lat_avg_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_p999_ms,lat_max_ms,lat_stdev_ms,slat_avg_us,clat_avg_us,cpu_usr_pct,cpu_sys_pct,io_util_pct,ctx_switches,profile,engine,file_size,timestamp
```

---

## Usage

```bash
chmod +x io_sweep.sh
sudo ./io_sweep.sh    # recommended — enables drop_caches between steps
# ./io_sweep.sh       # non-root — runs, but no cache drop
```

When the run finishes, the script prints the path to `sweep_results.csv` and suggests opening **`io_compare.html`** to upload the file.

### Web report (`io_compare.html` v4)

- Open the file in a browser (double-click or `file:///.../io_compare.html` — no backend).  
- **Single System** — upload one CSV; **Generate Report** shows overview, latency, throughput, resources, IO profile, and analysis (no System B required).  
- **Compare 2 Systems** — optional labels for **System A** / **System B**; upload two CSVs for deltas and verdict text.  
- **Universal CSV** (multiple `profile_name` / non-standard `profile_group`) — the UI builds a **Summary** tab plus **one tab per group** (Spark, Database, VM, …) with charts per profile. See [docs/IO_COMPARE_WEB.md](docs/IO_COMPARE_WEB.md) for implementation details.

---

## Examples from this repository

### Snippet from `io_sweep.sh` (Standard Sweep — fio `rw=` only)

After you choose **mode 1**, the script asks for the **fio read/write pattern** (this is *not* the 21 named profiles; those are modes **2–8** — see [IO workload profiles](#io-workload-profiles-full-catalog) above).

```bash
  echo -e "  ${BLD}Workload type${RST}  ${DIM}(fio rw= pattern — Standard Sweep only)${RST}"
  echo -e "  ${DIM}Other modes (2–8) pick ready-made profiles: Database, VM, Streaming, Backup, K8s, Spark, or full suite — not this list.${RST}"
  echo "   1) randwrite   Random write ← recommended (DB/VM worst case)"
  echo "   2) randread    Random read  (DB query pattern)"
  echo "   3) read        Sequential read  (throughput test)"
  echo "   4) write       Sequential write (throughput test)"
  echo "   5) randrw      Mixed 70R/30W (OLTP simulation)"
  # read -rp "  Select fio rw [default=1]: "
```

### Rows from `sweep_results_1.csv`

```csv
jobs,total_qd,bw_mbs,iops,bw_min_mbs,bw_max_mbs,bw_stdev_mbs,lat_avg_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_p999_ms,lat_max_ms,lat_stdev_ms,slat_avg_us,clat_avg_us,cpu_usr_pct,cpu_sys_pct,io_util_pct,ctx_switches,profile,engine,file_size,timestamp
1,32,348.77,89285,277.82,377.26,22.76,0.3581,0.3338,0.514,0.7496,2.0562,12.6718,0.1424,3.768,354.298,6.47,36.55,99.68,559600,rw=randwrite bs=4k iodepth=32 direct=1 dur=30s,libaio,1g,20260330T093315
2,64,419.06,107279,309.28,457.14,15.11,0.5962,0.5693,0.8806,1.1223,2.5723,9.2667,0.195,5.334,590.832,3.79,27.04,99.77,970731,rw=randwrite bs=4k iodepth=32 direct=1 dur=30s,libaio,1g,20260330T093349
```

### Real-time progress (live terminal “chart”)

While **fio** runs each step, `io_sweep.sh` redraws a **live dashboard** in the terminal (ANSI cursor moves; same lines update about once per second). It is not a GUI chart, but it behaves like a **real-time progress strip**: Braille **spinner** + **filled bar** (`█` vs `░`) + **percent** + **elapsed / runtime** + job parameters and cache hints.

**Behavior (from `run_one_step`):**

| Element | Role |
|---------|------|
| Spinner (`⠋⠙⠹…`) | Shows the step is active |
| Bar + `%` | Elapsed time vs `--runtime` (duration per step) |
| `jobs`, `iodepth`, `total_QD`, `file=` | Current concurrency and unique test file name |
| `Elapsed` / `Remaining` | ETA for this step |
| Final line | Turns green: `✔ [████…] 100% — Done` |

**Illustrative snapshot** (what you see *during* a 30s step — bar length and `%` increase every second until 100%):

```text
══════════════════════════════════════════════════════════════════════════════════
  STEP 4/8  jobs=4    qd_total=128    bs=4k      rw=randwrite
══════════════════════════════════════════════════════════════════════════════════
  [INFO]  Page cache dropped (echo 3 > /proc/sys/vm/drop_caches)

  ⠼ [████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  40%  12s / 30s

  jobs=4     iodepth/job=32    total_QD=128     file=testfile_j4_20260330T094512
  rw=randwrite    bs=4k       direct=1  engine=libaio

  Elapsed: 12s  Remaining: 18s  File size/job: 1g
  Cache: O_DIRECT=1 + drop_caches before step + unique file
```

When the step finishes, that block is replaced by the green 100% line and the numeric summary (Throughput, IOPS, latency percentiles, CPU / util).

A longer capture including configuration, per-step summaries, and the **sweep summary** is in **`Example Result.txt`**. An extra **realtime-only illustration** is in **`shell_realtime_progress_example.txt`**.

### Sweep complete — summary table and sweet spot

After all job counts finish, **`print_summary`** prints **`SWEEP COMPLETE`**, a **per-job table** (IOPS, bandwidth, average latency, P99 latency), and a **Status** column:

| Status | Meaning (heuristic) |
|--------|----------------------|
| **★ SWEET** | Row selected as the sweet spot (see below) |
| **OK** | Latency not yet elevated vs. sweet spot |
| **HIGH LAT** | Average latency > ~2× sweet-spot average |
| **SATURATED** | Average latency > ~2.5× sweet-spot average |

**Sweet spot selection** (embedded Python in `print_summary`): among all rows, find the minimum **average latency**; then, among rows whose average latency is **≤ 2× that minimum**, pick the row with the **highest IOPS**. That row is labeled **★ SWEET** and repeated in the banner line.

**Example end-of-run output** (same run as the sample CSV — condensed from `Example Result.txt`):

```text
══════════════════════════════════════════════════════════════════════════════════
                                                    SWEEP COMPLETE
══════════════════════════════════════════════════════════════════════════════════

  Jobs         IOPS       BW(MB/s)   AvgLat     P99Lat     Status
──────────────────────────────────────────────────────────────────────────────────
  1 jobs       89285      348.77     0.3581ms   0.7496ms   OK
  2 jobs       107279     419.06     0.5962ms   1.1223ms   ★ SWEET
  3 jobs       120336     470.07     0.7973ms   1.5811ms   OK
  4 jobs       124023     484.47     1.0316ms   1.8596ms   OK
  5 jobs       123621     482.9      1.2937ms   2.3429ms   HIGH LAT
  6 jobs       117395     458.58     1.6345ms   2.4084ms   SATURATED
  7 jobs       120184     469.47     1.8629ms   3.4898ms   SATURATED
  8 jobs       124854     487.71     2.0497ms   3.0638ms   SATURATED

══════════════════════════════════════════════════════════════════════════════════
  ★ Sweet spot: 2 jobs  |  IOPS: 107279  |  AvgLat: 0.5962 ms
══════════════════════════════════════════════════════════════════════════════════

  [INFO]  CSV: .../io_sweep_<timestamp>/sweep_results.csv
  [INFO]  Open io_compare.html in browser and upload this CSV to generate charts
```

### Terminal output (full log)

The script prints a banner, confirmation of settings (path, workload, sweep 1→N, iodepth, duration, file size, Direct IO, engine), then each **STEP** with the **live progress dashboard** and per-step Throughput / IOPS / Latency. The full transcript is in **`Example Result.txt`**.

### Web report (HTML)

Sample UI (`docs/screenshots/`, from `sweep_results_1.csv` / `sweep_results2.csv`):

**Landing** — release notes + full IO profile table:

![io_compare landing — release notes and profile catalog](docs/screenshots/io_compare-01-landing.png)

**Single system — Overview** (first tab after Generate):

![io_compare single-system overview](docs/screenshots/io_compare-02-overview.png)

**Single system — Latency distribution** (second tab):

![io_compare latency tab](docs/screenshots/io_compare-03-latency-tab.png)

**Compare 2 Systems — Overview**:

![io_compare A/B compare overview](docs/screenshots/io_compare-04-compare-overview.png)

**Regenerate screenshots:** from repo root, run `python -m http.server 8765` in another terminal, then `npm install` once and `npm run screenshots` (uses Playwright; see `scripts/capture-readme-screenshots.mjs`).

---

## Repository layout

| File | Description |
|------|-------------|
| `io_sweep.sh` | Main sweep script and CSV writer |
| `io_compare.html` | Browser report: single CSV, compare, or universal profile tabs |
| `RELEASE.md` | Version history (v4.0 universal tool) |
| `docs/IO_COMPARE_WEB.md` | Maintainer walkthrough of `io_compare.html` |
| `sweep_results_1.csv`, `sweep_results2.csv` | Sample CSV outputs |
| `Example Result.txt` | Full saved terminal output (config, steps, summary, sweet spot) |
| `shell_realtime_progress_example.txt` | Static “frames” of the live progress bar / spinner |
| `docs/screenshots/*.png` | HTML report screenshots (see README “Web report”) |
| `scripts/capture-readme-screenshots.mjs` | Regenerate `docs/screenshots` with Playwright |
| `package.json` | Dev-only: Playwright for screenshot script |

---

## Notes

- The script targets **Linux** first (macOS may not offer the same `drop_caches` behavior).  
- Testing production paths should be approved with a rollback plan.  
- Per-job file size should be **larger than RAM** when you need to avoid cache effects in complex cases (the menu includes guidance).

---

## License

Provided as-is for internal IO benchmarking and comparison — follow your organization’s policies before use in production environments.

Acknowledgement: idea and project context are credited to **Sontas Jiamsripong**.
