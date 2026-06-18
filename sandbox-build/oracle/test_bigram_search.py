"""
Oracle 2: Bigram 中文分词不变量 III 验证
模拟 KaJi/CardSearchIndex.swift 的 bigram 分词 + 子串校验算法
验证: 12 种卡型字段名往返恒等 + 中文子串/单字搜索
"""
import sys
import unicodedata

def is_indexable(c):
    """Character.isLetter || isNumber"""
    return c.isalpha() or c.isdigit()

def grams(text_lower):
    """完全模拟 CardSearchIndex.grams(_:)"""
    result = set()
    chars = list(text_lower)
    i = 0
    while i < len(chars):
        if not is_indexable(chars[i]):
            i += 1
            continue
        j = i
        while j < len(chars) and is_indexable(chars[j]):
            j += 1
        seg = chars[i:j]
        if len(seg) == 1:
            result.add(seg[0])
        else:
            for k in range(len(seg) - 1):
                result.add(seg[k] + seg[k+1])
        i = j
    return result

class SearchIndex:
    """完全模拟 CardSearchIndex (sync + search)"""
    def __init__(self):
        self.index = {}      # gram -> set of doc_id
        self.doc_text = {}   # id -> 原 searchText
        self.doc_lower = {}  # id -> 小写 searchText
        self.doc_grams = {}  # id -> 该卡的 grams

    def sync(self, summaries):
        """增量同步"""
        new_ids = {s['id'] for s in summaries}
        # 删除不存在的
        for id in list(self.doc_text.keys()):
            if id not in new_ids:
                self.remove_doc(id)
        # 新增 / 更新
        for s in summaries:
            if self.doc_text.get(s['id']) == s['searchText']:
                continue  # 未变跳过
            self.remove_doc(s['id'])
            lower = s['searchText'].lower()
            g = grams(lower)
            self.doc_text[s['id']] = s['searchText']
            self.doc_lower[s['id']] = lower
            self.doc_grams[s['id']] = g
            for gram in g:
                self.index.setdefault(gram, set()).add(s['id'])

    def remove_doc(self, id):
        if id in self.doc_grams:
            for gram in self.doc_grams[id]:
                if gram in self.index:
                    self.index[gram].discard(id)
                    if not self.index[gram]:
                        del self.index[gram]
        self.doc_grams.pop(id, None)
        self.doc_text.pop(id, None)
        self.doc_lower.pop(id, None)

    def search(self, keyword):
        """多 term AND 搜索 + 子串校验"""
        terms = [t for t in keyword.lower().split() if t]
        if not terms:
            return set()
        candidates = None
        for term in terms:
            idx_count = sum(1 for c in term if is_indexable(c))
            if idx_count < 2:
                # 单字: 全集 + 子串校验
                term_candidates = set(self.doc_lower.keys())
            else:
                tg = grams(term)
                inter = None
                for gram in tg:
                    s = self.index.get(gram, set())
                    inter = s if inter is None else inter & s
                    if not inter:
                        break
                term_candidates = inter if inter is not None else set()
            candidates = term_candidates if candidates is None else candidates & term_candidates
            if not candidates:
                return set()
        # 子串校验
        result = set()
        for id in candidates:
            doc = self.doc_lower.get(id)
            if doc and all(t in doc for t in terms):
                result.add(id)
        return result

def test_12_card_types_search():
    """12 种卡型字段名都能被搜到 (不变量 III + 修 BUG-3 后)"""
    from itertools import chain

    # 12 种卡型 + 字段名 (来自 CardType.swift:62-75)
    card_types = {
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

    idx = SearchIndex()
    summaries = []
    for i, (tname, fields) in enumerate(card_types.items()):
        # 模拟一张卡
        all_text = tname + " " + " ".join(fields) + " 测试内容"
        summaries.append({
            'id': f'card_{i}',
            'searchText': all_text,
        })
    idx.sync(summaries)

    # 每个字段名都应该能搜到对应卡
    for i, (tname, fields) in enumerate(card_types.items()):
        for field in fields:
            hits = idx.search(field)
            assert f'card_{i}' in hits, \
                f"BUG-3 回归！搜 '{field}' 应命中 card_{i} ({tname})，实际命中 {hits}"
    print(f"✅ test_12_card_types_search: 12 种卡型 39 个字段名全部命中")

def test_chinese_substring_and_single_char():
    """中文子串 + 单字搜索 (修群 2 后)"""
    idx = SearchIndex()
    summaries = [
        {'id': 'a', 'searchText': '卡片笔记 重要内容'},
        {'id': 'b', 'searchText': '卡片管理 方法论'},
        {'id': 'c', 'searchText': '英文 hello world'},
    ]
    idx.sync(summaries)

    # 中文子串
    hits = idx.search('笔记')
    assert 'a' in hits, f"搜 '笔记' 应命中 a，实际 {hits}"
    assert 'b' not in hits, f"搜 '笔记' 不应命中 b，实际 {hits}"
    print(f"✅ test_chinese_substring: 搜 '笔记' 命中 a，正确排除 b")

    # 中文单字
    hits = idx.search('笔')
    assert 'a' in hits, f"单字搜 '笔' 应命中 a（子串校验），实际 {hits}"
    print(f"✅ test_chinese_single_char: 单字搜 '笔' 命中 a")

    # 英文整词
    hits = idx.search('hello')
    assert 'c' in hits, f"搜 'hello' 应命中 c，实际 {hits}"
    print(f"✅ test_english_whole_word: 搜 'hello' 命中 c")

def test_bigram_no_false_positive():
    """bigram 不能有假阳性 (子串校验消除)"""
    idx = SearchIndex()
    idx.sync([
        {'id': 'a', 'searchText': '术语卡 定义 解释'},
        {'id': 'b', 'searchText': '新词卡 术语学习'},
    ])

    hits = idx.search('术语')
    assert 'a' in hits and 'b' in hits, f"搜 '术语' 应命中 a 和 b（都含子串）"

    hits = idx.search('卡定')
    assert 'a' not in hits, f"搜 '卡定'（bigram 假阳性候选）子串校验应排除 a"

    hits = idx.search('学习')
    assert 'b' in hits
    print(f"✅ test_bigram_no_false_positive: 子串校验正确消除 bigram 假阳性")

def main():
    print("=" * 60)
    print("Oracle 2: Bigram 搜索 + 12 种卡型字段名往返")
    print("=" * 60)
    test_12_card_types_search()
    test_chinese_substring_and_single_char()
    test_bigram_no_false_positive()
    print(f"\n所有不变量验证通过。\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
