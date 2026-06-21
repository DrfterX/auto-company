#!/bin/bash
# ============================================================
# Auto Company — 验证层 (verify.sh)
# 每轮 Claude 代码修改后自动执行。
# 不通过 → auto-loop.sh 回滚代码，标记失败。
# ============================================================
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OAS_DIR="$PROJECT_DIR/projects/options_arbitrage_system"
DB="$OAS_DIR/trading_system.db"
VENV="$OAS_DIR/.venv/bin/python"
FAIL=0
FAIL_REASONS=""

log() { echo "[verify] $1"; }
fail() { FAIL=1; FAIL_REASONS="$FAIL_REASONS\n  - $1"; log "FAIL: $1"; }

# ── 0. 检查是否有代码改动（没改动就跳过验证）──
CHANGED_FILES=$(cd "$OAS_DIR" && git diff --name-only 2>/dev/null | head -20)
ROOT_CHANGED=$(cd "$PROJECT_DIR" && git diff --name-only 2>/dev/null | head -20)
if [ -z "$CHANGED_FILES" ] && [ -z "$ROOT_CHANGED" ]; then
    log "No code changes detected — skipping verification"
    echo "VERIFY: PASS (no changes)"
    exit 0
fi

# ── 1. Python 语法检查 ──
log "1/5 Python syntax check..."
if [ -n "$CHANGED_FILES" ]; then
    PY_FILES=$(echo "$CHANGED_FILES" | grep '\.py$' || true)
    if [ -n "$PY_FILES" ]; then
        for f in $PY_FILES; do
            if [ -f "$OAS_DIR/$f" ]; then
                $VENV -m py_compile "$OAS_DIR/$f" 2>/dev/null || fail "Syntax error in $f"
            fi
        done
    fi
fi
[ "$FAIL" = "0" ] && log "  syntax OK" || true

# ── 2. Flask 能启动 + API 健康 ──
log "2/5 Flask API health..."
cd "$OAS_DIR"
$VENV -c "
import sys, json, signal
signal.alarm(15)  # 15秒超时
sys.path.insert(0, '.')
try:
    from web.app import app
    with app.test_client() as c:
        r = c.get('/api/summary')
        assert r.status_code == 200, f'API returned {r.status_code}'
        d = json.loads(r.data)
        fc = d.get('futures_count', 0)
        oc = d.get('options_count', 0)
        assert fc > 0, f'futures_count={fc}'
        assert oc > 0, f'options_count={oc}'
    print(f'  API OK: {fc} futures, {oc} options')
except Exception as e:
    print(f'  API FAIL: {e}')
    sys.exit(1)
" 2>&1 || fail "Flask API check failed"
cd "$PROJECT_DIR"

# ── 3. 数据库完整性 ──
log "3/5 Database integrity..."
if [ -f "$DB" ]; then
    KLINES=$(sqlite3 "$DB" "SELECT COUNT(*) FROM futures_klines" 2>/dev/null || echo "0")
    if [ "$KLINES" -lt 10000 ] 2>/dev/null; then
        fail "futures_klines too few: $KLINES (expected >10000)"
    else
        log "  klines: $KLINES OK"
    fi

    # 检查关键表是否存在且非空
    for table in futures_klines futures_swing_points futures_n_structures; do
        COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM $table" 2>/dev/null || echo "0")
        if [ "$COUNT" = "0" ]; then
            fail "$table is empty"
        fi
    done
else
    fail "Database file not found: $DB"
fi

# ── 4. 算法抽样验证 ──
log "4/5 Algorithm spot check..."
if [ -f "$DB" ]; then
    # N型结构: 检查 high/low 值是否合理（不为 NULL，不为 0）
    BAD_NS=$(sqlite3 "$DB" "
        SELECT COUNT(*) FROM futures_n_structures
        WHERE high IS NULL OR low IS NULL OR high = 0 OR low = 0
        OR high < low
    " 2>/dev/null || echo "0")
    if [ "$BAD_NS" -gt 0 ] 2>/dev/null; then
        fail "N-structure has $BAD_NS invalid rows (high<low or null)"
    else
        log "  N-structure data valid"
    fi

    # 摆动点: 检查价格在合理范围
    BAD_SWING=$(sqlite3 "$DB" "
        SELECT COUNT(*) FROM futures_swing_points
        WHERE price IS NULL OR price <= 0
    " 2>/dev/null || echo "0")
    if [ "$BAD_SWING" -gt 0 ] 2>/dev/null; then
        fail "swing_points has $BAD_SWING invalid rows (null or <=0 price)"
    else
        log "  swing_points data valid"
    fi
fi

# ── 5. git diff 合理性检查 ──
log "5/5 Diff sanity check..."
if [ -n "$CHANGED_FILES" ]; then
    # 检查没有意外删除关键文件
    DELETED=$(cd "$OAS_DIR" && git diff --name-only --diff-filter=D 2>/dev/null | grep -E '\.py$' || true)
    if [ -n "$DELETED" ]; then
        fail "Python files deleted: $DELETED"
    fi

    # 检查没有巨大的意外变更（>500行改动需要警告）
    DIFF_LINES=$(cd "$OAS_DIR" && git diff --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
    if [ "$DIFF_LINES" -gt 500 ] 2>/dev/null; then
        log "  WARNING: Large diff ($DIFF_LINES lines) — verify carefully"
    fi
fi

# ── 结果 ──
echo ""
if [ "$FAIL" = "1" ]; then
    echo "VERIFY: FAIL"
    echo -e "Reasons:$FAIL_REASONS"
    exit 1
fi
echo "VERIFY: PASS"
exit 0
