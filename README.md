# CPUthermal-L

CPU thermal management plugin for iOS 18, handling CPU heat/power limits through `thermalmonitord` and SpringBoard separately.

## 2.0 Improvements

- No longer writes user-provided MHz directly as the ThermalMonitor power value.
- Record system nominal power baseline during startup; when thermal control is lifted, clamp new CPU limits to 75% / 90% / 100%.
- Covers Objective-C controllers, IOKit property writes, and the Darwin thermal notify path on iOS 18.
- Handle SpringBoard `SBThermalController` and `SBThermalAlwaysOnPolicy` to prevent high-temperature auto-dimming while preserving normal manual brightness control.
- Low-power mode and thermal-release mode are completely separate; high-frequency targets only appear in thermal-release mode.
- Default extreme-temperature fallback enabled at 78°C with 5°C hysteresis.
- Settings take effect immediately and provide diagnostics for hook count, temperature, and fallback status.
- Settings page bottom samples IOReport once per second, displaying real-time average frequency estimates for performance and efficiency cores.
- Automatically migrates common settings from old CPUthermal and Insulation packages.

## Build

GitHub Actions uses macOS with Theos to build rootless `arm64 + arm64e` DEB:

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

Before installing the new package, remove older CPUthermal/Insulation packages that also inject into `thermalmonitord` to avoid multiple hooks overriding each other. This package has declared the corresponding conflict.
