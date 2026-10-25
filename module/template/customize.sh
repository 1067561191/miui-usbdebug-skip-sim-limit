# ============================================================================
# Magisk 模块安装/初始化脚本
# 在下述时刻被 source：
#   - 安装时（install_module 内，带 install 参数）
#   - 每次开机 post-fs-data 阶段
#
# 作用：仅做权限修正与状态提示；真正的 bypass 由 Zygisk 在 system_server
#       fork 后执行，因此这里不重复写 prop（避免与 system_server 竞争）。
# ============================================================================

SKIPUNZIP=0

ui_print "- MIUI ADB Input Bypass"
ui_print "- 目标: 绕过『USB调试（安全设置）』需插入 SIM 卡的限制"
ui_print "- 原理: system_server 内 persist.security.adbinput=1 + 刷新权限缓存"

# 设备/系统校验：本模块针对 MIUI / HyperOS
if [ "$BOOTMODE" = true ]; then
    MIUI_VER=$(getprop ro.miui.ui.version.name 2>/dev/null)
    MIOS_VER=$(getprop ro.mi.os.version.name 2>/dev/null)
else
    MIUI_VER=""
    MIOS_VER=""
fi

if [ -n "$MIUI_VER" ] || [ -n "$MIOS_VER" ]; then
    ui_print "- 检测到 MIUI/HyperOS: ${MIOS_VER:-$MIUI_VER}"
else
    ui_print "! 未检测到 MIUI/HyperOS，本模块可能无效（仍继续安装）"
fi

# 架构裁剪：删除当前设备用不到的 zygisk .so，减小体积
if [ "$BOOTMODE" = true ]; then
    ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)
    case "$ARCH" in
        arm64-v8a)
            rm -f "$MODPATH/zygisk/armeabi-v7a.so" \
                  "$MODPATH/zygisk/x86.so" \
                  "$MODPATH/zygisk/x86_64.so" 2>/dev/null
            ;;
        armeabi-v7a)
            rm -f "$MODPATH/zygisk/arm64-v8a.so" \
                  "$MODPATH/zygisk/x86.so" \
                  "$MODPATH/zygisk/x86_64.so" 2>/dev/null
            ;;
        x86_64)
            rm -f "$MODPATH/zygisk/arm64-v8a.so" \
                  "$MODPATH/zygisk/armeabi-v7a.so" \
                  "$MODPATH/zygisk/x86.so" 2>/dev/null
            ;;
        x86)
            rm -f "$MODPATH/zygisk/arm64-v8a.so" \
                  "$MODPATH/zygisk/armeabi-v7a.so" \
                  "$MODPATH/zygisk/x86_64.so" 2>/dev/null
            ;;
    esac
    ui_print "- 保留 ABI: $ARCH"
fi

# Zygisk 可用性检查
# 注意: ZYGISK_ENABLED 环境变量只在开机脚本(post-fs-data/service)阶段由 Magisk 注入，
#       安装阶段通常拿不到，不能据此判定未启用。这里改用更可靠的判定方式。
if [ "$BOOTMODE" = true ]; then
    _zygisk_ok=0
    # 1) 官方 Zygisk：nativebridge 属性被设为 libzygisk.so
    case "$(getprop ro.dalvik.vm.native.bridge 2>/dev/null)" in
        *zygisk*) _zygisk_ok=1 ;;
    esac
    # 2) 三方 Zygisk(next/zygisksu)：已安装且 libzygisk.so 存在
    [ "$_zygisk_ok" = 0 ] && [ -f /data/adb/modules/zygisksu/lib64/libzygisk.so ] && _zygisk_ok=1
    # 3) 已注入的 system_server 映射里出现 zygisk
    if [ "$_zygisk_ok" = 0 ]; then
        _ss_pid=$(pidof system_server 2>/dev/null)
        if [ -n "$_ss_pid" ] && grep -qi zygisk "/proc/$_ss_pid/maps" 2>/dev/null; then
            _zygisk_ok=1
        fi
    fi

    if [ "$_zygisk_ok" = 1 ]; then
        ui_print "- Zygisk: 已启用"
    else
        ui_print "! 警告: 未检测到 Zygisk，本模块不会生效"
        ui_print "! 请在 Magisk 设置中开启 Zygisk 后重启"
    fi
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
[ -d "$MODPATH/zygisk" ] && set_perm_recursive "$MODPATH/zygisk" 0 0 0755 0644

ui_print "- 安装完成，重启生效"
