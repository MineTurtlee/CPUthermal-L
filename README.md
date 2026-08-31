# CPUthermal-L

面向 iOS 18 的 CPU 温控管理插件，针对 `thermalmonitord` 与 SpringBoard 分别处理 CPU 热功耗限制和屏幕热调暗。

## 2.0 改进

- 不再把用户输入的 MHz 直接作为 ThermalMonitor 的功耗值写入。
- 启动阶段记录系统名义功耗基线，解除温控时按 75% / 90% / 100% 钳制新的 CPU 限制。
- 同时覆盖 Objective-C 控制器、IOKit 属性写入和 Darwin thermal notify 三条 iOS 18 路径。
- 在 SpringBoard 中处理 `SBThermalController` 与 `SBThermalAlwaysOnPolicy`，阻止高温自动调暗但保留正常手动亮度调节。
- 低功耗模式与解除温控模式完全分离；高频目标只在解除温控模式显示。
- 默认启用 78°C 极端温度回退，带 5°C 恢复迟滞。
- 设置即时生效，并提供 Hook 数量、温度和回退状态诊断。
- 自动迁移旧 CPUthermal 与 insulation 的常用设置。

## 构建

GitHub Actions 使用 macOS 与 Theos 构建 rootless `arm64 + arm64e` DEB：

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

安装新包前应移除会同时注入 `thermalmonitord` 的旧 CPUthermal/insulation 包，避免多个 Hook 相互覆盖。本包已声明对应冲突关系。
