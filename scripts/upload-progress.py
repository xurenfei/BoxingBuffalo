#!/usr/bin/env python3
"""Read-only progress observer for an in-flight BoxingBuffalo upload.

The running app cannot be hot-patched, so this watches kernel I/O counters
instead. It never touches the FATX structures and cannot interrupt a write.

Usage:
    python3 scripts/upload-progress.py --total 1.2G
    python3 scripts/upload-progress.py --total ~/Downloads/Aurora   # folder path
    python3 scripts/upload-progress.py                              # bytes only
"""

import argparse
import os
import subprocess
import sys
import time

IOSTAT = "/usr/sbin/iostat"


def human(n: float) -> str:
    n = max(0.0, float(n))
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} TB"


def duration(seconds: float) -> str:
    if seconds <= 0 or seconds != seconds:
        return "--"
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds} 秒"
    if seconds < 3600:
        return f"{seconds // 60} 分 {seconds % 60} 秒"
    return f"{seconds // 3600} 小时 {(seconds % 3600) // 60} 分"


def parse_size(text: str) -> float:
    text = text.strip().upper()
    factors = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}
    for suffix, factor in factors.items():
        if text.endswith(suffix) or text.endswith(suffix + "B"):
            return float(text.rstrip("BKTGM")) * factor
    return float(text)


def folder_bytes(path: str) -> float:
    """Mirror FolderUploadPlanner: skip hidden files, symlinks and >4 GiB."""
    total = 0
    for root, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if name.startswith("."):
                continue
            full = os.path.join(root, name)
            if os.path.islink(full):
                continue
            try:
                size = os.path.getsize(full)
            except OSError:
                continue
            if size <= 4 * 1024 ** 3:
                total += size
    return total


def sample_mbps(device: str, interval: int) -> float:
    """Second iostat sample is the last `interval` seconds, in MB/s."""
    try:
        out = subprocess.run(
            [IOSTAT, "-d", device, str(interval), "2"],
            capture_output=True, text=True, timeout=interval + 10,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 0.0
    rates = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            try:
                rates.append(float(parts[2]))  # KB/t  tps  MB/s
            except ValueError:
                pass
    return rates[-1] if rates else 0.0


def main() -> int:
    ap = argparse.ArgumentParser(description="只读观察 BoxingBuffalo 写盘进度")
    ap.add_argument("--device", default="disk8", help="磁盘设备名，默认 disk8")
    ap.add_argument("--total", default="", help="总字节数（1.2G）或本地文件夹路径")
    ap.add_argument("--interval", type=int, default=2, help="采样秒数，默认 2")
    args = ap.parse_args()

    total = 0.0
    if args.total:
        path = os.path.expanduser(args.total)
        total = folder_bytes(path) if os.path.isdir(path) else parse_size(args.total)

    print(f"观察 {args.device} 的写入吞吐（只读，不会干扰上传）。Ctrl-C 退出。")
    if total:
        print(f"本次总量约 {human(total)}（按 FATX 规则跳过隐藏文件/符号链接/>4GB）")
    else:
        print("未给 --total，只显示累计写入量与瞬时速率")
    print("注意：内核计数含 FAT 表与目录项写入，数字会略高于纯文件字节数。\n")

    written = 0.0
    recent = []
    interval = max(1, args.interval)
    try:
        while True:
            started = time.monotonic()
            rate = sample_mbps(args.device, interval)  # MB/s
            elapsed = max(interval, time.monotonic() - started)
            written += rate * 1024 ** 2 * elapsed
            recent.append(rate)
            recent = recent[-8:]
            avg = sum(recent) / len(recent)

            line = f"\r累计写入 ≈ {human(written):>10}   当前 {rate:5.2f} MB/s   均速 {avg:5.2f} MB/s"
            if total:
                pct = min(100.0, written / total * 100)
                eta = duration((total - written) / (avg * 1024 ** 2)) if avg > 0.05 else "--"
                line += f"   {pct:5.1f}%   剩余约 {eta}"
            print(line + "   ", end="", flush=True)
    except KeyboardInterrupt:
        print("\n已停止观察（上传不受影响）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
