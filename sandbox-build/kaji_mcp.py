#!/usr/bin/env python3
"""
KaJi MCP Server — 让 Claude Desktop 调用 Mac 上的 xcodebuild / git / 文件操作
用法见 claude_desktop_config.json

依赖: pip3 install mcp
"""
import subprocess
import os
from pathlib import Path
from mcp.server.fastmcp import FastMCP

# 项目根目录
KAJI_ROOT = "/Users/xinmin/openmind/03_Own_project/16-KaJi"

mcp = FastMCP("KaJi-MCP")


def _run(cmd: list[str], cwd: str = KAJI_ROOT, timeout: int = 600) -> dict:
    """统一执行命令的 helper"""
    try:
        result = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout
        )
        return {
            "returncode": result.returncode,
            "success": result.returncode == 0,
            "stdout": result.stdout[-5000:],   # 后 5000 字符防爆
            "stderr": result.stderr[-3000:],
        }
    except subprocess.TimeoutExpired:
        return {"returncode": -1, "success": False, "error": "timeout"}
    except Exception as e:
        return {"returncode": -1, "success": False, "error": str(e)}


@mcp.tool()
def xcodebuild(action: str = "build", scheme: str = "KaJi") -> dict:
    """Run xcodebuild. action: build / test / clean"""
    return _run([
        "xcodebuild",
        "-project", "KaJi.xcodeproj",
        "-scheme", scheme,
        "-destination", "platform=macOS",
        action,
    ])


@mcp.tool()
def xcodebuild_test(test_name: str = "") -> dict:
    """Run a single unit test. test_name: e.g. 'KaJiTests/CardFileIORoundTripTests'"""
    cmd = [
        "xcodebuild", "test",
        "-project", "KaJi.xcodeproj",
        "-scheme", "KaJi",
        "-destination", "platform=macOS",
    ]
    if test_name:
        cmd.extend(["-only-testing", test_name])
    return _run(cmd)


@mcp.tool()
def git_log(n: int = 10) -> dict:
    """Show last n git commits"""
    return _run(["git", "log", "--oneline", f"-{n}"])


@mcp.tool()
def git_status() -> dict:
    """Show working tree status"""
    return _run(["git", "status", "--short"])


@mcp.tool()
def git_apply_check(patch_path: str) -> dict:
    """Check if a .patch file applies cleanly (dry run)"""
    if not os.path.isabs(patch_path):
        patch_path = os.path.join(KAJI_ROOT, patch_path)
    return _run(["git", "apply", "--check", patch_path])


@mcp.tool()
def read_file(path: str, max_lines: int = 200) -> str:
    """Read a text file (limited to max_lines)"""
    if not os.path.isabs(path):
        path = os.path.join(KAJI_ROOT, path)
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        if len(lines) > max_lines:
            return f"... (truncated, total {len(lines)} lines)\n" + "".join(lines[:max_lines])
        return "".join(lines)
    except Exception as e:
        return f"error: {e}"


@mcp.tool()
def file_search(pattern: str) -> list:
    """List files matching glob pattern under KAJI_ROOT"""
    import glob
    abs_pattern = os.path.join(KAJI_ROOT, pattern)
    return glob.glob(abs_pattern, recursive=True)


if __name__ == "__main__":
    mcp.run()
