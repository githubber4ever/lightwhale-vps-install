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
curl -o install-bios.sh https://raw.githubusercontent.com/MatthewScholefield/lightwhale-vps-install/main/install-bios.sh
sudo bash install-bios.sh
```

Run the rescue environment itself in UEFI mode. Legacy BIOS / CSM boot is not supported.

Once finished, after a restart you should see the lightwhale login prompt and can login via `op` / `opsecret`.

## Update Lightwhale

Boot the VPS into its UEFI rescue environment and back up important data first. The updater stages and validates the new ISO before atomically switching GRUB to it; until that switch, the current ISO remains the active boot target. On success, the old ISO is removed. The data partition is not modified. `LWBOOT` needs enough free space to stage the new ISO alongside the current one.

```bash
curl -o update-lightwhale.sh https://raw.githubusercontent.com/MatthewScholefield/lightwhale-vps-install/main/update-lightwhale.sh
sudo bash update-lightwhale.sh https://lightwhale.asklandd.dk/download/lightwhale-3.0.6-x86.iso
```

After it reports success, reboot from the normal disk. If the update fails before the GRUB switch, the existing ISO remains the active boot target.

*Suggested next steps:*
 1. **Change passowrd:** Change password via `passwd`
    - NOTE: This is particularly important because unless your VPS has a firewall, by default Lightwhale exposes SSH with password auth
 3. **Install SSH public key:** Install your local key via `ssh-copy-id op@<public-ip>` and entering the password you just assigned. You can get your public IP in the VPS console or `curl http://ipinfo.io`
 4. **Harden SSH:** Set `PasswordAuthentication no` and optionally choose a custom random port for SSH via `Port 12345` within `/etc/ssh/sshd_config`. Reload via `/etc/init.d/S50sshd reload`. Update your `~/.ssh/config` with this port or specify it via `ssh op@<public-ip> -p 12345`
 5. **Customize Hostname:** `sudo setup-hostname my-server-name`
