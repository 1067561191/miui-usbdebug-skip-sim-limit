## 变更类型

<!-- 勾选适用的项 -->

- [ ] `feat` 新功能
- [ ] `fix` 修复
- [ ] `docs` 文档
- [ ] `build` 构建 / 依赖
- [ ] `refactor` 重构（不改变行为）
- [ ] `chore` 杂项

## 变更说明

<!-- 这个 PR 做了什么？为什么需要它？ -->

## 关联 Issue

<!-- 例如：Closes #12 -->

## 红线自查

<!-- 详见 AGENTS.md §5。请逐项确认。 -->

- [ ] **未**手改 `module/src/main/cpp/api.hpp`（Zygisk API 上游同步副本）
- [ ] **未**删除 `module/src/main/cpp/abi_stub.cpp`
- [ ] **未**引入 system 文件替换（不改 `services.jar` / `Settings.apk`，无 `system/` 挂载）
- [ ] **未**把权限授予范围扩大到 `uid=2000` 之外
- [ ] **未**为了绕过 UI 弹窗而去 hook `com.android.settings`
- [ ] **未**按机型硬编码特判
- [ ] **未**提交 `work/`、`.pi/` 或 `module/build/`

## 构建与验证

<!-- 详见 AGENTS.md §4。CI 会做静态检查，但功能验证需要你在真机上跑。 -->

### 构建

```bash
cd module && ./build.sh
```

- [ ] 本地构建通过（4 个 ABI 全部成功）

### 静态检查

- [ ] `zygisk_module_entry` 已导出
- [ ] 无残留 `__cxa_guard_*` / `cxxabi` 未解析符号
- [ ] 各 ABI 的 `Class` / `Machine` 正确

### 真机验证

<!-- 请填写实际测试环境 -->

| 项 | 值 |
|---|---|
| 设备 | |
| Android 版本 | |
| ROM / MIUI 版本 | |
| ABI | |
| Magisk 版本 | |

- [ ] 模块日志出现 `bypass done`
- [ ] `getprop persist.security.adbinput` 为 `1`
- [ ] `adb shell input tap` 成功（无 `SecurityException`）
- [ ] `adb shell settings put global xxx yyy` 成功

## 文档

- [ ] 行为变更已更新 `CHANGELOG.md` 的 `[Unreleased]` 段
- [ ] 机制/限制变更已**同时**更新 `README.md` **和** `README.zh-CN.md`

## 备注

<!-- 任何需要 reviewer 注意的地方，例如已知缺陷、后续计划 -->
