# `io_compare.html` — code walkthrough (v4.0)

This document summarizes how the self-contained page is structured so you can extend charts or profile metadata safely.

## Layout & modes

1. **`#modeBar`** — `setMode(1|2)` toggles Single vs Compare; dims `#cardB` in single mode; updates `#btnRunLbl`.
2. **`#reportPanels`** — On first load, `REPORT_PANELS_BACKUP` stores the **default** inner HTML (seven static `.tabpanel` blocks: Overview … Full Table). Any run of `render()` starts with `restoreDefaultPanels()` so canvas IDs and structure return to a known state before branching.
3. **Branches in `render()`**  
   - Single + universal CSV → `renderProfileSingle(da)` — **replaces** `#reportPanels` with dynamic Summary + group tabs.  
   - Compare + both universal → `renderProfileCompare(da, db)` — same idea.  
   - Single + classic sweep → `renderSingle(da)` — uses restored default panels; hides Analysis/Full Table tabs (`tab5`, `tab6`).  
   - Compare + classic → existing `initTabs()` + full seven tabs.

## CSV → rows

- **`parseCSVLine`** — Minimal RFC-style handling of quoted commas.
- **`parseCSV`** — If the first line looks like a header (`jobs`,`total_qd`,…), columns are mapped by **name** (case-insensitive). Otherwise the **fixed 26-column** layout is used.
- Each row gets **`profile_name`**, **`profile_group`** (default `standard`), and **`spark_op`** as an alias of `profile_name` for backward compatibility.

## Universal detection

- **`isUniversalProfileCsv(rows)`** — true when there is more than one profile name, more than one group, a single non-`standard` group, or a single profile name that is not the standard sweep label `sweep`.

## Profile metadata

- **`PROFILE_META`** — Keys match **`profile_name`** slugs from `io_sweep.sh` (`db_oltp`, `spark_read`, …). Each entry has `color`, `label`, `group`, `desc`.
- **`getMeta(name, grp)`** — Resolves display info for cards and section headers.

## Group tabs (dynamic)

- **`sortGroups`** / **`groupLabel`** — Consistent tab order and human-readable tab titles.
- **`renderProfileSingle`** — Builds tab bar: `Summary` + one tab per distinct `profile_group`. Summary grid: one card per **`profile_name`**. Group panels: for each profile in that group, a `<section>` with four canvases (`sp_iops_*`, `sp_bw_*`, `sp_lat_*`, `sp_cmp_*`). Chart draws are **deferred** until after `innerHTML` is applied (`deferredDraws`).
- **`renderProfileCompare`** — **`commonProfiles`**: names present in **both** files. Summary cards compare peak IOPS and min latency winners per profile. Each group tab only includes profiles in `commonProfiles`. Compare chart draws use `deferredCmp` after DOM insert.

## Standard single (`renderSingle`)

- Rebuilds tab bar to five tabs; clears System B legend labels; draws single-series charts on the default canvas IDs.

## Charting

- **`drawChart(id, datasets, opts)`** — Canvas sizing, grid, line/scatter. Used by both default and profile layouts.

## Resize

- Window resize triggers a **click** on **Generate** to redraw charts (same as re-running the report).

## Footer / version

- Page title and subtitle reference **v4.0** and universal modes; release detail is in **`RELEASE.md`**.
