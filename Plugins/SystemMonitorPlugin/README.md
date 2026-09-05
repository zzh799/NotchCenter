# System Monitor

System load blocks for the drawer grid: CPU, memory, disk, network, and an all-in-one overview. All five block types come from this single plugin and share one sampling engine.

## Blocks

- **CPU** — overall utilization with a trend sparkline (2×1) or load bar (1×1).
- **Memory** — used fraction (Activity Monitor basis); color follows the kernel memory-pressure level instead of fixed thresholds.
- **Disk** — read/write throughput aggregated across all physical drives (IOKit).
- **Network** — down/up throughput aggregated across non-virtual interfaces (loopback and virtual prefixes excluded by default).
- **System Overview** — 2×2 all-in-one cell; resize to 4×2/4×3/4×4 for a horizontal row.

## Per-instance settings

Each placed block can be configured separately from its edit-mode gear:

- History window: 30 s / 1 min / 2 min / 5 min.
- Elevated (yellow) / high (red) thresholds for CPU, disk and network.
- Rate unit: auto, KB/s, MB/s or GB/s (disk and network).
- Network interface exclusion prefixes (e.g. remove `utun` to watch VPN traffic).
- Overview: which metrics to include (cannot be all hidden).

## Sampling & power

Sampling runs only while at least one block is placed. The drawer open refreshes every 2 s; when it collapses the engine drops to 10 s so history stays continuous, and stops entirely when the last block is removed or the plugin is disabled.

## Data sources

Public APIs only: Mach host statistics (CPU/memory), `getifaddrs` counters (network), IOKit `IOBlockStorageDriver` statistics (disk). No private frameworks, no extra dependencies.
