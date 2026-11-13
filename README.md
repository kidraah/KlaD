# KlaD

**Kernel Block & Logical Allocation Debugger** — a free, open-source storage analyzer for macOS
that tells you where your SSD went, with sizes that are actually true on APFS.

It looks and behaves like an app that came with your Mac: native sidebar, toolbar, search,
inspector and Settings, system colors, and it follows Light/Dark mode and your accent color.

## Three promises

1. **No Full Disk Access, ever.** KlaD works fully without it.
2. **Protected and system data is never touched.** Mail, Messages, Safari, browser profiles,
   other apps' containers, iOS backups, the Photos library, the sealed macOS volume and system
   folders are never opened — not even listed — whether or not access was granted. Their space is
   accounted for from APFS's own volume totals, the same numbers System Settings › Storage uses.
3. **Nothing is deleted without proof and your OK.** KlaD can only move items *inside your home
   folder* to the Trash, only when a rule proves they're regeneratable (or you confirm a review),
   after re-checking identity, ownership, system flags, open files and running apps. All rules live in one file:
   [`Sources/Models/SystemPolicy.swift`](Sources/Models/SystemPolicy.swift).

## Why APFS needs a different kind of size

| Metric | Source | Meaning |
|---|---|---|
| Logical | `ATTR_FILE_TOTALSIZE` | What the file says it holds (a sparse VM disk can claim 1 TB). |
| Size on disk | `ATTR_FILE_ALLOCSIZE` | Physical blocks allocated. |
| Freed if deleted | `ATTR_CMNEXT_PRIVATESIZE` | Blocks not shared with APFS clones, snapshots or hard links (asked only for files APFS flags as sharing blocks). |
| In iCloud only | `SF_DATALESS` | Placeholders: 0 B on disk. Never opened or downloaded (enforced by the kernel I/O policy). |

Real example: a `uv` cache of 4.48 GB frees only 2.87 GB, because uv clones its files.

## What it does

- **Overview** — sunburst or heat-map treemap (sections, bold labels, real icons), Finder-style table and path bar.
  `getattrlistbulk(2)` scanning at ~350 000 items/s; a 2.5 M-item home folder in ~7 s, the whole disk in ~9 s.
- **Macintosh HD** — your user areas scanned; macOS, Preboot, Recovery, VM, Software Update and
  "System Data & Protected" sized by APFS, so the whole disk adds up without opening system data.
- **Recommendations** — Safe to Clear (node_modules + lockfile, Rust `target/`, `.venv`, DerivedData,
  package caches…), Review First (model weights, archives), and guided commands for Docker, VMs and snapshots.
- **Duplicates** — byte-identical files ≥ 1 MB (iCloud-only files never opened; APFS clones aren't waste).
- **History** — every scan saved; what changed between scans; live updates via FSEvents.

## Build

Command Line Tools are enough — no Xcode needed.

```sh
make app          # release build → build/KlaD.app (ad-hoc signed, inside-out, no --deep)
make run          # build + open
make test         # 141 Swift Testing tests
make probe        # headless scanner: .build/release/klad-probe scan ~ | verify <dir> | volume /
```

## Layout

```
Sources/Models/      contracts, SystemPolicy (what may be read / modified)
Sources/Scanner/     getattrlistbulk engine, firmlink/mount guard, APFS volume accounting
Sources/Services/    Intelligence (rules, classification, git) ·
                     StorageOps (history, duplicates, safe cleanup, FSEvents)
Sources/UI/, App/    native SwiftUI app
Tests/KlaDTests/     Core · Intelligence · StorageOps
```

MIT License.
