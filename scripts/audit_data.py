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
CHANNEL_BY_NETWORK = {
    "NW01": "041", "NW02": "051", "NW03": "061", "NW04": "071", "NW05": "081"
}
EXPECTED_RAW_VIEWING_ROWS = 1_050_648
EXPECTED_CLEAN_VIEWING_ROWS = 1_050_000


def read_csv(name: str):
    with gzip.open(DATA_DIR / f"{name}.csv.gz", "rt", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def fail(message: str):
    raise AssertionError(message)


def dates_in_range(start: date, end: date):
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)


def main():
    networks = read_csv("network_master")
    programs = read_csv("program_master")
    schedule = read_csv("program_schedule")
    creatives = read_csv("cm_master")
    spots = read_csv("cm_spot")
    panels = read_csv("panel_demographics")

    if {(row["NETWORK_ID"], row["CHANNEL_CODE"]) for row in networks} != set(CHANNEL_BY_NETWORK.items()):
        fail("局マスタのIDとチャンネルが想定と一致しません")

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
    expected_keys = {(d, network_id) for d in dates_in_range(PERIOD_START, PERIOD_END) for network_id in NETWORK_IDS}
    if set(schedule_by_day_network) != expected_keys:
        fail("番組表の日・局に不足または余分な組み合わせがあります")
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
    if set(spots_by_day_network) != expected_keys:
        fail("CMの日・局に不足または余分な組み合わせがあります")

    if len(panels) != 2000 or len({row["COMMON_ID"] for row in panels}) != 2000:
        fail("パネル対象が重複なしの2000台ではありません")

    viewing_rows = 0
    view_starts_by_hour = Counter()
    clean_intervals_by_device = defaultdict(list)
    seen_rows = set()
    reversed_rows = 0
    too_long_rows = 0
    duplicate_rows = 0
    clean_rows = 0
    for network_id in sorted(NETWORK_IDS):
        rows = read_csv(f"viewing_log_{network_id.lower()}")
        viewing_rows += len(rows)
        for row in rows:
            if row["NETWORK_ID"] != network_id:
                fail(f"局別ファイルに別局の行があります: {network_id} {row['NETWORK_ID']}")
            if row["CHANNEL_CODE"] != CHANNEL_BY_NETWORK[network_id]:
                fail(f"局とチャンネルが一致しません: {network_id} {row['CHANNEL_CODE']}")
            start = datetime.fromisoformat(row["VIEW_FROM"])
            end = datetime.fromisoformat(row["VIEW_TO"])
            view_starts_by_hour[start.hour] += 1
            row_key = tuple(row.values())
            if row_key in seen_rows:
                duplicate_rows += 1
                continue
            seen_rows.add(row_key)
            if end <= start:
                reversed_rows += 1
                continue
            if end - start > timedelta(hours=24):
                too_long_rows += 1
                continue
            clean_rows += 1
            if not PERIOD_START <= start.date() <= PERIOD_END:
                fail(f"期間外の正常な視聴区間があります: {row_key}")
            if start.hour < 4 or end > datetime.combine(start.date(), datetime.min.time()) + timedelta(hours=24):
                fail(f"放送時間外の正常な視聴区間があります: {row_key}")
            clean_intervals_by_device[row["COMMON_ID"]].append(
                (start, end, row["NETWORK_ID"])
            )

    if viewing_rows != EXPECTED_RAW_VIEWING_ROWS:
        fail(f"RAW視聴行数が想定外です: {viewing_rows:,}")
    if (clean_rows, reversed_rows, too_long_rows, duplicate_rows) != (EXPECTED_CLEAN_VIEWING_ROWS, 200, 148, 300):
        fail(
            "視聴ログの正常・異常件数が想定外です: "
            f"clean={clean_rows:,}, reversed={reversed_rows}, too_long={too_long_rows}, duplicate={duplicate_rows}"
        )

    missing_rows = [
        interval for intervals in clean_intervals_by_device.values() for interval in intervals
        if interval[2] == "NW03" and interval[0].date() == date(2026, 7, 17)
    ]
    if missing_rows:
        fail("意図したNW03の欠損日に正常な視聴ログがあります")

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
    print(f"正常 {clean_rows:,} / 逆転 {reversed_rows} / 24時間超 {too_long_rows} / 重複 {duplicate_rows}")
    print("CM開始時刻（時間別）:", dict(sorted(starts_by_hour.items())))
    print("視聴開始時刻（時間別）:", dict(sorted(view_starts_by_hour.items())))


if __name__ == "__main__":
    main()