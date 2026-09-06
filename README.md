# 🌕 luatools-moon-secure

Hardened fork of [`luatools-moon`](https://github.com/swwayps/luatools-moon) featuring account isolation and an automatic security gatekeeper for SteamOS / Steam Deck.

## Overview

This project is a security-focused fork of [`luatools-moon`](https://github.com/swwayps/luatools-moon) (the Linux port of `ltsteamplugin` built for [slsteam-moon](https://github.com/swwayps/slsteam-moon)). While upstream provides manifest downloading and native Linux integration, **luatools-moon-secure** adds essential protection layers for multi-account systems:

- 🛡️ **Account Isolation**: Binds the modded stack (SLSsteam, Lumen, LuaTools) exclusively to a designated secondary Steam account.
- 🚪 **Automatic Security Gatekeeper**: Wraps Steam in both Gaming Mode and Desktop Mode. It checks `loginusers.vdf` on launch:
  - **Authorized account**: Launches full modded environment with SLSsteam, Lumen, and CloudRedirect.
  - **Main / unauthorized account**: Launches **100% clean official Steam** — unhooks `LD_AUDIT` (`SLSsteam.so`), unhooks `LD_PRELOAD` (`cloud_redirect.so`), terminates sidecar processes, and hides the `stplug-in` directory so unowned manifest games are never visible to your main account.
- 👁️ **Session Watcher Daemon**: A lightweight background monitor (`gatekeeper-watcher.sh`) that detects account switching on the fly and immediately enforces clean state if you switch to your main account without restarting Steam.

## Install

Set up slsteam-moon, Lumen and the secure LuaTools stack:

```bash
curl -fsSL https://raw.githubusercontent.com/thejako/luatools-moon-secure/main/install.sh | bash
```

Or clone the repository and run:

```bash
git clone https://github.com/thejako/luatools-moon-secure.git
cd luatools-moon-secure
bash install.sh
```

> **Requirements:** Linux x86_64 and **native Steam** installed from your package
> manager. Flatpak and Snap Steam are not supported.
>
> **Want Steam theme support?** Use upstream's [`millennium` branch](https://github.com/swwayps/luatools-moon/tree/millennium).

---

## Credits

Direct Upstream:

- [swwayps](https://github.com/swwayps/luatools-moon) — creator of `luatools-moon` (the native Linux port of `ltsteamplugin` built for [slsteam-moon](https://github.com/swwayps/slsteam-moon) and [Lumen](https://github.com/swwayps/lumen)), which serves as the direct base for this fork.

Upstream Lineage:

- [piqseu](https://github.com/piqseu/ltsteamplugin) — the `ltsteamplugin`
  release line tracked by `luatools-moon`.
- [madoiscool](https://github.com/madoiscool/ltsteamplugin) — original creator of `ltsteamplugin`.

Reference Material & Ecosystem:

- [StarWarsK & geovanygrdt](https://github.com/Star123451/LuaToolsLinux) —
  prior Linux port.
- [Millennium](https://github.com/SteamClientHomebrew/Millennium) —
  Steam client modding framework.
- [CloudRedirect](https://github.com/Selectively11/CloudRedirect) by
  Selectively11 — optional cloud saves for unowned games.

## Support & Troubleshooting

- **Issues with this fork, gatekeeper, or installer**: [Open an issue on GitHub](https://github.com/thejako/luatools-moon-secure/issues)
- **Upstream issues**: If you encounter issues with the base plugin or manifest handling, refer to [swwayps/luatools-moon issues](https://github.com/swwayps/luatools-moon/issues)
- **Diagnostics**: If you need to generate a privacy-scrubbed diagnostic log bundle when requesting help:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/thejako/luatools-moon-secure/main/diagnose.sh | bash
  ```

## Cloud Saves (CloudRedirect)

[CloudRedirect](https://github.com/Selectively11/CloudRedirect) enables cloud save synchronization for added/unowned games by redirecting Steam Cloud calls to your personal cloud provider (**OneDrive** or **Google Drive**).

During `install.sh`, if you enable CloudRedirect, the installer will ask if you also want to install the **CloudRedirect companion app (Flatpak)**.
* **If you select YES**: The installer automatically deploys the Steam hook (`cloud_redirect.so`), installs the companion Flatpak app, and configures sandbox filesystem permissions so credentials sync seamlessly with Steam.
* **If you select NO**: Only the core Steam hook (`cloud_redirect.so`) is deployed. To connect your cloud provider (OneDrive / Google Drive), you can install and configure the companion app manually at any time.

### Manual Installation of the CloudRedirect Companion App

If you chose not to install the companion app during setup, or need to reinstall it, run these commands in your terminal (Konsole on Steam Deck):

```bash
# 1. Ensure Flathub is added as a user remote
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# 2. Install the KDE Platform runtime required by the app (~400 MB)
flatpak install --user -y flathub org.kde.Platform//6.10

# 3. Download the official Flatpak bundle from GitHub releases
curl -fL -o /tmp/cloudredirect.flatpak "https://github.com/Selectively11/CloudRedirect/releases/download/v2.6.5/cloudredirect.flatpak"

# 4. Install the Flatpak bundle
flatpak install --user -y --bundle /tmp/cloudredirect.flatpak

# 5. Grant filesystem access so the Flatpak app shares ~/.config/CloudRedirect with Steam (prevents sync errors)
flatpak override --user --filesystem=xdg-config/CloudRedirect org.cloudredirect.CloudRedirect

# 6. Clean up temporary download
rm -f /tmp/cloudredirect.flatpak
```

### Configuring OneDrive / Google Drive

1. Open the application from the desktop Application Menu or run:
   ```bash
   flatpak run org.cloudredirect.CloudRedirect
   ```
2. In the app, navigate to the **Cloud Provider** tab.
3. Select **OneDrive** (or Google Drive) from the dropdown.
4. Click **Sign In**. Your browser will open the Microsoft authentication page.
5. Log in with your Microsoft account and grant the requested permissions.
6. Once signed in, the application will save your credentials to `~/.config/CloudRedirect/config.json`.
7. Launch Steam. The CloudRedirect hook will load automatically and sync your saves with OneDrive.

### Troubleshooting Sync Errors

* **"Steam Cloud Error" on game launch/exit**:
  * Verify that `DisableCloud` is set to `no` in `~/.config/SLSsteam/config.yaml`:
    ```bash
    grep "DisableCloud" ~/.config/SLSsteam/config.yaml
    ```
    If it is set to `yes`, change it to `no`.
  * Ensure the Flatpak override is active so Steam and the app use the same config:
    ```bash
    flatpak override --user --filesystem=xdg-config/CloudRedirect org.cloudredirect.CloudRedirect
    ```
* **Inspect logs**:
  ```bash
  tail -n 50 ~/.config/CloudRedirect/cloud_redirect.log
  tail -n 50 ~/.config/CloudRedirect/cr_debug.log
  ```

## Test & Verify Installation

Verify that all components (Steam environment, SLSsteam, Lumen, LuaTools plugin, Security Gatekeeper, and Account Isolation) are installed and functioning properly:

```bash
curl -fsSL https://raw.githubusercontent.com/thejako/luatools-moon-secure/main/check-install.sh | bash
```

Or if you have the repository cloned:

```bash
bash check-install.sh
```

## Uninstall

Completely remove the full stack (slsteam-moon, Lumen, LuaTools plugin, Security Gatekeeper, and CloudRedirect), restoring Steam to its original clean state:

```bash
curl -fsSL https://raw.githubusercontent.com/thejako/luatools-moon-secure/main/uninstall.sh | bash
```

Or if you have the repository cloned:

```bash
bash uninstall.sh
```
