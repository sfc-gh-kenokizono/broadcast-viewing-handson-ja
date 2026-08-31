"""生成済みCSVの現実性と参照整合性を検証する。"""

from __future__ import annotations

import csv
import gzip
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path


DATA_DIR = Path(__file__).resolve().parent.parent / "data"
PERIOD_START = date(2026, 5, 1)
PERIOD_END = date(2026, 7, 31)
NETWORK_IDS = {f"NW{i:02d}" for i in range(1, 6)}


def read_csv(name: str):
    with gzip.open(DATA_DIR / f"{name}.csv.gz", "rt", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def fail(message: str):
    raise AssertionError(message)


def main():
    programs = read_csv("program_master")
    schedule = read_csv("program_schedule")
    creatives = read_csv("cm_master")
    spots = read_csv("cm_spot")

    if len({row["PROGRAM_ID"] for row in programs}) != len(programs):
        fail("PROGRAM_ID が重複しています")
    if len({row["SYNOPSIS"] for row in programs}) != len(programs):
        fail("番組概要文が重複しています")
    if len({row["CM_ID"] for row in creatives}) != len(creatives):
        fail("CM_ID が重複しています")
    if len({row["CREATIVE_DESC"] for row in creatives}) != len(creatives):
        fail("CM素材の説明文が重複しています")
    if sum(row["IS_ANALYSIS_TARGET"].lower() == "true" for row in creatives) != 20:
        fail("分析対象CM素材が20件ではありません")

    program_ids = {row["PROGRAM_ID"] for row in programs}
    schedule_by_day_network = defaultdict(list)
    for row in schedule:
        if row["PROGRAM_ID"] not in program_ids:
            fail(f"番組マスタにないID: {row['PROGRAM_ID']}")
        key = (date.fromisoformat(row["AIR_DATE"]), row["NETWORK_ID"])
        schedule_by_day_network[key].append(
            (datetime.fromisoformat(row["AIR_FROM"]), datetime.fromisoformat(row["AIR_TO"]))
        )

    days = (PERIOD_END - PERIOD_START).days + 1
    if len(schedule_by_day_network) != days * len(NETWORK_IDS):
        fail("番組表に存在しない日・局があります")
    program_counts = []
    for (air_date, network_id), slots in schedule_by_day_network.items():
        slots.sort()
        expected_start = datetime.combine(air_date, datetime.min.time()) + timedelta(hours=4)
        expected_end = datetime.combine(air_date, datetime.min.time()) + timedelta(hours=24)
        if slots[0][0] != expected_start or slots[-1][1] != expected_end:
            fail(f"放送時間が4:00-24:00ではありません: {air_date} {network_id}")
        for previous, current in zip(slots, slots[1:]):
            if previous[1] != current[0]:
                fail(f"番組枠に隙間または重複があります: {air_date} {network_id}")
        program_counts.append(len(slots))

    creative_by_id = {row["CM_ID"]: row for row in creatives}
    if len({row["SPOT_ID"] for row in spots}) != len(spots):
        fail("SPOT_ID が重複しています")
    spots_by_day_network = Counter()
    starts_by_hour = Counter()
    for row in spots:
        creative = creative_by_id.get(row["CM_ID"])
        if creative is None:
            fail(f"CMマスタにないID: {row['CM_ID']}")
        aired_at = datetime.fromisoformat(row["AIR_AT"])
        if not date.fromisoformat(creative["CAMPAIGN_FROM"]) <= aired_at.date() <= date.fromisoformat(creative["CAMPAIGN_TO"]):
            fail(f"出稿期間外の放送: {row['SPOT_ID']}")
        spots_by_day_network[(aired_at.date(), row["NETWORK_ID"])] += 1
        starts_by_hour[aired_at.hour] += 1
    if len(spots_by_day_network) != days * len(NETWORK_IDS):
        fail("CMが存在しない日・局があります")

    viewing_rows = 0
    view_starts_by_hour = Counter()
    clean_intervals_by_device = defaultdict(list)
    seen_rows = set()
    for network_id in sorted(NETWORK_IDS):
        rows = read_csv(f"viewing_log_{network_id.lower()}")
        viewing_rows += len(rows)
        for row in rows:
            start = datetime.fromisoformat(row["VIEW_FROM"])
            end = datetime.fromisoformat(row["VIEW_TO"])
            view_starts_by_hour[start.hour] += 1
            row_key = tuple(row.values())
            if row_key in seen_rows:
                continue
            seen_rows.add(row_key)
            if end <= start or end - start > timedelta(hours=24):
                continue
            clean_intervals_by_device[row["COMMON_ID"]].append(
                (start, end, row["NETWORK_ID"])
            )

    for common_id, intervals in clean_intervals_by_device.items():
        intervals.sort()
        for previous, current in zip(intervals, intervals[1:]):
            if previous[1] > current[0]:
                fail(
                    "同じTVの正常な視聴区間が重なっています: "
                    f"{common_id} {previous} {current}"
                )

    print("DATA AUDIT: PASS")
    print(f"番組マスタ: {len(programs):,}（概要文 {len(programs):,} 種類）")
    print(f"番組放送枠: {len(schedule):,}（1局1日 {sum(program_counts) / len(program_counts):.1f} 枠、20時間）")
    print(f"CM素材: {len(creatives):,}（分析対象 20）")
    print(f"CM放送実績: {len(spots):,}（1局1日 {len(spots) / days / len(NETWORK_IDS):.1f} 本）")
    print(f"視聴区間: {viewing_rows:,}")
    print("正常化後の同一TV内の時間重複: 0")
    print("CM開始時刻（時間別）:", dict(sorted(starts_by_hour.items())))
    print("視聴開始時刻（時間別）:", dict(sorted(view_starts_by_hour.items())))


if __name__ == "__main__":
    main()