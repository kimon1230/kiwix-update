# Kiwix Update Script

This bash script automates the management and updating of ZIM files for Kiwix offline content servers. I developed it to handle my personal Kiwix deployment where manually tracking updates across dozens of educational content collections had become impractical.

The script provides intelligent update detection, automated downloads, and library management while maintaining the integrity of existing Kiwix installations.

## Overview

The script interfaces with the Kiwix library catalog to identify available updates, compares them against local collections, and selectively downloads newer versions. It handles the complexities of ZIM file versioning and naming conventions that have evolved over time, ensuring compatibility across different content types and publishers.

Key capabilities include differential update detection, robust download management with resume support, and automated library synchronization.

## Dependencies

Required system packages:
```bash
sudo apt update
sudo apt install aria2 kiwix-tools curl coreutils
```

The script requires root privileges for system file management and service control.

## Installation

Download and prepare the script:
```bash
wget https://raw.githubusercontent.com/kimon1230/kiwix-update/main/kiwix-update.sh
chmod +x kiwix-update.sh
```

Default file locations (configurable by editing script variables):
- ZIM files: `/var/local/zims/`
- Library XML: `/var/local/library_zim.xml`
- Working directories: `/var/local/zims/{temp,backups}/`

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
-s:[LETTER]          Filter by filename prefix
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

# Subject-specific updates (e.g., Wikipedia collections)
sudo ./kiwix-update.sh smart-update -s:w
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

Uses aria2c for multi-connection downloads with automatic retry logic. Downloads are verified against remote checksums before replacing existing files. Temporary files are isolated to prevent corruption of active collections.

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
- Library XML parsing uses grep/awk for compatibility
- Download verification through HTTP header analysis
- Atomic file operations prevent corruption during updates

## License

This project is released under the MIT License. See LICENSE file for full terms.

## Contributing

Contributions are welcome. Please test thoroughly on non-production systems before submitting changes. The script is designed for educational and institutional use cases.

## Acknowledgments

Built for the Kiwix ecosystem (kiwix.org) and OpenZIM project (openzim.org). Uses aria2 for reliable content delivery.
