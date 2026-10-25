# MIUI ADB Input Bypass

[![Magisk](https://img.shields.io/badge/Magisk-≥24.0-00AF9C?logo=magisk)](https://github.com/topjohnwu/Magisk)
[![Zygisk API](https://img.shields.io/badge/Zygisk%20API-v5-blue)](https://github.com/topjohnwu/Magisk/blob/master/docs/guides.md#zygisk)
[![Android](https://img.shields.io/badge/Android-13%2B-3DDC84?logo=android)](https://www.android.com)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[简体中文](README.zh-CN.md) | English

A Magisk/Zygisk module that removes the SIM-card requirement from MIUI/HyperOS
**"USB debugging (Security settings)"** — the toggle that normally asks you to
insert a SIM card before allowing `adb` to simulate taps or change permissions.

Once installed, plain `adb shell input tap` / `keyevent` / `settings put` work
right after boot. **No UI interaction required.**

---

## The problem

In MIUI/HyperOS developer options there is a switch:

> **USB debugging (Security settings)** — *Allow granting permissions and
> simulating input via USB debugging*

MIUI refuses to turn it on unless a SIM card is present. The confirmation
wizard ends with a server round-trip that returns a localised error toast:

```
W/AdbInstallActivity: response: {"status":"-1","message":"请先插入SIM卡"}
W/AdbInstallActivity: server result: 请先插入SIM卡      # "Please insert SIM card"
```

For a test device with no SIM, this blocks the whole `input` / `pm grant` /
`settings put` workflow.

---

## How it actually works

The SIM requirement is **not** the real enforcement mechanism. There are three
independent layers, reverse-engineered from `Settings.apk`,
`miui-services.jar` and `framework.jar` on Android 13 (MIUI V816):

### Layer 1 — UI wizard
`com.miui.securitycenter/.permcenter.install.AdbInputApplyActivity`
Three warning pages with a 5-second countdown, then it launches
`AdbInstallVerifyActivity`.

### Layer 2 — Server-side check
`AdbInstallVerifyActivity$b.doInBackground` POSTs to
`https://srv.sec.miui.com/data/adb` and prints whatever `message` the server
returns. So *"Please insert SIM card"* is just a **server-supplied toast
string**, not a local SIM detection. If the server returns
`{"status":-1}`, the property is written back to `0`.

### Layer 3 — Permission enforcement (the real gate)

```java
// com.android.server.pm.PackageManagerServiceImpl
public int preCheckUidPermission(String permName, int uid) {
    if (UserHandle.getAppId(uid) != 2000                      // only shell
        || !sShellCheckPermissions.contains(permName)         // 14 perms, incl. INJECT_EVENTS
        || SystemProperties.getBoolean("persist.security.adbinput", false))
        return 0;      // allow
    return -1;         // deny — short-circuits the normal permission lookup
}
```

Called from `PermissionManagerService#checkUidPermission`, which is reached via
`InputManagerService#injectInputEventToTarget` →
`checkCallingPermission("android.permission.INJECT_EVENTS", ...)`.

`sShellCheckPermissions` contains 14 entries, including:

`SEND_SMS`, `CALL_PHONE`, `READ_CONTACTS`, `WRITE_CONTACTS`,
`CLEAR_APP_USER_DATA`, `WRITE_SECURE_SETTINGS`, `WRITE_SETTINGS`,
`MANAGE_DEVICE_ADMINS`, `UPDATE_APP_OPS_STATS`, **`INJECT_EVENTS`**,
`INSTALL_GRANT_RUNTIME_PERMISSIONS`, `GRANT_RUNTIME_PERMISSIONS`,
`REVOKE_RUNTIME_PERMISSIONS`, `SET_PREFERRED_APPLICATIONS`

### The hidden cache trap

Naively setting the property **does not work**. `android.permission.PermissionManager`
caches results in a `PropertyInvalidatedCache` keyed on `cache_key.package_info`:

```java
sPermissionCache = new PropertyInvalidatedCache<>(2048,
        "cache_key.package_info", "checkPermission");

public static int checkPermission(String permission, int pid, int uid) {
    return sPermissionCache.query(new PermissionQuery(permission, pid, uid));  // cached!
}
```

So you must **also** change `cache_key.package_info` to invalidate it.

And why can't a shell script just do this? Because of SELinux:

```
persist.security.  → u:object_r:system_prop:s0
cache_key.*        → u:object_r:binder_cache_system_server_prop:s0
```

`binder_cache_system_server_prop` is writable **only from the system_server
domain**. From `su`/Magisk root you get:

```
Failed to set property 'cache_key.package_info' to '...'.
See dmesg for error reason.
```

That is exactly why this module has to run inside `system_server` — and why
`resetprop`, `service.sh` or a plain `su -c setprop` cannot do the job.

---

## How this module works

A Zygisk module (API **v5**) that hooks `postServerSpecialize` — the point where
the `system_server` process already runs in the `system_server` SELinux domain:

1. `__system_property_set("persist.security.adbinput", "1")`
2. `__system_property_set("cache_key.package_info", <monotonic timestamp>)` → invalidates the permission cache

No Java hooking, no ART/ClassLoader tricks. Just two property writes from the
one process that is allowed to make them.

```
I/MiuiAdbInputBypass: preServerSpecialize: system_server forking
I/MiuiAdbInputBypass: postServerSpecialize: applying MIUI adb-input bypass
I/MiuiAdbInputBypass: persist.security.adbinput already 1, skip write
I/MiuiAdbInputBypass: permission cache invalidated: cache_key.package_info=1792938244457549946
I/MiuiAdbInputBypass: bypass done
```

---

## Requirements

| Item | Requirement |
|---|---|
| Device | Xiaomi / Redmi / POCO running MIUI 14 or HyperOS |
| Android | 13+ (verified on Android 13, MIUI V816) |
| Root | Magisk 24.0+ with **Zygisk enabled** |
| ABI | `arm64-v8a` (also builds `armeabi-v7a`, `x86`, `x86_64`) |

Verified on a Redmi M2012K11AC (`alioth`), Android 13, MIUI V816,
Magisk 30.7, Zygisk API v5.

---

## Installation

### From a release (recommended)

1. Download `miui_adbinput_bypass-vX.Y.Z.zip` from [Releases](../../releases).
2. In the Magisk app: **Modules → Install from storage**, pick the zip.
3. Reboot.

### From source

Requires an Android NDK (`$ANDROID_HOME/ndk/<version>`) and Python 3 (for zip
packaging; the script does not rely on a `zip` binary).

```bash
cd module
chmod +x build.sh
./build.sh          # builds all 4 ABIs and packages the zip
# → build/miui_adbinput_bypass-v1.0.0.zip
```

Build only the shared libraries, without packaging:

```bash
./build.sh abi
```

Install via CLI:

```bash
adb push build/miui_adbinput_bypass-v1.0.0.zip /data/local/tmp/
adb shell "su -c 'magisk --install-module /data/local/tmp/miui_adbinput_bypass-v1.0.0.zip'"
adb reboot
```

---

## Verification

After rebooting, **without touching the UI and without `su`**:

```bash
# 1. Property should be 1
adb shell getprop persist.security.adbinput        # → 1

# 2. Module log
adb shell su -c "logcat -d -s MiuiAdbInputBypass:*"

# 3. These must all succeed (exit code 0, no SecurityException)
adb shell input tap 300 1200
adb shell input keyevent KEYCODE_HOME
adb shell settings put global adb_enabled 1
adb shell pm list packages
```

End-to-end check — navigate purely with `adb`:

```bash
adb shell am start -a android.settings.SETTINGS
adb shell input tap 540 846          # tap "My device"
adb shell dumpsys window | grep mCurrentFocus
# → com.android.settings/com.android.settings.SubSettings   (navigated = injection works)
```

Expected failure mode when the bypass is **not** active:

```
java.lang.SecurityException: Injecting input events requires the caller
(or the source of the instrumentation, if any) to have the INJECT_EVENTS permission.
```

---

## Important caveat

**Do not tap the "USB debugging (Security settings)" switch in developer options.**

- It will already show as **enabled** (it reads the property this module sets).
- Tapping it when enabled takes the *disable* branch of
  `AdbInputPreferenceController` and writes the property back to `0`.
- Tapping it again opens the wizard, which ends in the server round-trip and also
  writes `0`.

If you accidentally tap it, **just reboot** — the module re-applies on every
boot. Nothing is broken permanently.

> The server-side check cannot be bypassed without hooking
> `com.android.settings`. This module intentionally does not do that: it makes
> the *functionality* work, not the *switch animation*. See
> [Why not hook Settings?](#why-not-hook-settings).

### Why not hook Settings?

Skipping the wizard would require an LSPosed module targeting
`AdbInputPreferenceController#updateAdbInputPreference` and calling
`AdbUtils.setInputEnabled(true)` directly. That adds a second framework
dependency and pins behaviour to a specific `Settings.apk` build, for cosmetic
benefit only — the permission layer is already open. Not worth it by default.

---

## Scope and safety

- Only affects `uid=2000` (`com.android.shell`), i.e. the `adb shell` user.
- Does **not** grant any permission to third-party apps.
- Does **not** modify `Settings.apk`, `services.jar` or any system file —
  it is a pure in-memory property change, re-applied at boot.
- No files under `/system` are altered, so AVB / dm-verity are untouched.

### Detection surface

Anything that inspects `persist.security.adbinput` or `cache_key.package_info`
can see the change; both are plain system properties readable by many processes.
If your threat model includes an app that checks this property, this module is
not stealthy.

---

## Uninstall / rollback

**Magisk app → Modules → remove the module → reboot.** That's it: no system
files were modified, so removal is complete.

To also reset the property:

```bash
adb shell su -c "resetprop --delete persist.security.adbinput"
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `input tap` still throws `SecurityException` | Zygisk disabled, or module not applied. Check `logcat -s MiuiAdbInputBypass` for the `postServerSpecialize` line. |
| No `MiuiAdbInputBypass` log at all | Zygisk is not injecting into `system_server`. Verify with `adb shell su -c "grep -i zygisk /proc/$(pidof system_server)/maps"`. |
| `getprop persist.security.adbinput` is `1` but injection fails | Stale permission cache — reboot. (A manual `setprop cache_key...` from `su` does **not** work; see SELinux note above.) |
| Module log says `setprop ... failed rc=...` | SELinux denied the write; the device's policy differs. Report the device/ROM in an issue. |
| Switch shows enabled but you want it "clean" | Don't touch it. See [Important caveat](#important-caveat). |

---

## Project layout

```
.
├── module/
│   ├── build.sh                    # NDK build + zip packaging
│   ├── src/main/cpp/
│   │   ├── api.hpp                 # Zygisk API v5 (from Magisk upstream)
│   │   ├── module.cpp              # the actual bypass
│   │   └── abi_stub.cpp            # minimal __cxa_guard_* stubs
│   └── template/
│       ├── update-binary           # Magisk installer bootstrap
│       ├── updater-script
│       └── customize.sh            # install checks + ABI trimming
├── AGENTS.md                       # contributor / agent guidelines
├── CHANGELOG.md
├── LICENSE
├── README.md
└── README.zh-CN.md
```

### Why `abi_stub.cpp`?

`REGISTER_ZYGISK_MODULE` creates function-local non-trivial statics:

```cpp
static Api api;
static T module;
static module_abi abi(m);
```

Those emit calls to `__cxa_guard_acquire` / `__cxa_guard_release`, but
`app_process64` (the `system_server` process) does not link `libc++abi`. Without
stubs the `.so` fails to `dlopen`. `abi_stub.cpp` provides the minimal
Itanium-ABI guard implementation, mirroring upstream
[`topjohnwu/libcxx`](https://github.com/topjohnwu/libcxx/blob/master/abi.cpp),
so we keep `-fno-exceptions -fno-rtti` and avoid pulling in all of libc++.

---

## Credits

- [Magisk](https://github.com/topjohnwu/Magisk) by topjohnwu — Zygisk API `v5`
  (`native/src/core/zygisk/api.hpp`)
- [zygisk-module-sample](https://github.com/topjohnwu/zygisk-module-sample) —
  module skeleton and build conventions
- [libcxx](https://github.com/topjohnwu/libcxx) — reference for the ABI stubs

## License

[MIT](LICENSE)
