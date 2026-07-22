<div align="center">

<img src="assets/icon-1024.png" width="120" alt="DontSleepMac icon" />

# DontSleepMac

**A one-click menu-bar toggle to keep your Mac awake.**

<img src="assets/hero.png" width="720" alt="DontSleepMac in the menu bar" />

</div>

---

## Why

Your Mac sleeps mid-task, and things break:

- 🤖 **Coding agents** drop their connection when the display sleeps.
- 🖥️ **Local servers & builds** pause the moment you step away.
- 📥 **Long downloads / uploads** stall on the lock screen.
- 📊 **Dashboards** on a wall screen go dark.
- 🎬 **Screen shares & recordings** freeze.
- ⏳ **A 2-hour render** you're babysitting — asleep at minute 11.

## Two modes

Right-click the menu-bar eye and pick one:

| Icon | Mode | What it does |
|------|------|--------------|
| ⚪ grey | **Off** | Normal — your Mac sleeps as usual |
| 🔴 red | **Keep display on** | Screen stays awake |
| 🟠 amber | **Display off, stay awake** | Screen turns off, but your work keeps running |

The icon always reflects the **real** state — if anything else is keeping your Mac awake, it shows that too.

No admin password. No background daemon. Uses Apple's built-in `caffeinate`.

## Install

**Requirements:** macOS 13+ and Xcode command-line tools (`xcode-select --install`).

```bash
git clone https://github.com/seeknull/DontSleepMac.git
cd DontSleepMac
./install.sh
```

That builds it and puts it in **/Applications**. Launch it any time:

> **Cmd + Space → "Don't Sleep"**

## Data & privacy

**Zero data is collected. No network calls are made.** The app only runs Apple's built-in `caffeinate` and reads local power state via `pmset`. Nothing leaves your Mac. [Read the source](main.swift) — it's one small file.

## Uninstall

Quit it (right-click → Quit), then delete `/Applications/DontSleepMac.app`. Nothing else is left behind.

## License

[MIT](LICENSE) © seeknull
