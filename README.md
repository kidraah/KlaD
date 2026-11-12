# KlaD

**APFS storage intelligence, developer purge & visual disk analyzer.** Free and open source. macOS 14+, Swift 6.

KlaD answers *"where did my SSD go?"* with numbers that are actually true on APFS — and only ever
recommends deleting things it can **prove** are regeneratable.

## Why another disk analyzer?

On APFS a single "size" lies:

| Metric | Source | Meaning |
|---|---|---|
| **Logical** | `ATTR_FILE_TOTALSIZE` | What the file says it contains (sparse VM disks: 1 TB). |
| **Allocated** | `ATTR_FILE_ALLOCSIZE` | Physical blocks on the SSD. |
| **Reclaimable** | `ATTR_CMNEXT_PRIVATESIZE` | Blocks **not** shared with an APFS clone, snapshot or hard link — what deleting frees *immediately*. |
| **iCloud** | `SF_DATALESS` | Placeholders: logical size in iCloud, 0 B on disk. **Never opened, read or hashed.** |

Example from a real scan: a `uv` cache shows *2.87 GB reclaimable of 4.48 GB allocated* — uv clones
files, so a naive cleaner would over-promise by 1.6 GB.

## Features

- **Bulk BSD scanner** — `getattrlistbulk(2)` on a dedicated thread pool: ~140 k items/s
  (2.5 M items of a home folder in ~20 s), byte-exact against `du`. Firmlink/volume-group aware,
  never crosses mount points or autofs triggers, counts hard links once, and engages
  `IOPOL_MATERIALIZE_DATALESS_FILES_OFF` so the kernel itself refuses to download iCloud files.
- **Explore** — LoD-culled **Sunburst** (5 rings, arcs < 0.46° merged) and squarified **Treemap**
  (tiles < 6 × 6 pt merged) on `Canvas`, cached geometry, O(log n) hover hit-testing, animated
  polar / affine zoom; synced tree-table and an APFS telemetry inspector.
- **Save Space** — evidence-first safety tiers:
  - *Safe · Regeneratable* only with positive proof (`node_modules` + `package.json` + lockfile,
    `target/` + `Cargo.toml`, `.venv` + `pyvenv.cfg` + pinned spec, DerivedData, package caches…);
  - *Review First* for model weights, archives, generic `build/`;
  - *Managed by Tool* for Docker/OrbStack/VM disks and local snapshots — KlaD shows the right
    command (`docker system df`, `tmutil thinlocalsnapshots`…) and **never** trashes the file.
  Git state and inactivity are shown as badges, never as proof. Duplicate finder: size → edge hash →
  SHA-256, skipping placeholders and treating APFS clones as one copy.
- **Pre-flight before every deletion** — identity (inode/device) re-check, protected-path guard,
  open-file scan via libproc (500 ms budget), related-app check; deletion is **only**
  `FileManager.trashItem` — never `removeItem`.
- **History** — every scan is stored as a compact SQLite snapshot; *"Where did my space go?"* diffs
  surface the deepest folders that actually grew. FSEvents marks changed subtrees dirty and rescans
  them in the background.
- **Volume truth** — Used vs *Purgeable* vs *Free now*, plus the APFS container breakdown
  (Preboot, VM, Recovery, Update volumes — the usual "System Data" suspects).

## Build

Command Line Tools are enough (no Xcode required).

```sh
make app          # release build → build/KlaD.app (ad-hoc signed, inside-out, no --deep)
make run          # build + open
make scan-home    # build + open + scan ~
make test         # 115 Swift Testing tests (wraps CLT test-framework paths)
make probe        # headless scanner: .build/release/klad-probe scan ~ | verify <dir> | volume /
```

For complete results grant **Full Disk Access** (System Settings → Privacy & Security). Ad-hoc
signatures change on every rebuild, which resets privacy grants — sign with a stable identity:
`make app SIGN_ID="Apple Development: …"`.

## Layout

```
Sources/Models/      frozen data contracts + service protocols
Sources/Scanner/     getattrlistbulk engine, firmlink/mount guard, volume inspector
Sources/Services/    Intelligence (rules, classification, git) · StorageOps (SQLite history,
                     duplicates, safe cleanup, FSEvents)
Sources/UI/, App/    SwiftUI shell, Canvas visualizers, AppState
Sources/Probe/       klad-probe CLI
Tests/KlaDTests/    Core · Intelligence · StorageOps
```


