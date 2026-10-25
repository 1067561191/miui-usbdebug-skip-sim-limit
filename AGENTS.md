# AGENTS.md

本文件面向在本仓库工作的自动化 Agent 与贡献者，说明项目约定、构建方式、
验证流程与不可逾越的红线。人类贡献者请先读 [README.md](README.md) /
[README.zh-CN.md](README.zh-CN.md)。

---

## 1. 项目是什么

一个 **Magisk / Zygisk 模块**（纯 Native，无 Java），用于绕过 MIUI/HyperOS
「USB调试（安全设置）」的插 SIM 卡限制，使 `uid=2000`（`com.android.shell`）
获得 `INJECT_EVENTS` 等 14 项受管控权限。

技术核心只有两件事，在 `system_server` 的 `postServerSpecialize` 阶段执行：

1. `persist.security.adbinput = 1`
2. `cache_key.package_info = <单调递增时间戳>`（使 `PermissionInvalidatedCache` 失效）

不 hook Java、不改系统文件、不做 ART/ClassLoader 操作。

---

## 2. 目录职责

| 路径 | 职责 | 是否可手改 |
|---|---|---|
| `module/src/main/cpp/module.cpp` | bypass 主逻辑 | ✅ 主要开发位置 |
| `module/src/main/cpp/abi_stub.cpp` | 最小 `__cxa_guard_*` 实现 | ⚠️ 谨慎，见 §5 |
| `module/src/main/cpp/api.hpp` | Zygisk API 头文件（上游同步） | ❌ 不要手改，见 §5 |
| `module/build.sh` | NDK 构建 + 打包 | ✅ |
| `module/template/update-binary` | Magisk 安装引导 | ❌ 上游原样 |
| `module/template/customize.sh` | 安装校验、ABI 裁剪 | ✅ |
| `module/build/` | 产物 | ❌ 已 gitignore |
| `work/` | 本地逆向工作区（APK/jadx/日志） | ❌ 已 gitignore，**绝不提交** |

---

## 3. 构建

```bash
cd module
./build.sh          # 全 ABI 构建 + 打包 zip
./build.sh abi      # 只编译 .so
```

前置：Android NDK（`$ANDROID_HOME/ndk/<ver>`）+ Python 3。

- **不要**引入 Gradle / AGP 构建链。当前方案是直接调用 NDK clang，规避 AGP
  与 JDK 版本耦合。
- **不要**假设系统有 `zip` 命令（Windows 常见缺失），打包走 Python `zipfile`。
- 编译器路径必须用 **Windows 风格绝对路径**（`cygpath -m`），MSYS 风格
  `/d/...` 会被 clang 拒绝。
- MSYS Bash 下调用 `adb` 时注意路径转换，必要时 `export MSYS2_ARG_CONV_EXCL="*"`。

### 关键编译标志

```
-std=c++17 -fno-exceptions -fno-rtti
-fvisibility=hidden -fvisibility-inlines-hidden
-shared -fPIC -O2
-llog -static-libgcc
```

**必须保留 `-fno-exceptions -fno-rtti`**：`system_server` 侧不保证有完整的
C++ 运行时，引入异常/RTTI 会拖进大量 `libc++abi` 依赖，导致 `dlopen` 失败。

---

## 4. 验证流程（改代码后必须做）

**不要只看编译通过就交付。** 按顺序验证：

### 4.1 静态检查

```bash
NDK=$ANDROID_HOME/ndk/<ver>
READELF="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe"

# 必须导出 zygisk_module_entry
"$READELF" --dyn-syms module/build/arm64-v8a/arm64-v8a.so | grep zygisk_module_entry

# 未定义符号只允许 libc / liblog（不允许 __cxa_guard_*、cxxabi 符号）
"$READELF" --dyn-syms module/build/arm64-v8a/arm64-v8a.so | grep UND

# 各 ABI 的 Class/Machine 必须正确
"$READELF" -h module/build/arm64-v8a/arm64-v8a.so | grep -E "Class|Machine"
```

### 4.2 设备验证

```bash
adb push module/build/miui_adbinput_bypass-*.zip /data/local/tmp/
adb shell "su -c 'magisk --install-module /data/local/tmp/miui_adbinput_bypass-*.zip'"
adb reboot
# 等待 sys.boot_completed=1 后再等约 20s，等 system_server 稳定

adb shell su -c "logcat -d -s MiuiAdbInputBypass:*"   # 必须看到 bypass done
adb shell getprop persist.security.adbinput            # 必须为 1

# 功能验证（注意：不要加 su）
adb shell input tap 300 1200
adb shell settings put global adb_enabled 1
```

**判定标准**：上述命令退出码 0，且 **不出现**
`SecurityException: ... INJECT_EVENTS permission`。

### 4.3 反向验证（回归保护）

证明修改确实必要时，可做对照实验：

```bash
# 强制缓存失效且 prop=0 → 必须失败
adb shell su -c "setprop persist.security.adbinput 0; setprop cache_key.package_info $(date +%s%N)"
adb shell input tap 300 1200      # 期望 SecurityException

# prop=1 且缓存失效 → 必须成功
adb shell su -c "setprop persist.security.adbinput 1; setprop cache_key.package_info $(date +%s%N)"
adb shell input tap 300 1200      # 期望 exit 0
```

> ⚠️ 在 `su`/Magisk 域下 `setprop cache_key.package_info` 会**失败**
> （`binder_cache_system_server_prop` 仅 `system_server` 域可写），
> 报 `Failed to set property`。这是预期行为，不是 bug —— 也正是本模块必须
> 运行在 `system_server` 内的原因。做对照实验时请用 reboot 代替手写该属性。

---

## 5. 红线（不要做）

1. **不要手改 `api.hpp`。** 它是 Magisk 上游
   `native/src/core/zygisk/api.hpp` 的同步副本，当前 **API v5**。
   升级方式：从上游重新取文件覆盖，并核对 `ZYGISK_API_VERSION`。
   历史上该头文件叫 `zygisk.hpp`，已更名 —— 不要回退到旧名/旧版本。

2. **不要删除 `abi_stub.cpp`。** 删掉后 `dlopen` 会失败。
   `REGISTER_ZYGISK_MODULE` 内部的非平凡 static 会引用
   `__cxa_guard_acquire/release`，而 `app_process64` 不链接 `libc++abi`。
   若新增了需要 `__cxa_*` 的代码，在 `abi_stub.cpp` 里补最小实现，
   **不要**改成链接整套 `libc++_static.a`（会引入大量无关依赖和体积）。

3. **不要提交 `work/`**（约 1 GB 的 APK 解包/jadx 产物），也不要提交
   `module/build/`。已在 `.gitignore` 中排除。

4. **不要引入 system 文件替换。** 不做 `system/` 目录挂载、不改
   `services.jar` / `Settings.apk`。本模块是纯属性变更，必须保持这一点，
   否则会破坏 AVB/dm-verity 的可回滚性。

5. **不要把权限授予范围扩大到 shell 之外。** 目标固定为 `uid=2000`。
   任何「顺便给其它 App 也放行」的改动一律拒绝。

6. **不要为了 UI 观感去 hook `com.android.settings`。** 已在 README 说明理由：
   收益纯观感、代价是多一个 LSPosed 依赖并绑定特定 `Settings.apk` 版本。
   如需实现，必须是**独立可选模块**，不得并入本模块。

7. **不要在代码里硬编码设备型号/ROM 版本判断后「针对某台机特判」。**
   平台差异请通过能力探测（属性是否存在、`setprop` 返回值）处理。

---

## 6. 代码风格

- C++17，无异常、无 RTTI。
- 命名：常量 `kPascalCase`（如 `kPropAdbInput`），函数 `camelCase`，
  成员变量 `snake_case_`。
- 日志宏统一 `LOGI/LOGW/LOGE`，TAG 固定 `MiuiAdbInputBypass`。
- 所有 `__system_property_set` 调用**必须检查返回值并记录失败**，
  否则 SELinux 拒绝时会静默失败，极难排查。
- 写入属性前先读旧值，已是目标值时跳过写入（幂等 + 减少日志噪音）。
- 注释解释「为什么」，不要复述「是什么」。涉及逆向结论的注释要写明来源
  （类名 + 方法名），便于后人复核。

---

## 7. 提交规范

Conventional Commits：

```
feat:     新功能
fix:      修复
docs:     文档
build:    构建脚本 / 依赖
refactor: 重构（不改行为）
chore:    杂项
```

要求：

- 一个提交只做一件事。
- 涉及行为变更必须**同时**更新 `CHANGELOG.md` 的 `[Unreleased]` 段。
- 涉及机制/限制的变更必须同步更新 `README.md` **和** `README.zh-CN.md`
  （两份内容需保持一致，不要只改一个）。
- 提交前跑一遍 §4.1 静态检查。

---

## 8. 排查经验（踩过的坑）

| 坑 | 结论 |
|---|---|
| 只设 `persist.security.adbinput=1` 不生效 | `PermissionManager` 有 `PropertyInvalidatedCache`，必须同时刷新 `cache_key.package_info` |
| 从 `su` 写 `cache_key.package_info` 失败 | SELinux：`binder_cache_system_server_prop` 仅 `system_server` 域可写 |
| `dlopen` 失败 / 未解析 `__cxa_guard_*` | 缺 `abi_stub.cpp`；或误删了 `-fno-exceptions/-fno-rtti` |
| 编译时 `no such file` 指向 `/d/...` | MSYS 路径未转 Windows 风格，需 `cygpath -m` |
| `-static-libstdc++` 报 unused | clang 驱动不认该参数，NDK 下应显式链 `.a` 或提供 stub |
| 安装日志说「Zygisk 未启用」但实际可用 | `ZYGISK_ENABLED` 环境变量只在开机脚本阶段存在，安装阶段拿不到；改用探测 `/proc/<system_server>/maps` 或 `zygisksu` 目录 |
| 手动点开发者选项的开关后失效 | 该开关在「已开启」时点击走关闭分支，会把属性写回 0；重启恢复 |
| `input tap` 成功但界面没反应 | 坐标错误，不是权限问题。用 `uiautomator dump` 取真实 bounds |

---

## 9. 兼容性说明

- 已验证：Android 13 / MIUI V816 / `alioth` / arm64-v8a / Magisk 30.7 / Zygisk API v5。
- 未验证：HyperOS 2.x、Android 14+、其它 OEM。
- 平台差异点集中在三处，适配时优先检查：
  1. `persist.security.adbinput` 是否仍是同一属性名；
  2. `cache_key.package_info` 是否仍是权限缓存的失效键；
  3. 对应 SELinux 域是否仍允许 `system_server` 写上述属性。
- 若属性名变化，应通过**探测多个候选键**实现兼容，而不是按机型分支。

---

## 10. 法务与授权

本仓库仅用于**自有设备的开发调试与逆向研究**。使用者必须对自己设备的
root、模块安装及由此产生的一切后果负责。详见 [LICENSE](LICENSE)。
