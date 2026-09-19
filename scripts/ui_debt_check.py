#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ui_debt_check.py —— UI 欠账机械检查门禁（analysis/11-ui-design.md §十一.5）。

作用：扫描 WanWo/UI/**.swift 中的占位/欠账标记，与 scripts/ui-debts-allowed.txt
（登记白名单）对账——白名单外的标记=未登记欠账，退出码 1（CI/提交前拦截）。

背景（四轮失败复盘·病根 2/3）：编译修复期引入的占位（noop）曾把主入口变成死路
（9-19）；骨架期妥协混进"完成"宣布（9-20 复盘）。本脚本把「欠账必须登记」变成机械约束。

用法：python scripts/ui_debt_check.py [repo_root]   # 默认=脚本上级目录
退出码：0=对账通过；1=存在白名单外欠账；2=白名单文件缺失。
"""
import re
import sys
from pathlib import Path

MARKERS = re.compile(r"\b(TODO|FIXME|XXX|HACK)\b|noop|占位待|待接线|未接线|骨架期占位")
# 「占位」单字出现在合法占位视图命名（WOSlotPlaceholder）中——排除类名/文件名场景。
PLACEHOLDER_OK = re.compile(r"WOSlotPlaceholder|placeholderText|\.placeholder")

def main() -> int:
    repo = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    ui_dir = repo / "WanWo" / "UI"
    allowed_file = repo / "scripts" / "ui-debts-allowed.txt"
    if not allowed_file.exists():
        print(f"[ui-debt-check] 白名单缺失：{allowed_file}", file=sys.stderr)
        return 2
    allowed = {
        line.strip() for line in allowed_file.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.strip().startswith("#")
    }

    findings: list[str] = []
    for swift in sorted(ui_dir.rglob("*.swift")):
        rel = swift.relative_to(repo).as_posix()
        for lineno, line in enumerate(swift.read_text(encoding="utf-8").splitlines(), 1):
            if PLACEHOLDER_OK.search(line):
                continue
            if MARKERS.search(line):
                findings.append(f"{rel}:{lineno}: {line.strip()[:160]}")

    unregistered = [f for f in findings if not any(a in f for a in allowed)]
    registered = len(findings) - len(unregistered)
    print(f"[ui-debt-check] 扫描 WanWo/UI/**.swift：标记 {len(findings)} 处"
          f"（已登记 {registered} / 白名单外 {len(unregistered)}）")
    for f in unregistered:
        print(f"  未登记欠账 → {f}")
    if unregistered:
        print("[ui-debt-check] FAIL：存在未登记欠账——先登记 11-ui-design §十五 再提交。")
        return 1
    print("[ui-debt-check] PASS")
    return 0

if __name__ == "__main__":
    sys.exit(main())
