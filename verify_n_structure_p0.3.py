"""
P0.3 — 逐周期验证 N 型结构标点正确性

对所有活跃品种 × 所有周期逐个检查 K 线浮窗的 4 点标点：
1. 读 DB 中当前活跃 N 型结构的 A/B/C 价格
2. 用修改后的算法重新计算，对比新旧结果
3. 记录不符合算法定义的周期和品种
4. 输出验证报告

算法判定（User Directives 定义）：
  上升 N 型：
    1. B > A（第一笔上涨）
    2. C < B（第二笔下跌）
    3. C > A（C 不破 A）
    4. 最新价 > C（潜在第三笔向上）
  下降 N 型：
    1. A > B（第一笔下跌）
    2. C > B（第二笔上涨）
    3. C < A（C 不高于 A）
    4. 最新价 < C（潜在第三笔向下）
"""

import datetime
import logging
import sys
from pathlib import Path

# ── 路径 ──────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent / "projects/options_arbitrage_system"
sys.path.insert(0, str(PROJECT_ROOT))

from core.db import Database
from config.settings import DB_PATH, DETECT_WINDOWS
from futures.n_structure import (
    detect_and_save,
    _get_swing_points,
    _merge_same_type,
    _find_n_structure_forward,
    _determine_overall_direction,
    _determine_direction,
    _get_klines,
)
import sqlite3

logging.basicConfig(level=logging.WARNING, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

TZ = datetime.timezone(datetime.timedelta(hours=8), "CST")
TIMEFRAMES = ["15m", "1h", "1d", "1w"]


def check_abc_definition(direction: str,
                         a_price: float, b_price: float, c_price: float,
                         current_price: float | None = None) -> list[str]:
    """检查 ABC 点是否符合 N 型算法定义，返回 violation 列表（空=全部通过）。"""
    violations = []

    if direction == "LONG":
        # 1. B > A（第一笔上涨）
        if b_price <= a_price:
            violations.append(f"条件1失败：B({b_price}) <= A({a_price})，第一笔未上涨")
        # 2. C < B（第二笔下跌）
        if c_price >= b_price:
            violations.append(f"条件2失败：C({c_price}) >= B({b_price})，第二笔未下跌")
        # 3. C > A（C 不破 A）
        if c_price <= a_price:
            violations.append(f"条件3失败：C({c_price}) <= A({a_price})，C 破 A")
        # 4. 最新价 > C
        if current_price is not None and current_price <= c_price:
            violations.append(f"条件4失败：最新价({current_price}) <= C({c_price})，第三笔未向上破位")
    elif direction == "SHORT":
        # 1. A > B（第一笔下跌）
        if a_price <= b_price:
            violations.append(f"条件1失败：A({a_price}) <= B({b_price})，第一笔未下跌")
        # 2. C > B（第二笔上涨）
        if c_price <= b_price:
            violations.append(f"条件2失败：C({c_price}) <= B({b_price})，第二笔未上涨")
        # 3. C < A（C 不高于 A）
        if c_price >= a_price:
            violations.append(f"条件3失败：C({c_price}) >= A({a_price})，C 高于 A")
        # 4. 最新价 < C
        if current_price is not None and current_price >= c_price:
            violations.append(f"条件4失败：最新价({current_price}) >= C({c_price})，第三笔未向下破位")

    return violations


def get_current_prices(db: Database) -> dict:
    """读取所有活跃品种-合约-周期的最新价。"""
    prices = {}
    with db.get_conn() as conn:
        rows = conn.execute("""
            SELECT DISTINCT n.symbol, n.contract, n.timeframe
            FROM futures_n_structures n
            WHERE n.state NOT IN ('COMPLETED', 'IDLE')
        """).fetchall()

    for row in rows:
        sym, contract, tf = row["symbol"], row["contract"], row["timeframe"]
        try:
            klines = _get_klines(db, sym, contract, tf, limit=1)
            if klines:
                prices[(sym, contract, tf)] = klines[-1]["close"]
        except Exception:
            pass

    return prices


def run():
    db = Database(str(DB_PATH))

    # ── 1. 读所有活跃结构 ──────────────────────────────────
    with db.get_conn() as conn:
        active_structures = conn.execute("""
            SELECT n.*,
                   datetime(n.point_a_time, 'unixepoch') as a_time_str,
                   datetime(n.point_b_time, 'unixepoch') as b_time_str,
                   datetime(n.point_c_time, 'unixepoch') as c_time_str
            FROM futures_n_structures n
            WHERE n.state NOT IN ('COMPLETED', 'IDLE')
            ORDER BY n.symbol, n.timeframe
        """).fetchall()

    print(f"\n{'='*80}")
    print(f"  P0.3 — N 型结构标点正确性验证报告")
    print(f"  生成时间: {datetime.datetime.now(TZ).strftime('%Y-%m-%d %H:%M:%S')} CST")
    print(f"  活跃结构总数: {len(active_structures)}")
    print(f"{'='*80}\n")

    # ── 2. 最新价 ──────────────────────────────────────────
    current_prices = get_current_prices(db)

    # ── 汇总统计 ────────────────────────────────────────────
    total = 0
    passed = 0
    violations_found: list[dict] = []
    label_mismatches: list[dict] = []
    direction_changes: list[dict] = []
    new_found_empty: list[dict] = []
    per_timeframe: dict[str, dict] = {tf: {"total": 0, "passed": 0, "failed": 0}
                                       for tf in TIMEFRAMES}
    per_symbol: dict[str, dict] = {}

    # ── 3. 逐个验证 ────────────────────────────────────────
    for row in active_structures:
        sym = row["symbol"]
        contract = row["contract"]
        tf = row["timeframe"]

        if contract == sym:
            label = f"{sym:<6} {tf:<4} (index)"
        else:
            label = f"{sym:<6} {tf:<4} ({contract})"

        total += 1
        per_timeframe.setdefault(tf, {"total": 0, "passed": 0, "failed": 0})
        per_timeframe[tf]["total"] += 1

        per_symbol.setdefault(sym, {"total": 0, "passed": 0, "failed": 0})
        per_symbol[sym]["total"] += 1

        stored = {
            "direction": row["direction"],
            "state": row["state"],
            "point_a_price": row["point_a_price"],
            "point_b_price": row["point_b_price"],
            "point_c_price": row["point_c_price"],
            "point_a_time": row["point_a_time"],
            "point_b_time": row["point_b_time"],
            "point_c_time": row["point_c_time"],
            "a_time_str": row["a_time_str"],
            "b_time_str": row["b_time_str"],
            "c_time_str": row["c_time_str"],
        }

        current_price = current_prices.get((sym, contract, tf))

        # ── 3a. 检查当前存储点是否符合算法定义 ──────────
        violations = check_abc_definition(
            stored["direction"],
            stored["point_a_price"],
            stored["point_b_price"],
            stored["point_c_price"],
            current_price,
        )

        # ── 3b. 用算法重新计算 ──────────────────────────
        try:
            new_result = detect_and_save(sym, contract, tf, db)
        except Exception as e:
            print(f"  ❌ {label} — 算法异常: {e}")
            violations_found.append({
                "symbol": sym, "contract": contract, "timeframe": tf,
                "issue": f"算法异常: {e}",
                "violations": [],
            })
            per_timeframe[tf]["failed"] += 1
            per_symbol[sym]["failed"] += 1
            continue

        # ── 3c. 算法结果对比 ────────────────────────────
        if not new_result.get("is_active"):
            # 算法认为不活跃
            direction_change = ""
            if stored["direction"] != (new_result.get("direction") or "N/A"):
                direction_change = f" (方向变化: {stored['direction']}→{new_result.get('direction', 'N/A')})"

            if new_result.get("state") == "IDLE":
                reason = new_result.get("reason", "未知")
                new_found_empty.append({
                    "symbol": f"{sym:<6}",
                    "contract": contract,
                    "timeframe": tf,
                    "stored_state": stored["state"],
                    "stored_dir": stored["direction"],
                    "reason": reason,
                    "dir_change": direction_change,
                })
        else:
            # 算法有活跃结构 — 比较标点
            new_a = new_result["point_a_price"]
            new_b = new_result["point_b_price"]
            new_c = new_result["point_c_price"]
            new_dir = new_result["direction"]

            a_match = abs(new_a - stored["point_a_price"]) < 0.01
            b_match = abs(new_b - stored["point_b_price"]) < 0.01
            c_match = abs(new_c - stored["point_c_price"]) < 0.01
            dir_match = new_dir == stored["direction"]
            all_match = a_match and b_match and c_match and dir_match

            if not all_match:
                label_mismatches.append({
                    "symbol": f"{sym:<6}",
                    "contract": contract,
                    "timeframe": tf,
                    "stored": f"A={stored['point_a_price']} B={stored['point_b_price']} C={stored['point_c_price']} ({stored['direction']})",
                    "recomputed": f"A={new_a} B={new_b} C={new_c} ({new_dir})",
                })

        # ── 3d. 判定总结果 ──────────────────────────────
        has_violations = len(violations) > 0
        has_mismatch = not all_match if new_result.get("is_active") else False

        if has_violations:
            violations_found.append({
                "symbol": sym, "contract": contract, "timeframe": tf,
                "stored": stored,
                "violations": violations,
                "current_price": current_price,
                "new_result": new_result if new_result.get("is_active") else None,
            })
            status = "❌"
            per_timeframe[tf]["failed"] += 1
            per_symbol[sym]["failed"] += 1
        elif has_mismatch:
            status = "⚠️"
            per_timeframe[tf]["passed"] += 1  # 标点不同但定义检查通过
            per_symbol[sym]["passed"] += 1
        else:
            status = "✅"
            per_timeframe[tf]["passed"] += 1
            per_symbol[sym]["passed"] += 1
            passed += 1

    # ── 4. 输出报告 ──────────────────────────────────────────

    print(f"## 汇总")
    print(f"  总计: {total} | 通过: {passed} | 标点偏差(⚠️): {len(label_mismatches)} "
          f"| 定义违规(❌): {len(violations_found)} "
          f"| 算法返回非活跃: {len(new_found_empty)}")
    print()

    # ── 按周期 ──────────────────────────────────────────────
    print(f"## 按周期统计")
    for tf in TIMEFRAMES:
        stats = per_timeframe.get(tf, {"total": 0, "passed": 0, "failed": 0})
        pct = stats["passed"] / stats["total"] * 100 if stats["total"] > 0 else 0
        bar = "█" * int(pct / 10) + "░" * (10 - int(pct / 10))
        print(f"  {tf:<4}: {stats['total']:>3} 个 | ✅ {stats['passed']:>3} | ❌ {stats['failed']:>3} | {pct:5.1f}% {bar}")
    print()

    # ── 按品种 ──────────────────────────────────────────────
    print(f"## 按品种统计（仅显示失败品种）")
    failed_symbols = {sym: st for sym, st in per_symbol.items() if st["failed"] > 0}
    if failed_symbols:
        for sym, st in sorted(failed_symbols.items()):
            pct = st["passed"] / st["total"] * 100 if st["total"] > 0 else 0
            print(f"  {sym:<6}: {st['total']:>3} 个 | ✅ {st['passed']:>3} | ❌ {st['failed']:>3} | {pct:5.1f}%")
    else:
        print(f"  (无品种有失败项)")
    print()

    # ── 算法定义违规（❌）──────────────────────────────────
    if violations_found:
        print(f"## 算法定义违规 (❌)")
        print(f"  共 {len(violations_found)} 条")
        print()
        for v in violations_found:
            sym = v["symbol"]
            contract = v["contract"]
            tf = v["timeframe"]
            if contract == sym:
                label = f"{sym:<6} {tf:<4} (index)"
            else:
                label = f"{sym:<6} {tf:<4} ({contract})"

            stored = v["stored"]
            print(f"  ❌ {label}")
            print(f"     存储: A={stored['point_a_price']} B={stored['point_b_price']} "
                  f"C={stored['point_c_price']} dir={stored['direction']} "
                  f"({stored['a_time_str']} → {stored['b_time_str']} → {stored['c_time_str']})")
            if v["current_price"] is not None:
                print(f"     最新价: {v['current_price']}")
            else:
                print(f"     最新价: N/A")
            for viol in v["violations"]:
                print(f"     └─ {viol}")
            print()
    else:
        print(f"## 算法定义违规 (❌)")
        print(f"  ✅ 未发现算法定义违规")
        print()

    # ── 标点偏差（⚠️）──────────────────────────────────────
    if label_mismatches:
        print(f"## 标点偏差 (⚠️ — 存储与重算不一致但定义检查通过)")
        print(f"  共 {len(label_mismatches)} 条")
        print()
        for m in label_mismatches:
            print(f"  ⚠️  {m['symbol']} {m['timeframe']:<4} ({m['contract']})")
            print(f"      存储:    {m['stored']}")
            print(f"      重算:    {m['recomputed']}")
            print()
    else:
        print(f"## 标点偏差 (⚠️)")
        print(f"  ✅ 全部一致")
        print()

    # ── 算法返回非活跃 ────────────────────────────────────
    if new_found_empty:
        print(f"## 算法返回非活跃 (DB 有活跃结构但算法计算后不活跃)")
        print(f"  共 {len(new_found_empty)} 条")
        print(f"  (可能由条件 4 硬过滤导致，需人工确认)")
        print()
        for item in new_found_empty:
            print(f"  ⚠️  {item['symbol']} {item['timeframe']:<4} ({item['contract']})")
            print(f"      DB 存储: {item['stored_dir']} / {item['stored_state']}")
            print(f"      算法状态: IDLE — {item['reason']}{item['dir_change']}")
            print()
    else:
        print(f"## 算法返回非活跃")
        print(f"  ✅ 全部一致（DB 活跃结构算法也判定为活跃）")
        print()

    # ── 保存报告 ──────────────────────────────────────────
    report_path = Path(__file__).resolve().parent / "docs/verify-p0-n-structure.md"
    report_path.parent.mkdir(parents=True, exist_ok=True)

    with open(report_path, "w") as f:
        f.write(f"# P0.3 — N 型结构标点正确性验证报告\n\n")
        f.write(f"- **生成时间**: {datetime.datetime.now(TZ).strftime('%Y-%m-%d %H:%M:%S')} CST\n")
        f.write(f"- **活跃结构总数**: {len(active_structures)}\n")
        f.write(f"- **通过**: {passed} | **标点偏差(⚠️)**: {len(label_mismatches)} | "
                f"**定义违规(❌)**: {len(violations_found)} | "
                f"**算法返回非活跃**: {len(new_found_empty)}\n\n")

        # 按周期
        f.write("## 按周期统计\n\n")
        for tf in TIMEFRAMES:
            stats = per_timeframe.get(tf, {"total": 0, "passed": 0, "failed": 0})
            pct = stats["passed"] / stats["total"] * 100 if stats["total"] > 0 else 0
            f.write(f"| {tf} | {stats['total']} | ✅ {stats['passed']} | ❌ {stats['failed']} | {pct:.1f}% |\n")
        f.write("\n")

        # 违规
        f.write("## 算法定义违规\n\n")
        if violations_found:
            f.write("| 品种 | 周期 | 合约 | 方向 | A | B | C | 最新价 | 违规描述 |\n")
            f.write("|------|------|------|------|---|----|----|--------|----------|\n")
            for v in violations_found:
                st = v["stored"]
                for viol in v["violations"]:
                    f.write(f"| {v['symbol']} | {v['timeframe']} | {v['contract']} | "
                            f"{st['direction']} | {st['point_a_price']} | "
                            f"{st['point_b_price']} | {st['point_c_price']} | "
                            f"{v['current_price'] or 'N/A'} | {viol} |\n")
        else:
            f.write("✅ 未发现算法定义违规\n")
        f.write("\n")

        # 标点偏差
        f.write("## 标点偏差\n\n")
        if label_mismatches:
            f.write("| 品种 | 周期 | 合约 | 存储 | 重算 |\n")
            f.write("|------|------|------|------|------|\n")
            for m in label_mismatches:
                f.write(f"| {m['symbol'].strip()} | {m['timeframe']} | {m['contract']} | "
                        f"{m['stored']} | {m['recomputed']} |\n")
        else:
            f.write("✅ 全部一致\n")
        f.write("\n")

        # 算法返回非活跃
        f.write("## 算法返回非活跃（DB 活跃但重算后 IDLE）\n\n")
        if new_found_empty:
            f.write("| 品种 | 周期 | 合约 | DB方向 | 原因 |\n")
            f.write("|------|------|------|--------|------|\n")
            for item in new_found_empty:
                f.write(f"| {item['symbol'].strip()} | {item['timeframe']} | "
                        f"{item['contract']} | {item['stored_dir']} | "
                        f"{item['reason']}{item['dir_change']} |\n")
            f.write("\n> 注：这些品种 DB 中存储为活跃结构，但当前算法计算后变为 IDLE。\n")
            f.write("> 可能原因：条件 4 硬过滤（最新价方向不匹配）、极值点不足、或 DB 数据未及时同步。\n")
        else:
            f.write("✅ 全部一致\n")
        f.write("\n")

    print(f"📄 详细报告已保存: {report_path}")

    # ── 结论摘要 ──────────────────────────────────────────
    print(f"\n{'='*80}")
    print(f"  结论摘要")
    print(f"{'='*80}")
    if violations_found:
        print(f"  ❌ {len(violations_found)} 个结构存在算法定义违规，需要修复")
    else:
        print(f"  ✅ 所有活跃结构的 ABC 标点均符合算法定义")
    if label_mismatches:
        print(f"  ⚠️  {len(label_mismatches)} 个结构存储与重算标点不一致（定义检查通过）")
    else:
        print(f"  ✅ 存储标点与算法重算结果全部一致")
    if new_found_empty:
        print(f"  ⚠️  {len(new_found_empty)} 个结构 DB 标记为活跃但算法判定 IDLE（条件 4）")
    else:
        print(f"  ✅ 活跃结构全部通过算法判定")

    return violations_found, label_mismatches, new_found_empty


if __name__ == "__main__":
    violations, mismatches, empty = run()