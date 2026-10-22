# Lightwhale VPS Install

[Lightwhale](https://lightwhale.asklandd.dk/) is a simple docker-focused OS with a few interesting features making it a good, simple base OS for use with docker / docker swarm.

This guide covers a simple approach for installing the OS to disk (with a focus being VPSs where this may be required).

## Requirements

- An x86-64 server supporting native UEFI boot
- A live/rescue Linux environment (ie. [SystemRescue](https://www.system-rescue.org/Download/) or whatever your VPS provides) and console access
- A disk named `/dev/sdX`, `/dev/nvme…`, or `/dev/mmcblk…`. Note: Paravirtualized disks like `/dev/vda` are not yet supported

## 1. Boot into rescue mode

Boot a **live image or emergency recovery OS** from your VPS control panel. If an installer opens, close it / navigate to a command prompt.

## 2. Run the installer

```bash
curl -o install-uefi.sh https://raw.githubusercontent.com/MatthewScholefield/lightwhale-vps-install/main/install-uefi.sh
sudo bash install-uefi.sh
```

Run the rescue environment itself in UEFI mode. Legacy BIOS / CSM boot is not supported.

Once finished, after a restart you should see the lightwhale login prompt and can login via `op` / `opsecret`.

## Update Lightwhale

Boot the VPS into its UEFI rescue environment and back up important data first. The updater downloads and validates the new ISO in `/var/tmp`, then temporarily backs up the current ISO there before replacing it on `LWBOOT`. The data partition is not modified. `/var/tmp` needs space for the download and the previous ISO; `LWBOOT` needs space for the new ISO after the old one is removed. These filesystems must be separate.

```bash
curl -o update-lightwhale.sh https://raw.githubusercontent.com/MatthewScholefield/lightwhale-vps-install/main/update-lightwhale.sh
sudo bash update-lightwhale.sh https://lightwhale.asklandd.dk/download/lightwhale-3.0.6-x86.iso
```

After it reports success, reboot from the normal disk. If the update fails before the GRUB switch, the existing ISO remains the active boot target.

If the destination filename already exists on `LWBOOT` but is not the active ISO, pass `--force` before the URL to replace it. The updater backs up that file in `/var/tmp` for rollback.

By default, the updater removes the old active ISO before copying the new one to `LWBOOT`, minimizing boot-partition space usage. Pass `--atomic` to keep the old ISO active while the new one is copied and verified, then switch GRUB and remove the old ISO. This mode requires temporary room for both images on `LWBOOT`. The flags may be combined in either order.

```bash
sudo bash update-lightwhale.sh --atomic https://lightwhale.asklandd.dk/download/lightwhale-3.0.6-x86.iso
```

*Suggested next steps:*
 1. **Change passowrd:** Change password via `passwd`
    - NOTE: This is particularly important because unless your VPS has a firewall, by default Lightwhale exposes SSH with password auth
 3. **Install SSH public key:** Install your local key via `ssh-copy-id op@<public-ip>` and entering the password you just assigned. You can get your public IP in the VPS console or `curl http://ipinfo.io`
 4. **Harden SSH:** Set `PasswordAuthentication no` and optionally choose a custom random port for SSH via `Port 12345` within `/etc/ssh/sshd_config`. Reload via `/etc/init.d/S50sshd reload`. Update your `~/.ssh/config` with this port or specify it via `ssh op@<public-ip> -p 12345`
 5. **Customize Hostname:** `sudo setup-hostname my-server-name`
