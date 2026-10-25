# MIUI ADB Input Bypass

[![Magisk](https://img.shields.io/badge/Magisk-≥24.0-00AF9C?logo=magisk)](https://github.com/topjohnwu/Magisk)
[![Zygisk API](https://img.shields.io/badge/Zygisk%20API-v5-blue)](https://github.com/topjohnwu/Magisk/blob/master/docs/guides.md#zygisk)
[![Android](https://img.shields.io/badge/Android-13%2B-3DDC84?logo=android)](https://www.android.com)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

简体中文 | [English](README.md)

一个 Magisk/Zygisk 模块，用于去掉 MIUI/HyperOS 开发者选项里
**「USB 调试（安全设置）」** 的插卡限制 —— 也就是那个要求你先插入 SIM 卡
才允许 `adb` 模拟点击、修改权限的开关。

安装后，开机即生效，直接 `adb shell input tap` / `keyevent` / `settings put`
就能用，**完全不需要操作任何界面**。

---

## 问题背景

MIUI/HyperOS 开发者选项里有一个开关：

> **USB调试（安全设置）** —— *允许通过USB调试修改权限或模拟点击*

不插 SIM 卡就无法开启。确认向导最后会走一次服务器校验，然后弹出提示：

```
W/AdbInstallActivity: response: {"status":"-1","message":"请先插入SIM卡"}
W/AdbInstallActivity: server result: 请先插入SIM卡
```

对于没有插卡的试验机来说，这直接堵死了 `input` / `pm grant` / `settings put`
一整套工作流。

---

## 真实机制（逆向结论）

「需要插卡」**并不是**真正的执行机制。在 Android 13（MIUI V816）上，从
`Settings.apk`、`miui-services.jar`、`framework.jar` 逆向出三层彼此独立的实现：

### 第 1 层 —— UI 向导

`com.miui.securitycenter/.permcenter.install.AdbInputApplyActivity`
三页警告文案，带 5 秒倒计时，走完后启动 `AdbInstallVerifyActivity`。

### 第 2 层 —— 服务端校验

`AdbInstallVerifyActivity$b.doInBackground` 会 POST 到
`https://srv.sec.miui.com/data/adb`，然后把服务端返回的 `message` 原样弹出来。
所以「请先插入SIM卡」只是一个**服务端下发的提示文案**，并不是本地检测 SIM 卡。
只要服务端返回 `{"status":-1}`，它就会把属性写回 `0`。

### 第 3 层 —— 权限执行（真正的闸门）

```java
// com.android.server.pm.PackageManagerServiceImpl
public int preCheckUidPermission(String permName, int uid) {
    if (UserHandle.getAppId(uid) != 2000                      // 只针对 shell
        || !sShellCheckPermissions.contains(permName)         // 14 项，含 INJECT_EVENTS
        || SystemProperties.getBoolean("persist.security.adbinput", false))
        return 0;      // 放行
    return -1;         // 拒绝 —— 直接短路，不进正常权限查询
}
```

调用链：`InputManagerService#injectInputEventToTarget` →
`checkCallingPermission("android.permission.INJECT_EVENTS", ...)` →
`PermissionManagerService#checkUidPermission` → 上面这个方法。

`sShellCheckPermissions` 共 14 项，包含：

`SEND_SMS`、`CALL_PHONE`、`READ_CONTACTS`、`WRITE_CONTACTS`、
`CLEAR_APP_USER_DATA`、`WRITE_SECURE_SETTINGS`、`WRITE_SETTINGS`、
`MANAGE_DEVICE_ADMINS`、`UPDATE_APP_OPS_STATS`、**`INJECT_EVENTS`**、
`INSTALL_GRANT_RUNTIME_PERMISSIONS`、`GRANT_RUNTIME_PERMISSIONS`、
`REVOKE_RUNTIME_PERMISSIONS`、`SET_PREFERRED_APPLICATIONS`

### 隐藏的缓存陷阱

**只设置属性是没用的。** `android.permission.PermissionManager` 用
`PropertyInvalidatedCache` 缓存了结果，失效键是 `cache_key.package_info`：

```java
sPermissionCache = new PropertyInvalidatedCache<>(2048,
        "cache_key.package_info", "checkPermission");

public static int checkPermission(String permission, int pid, int uid) {
    return sPermissionCache.query(new PermissionQuery(permission, pid, uid));  // 命中缓存！
}
```

所以必须**同时**改动 `cache_key.package_info` 让缓存失效。

那为什么不能写个 shell 脚本搞定？因为 SELinux：

```
persist.security.  → u:object_r:system_prop:s0
cache_key.*        → u:object_r:binder_cache_system_server_prop:s0
```

`binder_cache_system_server_prop` **只有 system_server 域可写**。
在 `su`/Magisk root 下执行会看到：

```
Failed to set property 'cache_key.package_info' to '...'.
See dmesg for error reason.
```

这正是本模块必须在 `system_server` 内部运行的原因 —— 也是为什么
`resetprop`、`service.sh`、`su -c setprop` 都做不到。

---

## 本模块的做法

一个 Zygisk 模块（API **v5**），挂到 `postServerSpecialize` —— 此时
`system_server` 进程已经运行在 `system_server` SELinux 域：

1. `__system_property_set("persist.security.adbinput", "1")`
2. `__system_property_set("cache_key.package_info", <单调递增时间戳>)` → 使权限缓存失效

不 hook 任何 Java 方法，不碰 ART/ClassLoader，只在**唯一有权限的那个进程**里
写两个属性。

```
I/MiuiAdbInputBypass: preServerSpecialize: system_server forking
I/MiuiAdbInputBypass: postServerSpecialize: applying MIUI adb-input bypass
I/MiuiAdbInputBypass: persist.security.adbinput already 1, skip write
I/MiuiAdbInputBypass: permission cache invalidated: cache_key.package_info=1792938244457549946
I/MiuiAdbInputBypass: bypass done
```

---

## 环境要求

| 项 | 要求 |
|---|---|
| 设备 | 小米 / Redmi / POCO，运行 MIUI 14 或 HyperOS |
| Android | 13+（已在 Android 13 / MIUI V816 实测） |
| Root | Magisk 24.0+，且**已开启 Zygisk** |
| ABI | `arm64-v8a`（同时会构建 `armeabi-v7a`、`x86`、`x86_64`） |

实测环境：Redmi M2012K11AC（`alioth`）、Android 13、MIUI V816、
Magisk 30.7、Zygisk API v5。

---

## 安装

### 用 Release 包（推荐）

1. 从 [Releases](../../releases) 下载 `miui_adbinput_bypass-vX.Y.Z.zip`。
2. Magisk App → **模块** → **从本地安装**，选中该 zip。
3. 重启。

### 从源码构建

需要 Android NDK（`$ANDROID_HOME/ndk/<version>`）和 Python 3（用于打包；
脚本不依赖 `zip` 命令）。

```bash
cd module
chmod +x build.sh
./build.sh          # 构建 4 个 ABI 并打包
# → build/miui_adbinput_bypass-v1.0.0.zip
```

只编译 `.so`、不打包：

```bash
./build.sh abi
```

命令行安装：

```bash
adb push build/miui_adbinput_bypass-v1.0.0.zip /data/local/tmp/
adb shell "su -c 'magisk --install-module /data/local/tmp/miui_adbinput_bypass-v1.0.0.zip'"
adb reboot
```

---

## 验证

重启后，**不碰界面、也不用 `su`**：

```bash
# 1. 属性应为 1
adb shell getprop persist.security.adbinput        # → 1

# 2. 模块日志
adb shell su -c "logcat -d -s MiuiAdbInputBypass:*"

# 3. 以下命令必须全部成功（退出码 0，无 SecurityException）
adb shell input tap 300 1200
adb shell input keyevent KEYCODE_HOME
adb shell settings put global adb_enabled 1
adb shell pm list packages
```

端到端验证 —— 纯 `adb` 导航：

```bash
adb shell am start -a android.settings.SETTINGS
adb shell input tap 540 846          # 点击「我的设备」
adb shell dumpsys window | grep mCurrentFocus
# → com.android.settings/com.android.settings.SubSettings    （发生跳转 = 注入生效）
```

未生效时的典型报错：

```
java.lang.SecurityException: Injecting input events requires the caller
(or the source of the instrumentation, if any) to have the INJECT_EVENTS permission.
```

---

## 重要注意事项

**不要去点开发者选项里那个「USB调试（安全设置）」开关。**

- 它本来就会显示为**已开启**（读的就是本模块设置的属性）。
- 在已开启状态下点它，会走 `AdbInputPreferenceController` 的**关闭**分支，
  把属性写回 `0`。
- 再点一次会进入向导，走完服务端校验后同样写回 `0`。

如果不小心点了，**重启一次即可** —— 模块每次开机都会重新应用，不会永久损坏。

> 服务端校验只有在 hook `com.android.settings` 的情况下才能绕过。本模块
> 刻意不这么做：它解决的是**功能可用**，而不是**开关动画好看**。
> 详见 [为什么不 hook Settings](#为什么不-hook-settings)。

### 为什么不 hook Settings

要跳过向导，需要另做一个 LSPosed 模块，作用域指向
`AdbInputPreferenceController#updateAdbInputPreference`，直接调用
`AdbUtils.setInputEnabled(true)`。这会再多一个框架依赖，并且把行为绑死在
某个具体的 `Settings.apk` 版本上，而换来的只是界面观感 —— 权限层其实早就开了。
默认不值得。

---

## 影响范围与安全性

- 只影响 `uid=2000`（`com.android.shell`），也就是 `adb shell` 这个用户。
- **不会**给任何第三方应用授予权限。
- **不会**修改 `Settings.apk`、`services.jar` 或任何系统文件 ——
  纯内存属性变更，每次开机重新应用。
- `/system` 下没有任何文件被改动，因此 AVB / dm-verity 不受影响。

### 检测面

任何读取 `persist.security.adbinput` 或 `cache_key.package_info` 的逻辑都能
看到改动；这两个都是普通系统属性，很多进程可读。如果你的威胁模型里包含
「有 App 会检查这个属性」，那本模块不具备隐蔽性。

---

## 卸载 / 回滚

**Magisk App → 模块 → 移除 → 重启。** 就这些：没有修改系统文件，
所以移除就是完全清理。

如需同时清除属性：

```bash
adb shell su -c "resetprop --delete persist.security.adbinput"
```

---

## 疑难排查

| 现象 | 原因 / 处理 |
|---|---|
| `input tap` 仍抛 `SecurityException` | Zygisk 没开，或模块未生效。看 `logcat -s MiuiAdbInputBypass` 有没有 `postServerSpecialize` 那行。 |
| 完全看不到 `MiuiAdbInputBypass` 日志 | Zygisk 没注入 `system_server`。用 `adb shell su -c "grep -i zygisk /proc/$(pidof system_server)/maps"` 确认。 |
| `persist.security.adbinput` 是 `1` 但注入仍失败 | 权限缓存是旧的 —— 重启。注意：从 `su` 手动 `setprop cache_key...` **无效**，原因见上面的 SELinux 说明。 |
| 日志出现 `setprop ... failed rc=...` | SELinux 拒绝了写入，说明该设备策略不同。请在 issue 里附上机型/ROM。 |
| 开关显示已开启，但想让它「干净」 | 别碰它。见 [重要注意事项](#重要注意事项)。 |

---

## 项目结构

```
.
├── module/
│   ├── build.sh                    # NDK 构建 + zip 打包
│   ├── src/main/cpp/
│   │   ├── api.hpp                 # Zygisk API v5（来自 Magisk 上游）
│   │   ├── module.cpp              # bypass 主体逻辑
│   │   └── abi_stub.cpp            # 最小 __cxa_guard_* stub
│   └── template/
│       ├── update-binary           # Magisk 安装引导脚本
│       ├── updater-script
│       └── customize.sh            # 安装校验 + ABI 裁剪
├── AGENTS.md                       # 贡献者 / Agent 工作约定
├── CHANGELOG.md
├── LICENSE
├── README.md
└── README.zh-CN.md
```

### 为什么需要 `abi_stub.cpp`

`REGISTER_ZYGISK_MODULE` 会生成函数内非平凡静态变量：

```cpp
static Api api;
static T module;
static module_abi abi(m);
```

它们会引入 `__cxa_guard_acquire` / `__cxa_guard_release` 调用，但
`app_process64`（`system_server` 进程）并不链接 `libc++abi`。没有这些 stub，
`.so` 会在 `dlopen` 时因未解析符号而失败。`abi_stub.cpp` 提供了最小化的
Itanium ABI guard 实现，与上游
[`topjohnwu/libcxx`](https://github.com/topjohnwu/libcxx/blob/master/abi.cpp)
一致，这样就能保持 `-fno-exceptions -fno-rtti` 并避免链入整个 libc++。

---

## 致谢

- [Magisk](https://github.com/topjohnwu/Magisk)（topjohnwu）—— Zygisk API `v5`
  （`native/src/core/zygisk/api.hpp`）
- [zygisk-module-sample](https://github.com/topjohnwu/zygisk-module-sample) ——
  模块骨架与构建约定
- [libcxx](https://github.com/topjohnwu/libcxx) —— ABI stub 参考实现

## 许可证

[MIT](LICENSE)
