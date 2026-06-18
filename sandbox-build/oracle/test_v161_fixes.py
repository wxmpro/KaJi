"""
Oracle 5: v1.6.1 修复后行为 oracle 验证
覆盖 4 条 oracle 此前未验的修复:
- BUG-1 + REL-1: 退出走 .terminateLater + flush MarkdownWriteQueue
- §4.4: ListState observer 去 .async 推迟一帧
- §4.3: StatsState observer 改 UUID token 模式
- PERF-3: purgeOldTrash 改 withTaskGroup 限流 8 并发

这些 oracle 验证修复的算法/状态机层逻辑（不验证 Swift 类型系统）
"""
import sys
import re
from pathlib import Path

# 直接读源文件做静态验证
# 沙箱挂载路径: /sessions/awesome-inspiring-curie/mnt/16-KaJi
KAJI_ROOT = Path("/sessions/awesome-inspiring-curie/mnt/16-KaJi")


def read_source(rel_path: str) -> str:
    """读源文件内容"""
    return (KAJI_ROOT / rel_path).read_text(encoding="utf-8")


def test_bug1_rel1_terminate_flush():
    """BUG-1 + REL-1: 退出走 .terminateLater + flush MarkdownWriteQueue"""
    src = read_source("KaJi/App/KaJiApp.swift")

    # 1. 必须有 .terminateLater
    assert ".terminateLater" in src, \
        "BUG-1 修复回归：applicationShouldTerminate 必须返回 .terminateLater"
    # 2. 必须有 NSApp.reply
    assert "NSApp.reply(toApplicationShouldTerminate:" in src, \
        "BUG-1 修复回归：必须用 NSApp.reply 通知可以退出"
    # 3. 必须有 MarkdownWriteQueue.shared.flush
    assert "MarkdownWriteQueue.shared.flush()" in src, \
        "REL-1 修复回归：退出前必须 flush MarkdownWriteQueue"
    # 4. 必须有 cancelPendingSave (避免 debounce 与 flush 双写)
    assert "cancelPendingSave()" in src, \
        "BUG-1 修复回归：退出前必须 cancel pending debounce save"
    # 5. 不能再有 .terminateNow (除非注释)
    terminate_now_lines = [
        l for l in src.split("\n")
        if ".terminateNow" in l and not l.strip().startswith("//")
    ]
    assert len(terminate_now_lines) == 0, \
        f"BUG-1 修复回归：不应再调用 .terminateNow，找到 {len(terminate_now_lines)} 处: {terminate_now_lines}"
    print("✅ test_bug1_rel1_terminate_flush: 退出序列正确")


def test_section_4_4_no_defer():
    """§4.4: ListState observer 去掉 .async 推迟一帧赌博"""
    src = read_source("KaJi/App/ListState.swift")

    # 1. observer 内不能再有 DispatchQueue.main.async
    assert "DispatchQueue.main.async" not in src, \
        "§4.4 修复回归：ListState observer 不应再有 .async 推迟一帧赌博"
    # 2. observer 仍直接调 refreshFilteredCards
    assert "refreshFilteredCards()" in src, \
        "§4.4 修复回归：observer 必须直接调用 refreshFilteredCards"
    print("✅ test_section_4_4_no_defer: 推迟一帧赌博已移除")


def test_section_4_3_observer_token():
    """§4.3: StatsState observer 改 UUID token 模式"""
    src = read_source("KaJi/App/StatsState.swift")

    # 1. updateObservers 必须是 [UUID: ...] 字典
    assert re.search(r"updateObservers:\s*\[UUID:\s*\(\)\s*->\s*Void\]", src), \
        "§4.3 修复回归：updateObservers 应为 [UUID: () -> Void]"
    # 2. addUpdateObserver 必须返回 UUID
    assert re.search(r"func\s+addUpdateObserver[^{]*->\s*UUID", src), \
        "§4.3 修复回归：addUpdateObserver 必须返回 UUID token"
    # 3. removeUpdateObserver 必须接受 token 参数
    assert re.search(r"func\s+removeUpdateObserver\s*\(\s*token:\s*UUID", src), \
        "§4.3 修复回归：removeUpdateObserver 必须接受 token: UUID"
    # 4. 不能再有空实现
    assert "// 闭包无法直接比较" not in src, \
        "§4.3 修复回归：空实现的借口注释应删除"
    print("✅ test_section_4_3_observer_token: token 模式已实现")


def test_perf3_purge_concurrency():
    """PERF-3: purgeOldTrash 改 withTaskGroup 限流 8 并发"""
    src = read_source("KaJi/Database/AppDatabase.swift")

    # 1. 必须有 withTaskGroup
    assert "withTaskGroup" in src, \
        "PERF-3 修复回归：必须用 withTaskGroup 限流"
    # 2. 必须有 maxConcurrent = 8
    assert "maxConcurrent = 8" in src or "maxConcurrent=8" in src, \
        "PERF-3 修复回归：限流数 = 8"
    # 3. 不能再用 DispatchQueue 并发删除
    assert "DispatchQueue.global" not in src and "DispatchQueue(label:" not in src, \
        "PERF-3 修复回归：不应再用 DispatchQueue 无限并发"
    # 4. 死代码 chunkSize 必须删除 (注释除外)
    # 找 let chunkSize = 8 (非注释行)
    buggy_lines = [
        l for l in src.split("\n")
        if re.search(r"\blet\s+chunkSize\s*=", l) and not l.strip().startswith("//")
    ]
    assert len(buggy_lines) == 0, \
        f"PERF-3 修复回归：死代码 chunkSize 必须删除，找到 {len(buggy_lines)} 处"
    print("✅ test_perf3_purge_concurrency: 限流 + 死代码清理完成")


def test_known_field_names_dynamic():
    """BUG-3: knownFieldNames 动态从 CardType.allCases 构建"""
    src = read_source("KaJi/Database/CardFileIO.swift")

    # 必须是闭包形式（动态构建），不是硬编码 Set 字面量
    # 匹配模式: knownFieldNames: Set<String> = { ... CardType.allCases ... }
    has_dynamic = re.search(
        r"knownFieldNames:\s*Set<String>\s*=\s*\{[^}]*CardType\.allCases",
        src,
        re.DOTALL
    )
    assert has_dynamic, \
        "BUG-3 修复回归：knownFieldNames 必须动态从 CardType.allCases 构建"
    # 不能有大量硬编码英文 (这正是修前的反模式)
    hardcoded_english = re.findall(r'"(definition|explanation|example|note|context)"', src)
    assert len(hardcoded_english) == 0, \
        f"BUG-3 修复回归：硬编码英文白名单应删除，找到 {hardcoded_english}"
    print("✅ test_known_field_names_dynamic: 动态白名单已实现")


def test_reconcile_critical_returns_result():
    """§4.1: reconcileCritical 必须返回 ReconcileResult, 失败显式上报"""
    repo = read_source("KaJi/Database/CardRepository.swift")
    service = read_source("KaJi/Services/CardService.swift")
    app = read_source("KaJi/App/KaJiApp.swift")

    # 1. ReconcileResult 结构体必须存在
    assert re.search(r"struct\s+ReconcileResult", repo), \
        "§4.1 修复回归：ReconcileResult 结构体必须存在"
    # 2. reconcileCritical 必须返回 ReconcileResult
    assert re.search(r"func\s+reconcileCritical\(\)\s+async\s+throws\s+->\s*ReconcileResult", repo), \
        "§4.1 修复回归：reconcileCritical 必须返回 ReconcileResult"
    # 3. bootstrapCritical 签名同步
    assert re.search(r"func\s+bootstrapCritical\(\)\s+async\s+throws\s+->\s*ReconcileResult", service), \
        "§4.1 修复回归：bootstrapCritical 必须返回 ReconcileResult"
    # 4. AppDelegate 必须检测 failedCount 并 alert
    assert "failedCount" in app and "saveError" in app, \
        "§4.1 修复回归：AppDelegate.bootstrap 必须把 failedCount 传给 alertState.saveError"
    print("✅ test_reconcile_critical_returns_result: 失败显式上报链路完整")


def test_id_retry_loop_continue():
    """BUG-5 + REL-4: ID 冲突重试用 continue + cardId 同步"""
    src = read_source("KaJi/Services/CardService.swift")

    # 1. 必须有 guard attempt < 10
    assert re.search(r"guard\s+attempt\s*<\s*10", src), \
        "BUG-5 修复回归：必须 guard attempt < 10 让循环真正跑 10 次"
    # 2. 重试时 CardField.cardId 必须同步为 newId
    assert re.search(r"CardField\(cardId:\s*newId", src), \
        "REL-4 修复回归：重试时 CardField.cardId 必须同步为 newId"
    # 3. 不能再用 return 直接跳出（v1.6.0 的 BUG）
    # 修后的循环结构: catch idConflict → guard → current = ... → continue (隐式)
    # 不应再在 catch 块里直接 return repo.save
    buggy_pattern = re.search(
        r"catch\s+DatabaseError\.idConflict.*?return\s+repo\.save",
        src, re.DOTALL
    )
    assert not buggy_pattern, \
        "BUG-5 修复回归：catch 块不应再直接 return repo.save (这是 v1.6.0 的 BUG)"
    print("✅ test_id_retry_loop_continue: continue + cardId 同步正确")


def test_settings_view_binding():
    """BUG-4: SettingsView 走 SettingsService setter binding"""
    src = read_source("KaJi/Views/Settings/SettingsView.swift")

    # 1. 必须有 binding wrapper
    assert "autoSaveIntervalBinding" in src, \
        "BUG-4 修复回归：必须有 autoSaveIntervalBinding"
    assert "trashRetentionDaysBinding" in src, \
        "BUG-4 修复回归：必须有 trashRetentionDaysBinding"
    # 2. binding 必须走 SettingsService setter
    assert re.search(r"set:\s*\{\s*SettingsService\.autoSaveInterval\s*=", src), \
        "BUG-4 修复回归：autoSaveIntervalBinding.set 必须调用 SettingsService.autoSaveInterval setter"
    assert re.search(r"set:\s*\{\s*SettingsService\.trashRetentionDays\s*=", src), \
        "BUG-4 修复回归：trashRetentionDaysBinding.set 必须调用 SettingsService.trashRetentionDays setter"
    # 3. Picker 必须用 binding 而非直 $autoSaveInterval
    assert "selection: autoSaveIntervalBinding" in src, \
        "BUG-4 修复回归：Picker 必须用 autoSaveIntervalBinding"
    assert "selection: trashRetentionDaysBinding" in src, \
        "BUG-4 修复回归：Picker 必须用 trashRetentionDaysBinding"
    print("✅ test_settings_view_binding: Settings binding 走 setter")


def main():
    print("=" * 70)
    print(" Oracle 5: v1.6.1 全部 8 条修复静态验证")
    print(" 读 HEAD 源文件，验证修复是否真的在代码里")
    print("=" * 70)
    test_known_field_names_dynamic()         # BUG-3
    test_reconcile_critical_returns_result()  # §4.1
    test_bug1_rel1_terminate_flush()          # BUG-1 + REL-1
    test_id_retry_loop_continue()             # BUG-5 + REL-4
    test_section_4_4_no_defer()               # §4.4
    test_settings_view_binding()              # BUG-4
    test_section_4_3_observer_token()         # §4.3
    test_perf3_purge_concurrency()            # PERF-3
    print(f"\n所有 8 条修复全部在 HEAD 代码中得到静态确认。\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
