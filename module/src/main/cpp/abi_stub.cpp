// ============================================================================
// 最小 C++ ABI 运行时 stub
//
// 背景：Zygisk 官方的 REGISTER_ZYGISK_MODULE 宏内部使用
//         static Api api;
//         static T module;        // T 有虚函数 => 非平凡构造
//         static module_abi abi(m);  // 有构造函数 => 非平凡
//       函数内非平凡 static 局部变量会生成 __cxa_guard_acquire / __cxa_guard_release
//       调用。而 Android 的 system_server(app_process64) 并不链接 libc++abi，
//       若不自行提供，dlopen 我们的 .so 时会因未解析符号而失败。
//
// 这里只实现必需的最小集合，语义与 Itanium C++ ABI 一致。
// 参考：topjohnwu/libcxx 的 abi.cpp。
// ============================================================================

#include <atomic>
#include <cstdint>

#if defined(__arm__) || defined(__i386__)
using guard_type = uint32_t;
#else
using guard_type = uint64_t;
#endif

extern "C" {

// 返回 1 表示当前线程需要执行初始化；返回 0 表示已被其他线程初始化完成。
__attribute__((visibility("default"))) int __cxa_guard_acquire(guard_type *raw_guard) {
    auto *guard = reinterpret_cast<std::atomic<uint8_t> *>(raw_guard);

    if (guard->load(std::memory_order_acquire) == 1) {
        return 0;
    }

    uint8_t expected = 0;
    if (guard->compare_exchange_strong(expected, 2, std::memory_order_acquire)) {
        return 1;  // 由本线程负责初始化
    }

    // 其他线程正在初始化，自旋等待其完成
    while (guard->load(std::memory_order_acquire) != 1) {
    }
    return 0;
}

__attribute__((visibility("default"))) void __cxa_guard_release(guard_type *raw_guard) {
    reinterpret_cast<std::atomic<uint8_t> *>(raw_guard)->store(1, std::memory_order_release);
}

__attribute__((visibility("default"))) void __cxa_guard_abort(guard_type *raw_guard) {
    reinterpret_cast<std::atomic<uint8_t> *>(raw_guard)->store(0, std::memory_order_release);
}

__attribute__((visibility("default"))) void __cxa_pure_virtual() {
    __builtin_trap();
}

}  // extern "C"
