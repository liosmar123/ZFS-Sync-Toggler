# ZFS Sync Toggler 💿

Interactive Bash helper to **toggle the ZFS `sync` property** with a clean TUI, icons, logs, and environment hints (Proxmox / TrueNAS).

> ⚠️ **Data safety note**  
> Setting `sync=disabled` can reduce SSD wear, but **may lose the last seconds of data** on sudden power loss. Use only where you accept that risk.

---

## Features

- 🧭 Environment detection: **Proxmox**, **TrueNAS SCALE/CORE**, generic Linux.
- 🫧 Pool & 🧩 dataset discovery with **interactive selection**.
- 🧪 **Dry-run mode**: preview actions without changing anything.
- 🗒️ Logging to `/var/log/zfs-sync-toggle.log`.
- ↩️ **Revert** easily to `sync=standard`.
- 🎯 Suggestions: guesses relevant pools/datasets per environment.
- ✍️ Regex selection (grep -E) for bulk dataset targeting.

---

## Quick Start

```bash
sudo install -m 0755 zfs-sync-toggler.sh /usr/local/sbin/zfs-sync-toggler.sh
sudo /usr/local/sbin/zfs-sync-toggler.sh
