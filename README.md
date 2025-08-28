# ZFS Sync Toggler 🛠

## Quick Run

Copy and paste to run directly (no installation required):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liosmar123/ZFS-Sync-Toggler/main/zfs-sync-toggler.sh)"
```

## Overview

Interactive Bash script to **toggle the ZFS `sync` property** with a clean menu, pool status check, and environment hints (Proxmox / TrueNAS Community / Linux).  

⚠️ **Warning**  
Setting `sync=disabled` reduces SSD wear and improves performance, but **you may lose the last few seconds of data** if the system loses power unexpectedly. Use only where this trade-off is acceptable.

## Features

- 🧭 **Environment detection**: Proxmox, TrueNAS Community (Linux base), generic Linux.  
- 🫧 **Pool status with check marks**:  
  - ✅ `sync=disabled`  
  - ❌ not disabled  
- 📋 **Interactive menu** with spacing and intuitive icons.  
- 🧪 **Dry-run mode**: preview actions without changing anything.  
- ↩️ **Revert support**: easily return to `sync=standard`.  
- 🗒️ **Logs**: all actions recorded in `/var/log/zfs-sync-toggle.log`.  
- 🔎 **Regex dataset selection** (via grep -E) for fine-grained control.  

## Example Menu

```
 Main menu
──────────────────────────────────────────────
 1) 🚫  Disable sync           sets sync=disabled · less writes (risk on power loss)
 2) ↩️  Revert to standard     sets sync=standard
 3) ℹ️   Show pools & datasets  includes pool sync status
 4) 🧭  Environment suggestions
 0) 🚪  Exit
```

Pools are displayed with their current sync status:

```
 Pools (root dataset sync status)
──────────────────────────────────────────────
  1)  ✅  tank        (sync=disabled)
  2)  ❌  nvme1       (sync=standard)
```

## Manual Installation

Download once and keep it in your PATH:

```bash
curl -fsSL -o /usr/local/sbin/zfs-sync-toggler.sh   https://raw.githubusercontent.com/liosmar123/ZFS-Sync-Toggler/main/zfs-sync-toggler.sh
chmod +x /usr/local/sbin/zfs-sync-toggler.sh
```

Run with:

```bash
zfs-sync-toggler.sh
```

## When should I use `sync=disabled`?

- 💨 Reduce unnecessary write amplification on SSDs.  
- 🖥️ For **test VMs**, scratch datasets, or non-critical shares.  
- 🧪 When you accept potential loss of very recent writes if power fails.  

If data safety is critical, consider adding a **dedicated SLOG device** instead.

## License

MIT License. See [LICENSE](LICENSE).
