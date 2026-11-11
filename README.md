# Lightwhale VPS Install

[Lightwhale](https://lightwhale.asklandd.dk/) is a simple docker-focused OS with a few interesting features making it a good, simple base OS for use with docker / docker swarm.

This guide covers a simple approach for installing the OS to disk (with a focus being VPSs where this may be required).

## Requirements

- An x86-64 server supporting either native UEFI boot or legacy BIOS / CSM boot
- A live/rescue Linux environment (ie. [SystemRescue](https://www.system-rescue.org/Download/) or whatever your VPS provides) and console access
- A disk named `/dev/sdX`, `/dev/nvme…`, or `/dev/mmcblk…`. Note: Paravirtualized disks like `/dev/vda` are not yet supported

## 1. Boot into rescue mode

Boot a **live image or emergency recovery OS** from your VPS control panel. If an installer opens, close it / navigate to a command prompt.

## 2. Run the installer

The installer detects whether the rescue environment booted in native UEFI or legacy BIOS / CSM mode and sets up the matching boot layout. The installed server must boot in that same mode. It erases the entire selected disk.

```bash
curl -O https://raw.githubusercontent.com/MatthewScholefield/lightwhale-vps-install/main/install.sh
sudo bash install.sh
```

Once finished, after a restart you should see the lightwhale login prompt and can login via `op` / `opsecret`.

## Update Lightwhale

Back up important data first. The updater can run **in place on the running Lightwhale system** or from a rescue environment, and works with either boot mode because both layouts use the same `LWBOOT` partition. The data partition is not modified.

The new ISO is downloaded directly onto `LWBOOT` (not into `/var/tmp`/RAM), validated, and only then is GRUB switched to it. The old ISO stays active until that switch and is removed afterwards, so a failed or interrupted update keeps booting the old version. `LWBOOT` needs room for two ISOs at once.

```bash
curl -o update-lightwhale.sh https://raw.githubusercontent.com/MatthewScholefield/lightwhale-vps-install/main/update-lightwhale.sh
sudo bash update-lightwhale.sh https://lightwhale.asklandd.dk/download/lightwhale-latest-x86.iso
```

After it reports success, reboot. If the update fails before the GRUB switch, the existing ISO remains the active boot target.

Options (before the URL):

- `--force`: replace a destination ISO that already exists but is not active, or re-install an identical active ISO.
- `--low-space`: for an `LWBOOT` too small for two ISOs. The download and a backup of the current ISO go to `/var/tmp` (needs RAM/disk for both), the old ISO is removed, then the new one is copied. Less safe against power loss in the middle of the copy.


*Suggested next steps:*
 1. **Change passowrd:** Change password via `passwd`
    - NOTE: This is particularly important because unless your VPS has a firewall, by default Lightwhale exposes SSH with password auth
 3. **Install SSH public key:** Install your local key via `ssh-copy-id op@<public-ip>` and entering the password you just assigned. You can get your public IP in the VPS console or `curl http://ipinfo.io`
 4. **Harden SSH:** Set `PasswordAuthentication no` and optionally choose a custom random port for SSH via `Port 12345` within `/etc/ssh/sshd_config`. Reload via `/etc/init.d/S50sshd reload`. Update your `~/.ssh/config` with this port or specify it via `ssh op@<public-ip> -p 12345`
 5. **Customize Hostname:** `sudo setup-hostname my-server-name`
