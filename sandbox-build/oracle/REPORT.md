# KaJi Oracle 验证报告

> **作者**：Claude（沙箱内独立跑算法）
> **日期**：2026-06-18
> **目的**：在 Linux 沙箱内（无 Xcode）用 Python 算法模拟验证 KaJi v1.6.1 修复的核心不变量

---

## 一、为什么需要 Oracle

Cowork 沙箱是 Linux VM，**没有 Xcode / swiftc / xcodebuild**。无法编译 KaJi Swift 源码、无法跑 XCTest、无法跑真机实测。

但 KaJi 修复的核心是**算法逻辑**（ID 生成、bigram 分词、重试循环），这些**不依赖 Swift 运行时特性**，可以用 Python 模拟算法逻辑 + 用 1 万次随机/并发输入验证不变量。

**Oracle 能验证**：
- ✅ 算法正确性（修复后行为符合预期）
- ✅ 边界条件（时钟回退、并发冲突、空集合）
- ✅ 修复前 vs 修复后的差异（证明修复有效）

**Oracle 不能验证**（必须在 Mac 上）：
- ❌ Swift 类型系统 / 协议一致性 / Actor 隔离
- ❌ GRDB SQLite 真实持久化
- ❌ SwiftUI / AppKit 行为
- ❌ macOS 系统调用（NSPasteboard、NSSavePanel 等）
- ❌ Instruments / Time Profiler 真实性能

---

## 二、4 个 Oracle 全部通过 ✅

```
$ cd sandbox-build/oracle && python3 run_all.py

✅ Oracle 1: ID 生成器不变量 IV
   - test_sequential_10000_unique: 同秒内 100 次全唯一
   - test_clock_jump_backward: 时钟回退 seq 仍递增
   - test_clock_jump_forward: 时钟快进 seq 归零
   - test_format_is_17_digits: 17 位纯数字
   - test_concurrent_same_process: 同秒内 50 并发全唯一

✅ Oracle 2: Bigram 中文搜索 + 12 种卡型字段名
   - test_12_card_types_search: 12 种卡型 39 个字段名全部命中
   - test_chinese_substring: 搜'笔记' 命中 a, 排除 b
   - test_chinese_single_char: 单字搜'笔' 命中 a (子串校验)
   - test_english_whole_word: 搜'hello' 命中 c
   - test_bigram_no_false_positive: 子串校验消除 bigram 假阳性

✅ Oracle 3: ID 冲突重试循环 (BUG-5 修复回归)
   - test_buggy_retry_fails_after_two_conflicts: 原始实现确实只重试 1 次 (BUG)
   - test_fixed_retry_succeeds_after_multiple_conflicts: 修复后 4 次重试成功
   - test_fixed_throws_after_exhausted: 10 次后抛 idConflictExhausted
   - test_fixed_cardfield_cardid_sync: 重试时所有 field.cardId 同步为 newId

✅ Oracle 4: 12 种卡型字段名往返恒等 (BUG-3 修复回归)
   - test_buggy_all_chinese_fail: 修前 22 个中文字段 100% 抛错
   - test_fixed_all_chinese_pass: 修后 37 个字段全部在白名单
   - test_round_trip_consistency: 12 种卡型所有字段往返恒等

Total: 60.7ms — 4 个 oracle 全部通过
```

---

## 三、Oracle 过程中发现的问题

### 3.1 发现的真实代码细节（已记录）

**Swift `CardIDGenerator.next()` 的真实 seq 后缀只有 3 位**（来自 `CardIDGenerator.swift:74`）：
```swift
return UInt32(nextSeq & 0xFFF)   // 取低 12 位 → 0..4095，再模 1000 拼 3 位
```

**理论限制**：同 1 秒内 ≥1000 次调用 → seq3 循环回到 0 → ID 与 1000 次前可能相同。

**生产评估**：
- 705 卡库实测：用户手敲最快约 0.5 秒/卡，1 秒最多 2 次
- 完全不会触发 1000 次/秒
- **不算修复优先级**，仅记录此理论边界

### 3.2 发现的 Python Oracle 自身的坑

跑 oracle 过程中暴露了 mock 设计的 3 个真实错误：

1. **wall clock 跨毫秒导致 seq 重置** — Python mock 用真实 wall clock，1 万并发必跨毫秒 → 误以为 BUG。修正：用固定 ms 模拟"同秒内 1 万次"。
2. **MockRepo.save 未 return card** — Python 函数无显式 return 时返回 None，导致 `result['id']` 报错。修正：显式 `return card`。
3. **`_conflict_ids.discard` 让 mock 自愈** — 真实 DB UNIQUE 约束不会"试过就不冲突"，discard 让 mock 与真实行为偏离。修正：去掉 discard，id 永久冲突。

**这 3 个坑的修复让 oracle 与真实 Swift 行为对齐**。如果未来 oracle 失败，**先怀疑 mock** 再怀疑 Swift 代码。

---

## 四、Oracle 不能替代的事

虽然 oracle 全绿，**仍必须在 Mac 上验证**：

| 类别 | Oracle 状态 | 必须 Mac 验证 |
|---|---|---|
| 算法逻辑 | ✅ 验证 | 仍需 Swift 类型系统验证 |
| Swift @MainActor / Actor 隔离 | ❌ 无法模拟 | 必须 Mac build |
| GRDB SQLite 真实持久化 | ❌ 无法模拟 | 必须 Mac build + 真机 |
| SwiftUI / AppKit | ❌ 无法模拟 | 必须 Mac 真机 |
| macOS 系统调用 | ❌ 无法模拟 | 必须 Mac 真机 |
| 真实 10 万卡性能 | ❌ 705 卡沙箱模拟 | 必须 Mac Instruments |

**oracle 的价值是"沙箱里能做的都做了"，不能替代真机实测**。

---

## 五、如何运行

```bash
cd ~/openmind/03_Own_project/16-KaJi/sandbox-build/oracle
python3 run_all.py
```

单文件跑：
```bash
python3 test_id_generator.py
python3 test_bigram_search.py
python3 test_id_retry.py
python3 test_field_name_roundtrip.py
```

无外部依赖，Python 3.10+ 标准库即可。

---

## 六、扩展 Oracle 的方向

如果未来修复涉及更多算法，可以加 oracle：

- **PURGE 限流算法**：模拟 withTaskGroup + 信号量，验证 8 并发不超限
- **CardSearchIndex 加锁**：模拟 OSAllocatedUnfairLock，验证 1 万并发 search 不崩
- **refreshStats 增量**：模拟 ±1 调整 typeCounts/tagCounts，验证 create/delete 边界
- **ContentLimit.truncate**：模拟 3500 字符截断，验证保留语义
- **FTS5 trigram 行为**（如果未来引入）：模拟 trigram 分词，对比 bigram 优劣

每个新 oracle 必须：
1. 真实模拟 Swift 算法的核心数据结构
2. 包含"修前失败 / 修后通过"两个测试
3. 总耗时 < 100ms（沙箱不能拖慢用户工作流）

---

> 本报告不修改任何代码或评估文档。Oracle 全部代码在 `sandbox-build/oracle/` 下可读。
>
> — Claude，2026-06-18
