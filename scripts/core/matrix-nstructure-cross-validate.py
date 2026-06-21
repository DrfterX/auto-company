#!/usr/bin/env python3
"""
A.3 — 全量交叉比对: Matrix API vs Klines API N 型结构一致性验证

遍历 Matrix 中所有 (symbol, contract, tf) 组合，
对有 N-type 标注的 cell，调用 Klines API 获取对应数据，
比对方向 (dir)、ABC 点 (a/b/c) 和时间戳 (at/bt/ct)。
"""
import json
import sys
import urllib.request
from datetime import datetime

BASE = "http://127.0.0.1:5100"

def fetch_json(path):
    url = f"{BASE}{path}"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {"_error": str(e)}

def ts2str(ts):
    if ts is None:
        return "N/A"
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")

def compare_n(a, b):
    """Compare two N-structure dicts. Returns list of differences."""
    diffs = []
    keys = ["dir", "a", "b", "c", "at", "bt", "ct", "state"]
    for k in keys:
        va = a.get(k, None)
        vb = b.get(k, None)
        if va != vb:
            diffs.append((k, va, vb))
    return diffs

def main():
    print("=" * 80)
    print("A.3 全量交叉比对 — Matrix vs Klines N 型结构一致性验证")
    print(f"运行时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} CST")
    print("=" * 80)

    # Step 1: Fetch Matrix
    print("\n📡 获取 Matrix 数据...")
    matrix_data = fetch_json("/api/matrix")
    if "_error" in matrix_data:
        print(f"❌ Matrix API 错误: {matrix_data['_error']}")
        sys.exit(1)

    rows = matrix_data.get("matrix", [])
    print(f"✅ Matrix 返回 {len(rows)} 行")

    # TF mapping
    tf_order = ["15m", "1h", "1d", "1w"]

    # Statistics
    stats = {
        "total_cells": 0,
        "matrix_has_n": 0,      # Matrix 有 N 型结构
        "klines_has_n": 0,       # Klines 也有 N 型结构
        "match": 0,              # 完全一致
        "dir_mismatch": 0,       # 方向不一致
        "abc_mismatch": 0,       # ABC 点不一致
        "ts_mismatch": 0,        # 时间戳不一致
        "matrix_only": 0,        # Matrix 有但 Klines 没有 (Cat1)
        "klines_only": 0,        # Klines 有但 Matrix 没有 (反向)
        "both_empty": 0,         # 都为空
        "matrix_error": 0,       # Matrix 数据格式异常
        "klines_error": 0,       # Klines API 调用失败
    }

    results = {}  # key -> detail

    for idx, row in enumerate(rows):
        sym = row.get("sym", "")
        contract = row.get("contract", "main")
        name = row.get("name", sym)

        cells = row.get("cells", [])
        for cell in cells:
            tf = cell.get("tf", "?")
            stats["total_cells"] += 1
            key = f"{sym}/{contract}/{tf}"

            matrix_n = {
                "dir": cell.get("dir"),
                "a": cell.get("a"),
                "b": cell.get("b"),
                "c": cell.get("c"),
                "at": cell.get("at"),
                "bt": cell.get("bt"),
                "ct": cell.get("ct"),
                "state": cell.get("state"),
            }

            matrix_has_n = matrix_n["dir"] is not None
            data = {"name": name, "sym": sym, "contract": contract, "tf": tf}
            data["matrix_n"] = matrix_n
            data["matrix_has_n"] = matrix_has_n

            if matrix_n["dir"] is None and "a" in cell:
                # Edge case: some ABC fields present but dir is None
                stats["matrix_error"] += 1
                data["matrix_error"] = "has_abc_no_dir"

            if matrix_has_n:
                stats["matrix_has_n"] += 1

            # Fetch Klines
            klines = fetch_json(f"/api/klines?symbol={sym}&contract={contract}&tf={tf}")
            if "_error" in klines:
                stats["klines_error"] += 1
                data["klines_error"] = klines["_error"]
                data["status"] = "Klines_API_error"
                results[key] = data
                continue

            klines_n = klines.get("n_structure", {})
            if not klines_n:
                klines_n = {}

            klines_has_n = klines_n.get("dir") is not None
            data["klines_n"] = klines_n
            data["klines_has_n"] = klines_has_n

            if klines_has_n:
                stats["klines_has_n"] += 1

            # Compare
            if not matrix_has_n and not klines_has_n:
                stats["both_empty"] += 1
                data["status"] = "both_empty"
            elif matrix_has_n and not klines_has_n:
                stats["matrix_only"] += 1
                data["status"] = "matrix_only"  # Cat1
            elif not matrix_has_n and klines_has_n:
                stats["klines_only"] += 1
                data["status"] = "klines_only"
            else:
                # Both have N-structure — compare
                diffs = compare_n(matrix_n, klines_n)
                if not diffs:
                    stats["match"] += 1
                    data["status"] = "match"
                else:
                    # Categorize diffs
                    dir_diffs = [d for d in diffs if d[0] == "dir"]
                    abc_diffs = [d for d in diffs if d[0] in ("a", "b", "c")]
                    ts_diffs = [d for d in diffs if d[0] in ("at", "bt", "ct")]
                    state_diffs = [d for d in diffs if d[0] == "state"]

                    if dir_diffs:
                        stats["dir_mismatch"] += 1
                    if abc_diffs:
                        stats["abc_mismatch"] += 1
                    if ts_diffs:
                        stats["ts_mismatch"] += 1

                    data["status"] = "mismatch"
                    data["diffs"] = diffs
                    data["dir_diffs"] = dir_diffs
                    data["abc_diffs"] = abc_diffs
                    data["ts_diffs"] = ts_diffs
                    data["state_diffs"] = state_diffs

            results[key] = data

    # ===== Report =====
    print(f"\n{'='*80}")
    print(f"📊 验证统计摘要")
    print(f"{'='*80}")
    print(f"总检查数:           {stats['total_cells']:4d}  cells ({len(rows)} 品种 × 4 周期)")
    print(f"---")
    print(f"Matrix 有 N 型:      {stats['matrix_has_n']:4d}  ({stats['matrix_has_n']/stats['total_cells']*100:.1f}%)")
    print(f"Klines 有 N 型:      {stats['klines_has_n']:4d}  ({stats['klines_has_n']/stats['total_cells']*100:.1f}%)")
    print(f"---")
    print(f"完全一致 (✅):       {stats['match']:4d}")
    print(f"方向不一致:          {stats['dir_mismatch']:4d}")
    print(f"ABC 点不一致:        {stats['abc_mismatch']:4d}")
    print(f"时间戳不一致:        {stats['ts_mismatch']:4d}")
    print(f"---")
    print(f"Matrix 独有 (🐱 Cat1): {stats['matrix_only']:4d}")
    print(f"Klines 独有:         {stats['klines_only']:4d}")
    print(f"两者都为空:          {stats['both_empty']:4d}")
    print(f"API 错误:            {stats['klines_error']:4d}")
    print(f"Matrix 异常:         {stats['matrix_error']:4d}")

    # Detailed reporting
    if stats["matrix_only"] > 0:
        print(f"\n{'='*80}")
        print(f"🐱 Cat1 — Matrix 有 N 型但 Klines 没有 (可能 Matrix 过滤不到位)")
        print(f"{'='*80}")
        for k, d in sorted(results.items()):
            if d["status"] == "matrix_only":
                mn = d["matrix_n"]
                print(f"  {d['name']:20s} {d['sym']:6s}/{d['contract']:6s}/{d['tf']:4s}  →  dir={mn['dir']:6s}  a={mn['a']}  b={mn['b']}  c={mn['c']}")

    if stats["dir_mismatch"] > 0 or stats["abc_mismatch"] > 0:
        print(f"\n{'='*80}")
        print(f"❌ 不一致详情（方向/ABC 数据不匹配）")
        print(f"{'='*80}")
        for k, d in sorted(results.items()):
            if d["status"] == "mismatch" and (d.get("dir_diffs") or d.get("abc_diffs")):
                mn = d["matrix_n"]
                kn = d["klines_n"]
                regions = []
                if d.get("dir_diffs"):
                    regions.append("方向")
                if d.get("abc_diffs"):
                    regions.append("ABC")
                if d.get("ts_diffs"):
                    regions.append("时间戳")
                if d.get("state_diffs"):
                    regions.append("状态")
                print(f"  ❌ {d['name']:20s} {d['sym']:6s}/{d['contract']:6s}/{d['tf']:4s}  [{','.join(regions)}]")
                print(f"     Matrix: dir={mn['dir']:6s}  A={mn['a']:>10}  B={mn['b']:>10}  C={mn['c']:>10}  state={mn.get('state','')}")
                print(f"     Klines: dir={kn['dir']:6s}  A={kn['a']:>10}  B={kn['b']:>10}  C={kn['c']:>10}  state={kn.get('state','')}")
                if d.get("ts_diffs"):
                    print(f"     Timestamps: at={ts2str(mn.get('at'))} vs {ts2str(kn.get('at'))}")

    if stats["klines_only"] > 0:
        print(f"\n{'='*80}")
        print(f"⬜ Klines 有但 Matrix 没有 (反向 Cat1)")
        print(f"{'='*80}")
        for k, d in sorted(results.items()):
            if d["status"] == "klines_only":
                kn = d["klines_n"]
                print(f"  {d['name']:20s} {d['sym']:6s}/{d['contract']:6s}/{d['tf']:4s}  →  dir={kn['dir']:6s}  a={kn['a']}  b={kn['b']}  c={kn['c']}")

    if stats["match"] > 0:
        print(f"\n{'='*80}")
        print(f"✅ 完全一致 (前 20 条)")
        print(f"{'='*80}")
        count = 0
        for k, d in sorted(results.items()):
            if d["status"] == "match" and count < 20:
                mn = d["matrix_n"]
                print(f"  ✅ {d['name']:20s} {d['sym']:6s}/{d['contract']:6s}/{d['tf']:4s}  dir={mn['dir']:6s}  A→{mn['a']}  B→{mn['b']}  C→{mn['c']}")
                count += 1
        if count == 20 and stats["match"] > 20:
            print(f"  ... 还有 {stats['match'] - 20} 条一致记录 (省略)")

    # Summary statistics
    total_with_data = stats["matrix_has_n"] + stats["klines_has_n"] - stats["match"]
    if stats["matrix_has_n"] > 0 or stats["klines_has_n"] > 0:
        error_rate = (stats["dir_mismatch"] + stats["abc_mismatch"] + stats["matrix_only"]) / max(stats["matrix_has_n"], 1) * 100
    else:
        error_rate = 0
    match_rate = stats["match"] / max(stats["matrix_has_n"], 1) * 100 if stats["matrix_has_n"] > 0 else 100

    print(f"\n{'='*80}")
    print(f"📈 最终评估")
    print(f"{'='*80}")
    print(f"  Matrix 有数据:     {stats['matrix_has_n']:4d}")
    print(f"  完全一致:          {stats['match']:4d} ({match_rate:.1f}%)")
    print(f"  Matrix 独有 (Cat1): {stats['matrix_only']:4d}")
    print(f"  方向/ABC 不一致:   {stats['dir_mismatch'] + stats['abc_mismatch']:4d}")
    print(f"  API 错误:          {stats['klines_error']:4d}")
    print(f"  错误率:            {error_rate:.1f}%")

    if stats["matrix_only"] == 0 and stats["dir_mismatch"] == 0 and stats["abc_mismatch"] == 0:
        print("\n🎉 结论: 验证通过! Matrix 与 Klines 的 N 型结构数据完全一致，无 Cat1/Cat2 残留差异。")
    elif stats["matrix_only"] == 0 and (stats["dir_mismatch"] > 0 or stats["abc_mismatch"] > 0):
        print(f"\n⚠️ 结论: Cat1 已消除 (0 条 Matrix 独有)，但仍有 {stats['dir_mismatch'] + stats['abc_mismatch']} 条方向/ABC 不一致需检查。")
    else:
        print(f"\n⚠️ 结论: 仍有 {stats['matrix_only']} 条 Matrix 独有 (Cat1) + {stats['dir_mismatch'] + stats['abc_mismatch']} 条不一致。")
        print("   Cat1 可能是 Matrix 中还有品种未正确过滤。")

    return results, stats

if __name__ == "__main__":
    results, stats = main()