// ============================================================================
// MIUI ADB Input Bypass — Zygisk module
//
// 实测环境: Redmi M2012K11AC (alioth) / MIUI V816 / Android 13 / arm64-v8a
//           Magisk 30.7, Zygisk API v5
//
// ======================== 目标限制的完整机制 ========================
// [UI 层] com.miui.securitycenter/.permcenter.install.AdbInputApplyActivity
//         三页警告 + 5s 倒计时，最终跳 AdbInstallVerifyActivity
//
// [服务端] AdbInstallVerifyActivity$b.doInBackground
//         POST https://srv.sec.miui.com/data/adb
//         -> {"status":-1,"message":"请先插入SIM卡"}
//         即「插 SIM 卡」只是服务端下发的提示文案，不是本地逻辑
//
// [执行层] com.android.server.pm.PackageManagerServiceImpl#preCheckUidPermission
//             if (UserHandle.getAppId(uid) != 2000                // 仅 shell
//                 || !sShellCheckPermissions.contains(permName)    // 14 项含 INJECT_EVENTS
//                 || SystemProperties.getBoolean("persist.security.adbinput", false))
//                 return 0;   // 放行
//             return -1;      // 拒绝，直接短路，不进正常权限查询
//
//            调用点: PermissionManagerService#checkUidPermission
//
// [缓存层] **关键坑** android.permission.PermissionManager
//         sPermissionCache = new PropertyInvalidatedCache<>(2048,
//                 "cache_key.package_info", "checkPermission");
//         仅 setprop persist.security.adbinput=1 不会命中重算，
//         必须让 cache_key.package_info 变化，缓存才会失效。
//
// ======================== 本模块做法 ========================
// 在 system_server 的 postServerSpecialize 阶段（此时进程已是 system_server
// SELinux 域，具备写 system_prop / binder_cache_system_server_prop 的权限）：
//   1. __system_property_set("persist.security.adbinput", "1")
//   2. __system_property_set("cache_key.package_info", <单调递增时间戳>)
//
// 不 hook 任何 Java 方法 => 不涉 ART/ClassLoader，稳定性与兼容性最好。
// 影响面: 仅 uid=2000 (com.android.shell)，不改变其他应用权限模型。
// ============================================================================

#include <fcntl.h>
#include <sys/system_properties.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

#include <android/log.h>

#include "api.hpp"

#define LOG_TAG "MiuiAdbInputBypass"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

constexpr char kPropAdbInput[] = "persist.security.adbinput";
constexpr char kPropPermCache[] = "cache_key.package_info";

// 单调递增的时间戳，保证每次写入的值都不同，从而必定触发 PropertyInvalidatedCache 重算
void bumpPermissionCache() {
    struct timespec ts {};
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        ts.tv_sec = static_cast<time_t>(time(nullptr));
        ts.tv_nsec = 0;
    }

    char value[PROP_VALUE_MAX] = {};
    snprintf(value, sizeof(value), "%lld%09ld",
             static_cast<long long>(ts.tv_sec),
             static_cast<long>(ts.tv_nsec));

    int rc = __system_property_set(kPropPermCache, value);
    if (rc != 0) {
        LOGE("setprop %s failed rc=%d (SELinux?)", kPropPermCache, rc);
    } else {
        LOGI("permission cache invalidated: %s=%s", kPropPermCache, value);
    }
}

void applyBypass() {
    char cur[PROP_VALUE_MAX] = {};
    int has = __system_property_get(kPropAdbInput, cur);

    if (has > 0 && strcmp(cur, "1") == 0) {
        LOGI("%s already 1, skip write", kPropAdbInput);
    } else {
        int rc = __system_property_set(kPropAdbInput, "1");
        if (rc != 0) {
            LOGE("setprop %s=1 failed rc=%d (SELinux?)", kPropAdbInput, rc);
        } else {
            LOGI("setprop %s=1 ok (previous='%s')", kPropAdbInput,
                 has > 0 ? cur : "<unset>");
        }
    }

    // 幂等：即便 prop 原本就是 1，也刷新一次缓存，
    // 避免「缓存里存着 denied」的历史结果继续生效。
    bumpPermissionCache();
}

}  // namespace

class MiuiAdbInputBypass : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        api_ = api;
        (void)env;
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *args) override {
        (void)args;
        LOGI("preServerSpecialize: system_server forking");
    }

    void postServerSpecialize(const zygisk::ServerSpecializeArgs *args) override {
        (void)args;
        LOGI("postServerSpecialize: applying MIUI adb-input bypass");
        applyBypass();
        LOGI("bypass done");
    }

private:
    zygisk::Api *api_ = nullptr;
};

REGISTER_ZYGISK_MODULE(MiuiAdbInputBypass)
