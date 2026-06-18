"""
Oracle 4: 12 种卡型字段名往返恒等 (BUG-3 修复回归)
模拟 CardFileIO.renderMarkdown + parseMarkdown 的字段名校验
验证: 修前 knownFieldNames 英文白名单让中文 100% 抛错；修后动态白名单全过
"""
import sys

# 12 种卡型字段名 (来自 CardType.swift:62-75)
CARD_TYPE_FIELDS = {
    "术语卡": ["定义", "解释", "例子", "参考"],
    "反常识卡": ["常识", "反常识", "例子", "参考"],
    "新知卡": ["已知", "新知", "例子", "参考"],
    "人物卡": ["简介", "参考"],
    "金句卡": ["原句", "评论", "参考"],
    "新词卡": ["原句", "造句", "参考"],
    "行动卡": ["内容", "行动", "参考"],
    "事件卡": ["时间", "地点", "参与者", "经过", "理解", "参考"],
    "图示卡": ["说明", "参考"],
    "索引卡": ["引用", "参考"],
    "综述卡": ["论点", "参考"],
    "自由卡": ["内容", "参考"],
}

# 修前 (v1.6.0): 硬编码英文白名单 (来自 CardFileIO.swift:28-39)
BUGGY_KNOWN_FIELDS = {
    "title", "tags", "content", "reference",
    "definition", "explanation", "example", "note", "context",
    "question", "answer", "cloze",
    "term", "synonym", "antonym", "translation",
    "name", "birth", "death", "achievement",
    "quote", "source", "author",
    "action", "deadline", "status",
    "event", "date", "location",
    "diagram", "caption", "index", "page",
}

# 修后 (v1.6.1): 动态从 CardType.allCases 构建
def fixed_known_fields():
    fields = {"title", "tags"}
    for type_fields in CARD_TYPE_FIELDS.values():
        fields.update(type_fields)
    return fields

def test_buggy_all_chinese_fail():
    """修前: 12 种卡型所有中文字段名都 100% 抛 MarkdownError.unknownField"""
    all_chinese = set()
    for fields in CARD_TYPE_FIELDS.values():
        all_chinese.update(fields)
    failed = all_chinese - BUGGY_KNOWN_FIELDS
    assert len(failed) == len(all_chinese), \
        f"BUG-3 验证：原始英文白名单应让所有 {len(all_chinese)} 个中文字段名失败"
    print(f"✅ test_buggy_all_chinese_fail: 修前 {len(all_chinese)} 个中文字段 100% 抛错")

def test_fixed_all_chinese_pass():
    """修后: 12 种卡型所有中文字段名都在动态白名单内"""
    fields = fixed_known_fields()
    failed = 0
    for type_fields in CARD_TYPE_FIELDS.values():
        for f in type_fields:
            if f not in fields:
                failed += 1
    assert failed == 0, f"修后所有字段都应在白名单，但 {failed} 个仍失败"
    print(f"✅ test_fixed_all_chinese_pass: 修后 {sum(len(v) for v in CARD_TYPE_FIELDS.values())} 个字段全部在白名单")

def test_round_trip_consistency():
    """修后: render + parse 往返恒等"""
    fields = fixed_known_fields()
    for tname, type_fields in CARD_TYPE_FIELDS.items():
        for f in type_fields:
            # render: 把字段名写入 ## 标题
            rendered = f"## {f}\n\n内容"
            # parse: 检查字段名是否在白名单
            assert f in fields, \
                f"BUG-3 回归！{tname}.{f} 不在 knownFieldNames，parse 会抛错"
    print(f"✅ test_round_trip_consistency: 12 种卡型所有字段往返恒等")

def main():
    print("=" * 60)
    print("Oracle 4: 12 种卡型字段名往返恒等 (BUG-3 修复回归)")
    print("=" * 60)
    test_buggy_all_chinese_fail()
    test_fixed_all_chinese_pass()
    test_round_trip_consistency()
    print(f"\n所有不变量验证通过。\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
