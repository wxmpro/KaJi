#!/usr/bin/env python3
"""
oracle runner: 跑全部 4 个 oracle 验证 KaJi v1.6.1 修复的核心不变量
沙箱内可跑，无需任何外部依赖
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
]

def run(name):
    path = HERE / name
    start = time.time()
    print(f"\n▶ Running {name}...")
    result = subprocess.run(
        [sys.executable, str(path)],
        capture_output=True,
        text=True,
    )
    elapsed = time.time() - start
    print(result.stdout)
    if result.stderr:
        print(f"stderr: {result.stderr}")
    return result.returncode == 0, elapsed

def main():
    print("=" * 70)
    print(" KaJi v1.6.1 Oracle Verification Suite")
    print(" 沙箱内 Python 模拟 + 算法验证 (无外部依赖)")
    print("=" * 70)

    results = []
    total_start = time.time()
    for oracle in ORACLES:
        ok, elapsed = run(oracle)
        results.append((oracle, ok, elapsed))

    total_elapsed = time.time() - total_start
    print("\n" + "=" * 70)
    print(" Summary")
    print("=" * 70)
    for name, ok, elapsed in results:
        status = "✅ PASS" if ok else "❌ FAIL"
        print(f"  {status}  {name:<40} {elapsed*1000:>6.1f}ms")
    print(f"\n  Total: {total_elapsed*1000:.1f}ms")
    print("=" * 70)

    if all(ok for _, ok, _ in results):
        print("\n🎉 所有 oracle 通过 — 4 个核心不变量在算法层面已被验证。")
        print("   真实运行时验证仍需你在 Mac 上 xcodebuild build + 真机实测。\n")
        return 0
    else:
        print("\n⚠️  有 oracle 失败，需要重新审视修复逻辑。\n")
        return 1

if __name__ == "__main__":
    sys.exit(main())
