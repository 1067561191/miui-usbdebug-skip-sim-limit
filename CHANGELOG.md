# Changelog

本项目所有值得注意的变更都记录在此。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.0.0] - 2025-10-25

### Added

- 首个可用版本：Zygisk 模块，绕过 MIUI/HyperOS「USB调试（安全设置）」的
  插 SIM 卡限制。
- 在 `system_server` 的 `postServerSpecialize` 阶段写入
  `persist.security.adbinput=1`，并刷新 `cache_key.package_info`
  使 `PermissionInvalidatedCache` 失效。
- 支持 `arm64-v8a`、`armeabi-v7a`、`x86`、`x86_64` 四个 ABI。
- `build.sh`：直接调用 NDK clang 构建 + Python `zipfile` 打包，
  不依赖 Gradle 或系统 `zip` 命令。
- `customize.sh`：安装时校验 MIUI/HyperOS 与 Zygisk 状态，并按设备 ABI
  裁剪多余的 `.so`。
- `abi_stub.cpp`：最小 `__cxa_guard_*` 实现，避免链入完整 `libc++abi`。

### Notes

- 已在 Redmi M2012K11AC（`alioth`）、Android 13、MIUI V816、
  Magisk 30.7、Zygisk API v5 上实测通过。
- 服务端校验（`srv.sec.miui.com/data/adb`）未被绕过，也刻意未 hook
  `com.android.settings`。因此**手动点击开发者选项中的该开关**仍会失败并把
  属性写回 `0`；功能本身不受影响，重启即恢复。

[Unreleased]: https://github.com/1067561191/miui-usbdebug-skip-sim-limit/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/1067561191/miui-usbdebug-skip-sim-limit/releases/tag/v1.0.0
