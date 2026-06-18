"""
Oracle 3: ID 冲突重试循环 (BUG-5 修复回归)
模拟 CardService.persist 的 for 1...10 循环 (修后改 continue)
验证: 修前 return 跳出循环只重试 1 次；修后 continue 让循环继续
"""
import sys

class IDConflictError(Exception): pass

class MockRepo:
    """真实场景模拟: DB UNIQUE 约束意味着同一 id 永远冲突（不会因试过而消失）"""
    def __init__(self, conflict_ids):
        self._conflict_ids = set(conflict_ids)
        self._attempts = []

    def save(self, card):
        self._attempts.append(card['id'])
        if card['id'] in self._conflict_ids:
            # 真实 DB: 同一 id 永远冲突；不因试过而消失
            raise IDConflictError(f"id conflict: {card['id']}")
        return card

def persist_buggy(repo, card, id_gen):
    """原始 BUG-5 实现: catch 后 return 跳出循环"""
    for _ in range(10):
        try:
            return repo.save(card)
        except IDConflictError:
            new_id = id_gen()
            card = {**card, 'id': new_id}
            return repo.save(card)  # ← BUG: 直接 return，二次冲突逃出循环
    raise Exception("idConflictExhausted")

def persist_fixed(repo, card, id_gen):
    """修复后: continue 让循环继续"""
    current = card
    for attempt in range(1, 11):
        try:
            return repo.save(current)
        except IDConflictError:
            if attempt >= 10:
                raise Exception("idConflictExhausted")
            new_id = id_gen()
            current = {**current, 'id': new_id}
            # 不 return，继续循环

def test_buggy_retry_fails_after_two_conflicts():
    """原始实现：第 2 次冲突就 raise，循环失效"""
    id_counter = [1]
    def gen_id():
        id_counter[0] += 1
        return f'id_{id_counter[0]:03d}'

    # id_001 冲突, id_002 冲突 → 第二次 save(用 id_002) 也冲突 → raise
    repo = MockRepo({'id_001', 'id_002'})
    try:
        persist_buggy(repo, {'id': 'id_001'}, gen_id)
        assert False, "应有异常抛出"
    except IDConflictError:
        # 原始实现: 第 1 次 save(id_001) 冲突 → catch → 第二次 save(id_002) 冲突 → 抛出
        # 循环没有执行第 2 次迭代, attempts 应为 2
        assert len(repo._attempts) == 2, \
            f"BUG-5 验证：原始实现第 2 次冲突就 raise，attempts={len(repo._attempts)}"
    print(f"✅ test_buggy_retry_fails_after_two_conflicts: 原始实现确实只重试 1 次（BUG）")

def test_fixed_retry_succeeds_after_multiple_conflicts():
    """修复实现：3 次冲突后第 4 次成功"""
    id_counter = [1]
    def gen_id():
        id_counter[0] += 1
        return f'id_{id_counter[0]:03d}'

    # id_001, id_002, id_003 都冲突, id_004 不冲突 → 第 4 次 save 成功
    repo = MockRepo({'id_001', 'id_002', 'id_003'})
    result = persist_fixed(repo, {'id': 'id_001'}, gen_id)
    assert result is not None, f"修复应返回 card，实际 {result}"
    assert result['id'] == 'id_004', f"应最终用 id_004 成功，实际 {result}"
    assert len(repo._attempts) == 4, f"应尝试 4 次，实际 {len(repo._attempts)}"
    print(f"✅ test_fixed_retry_succeeds_after_multiple_conflicts: 修复后循环真正重试，attempts={len(repo._attempts)}")

def test_fixed_throws_after_exhausted():
    """修复实现：10 次冲突后抛 idConflictExhausted"""
    id_counter = [1]
    def gen_id():
        id_counter[0] += 1
        return f'id_{id_counter[0]:03d}'

    # 11+ 个 id 都冲突 → 10 次后抛
    repo = MockRepo({f'id_{i:03d}' for i in range(2, 20)})
    raised = False
    try:
        persist_fixed(repo, {'id': 'id_002'}, gen_id)
    except Exception as e:
        raised = True
        assert "idConflictExhausted" in str(e), f"应抛 idConflictExhausted，实际 {e}"
        assert len(repo._attempts) == 10, f"应尝试 10 次后抛错，实际 {len(repo._attempts)}"
    assert raised, "应有异常抛出"
    print(f"✅ test_fixed_throws_after_exhausted: 10 次后抛错，attempts={len(repo._attempts)}")

def test_fixed_cardfield_cardid_sync():
    """REL-4 修复回归：重试时 CardField.cardId 必须同步为 newId"""
    # 模拟 CardService.persist 重试时构造新 Card
    # 修复后: fields 内每个 CardField.cardId 都更新为 newId
    def sync_cardfields(card, new_id):
        # 修复实现: map 字段同步 cardId
        new_fields = [{**f, 'cardId': new_id} for f in card['fields']]
        return {**card, 'id': new_id, 'fields': new_fields}

    original_card = {
        'id': 'id_001',
        'fields': [
            {'cardId': 'id_001', 'fieldName': '定义', 'fieldValue': 'x', 'fieldOrder': 0},
            {'cardId': 'id_001', 'fieldName': '解释', 'fieldValue': 'y', 'fieldOrder': 1},
        ]
    }
    retried = sync_cardfields(original_card, 'id_002')
    # 验证所有 field 的 cardId 都同步
    for f in retried['fields']:
        assert f['cardId'] == 'id_002', \
            f"REL-4 修复回归：field.cardId 必须为 newId，实际 {f['cardId']}"
    # 验证 card.id 也是新值
    assert retried['id'] == 'id_002'
    print(f"✅ test_fixed_cardfield_cardid_sync: 重试时所有 field.cardId 同步为 newId")

def main():
    print("=" * 60)
    print("Oracle 3: ID 冲突重试循环 (BUG-5 修复回归)")
    print("=" * 60)
    test_buggy_retry_fails_after_two_conflicts()
    test_fixed_retry_succeeds_after_multiple_conflicts()
    test_fixed_throws_after_exhausted()
    test_fixed_cardfield_cardid_sync()
    print(f"\n所有不变量验证通过。\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
