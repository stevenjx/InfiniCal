# InfiniCal

English · [简体中文](README.md)

A macOS battery tool by Infinity Computer: **measure the battery's real health**, and control charging and cooling.

The “Maximum Capacity” macOS shows is a long-running estimate from the fuel-gauge firmware. InfiniCal runs one
controlled full cycle (charge → deep discharge → recharge → rest → settle) and integrates current over time, so the
capacity it reports is the charge that actually moved through the pack — plus real health, coulombic efficiency and
DC internal resistance. Fan and charge control talk to the SMC directly. Every number comes from this Mac's
IORegistry, SMC and IOHID — **nothing is estimated or invented**: when a value cannot be read, the UI shows `--`
and says why.

---

## Features

### Battery calibration

| Phase | Action | Completion |
| --- | --- | --- |
| 1 Pre-charge | Raise the ceiling to 100% | ≥ 100% and current ≤ 0.05 A |
| 2 Controlled discharge | Discharge to 5/10/15/20%, optionally with a CPU load | Level ≤ target |
| 3 Recharge | Charge back to full | ≥ 100% and current < 0.15 A |
| 4 Rest | Hold at full | 10 minutes |
| 5 Settle | Discharge to the storage level (80% by default) | Level ≤ storage level |

- **Coulomb counting** — trapezoidal `∫I dt`, 25 mA deadband, samples spanning more than 5 s are dropped entirely
- **True capacity** — `discharged energy ÷ (start level − end level)`, in Wh and mAh
- **Coulombic efficiency** — `discharged Ah ÷ recharged Ah`
- **DCIR** — current step ≥ 1 A with an opposing voltage response, median then EWMA, bounded to 10–600 mΩ
- **Health** — 65% measured this session, 35% firmware prior, older sessions weighted by `exp(-0.35·n)`
- **Cell balance** — per-group voltages and ΔV

A TXT report and a full CSV telemetry log are written to `~/Library/Application Support/InfiniCal/Reports/`.

### Fan control

Fans are discovered at runtime (`FNum`), on Apple Silicon and Intel alike.

| Mode | Behaviour |
| --- | --- |
| Automatic | Clears the forced bit; the SMC firmware takes over |
| Custom | Fixed RPM from a slider (50 RPM steps) |
| Full speed | Target = `F{n}Mx` |
| Temperature curve | Three anchors — start / mid / peak — piecewise linear; changes under 1 °C are ignored and RPM moves at most 150 per second |

Every temperature reading is labelled with its source: CPU (IOHID `PMU tdie*`, falling back to SMC
`Tp01/Tp05/Tp09/Tp0D`), battery (`TB0T`), SSD (`NAND`), GPU (`Tg0B/Tg0C/Tg0H/TG0V`, only when the key exists).

### Charging

Charge limit, allowing limits below 80%, automatic discharge, sailing mode and overheat protection. The control key
is probed at runtime: `BCLM` (ceiling) or `CHIE` (inhibit) on Apple Silicon, `CH0B`/`CH0C` on Intel/T2.

- **Top up** is a one-shot override: the ceiling goes to 100%, then the previous limit returns once the pack is
  full and unplugged, or after four hours.
- **Top up by time**: keep the normal ceiling all day and start charging just early enough to be full on time,
  using the remaining energy and the measured charge rate.
- **Adapter diagnosis**: rated / input / system / battery / headroom / conversion loss, and an explicit warning
  when the adapter cannot cover the load and the battery is discharging.

### Menu bar and notifications

The app runs as an accessory, so the menu bar is the way back in after closing the window: charge level, state,
temperature, fans, adapter, plus top up / pause / set 80% / fans automatic.

Notifications cover: charge limit reached, full, overheat protection on and off, top-up complete. Each event has a
cooldown, so nothing fires every two seconds.

### History

Daily energy in and out, temperature range, time on AC and health, kept for 400 days, with 7 / 30-day views.
The calibration history sheet adds trend lines for health, measured capacity and DC resistance across sessions.

### Sleep & energy

- Charging is inhibited before sleep according to your setting and re-evaluated on wake.
- “Disable sleep entirely” holds an `IOPMAssertion`, and decides separately whether the display may sleep.
- “Lock screen when lid closes” polls `IOPMrootDomain.AppleClamshellState`.
- With “Update dashboard in background” off, the 2 Hz power sampling and chart history stop while the window is
  not frontmost.

---

## Data sources

| Field | Source | Conversion |
| --- | --- | --- |
| Charge level | `AppleSmartBattery.CurrentCapacity`, `AppleSmartBatteryPack.StateOfCharge` | — |
| Max capacity | `BatteryData.AppleRawMaxCapacity` (fallback `FullChargeCapacity`) | mAh |
| Design capacity | `BatteryData.DesignCapacity` | mAh |
| Cycle count | `CycleCount` | — |
| Voltage / current / power | `Voltage`, `Amperage`, `InstantAmperage` | mV→V, mA→A |
| Battery temperature | SMC `TB0T` (`flt`) | °C |
| Adapter | `AdapterDetails` | mV→V |
| Fan RPM | SMC `F{n}Ac` (`flt`) | RPM |
| Live power | SMC `PSTR` / `PDTR`, 5 Hz | W |

`TimeRemaining` is stuck at `65535` on some models, so runtime is computed as `stored Wh ÷ current draw W`.

---

## Build

```bash
./build.sh                 # → build/InfiniCal.app (arm64 + x86_64 universal)
open build/InfiniCal.app
```

Requires Xcode 16 or newer (or just the Command Line Tools with a Swift 6 toolchain). You can also
`open InfiniCal.xcodeproj`.

The project file is generated by `Tools/generate_xcodeproj.py`; **rerun it after adding or removing a `.swift` file**.

Debug arguments:

```bash
build/InfiniCal.app/Contents/MacOS/InfiniCal --panel fanControl   # open a panel directly
build/InfiniCal.app/Contents/MacOS/InfiniCal --menubar            # open the menu bar popover
```

Panels: `dashboard`, `chargeControl`, `calibration`, `fanControl`, `sleep`, `history`, `schedule`, `other`.

---

## Localisation

The interface follows the system language, switching between Simplified Chinese and English. Chinese is the source
language; English lives in `Resources/en.json` and missing keys fall back to Chinese. Interpolated strings use
`{p}` placeholders so a translation can reorder them.

---

## Permissions

Writing the SMC requires **root**. The app itself is read-only; every write goes through a privileged daemon:

- Installed once with an administrator prompt to `/Library/PrivilegedHelperTools/com.infinitycomputer.infinical.helper`
- Talks over a Unix socket at `/var/run/com.infinitycomputer.infinical.helper.sock`, owned by the installing user, mode 0600
- Accepts only whitelisted commands (ping / info / read / write / socpower / exec); `exec` only runs whitelisted binaries

On quit, fan modes are written back to `F{n}Md = 0` and an unfinished calibration releases its charge inhibit.

---

## Layout

```
InfiniCal/
├── InfiniCal.xcodeproj/             Xcode project
├── Tools/generate_xcodeproj.py      Project generator
├── Sources/
│   ├── Core/                        SMC, telemetry, calibration, history, notifications, sleep, localisation
│   ├── UI/                          Dashboard, panels, power flow, charts, menu bar
│   └── main.swift
├── Helper/main.swift                root daemon
├── Resources/                       Info.plist, icon, en.json
└── build.sh
```

---

## Requirements

- macOS 12.0 Monterey or later, universal binary for Intel and Apple Silicon
- Fanless models hide the fan controls and keep the temperature readings
- Verified fan writes on MacBookPro19,1; Intel models take the `FS!` fallback path

---

## Licence

Copyright © 2026 Infinity Computer. All rights reserved.

The interface takes cues from AlDente Pro's public design; all code and assets are independent. No third-party
libraries are used.
