"""Reconcile an Indonesia monitor snapshot offline. All money fields are CNY."""
import argparse
import json
import math
from pathlib import Path


def same_amount(actual, expected, label):
    if not math.isclose(actual, expected, abs_tol=0.02, rel_tol=0):
        raise ValueError(f"{label}: {actual:.2f} vs {expected:.2f}")


def summary(rows):
    cash = sum(row["mtd_cash_cny"] for row in rows)
    pace = sum(row["workday_tracking_mtd_target_cny"] for row in rows)
    target = sum(row["tracking_target_cny"] for row in rows)
    return cash, pace, target


def display(label, rows):
    cash, pace, target = summary(rows)
    attainment = f"{cash / pace:.1%}" if pace > 0 else "—"
    completion = f"{cash / target:.1%}" if target > 0 else "—"
    print(f"{label}  实收 {cash:,.2f}  序时目标 {pace:,.2f}  "
          f"序时达成 {attainment}  月目标完成 {completion}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    report = json.loads(parser.parse_args().snapshot.read_text(encoding="utf-8-sig"))
    regular = report["main"]
    freeze = report["freeze_monitor"]["main"]
    rows = regular + freeze
    keys = [(row["stage"], row["mode"]) for row in rows]
    if len(set(keys)) != len(keys):
        raise ValueError("账龄×模式汇总键重复")
    reconciliation = report["receipt_reconciliation"]
    if reconciliation["date"] != report["meta"]["as_of"]:
        raise ValueError("对账日期与经营快照不一致")
    cash, _, _ = summary(rows)
    same_amount(cash, reconciliation["total_cny"], "经营和对账合计")
    same_amount(cash, reconciliation["normal_cny"] + reconciliation["other_cny"], "正常与Other")
    same_amount(cash - reconciliation["finance_cny"], reconciliation["difference_cny"], "财务差额")
    print(report["meta"]["as_of"], "人民币元，业绩追踪目标")
    display("整体", rows)
    for stage in ("M2", "M3", "M4-7", "M7+"):
        display(stage, [row for row in regular if row["stage"] == stage])
    display("常规人催", [row for row in regular if row["mode"] in {"专催", "委外"}])
    display("冻结＋Other", freeze)
    print(f"监控减财务 {reconciliation['difference_cny']:,.2f} 元")


if __name__ == "__main__":
    main()
