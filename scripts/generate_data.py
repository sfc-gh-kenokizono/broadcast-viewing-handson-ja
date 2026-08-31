#!/usr/bin/env python3
"""放送視聴データ活用ハンズオン用のサンプルデータを生成する。

すべて架空のデータで、実在の放送局・番組・広告主とは関係がない。
生成物は data/ 配下に gzip 圧縮した CSV として出力し、Snowflake からは
Git リポジトリステージ経由で COPY INTO する。

使い方:
    python3 scripts/generate_data.py
    python3 scripts/generate_data.py --viewing-per-network 100000 --seed 7

設計の意図:
  - 対象は地上波 5 局の非特定視聴データだけ。配信（見逃し）は含めない。
    放送と配信を紐付けるには名寄せが必要で、そこが最大の論点になるため、
    名寄せ済みを前提にしたデータは作らない。
  - 1 行 = 1 視聴区間（from-to）。放送の非特定視聴データの粒度に合わせる。
  - ID は 3 階層（各局 ID / 共通 ID / IP アドレス）。各局 ID は局をまたいで一致しない。
  - 属性は 10 パーセントの端末にしか存在しない。世帯人数も個人属性も視聴ログには入れない。
  - 視聴は番組の放送枠に紐づけて発生させる。そうしないと番組別の集計が意味を持たない。
  - 端末の嗜好は「強すぎない」ようにする。作られたデータに見えないための調整。
  - クレンジングの章が空回りしないよう、異常値と欠落を意図的に混ぜる。
  - 番組表は各局 4 時から 24 時まで切れ目なく編成する。
  - コマーシャルは 20 分ごとの 3 分ブレークに、6 / 15 / 30 秒素材を並べる。
    CM_SPOT は局全体の在庫、AI 分析は IS_ANALYSIS_TARGET が TRUE の 20 素材に絞る。
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import random
from datetime import date, datetime, timedelta
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# 蓄積されていくデータを実感してもらうため 3 ヶ月分にしてある。
# 1 ヶ月だと月次の推移が 1 点しか出ず、伸びや季節の動きが見えない。
PERIOD_START = date(2026, 5, 1)
PERIOD_END = date(2026, 7, 31)
PERIOD_DAYS = (PERIOD_END - PERIOD_START).days      # 期間の日数 - 1（randint の上限に使う）
MISSING_DAY = date(2026, 7, 17)      # NW03 のログが届かなかった日
MISSING_NETWORK = "NW03"

NETWORKS = [
    ("NW01", "第一放送ネットワーク", "041"),
    ("NW02", "第二放送ネットワーク", "051"),
    ("NW03", "第三放送ネットワーク", "061"),
    ("NW04", "第四放送ネットワーク", "071"),
    ("NW05", "第五放送ネットワーク", "081"),
]

# 局ごとの規模の差。合計が 1 になるように配分する。
# ここを均等にすると 5 局のリーチがほぼ横一線になり、局別のグラフが意味を持たない。
NETWORK_SHARE = {"NW01": 0.27, "NW02": 0.23, "NW03": 0.20, "NW04": 0.17, "NW05": 0.13}

GENRES = ["ドラマ", "バラエティ", "アニメ", "ニュース", "スポーツ", "音楽", "映画", "情報"]

# 時間帯ごとの視聴の出やすさ。時刻は番組の開始時刻から判定する。
# ゴールデンを山にするが、以前のように 20 時台へ 70% 集中させない。
TIME_SLOTS = {
    "朝":         {"weight": 12},
    "昼":         {"weight": 8},
    "夕方":       {"weight": 14},
    "ゴールデン": {"weight": 24},
    "深夜":       {"weight": 7},
}

BROADCAST_START_HOUR = 4
BROADCAST_END_HOUR = 24
CM_BREAK_INTERVAL_MIN = 20
CM_BREAK_DURATION_SEC = 180

SEGMENTS = ["T", "F1", "F2", "F3", "M1", "M2", "M3"]

# セグメントごとの嗜好。1.0 が基準で、値が大きいほどそのジャンルを見やすい。
# 差を付けすぎると出来すぎたデータになるので 0.6 から 1.8 の範囲に収める。
SEGMENT_GENRE_AFFINITY = {
    "T":  {"アニメ": 1.8, "音楽": 1.4, "バラエティ": 1.3, "ニュース": 0.6, "情報": 0.7},
    "F1": {"ドラマ": 1.6, "バラエティ": 1.3, "音楽": 1.3, "スポーツ": 0.7},
    "F2": {"ドラマ": 1.5, "情報": 1.5, "バラエティ": 1.1, "スポーツ": 0.7},
    "F3": {"情報": 1.7, "ニュース": 1.4, "ドラマ": 1.2, "アニメ": 0.6},
    "M1": {"スポーツ": 1.7, "アニメ": 1.3, "映画": 1.3, "情報": 0.7},
    "M2": {"スポーツ": 1.5, "ニュース": 1.4, "映画": 1.2, "アニメ": 0.7},
    "M3": {"ニュース": 1.8, "スポーツ": 1.3, "情報": 1.2, "アニメ": 0.6},
}

PROGRAM_TITLES = [
    ("ドラマ", "ゴールデン", "夜明けの診療室"),
    ("ドラマ", "ゴールデン", "海辺の約束"),
    ("ドラマ", "深夜", "三番町ミステリ"),
    ("ドラマ", "ゴールデン", "花咲く食卓"),
    ("ドラマ", "昼", "午後のカルテ"),
    ("ドラマ", "ゴールデン", "刑事と猫"),
    ("ドラマ", "ゴールデン", "遠回りの帰り道"),
    ("ドラマ", "深夜", "深夜の図書室"),
    ("バラエティ", "ゴールデン", "元気満点クイズ王"),
    ("バラエティ", "ゴールデン", "きらめきトークサロン"),
    ("バラエティ", "深夜", "真夜中のネタ合戦"),
    ("バラエティ", "夕方", "帰り道のわらいばな"),
    ("バラエティ", "ゴールデン", "びっくり実験ラボ"),
    ("バラエティ", "ゴールデン", "全国どこでも旅くらべ"),
    ("バラエティ", "深夜", "こだわり酒場の夜"),
    ("バラエティ", "昼", "お昼のなぞなぞ大会"),
    ("アニメ", "夕方", "そらとぶ探検隊"),
    ("アニメ", "夕方", "まほうの給食室"),
    ("アニメ", "朝", "げんきロボくん"),
    ("アニメ", "深夜", "星屑クロニクル"),
    ("アニメ", "夕方", "きりん商店街の仲間たち"),
    ("アニメ", "深夜", "剣士と機械仕掛けの街"),
    ("アニメ", "朝", "ふしぎ動物ずかん"),
    ("ニュース", "朝", "モーニングニュース"),
    ("ニュース", "夕方", "イブニングニュース"),
    ("ニュース", "ゴールデン", "ナイトニュースアワー"),
    ("ニュース", "昼", "お昼のニュース"),
    ("ニュース", "深夜", "深夜のニュースダイジェスト"),
    ("ニュース", "朝", "けいざい朝ラボ"),
    ("スポーツ", "ゴールデン", "プロ野球中継"),
    ("スポーツ", "ゴールデン", "サッカーリーグ中継"),
    ("スポーツ", "深夜", "スポーツハイライト"),
    ("スポーツ", "夕方", "夕方のスポーツ情報"),
    ("スポーツ", "ゴールデン", "マラソン特別中継"),
    ("スポーツ", "深夜", "格闘技ナイト"),
    ("音楽", "ゴールデン", "ミュージックステージ"),
    ("音楽", "深夜", "深夜の名曲アルバム"),
    ("音楽", "夕方", "うたのじかん"),
    ("音楽", "ゴールデン", "全国のどじまん大会"),
    ("音楽", "深夜", "アコースティックナイト"),
    ("映画", "ゴールデン", "土曜シネマ劇場"),
    ("映画", "深夜", "深夜のB級映画館"),
    ("映画", "ゴールデン", "日曜名作シアター"),
    ("映画", "深夜", "海外ドラマ劇場"),
    ("映画", "ゴールデン", "アニメ映画特別上映"),
    ("情報", "朝", "あさイチ情報便"),
    ("情報", "昼", "暮らしのヒント"),
    ("情報", "夕方", "とれたて産地便"),
    ("情報", "朝", "けんこう朝ごはん"),
    ("情報", "昼", "住まいとお金の相談室"),
    ("情報", "夕方", "おでかけ天気予報"),
    ("情報", "朝", "通勤ビジネス情報"),
    ("ドラマ", "ゴールデン", "山あいの分校"),
    ("バラエティ", "ゴールデン", "大食い列島紀行"),
    ("アニメ", "夕方", "ぽかぽか村の一年"),
    ("ニュース", "ゴールデン", "特集ニュースの深層"),
    ("スポーツ", "ゴールデン", "バスケットボール中継"),
    ("音楽", "ゴールデン", "季節のうたコンサート"),
    ("映画", "深夜", "ミッドナイトサスペンス"),
    ("情報", "昼", "お昼のグルメ探訪"),
]

SYNOPSIS_TEMPLATES = {
    "ドラマ": [
        "地方の小さな町を舞台に、そこで働く人たちの日常と、ふとしたきっかけで動き出す人間関係を描く連続ドラマです。",
        "家族と仕事のあいだで揺れる主人公が、周囲の人に支えられながら少しずつ前に進んでいく物語を描きます。",
        "ひとつの事件をきっかけに、それぞれの登場人物が抱えていた過去が明らかになっていく群像劇です。",
    ],
    "バラエティ": [
        "スタジオに集まった出演者が体を張った挑戦に取り組み、その様子を笑いを交えて紹介するバラエティ番組です。",
        "毎回さまざまなテーマでクイズやゲームに挑戦し、出演者同士のかけ合いを楽しむ内容です。",
        "全国各地を訪ね、その土地の食べ物や暮らしを出演者が体験しながら紹介していきます。",
    ],
    "アニメ": [
        "小学生の主人公が不思議な仲間たちと出会い、身のまわりの小さな謎を解いていく子ども向けのアニメーションです。",
        "少年少女が力を合わせて困難に立ち向かう、家族で楽しめる冒険アニメーションです。",
        "夜の時間帯に放送している、思春期の登場人物たちの心の動きをていねいに描いたアニメーション作品です。",
    ],
    "ニュース": [
        "その日の国内外の出来事を整理して伝える報道番組です。政治や経済の動きに加え、暮らしに関わる話題も取り上げます。",
        "取材にもとづいて社会の課題を掘り下げ、専門家の解説を交えて背景まで伝える報道番組です。",
        "短い時間で主要なニュースをまとめて伝える番組です。天気やスポーツの結果も合わせて紹介します。",
    ],
    "スポーツ": [
        "プロの試合を会場から生中継し、解説を交えて見どころを伝えるスポーツ中継です。",
        "その日の各競技の結果をまとめ、注目の場面を映像で振り返るスポーツ情報番組です。",
        "選手の練習や試合前の準備にも密着し、競技の背景まで紹介するスポーツ番組です。",
    ],
    "音楽": [
        "スタジオに招いた出演者が歌を披露する音楽番組です。新曲だけでなく、長く親しまれてきた曲も取り上げます。",
        "落ち着いた雰囲気のなかで演奏を届ける、夜の時間帯の音楽番組です。",
        "全国から集まった参加者が歌を披露し、その土地のエピソードも合わせて紹介します。",
    ],
    "映画": [
        "週末の夜に劇場作品を放送する映画枠です。話題作から往年の名作まで幅広く取り上げます。",
        "深夜の時間帯に、あまり知られていない作品を紹介する映画枠です。",
        "家族で楽しめるアニメーション映画や話題の話題作を放送する映画枠です。",
    ],
    "情報": [
        "暮らしに役立つ情報を紹介する番組です。季節の食材やお金の話、健康の話題などを取り上げます。",
        "生産地を訪ねて食材の魅力を伝えたり、旬の話題を専門家と一緒に掘り下げていきます。",
        "朝の時間帯に、天気や交通、その日の予定に役立つ情報をまとめて届けます。",
    ],
}

ADVERTISERS = [
    ("清涼飲料", "みなみ野ビバレッジ", "夏の屋外で炭酸飲料を飲み、爽快な表情を見せる 15 秒の映像です。若い世代に向けた明るいトーンで、商品名を最後に大きく表示します。"),
    ("清涼飲料", "白鷺ミネラルウォーター", "山あいの水源の風景から始まり、家庭で水を飲む場面につながる落ち着いた構成です。健康志向の視聴者に向けています。"),
    ("自動車", "つばさモータース", "家族が新型の乗用車で郊外へ出かける様子を描き、安全支援機能を字幕で説明します。"),
    ("自動車", "ひばりオートリース", "通勤に車を使う会社員が、月々の料金の分かりやすさに納得する場面を中心にした説明型の内容です。"),
    ("通信", "そよかぜモバイル", "料金プランの見直しをテーマに、店頭で相談する場面を親しみやすく描いています。"),
    ("通信", "みやこネット光", "家のなかで家族がそれぞれ動画や通話を使い、通信が途切れない様子を描いています。"),
    ("小売", "まるやまストア", "週末の食料品の買い物をテーマに、旬の野菜や総菜の売り場を紹介します。"),
    ("小売", "こだま電機販売", "季節の家電の値引きを告知する短い内容で、店舗名と期間を繰り返し伝えます。"),
    ("金融", "あさひ信用金庫", "住宅の購入を検討する夫婦が窓口で相談する場面を、落ち着いた雰囲気で描いています。"),
    ("金融", "つくば少額保険", "急なけがや入院に備える保険の説明を、図とナレーションで分かりやすく伝えます。"),
    ("食品", "山彦製菓", "焼き菓子の生地を伸ばす工程を丁寧に映し、素材へのこだわりを伝える内容です。"),
    ("食品", "ふたば冷凍食品", "帰宅後の短い時間で食事を用意する場面を描き、時間を節約できることを伝えます。"),
    ("化粧品", "こもれびコスメ", "肌の乾燥が気になる季節に向けた保湿用品の紹介で、使用感を静かな映像で表現します。"),
    ("化粧品", "はなみずき薬粧", "毎朝の手入れを短くまとめられることをテーマに、鏡の前の場面を中心に構成しています。"),
    ("教育", "青葉ゼミナール", "受験を控えた生徒と講師のやりとりを通して、学習の進め方を紹介します。"),
    ("教育", "こもれび英会話", "仕事のあとに通う受講者の様子を描き、続けやすさを伝える内容です。"),
    ("旅行", "みずうみトラベル", "国内の温泉地を訪れる旅の様子を紹介し、期間限定の割引を告知します。"),
    ("旅行", "そらいろエアサービス", "早朝の空港から出発する場面を映し、路線の広がりを地図で示します。"),
    ("住宅", "けやきホーム", "住宅の内部を歩きながら間取りを紹介する、説明を中心とした構成です。"),
    ("住宅", "しおかぜリフォーム", "築年数の経った家の水まわりを新しくする工程を、前後の比較で伝えます。"),
]

POSTAL_PREFIXES = [
    "100", "101", "104", "105", "106", "107", "108", "110", "111", "112",
    "113", "114", "116", "120", "130", "135", "140", "150", "151", "152",
    "153", "154", "156", "158", "160", "162", "164", "166", "167", "168",
    "170", "171", "173", "174", "176", "179", "180", "182", "183", "184",
    "185", "190", "192", "194", "196", "203", "210", "212", "220", "221",
    "222", "231", "232", "240", "241", "244", "247", "251", "254", "260",
    "261", "263", "270", "272", "273", "275", "277", "279", "285", "290",
    "300", "305", "310", "320", "330", "331", "332", "336", "343", "344",
    "350", "351", "352", "354", "358", "359", "360", "362", "365", "367",
    "370", "371", "373", "374", "376", "379", "380", "400", "420", "440",
]


def weighted_choice(rng: random.Random, pairs):
    """(value, weight) の並びから 1 つ選ぶ。"""
    total = sum(w for _, w in pairs)
    r = rng.uniform(0, total)
    upto = 0.0
    for value, weight in pairs:
        upto += weight
        if r <= upto:
            return value
    return pairs[-1][0]


def station_device_id(network_id: str, common_id: str) -> str:
    """各局が独自に付与するデバイス ID。局ごとに値空間が違うことを表現する。

    共通 ID からハッシュで導出しているが、局 ID を混ぜているので
    同じ受信機でも局が違えばまったく別の文字列になる。名寄せの章で、
    この文字列だけでは局をまたいだ突合ができないことを確認する。
    """
    digest = hashlib.sha1(f"{network_id}:{common_id}".encode("utf-8")).hexdigest()
    return f"{network_id}-D-{digest[:10]}"


def date_trend(d: date, start_factor: float, end_factor: float) -> float:
    """期間の中で少しずつ変えるための係数。

    3 ヶ月分を用意しても、どの日も同じ量なら月次の推移が平らになり、
    蓄積していくデータを見る意味がなくなる。放送の視聴が期間の後半に
    かけてゆるやかに減る形にして、月次の推移が読めるようにしている。
    """
    if PERIOD_DAYS == 0:
        return start_factor
    ratio = (d - PERIOD_START).days / PERIOD_DAYS
    return start_factor + (end_factor - start_factor) * ratio


def dates_in_period():
    d = PERIOD_START
    while d <= PERIOD_END:
        yield d
        d += timedelta(days=1)


def time_slot_for_hour(hour: int) -> str:
    """番組・CMの開始時刻を、放送で使う時間帯に変換する。"""
    if 4 <= hour < 9:
        return "朝"
    if 9 <= hour < 16:
        return "昼"
    if 16 <= hour < 19:
        return "夕方"
    if 19 <= hour < 23:
        return "ゴールデン"
    return "深夜"


def write_csv(filename: str, header, rows, compress: bool = True):
    path = DATA_DIR / (filename + (".gz" if compress else ""))
    opener = (lambda: gzip.open(path, "wt", encoding="utf-8", newline="")) if compress \
        else (lambda: open(path, "w", encoding="utf-8", newline=""))
    with opener() as fh:
        writer = csv.writer(fh, quoting=csv.QUOTE_MINIMAL)
        writer.writerow(header)
        writer.writerows(rows)
    size_kb = path.stat().st_size / 1024
    print(f"  {path.name:<34} {len(rows):>9,} 行  {size_kb:>8,.0f} KB")


def build_devices(rng: random.Random, n_devices: int, n_ips: int):
    """共通 ID を作り、IP アドレスと郵便番号を割り当てる。

    IP アドレスの数を共通 ID より少なくすることで、1 つの IP に複数の
    受信機がぶら下がる状況を作る。集合住宅で回線を共有している状態に相当し、
    IP アドレスを世帯の代わりに使うことの限界がそのまま現れる。

    さらに、受信機ごとに「よく見る局」の偏りを持たせる。これがないと全員が
    5 局すべてに登場してしまい、局横断の名寄せで重複を除いたときの効果が
    現実とかけ離れる。
    """
    # ドキュメント用に予約されている 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 を先に使い、
    # 足りない分は private アドレスで補う。実在のアドレスを避けるための配慮。
    ips = []
    for block in ("192.0.2", "198.51.100", "203.0.113"):
        for last in range(1, 255):
            ips.append(f"{block}.{last}")
            if len(ips) >= n_ips:
                break
        if len(ips) >= n_ips:
            break
    i = 0
    while len(ips) < n_ips:
        ips.append(f"10.{i // 65536 % 250}.{i // 256 % 256}.{i % 256}")
        i += 1
    ip_postal = {ip: rng.choice(POSTAL_PREFIXES) + "-" + f"{rng.randint(0, 9999):04d}" for ip in ips}

    # 1 つの IP に何台ぶら下げるか。一戸建てが多く、集合住宅の共有は少数になるようにする。
    slots = []
    for ip in ips:
        slots.extend([ip] * weighted_choice(rng, [(1, 62), (2, 28), (3, 8), (4, 2)]))
    rng.shuffle(slots)
    while len(slots) < n_devices:
        slots.append(rng.choice(ips))

    network_ids = [nw[0] for nw in NETWORKS]
    devices = []
    for i in range(n_devices):
        common_id = f"C{i + 1:06d}"
        ip = slots[i]
        # 視聴の多い家と少ない家の差を付ける。1 に近いほどよく見る。
        activity = rng.betavariate(2.0, 3.0) * 0.9 + 0.1
        # よく見る局の順位を受信機ごとにシャッフルして重みを割り当てる
        order = network_ids[:]
        rng.shuffle(order)
        weights = [1.0, 0.5, 0.15, 0.05, 0.02]
        devices.append({
            "common_id": common_id,
            "ip": ip,
            "postal_code": ip_postal[ip],
            "activity": activity,
            "segment": None,          # あとでパネル分だけ埋める
            "nw_affinity": dict(zip(order, weights)),
        })
    return devices, ip_postal


def build_programs(rng: random.Random):
    programs = []
    for idx, (genre, slot, title) in enumerate(PROGRAM_TITLES):
        network_id = NETWORKS[idx % len(NETWORKS)][0]
        duration = weighted_choice(rng, [(30, 40), (60, 40), (90, 15), (120, 5)])
        synopsis = (
            rng.choice(SYNOPSIS_TEMPLATES[genre])
            + f" 番組『{title}』では、毎回異なる題材を通じて{genre}ならではの見どころを届けます。"
        )
        programs.append({
            "program_id": f"PG{idx + 1:04d}",
            "program_name": title,
            "network_id": network_id,
            "genre": genre,
            "time_slot": slot,
            "duration_min": duration,
            "synopsis": synopsis,
            # 曜日は局ごとに 0 から 6 をすべて埋める。
            # idx % 7 にすると局と曜日の組み合わせに穴ができ、
            # 「ある局のある曜日には番組がない」＝その日の行が 0 件になる。
            # 意図した欠落（NW03 の 1 日）と区別できなくなるので、
            # 局のなかで曜日を順に割り当てる。
            "day_of_week": (idx // len(NETWORKS)) % 7,
        })
    return programs


def build_schedule(programs):
    """各局の 4 時から 24 時までを、番組で切れ目なく編成する。"""
    rows = []
    programs_by_network = {
        network_id: [p for p in programs if p["network_id"] == network_id]
        for network_id, _, _ in NETWORKS
    }

    for day_index, d in enumerate(dates_in_period()):
        day_start = datetime(d.year, d.month, d.day, BROADCAST_START_HOUR)
        day_end = datetime(d.year, d.month, d.day) + timedelta(hours=BROADCAST_END_HOUR)
        for network_index, (network_id, _, _) in enumerate(NETWORKS):
            network_programs = programs_by_network[network_id]
            start = day_start
            slot_index = 0
            while start < day_end:
                slot_name = time_slot_for_hour(start.hour)
                preferred = [p for p in network_programs if p["time_slot"] == slot_name]
                pool = preferred or network_programs
                p = pool[(day_index + network_index * 3 + slot_index) % len(pool)]
                remaining_min = int((day_end - start).total_seconds() // 60)
                duration_min = min(p["duration_min"], remaining_min)
                if duration_min < 30:
                    duration_min = remaining_min
                finish = start + timedelta(minutes=duration_min)
                rows.append({
                    "program_id": p["program_id"],
                    "network_id": network_id,
                    "air_date": d,
                    "air_from": start,
                    "air_to": finish,
                    "genre": p["genre"],
                    "time_slot": slot_name,
                })
                start = finish
                slot_index += 1
    return rows


def assign_panel(rng: random.Random, devices, panel_size: int):
    """全体の一部にだけ属性を与える。残りは属性が分からないままにする。"""
    picked = rng.sample(devices, panel_size)
    rows = []
    for dev in picked:
        segment = weighted_choice(rng, [
            ("T", 9), ("F1", 14), ("F2", 16), ("F3", 18),
            ("M1", 13), ("M2", 15), ("M3", 15),
        ])
        dev["segment"] = segment
        rows.append([
            dev["common_id"],
            segment,
            (PERIOD_START + timedelta(days=rng.randint(0, PERIOD_DAYS))).isoformat(),
        ])
    return rows


_AFFINITY_CACHE: dict[tuple[str, str], float] = {}


def genre_affinity(dev, genre: str) -> float:
    """その受信機がそのジャンルを見やすいかどうか。

    属性が分かっている端末はセグメントの傾向を使い、分からない端末は
    受信機ごとに固定の弱い好みを持たせる。差を付けすぎないのが要点で、
    ルールで簡単に言い当てられるデータにしないための調整。
    """
    key = (dev["common_id"], genre)
    cached = _AFFINITY_CACHE.get(key)
    if cached is not None:
        return cached
    if dev["segment"]:
        value = SEGMENT_GENRE_AFFINITY.get(dev["segment"], {}).get(genre, 1.0)
    else:
        seed = int(hashlib.md5(f"{dev['common_id']}:{genre}".encode()).hexdigest()[:6], 16)
        value = 0.8 + (seed % 100) / 250.0     # 0.8 から 1.2
    _AFFINITY_CACHE[key] = value
    return value


def build_viewing_logs(rng: random.Random, devices, schedule, total_rows: int):
    """局ごとの視聴区間を作る。

    放送枠に紐づけて発生させる。そうしないと番組別の集計が意味を持たない。
    区間の長さは短いものが多く長いものが少ない分布にし、平均を 12 分前後にする。
    局ごとの行数は NETWORK_SHARE で配分し、規模の差を作る。
    """
    by_network = {nw[0]: [] for nw in NETWORKS}
    sched_by_network = {nw[0]: [] for nw in NETWORKS}
    for s in schedule:
        sched_by_network[s["network_id"]].append(s)

    channel_of = {n[0]: n[2] for n in NETWORKS}
    device_weights = [d["activity"] for d in devices]
    duration_values = [2, 5, 8, 12, 20, 30, 45, 60]
    duration_weights = [18, 20, 14, 14, 12, 10, 7, 5]

    for network_id, slots in sched_by_network.items():
        per_network = int(total_rows * NETWORK_SHARE[network_id])
        # この局に届かない日の枠は最初から除いておく
        usable = [s for s in slots
                  if not (network_id == MISSING_NETWORK and s["air_date"] == MISSING_DAY)]
        # 時間帯の重みに、日付のトレンド（放送は微減）を掛けておく
        slot_weights = [TIME_SLOTS[s["time_slot"]]["weight"]
                        * date_trend(s["air_date"], 1.12, 0.88)
                        for s in usable]
        rows = []
        # rng.choices は C 実装で、まとめて引くと 1 件ずつ選ぶより桁違いに速い
        batch = 20000
        while len(rows) < per_network:
            picked_slots = rng.choices(usable, weights=slot_weights, k=batch)
            picked_devs = rng.choices(devices, weights=device_weights, k=batch)
            picked_durations = rng.choices(duration_values, weights=duration_weights, k=batch)
            for slot, dev, duration in zip(picked_slots, picked_devs, picked_durations):
                accept = 0.60 * genre_affinity(dev, slot["genre"]) * dev["nw_affinity"][network_id]
                if rng.random() > min(1.0, accept):
                    continue
                span_min = int((slot["air_to"] - slot["air_from"]).total_seconds() // 60)
                offset = rng.randint(0, max(0, span_min - 2))
                duration = min(duration, span_min - offset) or 1
                start = slot["air_from"] + timedelta(minutes=offset, seconds=rng.randint(0, 59))
                rows.append([
                    network_id,
                    station_device_id(network_id, dev["common_id"]),
                    dev["common_id"],
                    dev["ip"],
                    dev["postal_code"],
                    channel_of[network_id],
                    start.strftime("%Y-%m-%d %H:%M:%S"),
                    (start + timedelta(minutes=duration)).strftime("%Y-%m-%d %H:%M:%S"),
                ])
                if len(rows) >= per_network:
                    break
        by_network[network_id] = rows
    return by_network


def inject_anomalies(rng: random.Random, by_network):
    """クレンジングの章が空回りしないよう、生データに異常を混ぜる。"""
    counts = {"reversed": 0, "too_long": 0, "duplicated": 0}
    for network_id, rows in by_network.items():
        # 終了時刻が開始時刻より前
        for _ in range(int(40 * NETWORK_SHARE[network_id] * 5)):
            src = list(rng.choice(rows))
            src[6], src[7] = src[7], src[6]
            rows.append(src)
            counts["reversed"] += 1
        # 視聴時間が 24 時間を超える
        for _ in range(int(30 * NETWORK_SHARE[network_id] * 5)):
            src = list(rng.choice(rows))
            start = datetime.strptime(src[6], "%Y-%m-%d %H:%M:%S")
            src[7] = (start + timedelta(hours=rng.randint(25, 40))).strftime("%Y-%m-%d %H:%M:%S")
            rows.append(src)
            counts["too_long"] += 1
        # 完全に重複した行
        for _ in range(int(60 * NETWORK_SHARE[network_id] * 5)):
            rows.append(list(rng.choice(rows)))
            counts["duplicated"] += 1
        rng.shuffle(rows)
    return counts


def build_cm(rng: random.Random, schedule):
    """コマーシャル素材のマスタと、局全体の放送実績。

    各局に 20 分ごと・3 分間のブレークを作り、6 / 15 / 30 秒素材で埋める。
    最初の 20 素材だけをハンズオンの分析対象とし、残り 80 素材は局全体の
    CM 在庫を現実的にする背景素材として扱う。
    """
    creative_specs = []
    for advertiser_index, (category, advertiser, desc) in enumerate(ADVERTISERS):
        for variant in range(5):
            creative_index = advertiser_index * 5 + variant
            cm_id = f"CM{creative_index + 1:04d}"
            is_target = variant == 0
            if is_target:
                creative_desc = desc
            else:
                angles = ["商品特長", "利用場面", "季節感", "企業姿勢"]
                creative_desc = (
                    f"{desc} 同じ広告主の別素材として、{angles[variant - 1]}を中心に構成し、"
                    f"終盤で『{advertiser}』の名称を表示します。"
                )
            if is_target:
                length = [14, 21, 28][advertiser_index % 3]
                max_start = max(0, PERIOD_DAYS - length + 1)
                start_offset = (advertiser_index * 11) % (max_start + 1) if max_start else 0
                campaign_from = PERIOD_START + timedelta(days=start_offset)
                campaign_to = campaign_from + timedelta(days=length - 1)
            else:
                # 局全体の通常在庫を表す背景素材。分析対象キャンペーンと違い、
                # 全期間を通じてブレークを埋められるようにする。
                campaign_from = PERIOD_START
                campaign_to = PERIOD_END
            first_network = creative_index % len(NETWORKS)
            target_networks = {
                NETWORKS[first_network][0],
                NETWORKS[(first_network + 1 + creative_index % 3) % len(NETWORKS)][0],
            }
            slot_names = list(TIME_SLOTS)
            target_slots = {
                slot_names[creative_index % len(slot_names)],
                slot_names[(creative_index + 2) % len(slot_names)],
            }
            creative_specs.append({
                "cm_id": cm_id,
                "category": category,
                "advertiser": advertiser,
                "duration_sec": [15, 15, 15, 30, 6][variant],
                "creative_desc": creative_desc,
                "campaign_from": campaign_from,
                "campaign_to": campaign_to,
                "is_analysis_target": is_target,
                "target_networks": target_networks,
                "target_slots": target_slots,
            })

    master = []
    for spec in creative_specs:
        master.append([
            spec["cm_id"],
            spec["advertiser"],
            spec["category"],
            spec["duration_sec"],
            spec["creative_desc"],
            spec["campaign_from"].isoformat(),
            spec["campaign_to"].isoformat(),
            spec["is_analysis_target"],
        ])

    spots = []
    spot_number = 1
    for d in dates_in_period():
        for network_id, _, _ in NETWORKS:
            day_start = datetime(d.year, d.month, d.day, BROADCAST_START_HOUR)
            total_minutes = (BROADCAST_END_HOUR - BROADCAST_START_HOUR) * 60
            for break_index, break_offset in enumerate(
                    range(CM_BREAK_INTERVAL_MIN - 3, total_minutes, CM_BREAK_INTERVAL_MIN)):
                break_start = day_start + timedelta(minutes=break_offset)
                slot_name = time_slot_for_hour(break_start.hour)
                eligible = [
                    spec for spec in creative_specs
                    if spec["campaign_from"] <= d <= spec["campaign_to"]
                    and network_id in spec["target_networks"]
                    and slot_name in spec["target_slots"]
                ]
                if not eligible:
                    eligible = [
                        spec for spec in creative_specs
                        if spec["campaign_from"] <= d <= spec["campaign_to"]
                        and network_id in spec["target_networks"]
                    ]
                if not eligible:
                    eligible = [
                        spec for spec in creative_specs
                        if spec["campaign_from"] <= d <= spec["campaign_to"]
                    ]

                # どの並びも合計 180 秒。ランダムに尺を選ぶと 9 秒などの端数が
                # 残るため、放送枠として成立する組み合わせを先に決めておく。
                duration_patterns = [
                    [15] * 12,
                    [30] * 6,
                    [6] * 5 + [15] * 10,
                ]
                durations = duration_patterns[(break_index + int(network_id[-1])) % len(duration_patterns)]
                rng.shuffle(durations)
                elapsed_sec = 0
                for duration_sec in durations:
                    fitting = [spec for spec in eligible if spec["duration_sec"] == duration_sec]
                    if not fitting:
                        fitting = [
                            spec for spec in creative_specs
                            if spec["duration_sec"] == duration_sec
                            and spec["campaign_from"] <= d <= spec["campaign_to"]
                        ]
                    if not fitting:
                        raise RuntimeError(f"{d} に {duration_sec} 秒素材がありません")
                    spec = rng.choice(fitting)
                    air_at = break_start + timedelta(seconds=elapsed_sec)
                    spots.append([
                        f"SP{spot_number:07d}",
                        spec["cm_id"],
                        network_id,
                        air_at.strftime("%Y-%m-%d %H:%M:%S"),
                    ])
                    spot_number += 1
                    elapsed_sec += duration_sec
    return master, spots


def main():
    parser = argparse.ArgumentParser(description="ハンズオン用サンプルデータの生成")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--devices", type=int, default=20000, help="共通 ID の数")
    parser.add_argument("--ips", type=int, default=12000, help="IP アドレスの数")
    parser.add_argument("--viewing-total", type=int, default=1050000,
                        help="視聴区間の合計行数。局ごとの配分は NETWORK_SHARE に従う")
    parser.add_argument("--panel", type=int, default=2000)
    parser.add_argument("--no-compress", action="store_true")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    compress = not args.no_compress

    print("データを組み立てています ...")
    devices, _ = build_devices(rng, args.devices, args.ips)
    programs = build_programs(rng)
    schedule = build_schedule(programs)
    panel_rows = assign_panel(rng, devices, args.panel)
    viewing = build_viewing_logs(rng, devices, schedule, args.viewing_total)
    anomaly_counts = inject_anomalies(rng, viewing)
    cm_master, cm_spots = build_cm(rng, schedule)

    print("\n書き出しています ...")
    for network_id, _, _ in NETWORKS:
        write_csv(
            f"viewing_log_{network_id.lower()}.csv",
            ["NETWORK_ID", "STATION_DEVICE_ID", "COMMON_ID", "IP_ADDRESS",
             "POSTAL_CODE", "CHANNEL_CODE", "VIEW_FROM", "VIEW_TO"],
            viewing[network_id], compress,
        )

    write_csv("network_master.csv",
              ["NETWORK_ID", "NETWORK_NAME", "CHANNEL_CODE"],
              [list(n) for n in NETWORKS], compress)

    write_csv("program_master.csv",
              ["PROGRAM_ID", "PROGRAM_NAME", "NETWORK_ID", "GENRE", "TIME_SLOT",
               "DURATION_MIN", "SYNOPSIS"],
              [[p["program_id"], p["program_name"], p["network_id"], p["genre"],
                p["time_slot"], p["duration_min"], p["synopsis"]] for p in programs],
              compress)

    write_csv("program_schedule.csv",
              ["PROGRAM_ID", "NETWORK_ID", "AIR_DATE", "AIR_FROM", "AIR_TO"],
              [[s["program_id"], s["network_id"], s["air_date"].isoformat(),
                s["air_from"].strftime("%Y-%m-%d %H:%M:%S"),
                s["air_to"].strftime("%Y-%m-%d %H:%M:%S")] for s in schedule],
              compress)

    write_csv("cm_master.csv",
              ["CM_ID", "ADVERTISER", "CATEGORY", "DURATION_SEC", "CREATIVE_DESC",
               "CAMPAIGN_FROM", "CAMPAIGN_TO", "IS_ANALYSIS_TARGET"],
              cm_master, compress)

    write_csv("cm_spot.csv",
              ["SPOT_ID", "CM_ID", "NETWORK_ID", "AIR_AT"],
              cm_spots, compress)

    write_csv("panel_demographics.csv",
              ["COMMON_ID", "GENDER_AGE_SEGMENT", "SURVEY_DATE"],
              panel_rows, compress)

    total_viewing = sum(len(v) for v in viewing.values())
    print(f"\n視聴区間の合計: {total_viewing:,} 行")
    print(f"混ぜた異常値: 終了が開始より前 {anomaly_counts['reversed']} 件 / "
          f"24 時間超 {anomaly_counts['too_long']} 件 / 重複 {anomaly_counts['duplicated']} 件")
    print(f"{MISSING_NETWORK} の {MISSING_DAY} のログは意図的に欠落させています。")


if __name__ == "__main__":
    main()
