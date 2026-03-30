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

## Maintenance fixes (post–v4.0 documentation)

- **Full Universal suite CSV** — `run_profile_group_sweep` no longer calls `write_csv_header` on every group; only the first group creates the file, later groups **append** so all profiles remain in one CSV.
- **Terminal `print_summary`** — Replaced fragile `cut`/`grep` on comma-separated lines with **`csv.DictReader`** (Python), with per-**`profile_name`** sweet spot and status when the CSV contains multiple profiles (all modes, not only Spark).
- **`PROFILES_ALL_DUMMY`** — Declared as an empty array so the Full Universal menu `nameref` is valid.
- **Container profile colors** — `pcol` updated from `2` (dim) to **`1;35`** (magenta) for consistent group highlighting.
- **`io_compare.html`** — UTF-8 **BOM** stripped on load; **empty chart data** avoids `Infinity`/`NaN` scale; **scatter** X-axis avoids divide-by-zero; **`findSweet`** guards empty rows; resize debounce **400ms**.

## Earlier

- v2.x: Rich CSV + `io_compare.html` two-system compare.
- v3.x: Single-system path and profile metadata in HTML (evolved into v4 universal layout).
