# Kiwix Update Script

This bash script automates the management and updating of ZIM files for Kiwix offline content servers. I developed it to handle my personal Kiwix deployment where manually tracking updates across dozens of educational content collections had become impractical.

The script provides intelligent update detection, automated downloads, and library management while maintaining the integrity of existing Kiwix installations.

## Overview

The script interfaces with the Kiwix library catalog to identify available updates, compares them against local collections, and selectively downloads newer versions. It handles the complexities of ZIM file versioning and naming conventions that have evolved over time, ensuring compatibility across different content types and publishers.

Key capabilities include differential update detection, robust download management with resumable downloads, and automated library synchronization.

## Dependencies

Required system packages:
```bash
sudo apt update
sudo apt install aria2 kiwix-tools curl coreutils
```

The script runs as **root** by default (managing the `kiwix-serve` service and
files under `/var/local`), but also supports an **unprivileged mode** for a
single user running against a directory they own — see [Run modes](#run-modes).

## Installation

Download and prepare the script:
```bash
wget https://raw.githubusercontent.com/kimon1230/kiwix-update/main/kiwix-update.sh
chmod +x kiwix-update.sh
```

Default file locations (override with the environment variables below):
- ZIM files: `/var/local/zims/`
- Library XML: `/var/local/library_zim.xml`
- Working directories: `/var/local/zims/{temp,backups}/`

| Variable | Purpose | Default |
|---|---|---|
| `KIWIX_WORK_DIR` | Directory holding the ZIM files and state | `/var/local/zims` |
| `KIWIX_ZIM_LIBRARY` | Path to `library_zim.xml` | `/var/local/library_zim.xml` (root mode); `$KIWIX_WORK_DIR/library_zim.xml` (unprivileged mode) |

**Permissions prerequisite (security):** the working directory and every parent
must be owned by root and not group/other-writable. On stock Debian `/var/local`
is `2775 root:staff` (group-writable), so the script will refuse to run until you
either tighten it (`sudo chmod g-w /var/local`) or point `KIWIX_WORK_DIR` at a
root-owned path such as `/var/lib/kiwix`. This prevents a non-root user from
pre-planting directories or symlinks that root would otherwise act on.

## Run modes

The script picks a mode automatically from the effective UID — there is no flag:

- **Root mode** (`euid == 0`): the behavior described throughout this README —
  manages the `kiwix-serve` service, chowns the library to `root:root`, and
  defaults to `/var/local`. `KIWIX_WORK_DIR` and all its ancestors must be
  root-owned and not group/other-writable.

- **Unprivileged mode** (any non-root user): for a single user updating ZIMs in a
  directory they own (e.g. `KIWIX_WORK_DIR=$HOME/zims`). It performs no `chown`
  and does not touch the service. The trust gate still applies, generalized:
  `KIWIX_WORK_DIR` and its ancestors must be owned by **that user or root** and
  not group/other-writable — so keep the directory out of world-writable paths
  such as `/tmp`. Because it can't manage the service, **`kiwix-serve` must be
  stopped first**: the script refuses to run a `smart-update`/`update-library`
  while a `kiwix-serve` process is detected (or while it can't check, e.g. no
  `pidof`/`pgrep`), unless you pass an explicit `-y` (then it warns and proceeds).
  This override requires `-y` specifically: `-b` (background) alone does **not**
  disarm the guard — an unattended run fails closed rather than risk corrupting a
  served collection — so use `-b -y` if you intend to override it in background.

```bash
# Unprivileged: update ZIMs under your home directory, no root needed
KIWIX_WORK_DIR=$HOME/zims ./kiwix-update.sh smart-update
```

Notes and limits:
- A non-root run against the default root-owned `/var/local` fails with a clear
  permission error rather than silently downgrading — set `KIWIX_WORK_DIR` to a
  directory you own to use unprivileged mode.
- The threat model is **peer users, not root**. Trust checks are
  ownership/permission based only (no ACL or NFS awareness) and assume a **local
  filesystem**.
- Under `sudo`, pass `-E` (or set the `KIWIX_*` vars in the sudo environment) if
  you need your `KIWIX_WORK_DIR`/`KIWIX_ZIM_LIBRARY` overrides to survive.

## Usage

### Primary Commands

```bash
# Analyze available updates
sudo ./kiwix-update.sh check-updates

# Execute selective updates
sudo ./kiwix-update.sh smart-update

# Synchronize library with filesystem
sudo ./kiwix-update.sh update-library

# Monitor running processes
sudo ./kiwix-update.sh status
```

### Configuration Options

```bash
-y                   Non-interactive mode
-b                   Background execution
-q                   Suppress output
-v                   Verbose logging
-c                   Continue on errors
-p:[NUM]             Parallel connections (1-50)
-m:[SPEED]           Bandwidth limit (e.g., -m:5M)
-u:[CRITERIA]        Update criteria (size|newer|all)
--allow-unverified   Permit installs when no SHA-256 metalink is available,
                     falling back to size-only verification against the
                     authoritative catalog size (default: OFF — a missing hash
                     blocks the download). Size-only verification requires that
                     authoritative catalog size; when neither a SHA-256 metalink
                     nor a catalog size is available the download is refused (a
                     mirror-reported size is not accepted — it is circular).
--https-only         Force HTTPS-only for the .zim download even when a
                     SHA-256 hash is present (default: OFF — an HTTP mirror
                     hop is permitted and verified by the hash)
```

### Update Criteria

The script supports three update determination methods:

- **size**: Update when remote file is larger than local version
- **newer**: Update when remote file has more recent timestamp
- **all**: Update when either size or date criteria indicate newer content (default)

### Practical Examples

```bash
# Conservative updates (size-based only)
sudo ./kiwix-update.sh check-updates -u:size

# Automated background processing
sudo ./kiwix-update.sh smart-update -b -y

# Bandwidth-limited updates
sudo ./kiwix-update.sh smart-update -m:2M -p:3
```

## Implementation Details

### Update Logic

The script fetches the current Kiwix library catalog and performs content analysis against local files. It accounts for publisher naming convention changes and handles version transitions intelligently.

File matching includes special handling for:
- Legacy naming schemes (e.g., `_maxi` suffix variations)
- Publisher reorganizations (TED content restructuring)
- Date-versioned releases
- Content type migrations

### Service Integration

During updates, the script:
1. Verifies Kiwix service status
2. Creates library backup
3. Temporarily stops service if running
4. Performs downloads and verification
5. Updates library configuration
6. Restarts service if previously active

### Download Management

Uses aria2c for multi-connection downloads with automatic retry logic. Each download is verified against the **SHA-256 hash published in the Kiwix `.meta4` metalink** before it replaces an existing file; a mismatch (or, by default, a missing hash) blocks the install.

The catalog and metalink metadata are always fetched over **HTTPS from the `kiwix.org` domain** (the catalog uses the OPDS v2 endpoint `catalog/v2/entries`; the `.meta4` is served directly by the load balancer), so the hash is authoritative. The bulk `.zim` transfer itself is delivered via `lb.download.kiwix.org`, which redirects to a **rotating pool of mirrors** — some of which are HTTP-only. Because the SHA-256 hash is the integrity control, an HTTP mirror hop is permitted **on the default path** (a tampered mirror is caught after download). If you would rather refuse HTTP mirrors outright, pass `--https-only` (downloads may then fail on HTTP-mirror days). When `--allow-unverified` drops the hash gate, transport is automatically forced HTTPS-only regardless — without a hash, transport is the only remaining control. Temporary files are isolated to prevent corruption of active collections.

## Monitoring and Logging

All operations are logged to `/var/local/zims/kiwix_update.log` with structured timestamps and severity levels. Background processes maintain status files for monitoring:

```bash
# Real-time log monitoring
sudo tail -f /var/local/zims/kiwix_update.log

# Process status checking
sudo ./kiwix-update.sh status
```

## Troubleshooting

### Common Issues

**Silent execution failure:**
Typically indicates missing dependencies or directory permissions. Verify all required packages are installed and directories exist with appropriate permissions.

**Network timeout errors:**
Adjust timeout values or reduce parallel connections for unstable connections. The script includes automatic retry mechanisms for transient failures.

**Disk space limitations:**
Pre-flight space checking prevents partial downloads, but ensure adequate free space for largest expected files (Wikipedia collections can exceed 100GB).

**Service restart failures:**
Manual service management may be required if automatic restart fails:
```bash
sudo systemctl restart kiwix-serve
```

### Debug Mode

Enable verbose output for troubleshooting:
```bash
sudo ./kiwix-update.sh check-updates -v
```

## Operational Considerations

For institutional deployments, consider:

- **Scheduling**: Use cron for regular automated updates
- **Bandwidth management**: Implement rate limiting during business hours
- **Storage planning**: Monitor disk usage trends for capacity planning
- **Service continuity**: Schedule updates during low-usage periods

### Recommended Workflow

```bash
# Weekly update assessment
sudo ./kiwix-update.sh check-updates -u:all

# Scheduled overnight updates
sudo ./kiwix-update.sh smart-update -b -y -m:5M
```

## File Organization

```
/var/local/zims/
├── [content].zim                # ZIM content files
├── temp/                        # Download staging area
├── backups/                     # Library configuration backups
├── kiwix_update.log             # Operation log
├── .kiwix_update_status         # Process status
└── .kiwix_library_cache         # Cached catalog data
```

## Technical Notes

- Requires bash 4.0+ with standard POSIX utilities
- Tested on Debian/Ubuntu systems (Raspberry Pi OS, Ubuntu Server)
- Library and catalog parsing use bash regex, grep, and awk for compatibility (OPDS v2 catalog: `catalog/v2/entries`)
- Download integrity verified via SHA-256 from the Kiwix metalink (metadata is HTTPS-only from kiwix.org; the hash gates the bulk transfer, so rotating HTTP mirrors are permitted by default — override with `--https-only`)
- Atomic (intra-filesystem) rename on install prevents corruption during updates

## License

This project is released under the MIT License. See LICENSE file for full terms.

## Contributing

Contributions are welcome. Please test thoroughly on non-production systems before submitting changes. The script is designed for educational and institutional use cases.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, how to run the test suites, the ShellCheck gate, and the conventions for writing tests and preserving the root/unprivileged run-mode invariant.

## Acknowledgments

Built for the Kiwix ecosystem (kiwix.org) and OpenZIM project (openzim.org). Uses aria2 for reliable content delivery.
