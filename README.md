# PVE8-9

Proxmox VE 8 to 9 upgrade helper for operators who want a guided, auditable command-line flow while still following the official Proxmox upgrade process.

This repository is intentionally small: one Bash helper, documentation, and CI syntax/lint checks. The helper does not try to hide the upgrade behind unsafe automation. It keeps `apt dist-upgrade` interactive so package configuration prompts can be reviewed deliberately.

## Current Guidance

Last reviewed: 2026-05-19.

Primary references:

- [Official Proxmox VE 8 to 9 upgrade guide](https://pve.proxmox.com/wiki/Upgrade_from_8_to_9)
- [Proxmox VE package repository documentation](https://pve.proxmox.com/pve-docs/pve-package-repos-plain.html)
- [Proxmox VE 9.1 release announcement](https://www.proxmox.com/en/about/company-details/press-releases/proxmox-virtual-environment-9-1)
- [Debian 13 Trixie release notes](https://www.debian.org/releases/trixie/)

The official upgrade path is:

1. Upgrade each node to the latest Proxmox VE 8.4 packages.
2. Run `pve8to9 --full` and resolve blocking issues.
3. Move Debian and Proxmox repositories from Bookworm to Trixie using current deb822 `.sources` files.
4. Run `apt dist-upgrade`.
5. Run `pve8to9 --full` again.
6. Reboot into the Proxmox VE 9 kernel and verify the host.

## What This Helper Does

- Checks that it is running as root on a Proxmox VE host.
- Verifies free root filesystem space.
- Warns when running over SSH without `tmux` or `screen`.
- Requires backup and console-access confirmation.
- Detects clusters and reminds you to upgrade one node at a time.
- Checks local Ceph version when Ceph is installed.
- Runs the official `pve8to9 --full` checker before and after the upgrade.
- Backs up current APT source files under `/root`.
- Rewrites only official Debian repository suites from Bookworm to Trixie.
- Disables third-party Bookworm repositories unless you choose to stop and review them manually.
- Disables backports repositories, including deb822 `.sources` files.
- Writes Proxmox VE 9 repository files in deb822 format.
- Supports either `enterprise` or `no-subscription` Proxmox repositories.
- Supports Ceph Squid `enterprise`, `no-subscription`, `auto`, or `none` repository handling.
- Leaves `apt dist-upgrade` interactive.
- Logs actions to `/var/log/pve8to9-upgrade-helper.log`.

## What This Helper Does Not Do

- It does not patch out Proxmox subscription UI notices.
- It does not force no-subscription repositories over enterprise repositories.
- It does not run the main distribution upgrade with `DEBIAN_FRONTEND=noninteractive`.
- It does not promise a zero-touch production upgrade.
- It does not replace the official `pve8to9` checker or Proxmox documentation.
- It does not automatically rewrite third-party repositories to Trixie.

## Requirements

- Proxmox VE 8.x host, with 8.4.x required before repository migration.
- Root shell.
- Reliable network access.
- At least 5 GiB free on `/`, ideally more than 10 GiB.
- Console, IPMI, iKVM, physical access, or an SSH session protected by `tmux`/`screen`.
- Tested backups of all guests and host configuration.
- For hyper-converged Ceph, Ceph Squid 19.2 before the Proxmox VE 9 upgrade.

## Usage

Download and run the helper from your fork:

```bash
wget https://raw.githubusercontent.com/willadamskeane/PVE8-9/main/ProxmoxVE8to9.sh
chmod +x ProxmoxVE8to9.sh
sudo ./ProxmoxVE8to9.sh --check-only
sudo ./ProxmoxVE8to9.sh --pve-repo enterprise --ceph-repo enterprise
```

For a no-subscription lab or home host:

```bash
sudo ./ProxmoxVE8to9.sh --pve-repo no-subscription --ceph-repo auto
```

For SSH-based work, use a terminal multiplexer:

```bash
tmux new -s pve8to9
sudo ./ProxmoxVE8to9.sh --pve-repo enterprise --ceph-repo auto
```

Show all options:

```bash
sudo ./ProxmoxVE8to9.sh --help
```

## Recommended Manual Preflight

Before using any helper script, run:

```bash
apt update
apt dist-upgrade
pveversion
pve8to9 --full
```

The `pveversion` output should show Proxmox VE 8.4.x before the repository migration. Resolve warnings from `pve8to9 --full` before continuing.

For clusters:

```bash
pvecm status
```

Drain or migrate workloads away from the node being upgraded where needed. Upgrade nodes one at a time.

For Ceph:

```bash
ceph --version
```

Do not start the Proxmox VE 9 upgrade until hyper-converged Ceph is on Squid 19.2.

## Post-Upgrade Verification

After the upgrade and reboot:

```bash
uname -r
pveversion
pve8to9 --full
systemctl status pve-cluster pvedaemon pveproxy
qm list
pct list
journalctl -p warning..alert -b
```

Clear or hard-refresh the browser cache before using the web UI after the upgrade.

## Known Issues to Review

Read the official known issues before running an in-place upgrade. Pay particular attention to:

- `linux-image-amd64` conflicts on Debian-installed hosts.
- `systemd-boot` meta-package behavior on PVE-managed boot setups.
- UEFI + LVM GRUB boot handling.
- cgroup v1 removal for old containers.
- NVIDIA vGPU driver compatibility.
- Veeam limitations with QEMU machine version 10.0 or newer.
- PCI passthrough behavior with newer kernels.
- Backports and third-party repositories.
- Third-party storage plugins.

## Development

Local checks:

```bash
bash -n ProxmoxVE8to9.sh
bash tests/run.sh
```

CI runs ShellCheck and the regression test suite on pull requests and pushes.

## License

MIT. See [LICENSE](LICENSE).
