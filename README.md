# 🌕 luatools-moon-secure

Hardened fork of `luatools-moon` featuring account isolation and an automatic security gatekeeper for SteamOS / Steam Deck.

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
> **Want Steam theme support?** Use the [`millennium` branch](https://github.com/swwayps/luatools-moon/tree/millennium).

---

Linux port of the `ltsteamplugin` plugin, built exclusively for the [slsteam-moon](https://github.com/swwayps/slsteam-moon) project. It serves as an integration layer that fetches manifest packs and installs them for slsteam-moon to consume natively on Linux.

## Credits

Upstream:

- [piqseu](https://github.com/piqseu/ltsteamplugin) — the `ltsteamplugin`
  release line this fork tracks. Originally by
  [madoiscool](https://github.com/madoiscool/ltsteamplugin).

Reference material:

- [StarWarsK & geovanygrdt](https://github.com/Star123451/LuaToolsLinux) —
  prior Linux port.
- [Millennium](https://github.com/SteamClientHomebrew/Millennium) —
  Steam client modding framework.
- [CloudRedirect](https://github.com/Selectively11/CloudRedirect) by
  Selectively11 — optional cloud saves for unowned games.

## Support

Open an issue: https://github.com/swwayps/luatools-moon/issues

## Uninstall

Want to remove everything? Run:

```bash
curl -fsSL https://raw.githubusercontent.com/thejako/luatools-moon-secure/main/uninstall.sh | bash
```
