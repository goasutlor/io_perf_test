# IO Performance Sweep & Comparison Report

Tools for IO performance testing with a **jobs 1→N** sweep using [fio](https://github.com/axboe/fio), exporting **CSV** results for side-by-side comparison in the browser via **`io_compare.html`** (no server required).

Repository: [https://github.com/goasutlor/io_perf_test](https://github.com/goasutlor/io_perf_test)

---

## Workflow

```mermaid
flowchart LR
  A[Install prerequisites] --> B[Run io_sweep.sh]
  B --> C[sweep_results.csv + JSON/LOG per step]
  C --> D[Open io_compare.html]
  D --> E[Upload two CSV files]
  E --> F[Charts + tables + comparison summary]
```

1. **Linux (root recommended)** — Run `io_sweep.sh` against the path you want to test.  
2. **Output** — `sweep_results.csv` is written under `io_sweep_<timestamp>/`.  
3. **Web report** — Open `io_compare.html` in a browser and upload the System A / System B CSV files to view charts and analysis.

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
- **Interactive menu** — Path, workload (randwrite / randread / read / write / randrw), block size, max jobs, iodepth, duration, per-job file size, Direct IO on/off.  
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

### Web report (`io_compare.html`)

- Open the file in a browser (double-click or `file:///.../io_compare.html` — no backend).  
- Set labels for **System A** / **System B** (e.g. NVMe vs iSCSI).  
- Drag or select two **`sweep_results.csv`** files.  
- Run the report — you get IOPS/latency charts, comparison narrative, and numeric tables.

---

## Examples from this repository

### Snippet from `io_sweep.sh` (workload menu)

```bash
  echo "   1) randwrite   Random write ← recommended (DB/VM worst case)"
  echo "   2) randread    Random read  (DB query pattern)"
  echo "   3) read        Sequential read  (throughput test)"
  echo "   4) write       Sequential write (throughput test)"
  echo "   5) randrw      Mixed 70R/30W (OLTP simulation)"
```

### Rows from `sweep_results_1.csv`

```csv
jobs,total_qd,bw_mbs,iops,bw_min_mbs,bw_max_mbs,bw_stdev_mbs,lat_avg_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_p999_ms,lat_max_ms,lat_stdev_ms,slat_avg_us,clat_avg_us,cpu_usr_pct,cpu_sys_pct,io_util_pct,ctx_switches,profile,engine,file_size,timestamp
1,32,348.77,89285,277.82,377.26,22.76,0.3581,0.3338,0.514,0.7496,2.0562,12.6718,0.1424,3.768,354.298,6.47,36.55,99.68,559600,rw=randwrite bs=4k iodepth=32 direct=1 dur=30s,libaio,1g,20260330T093315
2,64,419.06,107279,309.28,457.14,15.11,0.5962,0.5693,0.8806,1.1223,2.5723,9.2667,0.195,5.334,590.832,3.79,27.04,99.77,970731,rw=randwrite bs=4k iodepth=32 direct=1 dur=30s,libaio,1g,20260330T093349
```

### Terminal output (summary)

The script prints a banner, confirmation of settings (path, workload, sweep 1→N, iodepth, duration, file size, Direct IO, engine), then each STEP with a progress bar and per-step Throughput / IOPS / Latency. Full sample text is in **`Example Result.txt`**.

### Web report (HTML)

Comparison UI after uploading two CSV files:

![IO Comparison Report — overview](Screenshot%202026-03-30%20095752.png)

![IO Comparison Report — charts/detail](Screenshot%202026-03-30%20095817.png)

---

## Repository layout

| File | Description |
|------|-------------|
| `io_sweep.sh` | Main sweep script and CSV writer |
| `io_compare.html` | Browser-based two-CSV comparison report |
| `sweep_results_1.csv`, `sweep_results2.csv` | Sample CSV outputs |
| `Example Result.txt` | Saved terminal output sample |
| `Screenshot *.png` | Sample HTML report screenshots |

---

## Notes

- The script targets **Linux** first (macOS may not offer the same `drop_caches` behavior).  
- Testing production paths should be approved with a rollback plan.  
- Per-job file size should be **larger than RAM** when you need to avoid cache effects in complex cases (the menu includes guidance).

---

## License

Provided as-is for internal IO benchmarking and comparison — follow your organization’s policies before use in production environments.
