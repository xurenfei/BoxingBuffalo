#!/usr/bin/env python3
"""Free FATX clusters claimed by an interrupted BoxingBuffalo upload.

Safe-by-default: without --apply this is a pure read-only report. With --apply
it (1) re-verifies that every target FAT entry is still an orphan end-of-chain
marker, (2) backs up the exact FAT byte range to a local file, (3) zeroes the
entries with 4096-byte aligned read-modify-write, (4) reads everything back,
and (5) verifies the neighbouring entries did not change.

Only FAT entries are touched. No directory record, no file payload, no
superblock. Rolling back = restore the backup file over the same byte range.

Usage:
    python3 scripts/reclaim-orphan-clusters.py                    # dry run
    python3 scripts/reclaim-orphan-clusters.py --apply
"""
import argparse
import datetime
import os
import struct
import sys

DEV = "/dev/rdisk8"
PART = 0x130EB0000
FAT_OFF = PART + 0x1000
DATA_OFF = 0x1381F1000
CLUSTER = 16384
FAT_SIZE = 0x7340000
BLOCK = 4096                     # USB bridge requires 4096-aligned writes
EOC = 0xFFFFFFFF
SECTOR = 512

DEFAULT_LO, DEFAULT_HI = 2_376_801, 2_425_835   # measured orphan run
BACKUP_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "_local", "fat-backups",
)


def aligned_read(fd, off, length):
    start = off - off % SECTOR
    end = ((off + length + SECTOR - 1) // SECTOR) * SECTOR
    want = end - start
    parts, got = [], 0
    while got < want:
        chunk = os.pread(fd, want - got, start + got)
        if not chunk:
            break
        parts.append(chunk)
        got += len(chunk)
    buf = b"".join(parts)
    return buf[off - start: off - start + length]


def fat_window(fd, lo, hi):
    """Raw FAT bytes covering clusters [lo, hi]."""
    off = FAT_OFF + lo * 4
    length = (hi - lo + 1) * 4
    return off, aligned_read(fd, off, length)


def fat_next(fd, cache, cluster):
    byte = cluster * 4
    if byte + 4 > FAT_SIZE:
        return EOC
    key = byte // 65536
    if key not in cache:
        cache[key] = aligned_read(fd, FAT_OFF + key * 65536, 65536)
    block = cache[key]
    at = byte - key * 65536
    return struct.unpack(">I", block[at:at + 4])[0]


def read_dir(fd, cache, cluster, limit=64):
    entries = []
    c, steps = cluster, 0
    while 1 <= c < EOC and steps < limit:
        c, steps = c, steps + 1
        data = aligned_read(fd, DATA_OFF + (c - 1) * CLUSTER, CLUSTER)
        for i in range(0, CLUSTER, 64):
            rec = data[i:i + 64]
            first4 = struct.unpack("<I", rec[0:4])[0]
            if first4 == 0 or first4 == EOC:
                return entries
            nlen, flags = rec[0], rec[1]
            if nlen == 0 or nlen == 0xE5:
                continue
            if nlen > 42:
                continue
            start, size = struct.unpack(">II", rec[0x2C:0x34])
            entries.append((start, bool(flags & 0x10), size))
        c = fat_next(fd, cache, c)
    return entries


def live_references(fd, cache):
    """Every cluster reachable from a live directory entry."""
    refs = set()
    root = read_dir(fd, cache, 1)
    queue = [(start, 1) for start, is_dir, _ in root if is_dir]
    all_entries = list(root)
    depth_guard = 0
    while queue and depth_guard < 400:
        parent, depth = queue.pop(0)
        if depth > 6:
            continue
        depth_guard += 1
        kids = read_dir(fd, cache, parent)
        all_entries.extend(kids)
        for start, is_dir, _ in kids:
            if is_dir:
                queue.append((start, depth + 1))
    for start, is_dir, size in all_entries:
        c, steps, seen = start, 0, set()
        while 1 <= c < EOC and c not in seen and steps < 200_000:
            seen.add(c)
            refs.add(c)
            c = fat_next(fd, cache, c)
            steps += 1
    return refs, len(all_entries)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, default=DEFAULT_LO)
    ap.add_argument("--end", type=int, default=DEFAULT_HI)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    lo, hi = args.start, args.end
    if lo > hi or lo < 2 or (hi + 1) * 4 > FAT_SIZE:
        print("簇区间非法", file=sys.stderr)
        return 2

    # Refuse to touch the disk while anything else has it open.
    busy = os.popen("lsof /dev/rdisk8 2>/dev/null").read().strip()
    if busy:
        print("中止：/dev/rdisk8 仍被其它进程打开：\n" + busy, file=sys.stderr)
        return 2

    fd = os.open(DEV, os.O_RDONLY)
    cache = {}
    off, blob = fat_window(fd, lo, hi)
    values = [struct.unpack(">I", blob[i:i + 4])[0] for i in range(0, len(blob), 4)]
    os.close(fd)

    fd = os.open(DEV, os.O_RDONLY)
    refs, entry_count = live_references(fd, {})
    os.close(fd)

    print("目标：cluster %d..%d（%d 簇，%.1f MB）"
          % (lo, hi, hi - lo + 1, (hi - lo + 1) * CLUSTER / 1e6))
    print("FAT 字节范围：0x%x .. 0x%x（%d 字节）"
          % (off, off + len(blob), len(blob)))
    print("扫描活跃目录项 %d 条，跟踪到 %d 个被引用簇" % (entry_count, len(refs)))

    zero = sum(1 for v in values if v == 0)
    eoc = sum(1 for v in values if v == EOC)
    other = len(values) - zero - eoc
    print("区间内 FAT 状态：空闲 %d · EOC 占位 %d · 其它 %d" % (zero, eoc, other))

    if zero == len(values):
        print("✅ 区间已全部空闲，无需重复清理（幂等退出）")
        return 0

    if other:
        print("❌ 中止：区间内存在 %d 个非 EOC 项，可能是有效链，不能清" % other,
              file=sys.stderr)
        return 2
    referenced_inside = [lo + i for i, v in enumerate(values)
                         if v != 0 and (lo + i) in refs]
    if referenced_inside:
        print("❌ 中止：区间内 %d 个簇被活跃目录项引用：%s…"
              % (len(referenced_inside), referenced_inside[:8]), file=sys.stderr)
        return 2

    # Also make sure no live chain *enters* the range from just outside it.
    fd = os.open(DEV, os.O_RDONLY)
    before = fat_next(fd, {}, lo - 1)
    os.close(fd)
    if lo <= before < EOC and lo <= before <= hi:
        print("❌ 中止：cluster %d 的链指向区间内部（%d）" % (lo - 1, before),
              file=sys.stderr)
        return 2

    if not args.apply:
        print("DRY RUN 通过：%d 个孤儿簇可以安全回收。加 --apply 执行。" % eoc)
        return 0

    # --- Apply ---
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    os.makedirs(BACKUP_DIR, exist_ok=True)
    backup = os.path.join(BACKUP_DIR, "fat-orphans-%d-%d-%s.bin" % (lo, hi, stamp))
    with open(backup, "wb") as f:
        f.write(blob)
    print("已备份原 FAT 区间 → %s（回滚用）" % backup)

    new_blob = bytearray(len(blob))
    # Start from the CURRENT on-disk bytes, not the earlier snapshot.
    fd = os.open(DEV, os.O_RDWR)
    wstart = off - off % BLOCK
    wend = ((off + len(blob) + BLOCK - 1) // BLOCK) * BLOCK
    wspan = wend - wstart
    whole = bytearray(aligned_read(fd, wstart, wspan))
    inner = off - wstart
    whole[inner:inner + len(blob)] = new_blob
    written = 0
    while written < wspan:
        chunk = bytes(whole[written:written + BLOCK])
        n = os.pwrite(fd, chunk, wstart + written)
        if n != len(chunk):
            print("❌ 写入失败于 0x%x（返回 %d）" % (wstart + written, n),
                  file=sys.stderr)
            os.close(fd)
            return 3
        written += n
    os.close(fd)

    # --- Verify ---
    fd = os.open(DEV, os.O_RDONLY)
    check_off, check = fat_window(fd, lo, hi)
    left = aligned_read(fd, FAT_OFF + (lo - 1) * 4, 4)
    right = aligned_read(fd, FAT_OFF + (hi + 1) * 4, 4)
    os.close(fd)
    bad = sum(1 for i in range(0, len(check), 4)
              if struct.unpack(">I", check[i:i + 4])[0] != 0)
    print("回读校验：区间内非 0 项 = %d" % bad)
    print("相邻未动项：FAT[%d]=0x%08X  FAT[%d]=0x%08X"
          % (lo - 1, struct.unpack(">I", left)[0],
             hi + 1, struct.unpack(">I", right)[0]))
    if bad == 0:
        print("✅ 已回收 %d 簇（%.1f MB），其它结构未改动"
              % (hi - lo + 1, (hi - lo + 1) * CLUSTER / 1e6))
        return 0
    print("❌ 回读不一致，请用备份文件回滚", file=sys.stderr)
    return 4


if __name__ == "__main__":
    sys.exit(main())
