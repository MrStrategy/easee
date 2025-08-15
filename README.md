# Easee FHEM Module

## Overview
This repository provides the `98_EaseeWallbox` module for the [FHEM](https://fhem.de) home automation system.  The module connects FHEM with the Easee Cloud so that an Easee charging station can be monitored and controlled.  All communication takes place via the public Easee cloud API; therefore the charger must be online for commands to work.

## Installation
Copy `98_EaseeWallbox.pm` into your FHEM installation (usually in the `FHEM/` directory) and reload FHEM.  After the reload the module can be defined like any other FHEM device.

## Definition
```
define <name> EaseeWallbox <username> <password> [<interval>] [<chargerID>]
```
- **interval** – optional polling interval in seconds (default `60`, minimum `5`).
- **chargerID** – optional charger identifier if more than one charger is registered for the account.

## Set commands
The module implements numerous commands for controlling the charger:
- `activateTimer` / `deactivateTimer` – start or stop the periodic refresh of readings.
- `startCharging` / `stopCharging` – start or stop charging when authorisation is required.
- `pauseCharging` / `resumeCharging` – temporarily pause or resume the current charging session.
- `enabled` / `disabled` – enable or disable the charger.
- `enableSmartButton <true|false>` – enable or disable the smart button.
- `authorizationRequired <true|false>` – require authorisation before charging starts.
- `cableLock <true|false>` – permanently lock or unlock the charging cable.
- `enableSmartCharging <true|false>` – switch smart charging on or off.
- `ledStripBrightness <0‑100>` – set LED strip brightness.
- `dynamicCurrent <p1> <p2> <p3> [ttl]` – set the dynamic current limit for each phase with an optional time‑to‑live.
- `pairRfidTag [timeout]` – start RFID pairing (default `60` seconds).
- `pricePerKWH <price>` – set the price per kWh (EUR, VAT 19 %).
- `refreshToken` – refresh the OAuth token.
- `reboot` – reboot the charger.
- `updateFirmware` – trigger a firmware update.
- `overrideChargingSchedule` – override the configured charging schedule.

## Get commands
- `get <name> update` – refresh all data immediately.
- `get <name> charger` – reload basic charger information.

## Attributes
- `interval` – polling interval in seconds (default `60`).
- `SmartCharging <true|false>` – automatically enable smart charging.

## Readings
The module exposes a wide range of readings, including:
- **Basic information** – `charger_id`, `charger_name`, `site_id`, `site_key`, `circuit_id`.
- **Charger configuration** – `isEnabled`, `isCablePermanentlyLocked`, `isAuthorizationRequired`, `isRemoteStartRequired`, `isSmartButtonEnabled`, `isLocalAuthorizationRequired`, `wiFiSSID`, `phaseModeId`, `phaseMode`, `maxChargerCurrent`, `ledStripBrightness`.
- **Site configuration** – `cost_perKWh`, `cost_perKwhExcludeVat`, `cost_vat`, `cost_currency`.
- **Charger state** – `operationModeCode`, `operationMode`, `online`, `power`, `current`, `dynamicCurrent`, `kWhInSession`, `latestPulse`, `reasonCodeForNoCurrent`, `reasonForNoCurrent`, `errorCode`, `fatalErrorCode`, `lifetimeEnergy`, `voltage`, `wifi_rssi`, `wifi_apEnabled`, `cell_rssi`.
- **Current session** – `session_energy`, `session_start`, `session_end`, `session_chargeDurationInSeconds`, `session_firstEnergyTransfer`, `session_lastEnergyTransfer`, `session_pricePerKWH`, `session_chargingCost`, `session_id`.
- **Dynamic current** – `dynamicCurrent_phase1`, `dynamicCurrent_phase2`, `dynamicCurrent_phase3`.
- **Historic consumption** – `daily_1_consumption` … `daily_7_consumption`, `daily_1_cost` … `daily_7_cost`.

## License
This module is distributed under the same license as FHEM itself.  Use at your own risk.
