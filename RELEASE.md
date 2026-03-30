# Release notes — IO Performance Tooling

**Credit:** Idea and context for this tooling are attributed to **Sontas Jiamsripong**.

## v4.0 — Universal IO Testing Tool (2026-03-30)

### `io_sweep.sh` (shell)

- **Version** `4.0` — banner identifies the tool as a **Universal IO Testing Tool**.
- **Eight modes**: Standard Sweep; Database; VM/Virtualization; Streaming/Media; Backup/Archive; Container/K8s; Spark; Full Universal (all profile groups).
- **21 workload profiles** across those groups (OLTP, OLAP, WAL, Index, VM guest/clone/VDI, streaming ingest/playback/log, backup read/write/dedup, K8s pull/PVC/etcd, Spark read/write/shuffle/HEAD/MOVE, etc.). Definitions live in `PROFILES_*` arrays near the top of the script.
- **CSV schema** (see `write_csv_header`): base metrics plus **`profile_name`** and **`profile_group`** columns (written by `run_one_step` for every row).
- **`run_one_step`** now takes **`step_group`** as the 6th argument and **`step_rwmix`** as the 7th; terminal output shows `[GROUP] profile_name` for profile runs. **Fixed**: `profile_group` is no longer written empty to the CSV.

### `io_compare.html` (web)

- **Single-system mode**: Upload **one** `sweep_results.csv` (or universal CSV), choose **Single System**, **Generate Report** — full charts and summary without System B.
- **Compare mode**: Two CSVs; classic A/B charts unchanged for **standard** (non-universal) sweeps.
- **Automatic universal / profile detection**: If the CSV contains multiple **`profile_name`** values and/or non-`standard` **`profile_group`** values, the page switches to **profile layout**:
  - **Tabs** = **Summary** + **one tab per `profile_group`** present in the file (order: Standard → Spark → Database → VM → Streaming → Backup → Container → Universal → other).
  - **Summary** lists every profile with peak IOPS/BW, min latency, and **sweet spot** (jobs + IOPS).
  - **Group tabs** list each **`profile_name`** in that group with IOPS/BW/latency charts (colors/descriptions from `PROFILE_META` in the HTML).
- **Two-file universal compare**: Summary compares **profiles that exist in both uploads**; group tabs show side-by-side charts per matching `profile_name`.
- **CSV parsing**: Header row is detected (`jobs`,`total_qd`,…); quoted fields supported. Legacy 24-column files without `profile_name` / `profile_group` still work as standard sweeps.
- **UI**: Mode toggle, dynamic button label (“Generate Report” vs “Generate Comparison Report”), `reportPanels` template is restored when switching between standard and profile layouts.

### Files in this release

| Artifact | Role |
|----------|------|
| `io_sweep.sh` | Benchmark driver + CSV with `profile_*` columns |
| `io_compare.html` | Offline report / compare / universal profile UI |
| `docs/IO_COMPARE_WEB.md` | HTML/JS walkthrough for maintainers |

---

## v4.0.3 — Unified Spark storage menu (2026-03-30)

- **`storage_spark_sweep.sh`** — Single script: choose **Filesystem (fio)** vs **HDFS** vs **S3**, then **Spark profile** (`spark_read` … `spark_move` or full suite). CSV uses **`profile_group=spark`** and **`profile_name`** matching `io_sweep.sh`; **`storage_backend`** distinguishes fio / hdfs / s3.

---

## v4.0.2 — S3/HDFS CSV + offline tarball (2026-03-30)

### CSV

- **`io_sweep.sh`** — Header and each data row include **`storage_backend`** (local runs use **`fio`**).
- **`s3_sweep.sh`** / **`hdfs_sweep.sh`** — Produce the same column layout for **`io_compare.html`**; set **`storage_backend`** to **`s3`** or **`hdfs`**.

### Web (`io_compare.html`)

- Parses optional **`storage_backend`**; legacy 26-column CSVs default to **`fio`**.
- Subtitle shows **Storage: S3 / HDFS** when applicable.
- **`PROFILE_META`** / tab order extended for **`s3`** / **`hdfs`** groups.

### Packaging

- **`packaging/vendor-aws-cli.sh`** — Install AWS CLI v2 into **`vendor/aws-cli/`** (Linux x86_64).
- **`packaging/build-offline-bundle.sh`** — Build **`dist/io-perf-offline-*.tar.gz`** (project + vendored CLI if present).

---

## v4.0.1 — `io_compare.html` UX (2026-03-30)

### Improvements

- **Sweet spot on charts** — Clear visual cues for the sweet-spot job count without obscuring numeric labels: subtle column tint behind the plot, a **sweet spot** sub-label under the jobs axis, and a tight double-ring at the data point (compare, single, and universal/profile flows). Scatter (QD vs IOPS) keeps point rings only; no vertical line through labels.
- **Analysis & Recommendation typography** — Verdict body (`.vtext`) uses a single readable system UI font stack; emphasis uses color and weight only, consistent with the rest of the report.
- **Analysis tooltips (English)** — Row-level `title` hints on the Analysis / Performance Summary table (metric meaning, higher vs lower is better). The **Latency × IOPS Score** chart title includes a dotted underline and a tooltip explaining the formula, that higher is better, and how it relates to **Best IO Score**.
- **Landing page** — On first load (before generating a report), the page shows **release notes** (v4.0.1 + v4.0 summary) and a **sortable table of all IO workload profiles** (`profile_name`, group, label, description from `PROFILE_META`). This block is hidden while a report is open; refresh the page to see it again.
- **README.md** — Full **IO workload catalog** (all 21 named profiles + main menu modes + Standard Sweep fio `rw=` options) documented on the repository front page.
- **Screenshots** — `docs/screenshots/` holds current `io_compare.html` captures; `npm run screenshots` (Playwright) regenerates them — see README.

---

## Maintenance fixes (post–v4.0 documentation)

- **Full Universal suite CSV** — `run_profile_group_sweep` no longer calls `write_csv_header` on every group; only the first group creates the file, later groups **append** so all profiles remain in one CSV.
- **Terminal `print_summary`** — Replaced fragile `cut`/`grep` on comma-separated lines with **`csv.DictReader`** (Python), with per-**`profile_name`** sweet spot and status when the CSV contains multiple profiles (all modes, not only Spark).
- **`PROFILES_ALL_DUMMY`** — Declared as an empty array so the Full Universal menu `nameref` is valid.
- **Container profile colors** — `pcol` updated from `2` (dim) to **`1;35`** (magenta) for consistent group highlighting.
- **`io_compare.html`** — UTF-8 **BOM** stripped on load; **empty chart data** avoids `Infinity`/`NaN` scale; **scatter** X-axis avoids divide-by-zero; **`findSweet`** guards empty rows; resize debounce **400ms**.

## Earlier

- v2.x: Rich CSV + `io_compare.html` two-system compare.
- v3.x: Single-system path and profile metadata in HTML (evolved into v4 universal layout).
