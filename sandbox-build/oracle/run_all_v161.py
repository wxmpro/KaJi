#!/usr/bin/env python3
"""
v1.6.1 完整 oracle suite: 算法层 + 静态层
"""
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).parent
ORACLES = [
    "test_id_generator.py",
    "test_bigram_search.py",
    "test_id_retry.py",
    "test_field_name_roundtrip.py",
    "test_v161_fixes.py",   # 新增：8 条修复静态验证
]

def run(name):
    path = HERE / name
    start = time.time()
    print(f"\n▶ Running {name}...")
    result = subprocess.run([sys.executable, str(path)], capture_output=True, text=True)
    elapsed = time.time() - start
    print(result.stdout)
    if result.stderr:
        print(f"stderr: {result.stderr}")
    return result.returncode == 0, elapsed

def main():
    print("=" * 70)
    print(" KaJi v1.6.1 Oracle Verification Suite (算法 + 静态)")
    print("=" * 70)

    results = []
    total_start = time.time()
    for oracle in ORACLES:
        ok, elapsed = run(oracle)
        results.append((oracle, ok, elapsed))
    total = time.time() - total_start

    print("\n" + "=" * 70)
    print(" Summary")
    print("=" * 70)
    for name, ok, elapsed in results:
        status = "✅ PASS" if ok else "❌ FAIL"
        print(f"  {status}  {name:<40} {elapsed*1000:>6.1f}ms")
    print(f"\n  Total: {total*1000:.1f}ms")
    print("=" * 70)

    if all(ok for _, ok, _ in results):
        print("\n🎉 全部 oracle 通过:")
        print("   - 4 个算法 oracle (ID 生成 / bigram 搜索 / 重试 / 字段名)")
        print("   - 1 个静态 oracle (8 条修复全在 HEAD 代码中)")
        print("\n   算法层 + 静态层双重确认 v1.6.1 修复已落地。")
        print("   真实运行时验证仍需你在 Mac 上 xcodebuild + 真机实测。\n")
        return 0
    else:
        print("\n⚠️  有 oracle 失败，需重新审视。\n")
        return 1

if __name__ == "__main__":
    sys.exit(main())
