"""放送視聴データの可視化アプリ

Git リポジトリから内部ステージへ配置し、CREATE STREAMLIT で実行します。
コードを画面へ貼り付けたり、ローカルへインストールしたりする必要はありません。

参照するのはマート層だけです。セマンティックビューと同じ指標式を SQL に使い、
画面表示用の集計を行います。
"""

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

# -----------------------------------------------------------------------------
# 見た目の設定
# -----------------------------------------------------------------------------
st.set_page_config(page_title="放送視聴データ", layout="wide")

FONT = "Hiragino Sans, Noto Sans JP, Yu Gothic, sans-serif"
BLUE, DEEP, GREY = "#29B5E8", "#11567F", "#8899AB"
AMBER, GREEN, RED = "#FFB020", "#2EB88A", "#E5484D"
PALETTE = [BLUE, DEEP, AMBER, GREEN, RED]

DB = "BCAST_VIEWING_HANDSON"
MART = f"{DB}.MART"


def styled(chart: alt.Chart) -> alt.Chart:
    """日本語が崩れないように共通の体裁を当てる。"""
    return (
        chart.configure_axis(labelFont=FONT, titleFont=FONT, labelFontSize=11, titleFontSize=12)
        .configure_legend(labelFont=FONT, titleFont=FONT, labelFontSize=11, titleFontSize=12)
        .configure_title(font=FONT, fontSize=14)
        .configure_view(strokeWidth=0)
    )


session = get_active_session()


@st.cache_data(ttl=600)
def run(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


# -----------------------------------------------------------------------------
# 絞り込み
# -----------------------------------------------------------------------------
st.title("放送視聴データ")

networks = run(f"SELECT DISTINCT NETWORK_NAME FROM {MART}.MART_DEVICE_DAILY ORDER BY 1")
network_list = networks["NETWORK_NAME"].tolist()

# 対象期間はデータから取る。ここを固定値にすると、データを作り直したときに
# 画面の初期値と実データがずれる。
span = run(f"SELECT MIN(VIEW_DATE) AS D_MIN, MAX(VIEW_DATE) AS D_MAX FROM {MART}.MART_DEVICE_DAILY")
d_min = pd.Timestamp(span["D_MIN"].iloc[0]).date()
d_max = pd.Timestamp(span["D_MAX"].iloc[0]).date()
st.caption(
    "非特定視聴データにもとづく視聴実績。対象期間は "
    f"{d_min.year} 年 {d_min.month} 月 {d_min.day} 日から "
    f"{d_max.year} 年 {d_max.month} 月 {d_max.day} 日です。"
)

with st.sidebar:
    st.header("絞り込み")
    selected_networks = st.multiselect("局", network_list, default=network_list)
    date_from, date_to = st.date_input(
        "期間",
        value=(d_min, d_max),
        min_value=d_min,
        max_value=d_max,
    )

if not selected_networks:
    st.warning("局を 1 つ以上選んでください。")
    st.stop()

network_filter = ", ".join(f"'{n}'" for n in selected_networks)
period_filter = f"VIEW_DATE BETWEEN '{date_from}' AND '{date_to}'"

# -----------------------------------------------------------------------------
# 全体の数字
# -----------------------------------------------------------------------------
summary = run(f"""
    SELECT
      COUNT(DISTINCT COMMON_ID)  AS REACH_DEVICES,
      COUNT(DISTINCT IP_ADDRESS) AS REACH_HOUSEHOLDS,
      SUM(VIEWING_SESSIONS)      AS SESSIONS,
      ROUND(SUM(VIEW_MINUTES))   AS MINUTES
    FROM {MART}.MART_DEVICE_DAILY
    WHERE NETWORK_NAME IN ({network_filter}) AND {period_filter}
""").iloc[0]

c1, c2, c3, c4 = st.columns(4)
c1.metric("リーチ（台数）", f"{int(summary['REACH_DEVICES']):,}")
c2.metric("リーチ（IP数）", f"{int(summary['REACH_HOUSEHOLDS']):,}")
c3.metric("視聴回数", f"{int(summary['SESSIONS']):,}")
c4.metric("総視聴時間（分）", f"{int(summary['MINUTES']):,}")

st.info(
    "台数とIP数が違うのは、同じIPアドレスを複数の受信機が共有することがあるためです。"
    "IP数は世帯数そのものではなく、世帯到達の代理指標です。"
)

tab1, tab2, tab3, tab4, tab5 = st.tabs(["リーチの推移", "番組", "次に見た別の局", "フリークエンシー", "毎分の推移"])

# -----------------------------------------------------------------------------
# リーチの推移
# -----------------------------------------------------------------------------
with tab1:
    daily = run(f"""
        SELECT
          VIEW_DATE,
          NETWORK_NAME,
          COUNT(DISTINCT COMMON_ID) AS REACH_DEVICES
        FROM {MART}.MART_DEVICE_DAILY
        WHERE NETWORK_NAME IN ({network_filter}) AND {period_filter}
        GROUP BY VIEW_DATE, NETWORK_NAME
        ORDER BY VIEW_DATE, NETWORK_NAME
    """)

    chart = (
        alt.Chart(daily)
        .mark_line(point=True, strokeWidth=2)
        .encode(
            x=alt.X("VIEW_DATE:T", title="視聴日"),
            y=alt.Y("REACH_DEVICES:Q", title="リーチ（台数）"),
            color=alt.Color("NETWORK_NAME:N", title="局",
                            scale=alt.Scale(range=PALETTE)),
            tooltip=["VIEW_DATE:T", "NETWORK_NAME:N", "REACH_DEVICES:Q"],
        )
        .properties(height=340, title="日別・局別のリーチ")
    )
    st.altair_chart(styled(chart), use_container_width=True)

    st.subheader("エリア別のリーチ")
    area = run(f"""
        SELECT POSTAL_AREA, COUNT(DISTINCT COMMON_ID) AS REACH_DEVICES
        FROM {MART}.MART_DEVICE_DAILY
        WHERE NETWORK_NAME IN ({network_filter}) AND {period_filter}
        GROUP BY POSTAL_AREA
        ORDER BY REACH_DEVICES DESC
        LIMIT 20
    """)
    chart = (
        alt.Chart(area)
        .mark_bar(color=BLUE)
        .encode(
            x=alt.X("REACH_DEVICES:Q", title="リーチ（台数）"),
            y=alt.Y("POSTAL_AREA:N", title="郵便番号の上 3 桁", sort="-x"),
            tooltip=["POSTAL_AREA:N", "REACH_DEVICES:Q"],
        )
        .properties(height=440, title="エリア別のリーチ（上位 20）")
    )
    st.altair_chart(styled(chart), use_container_width=True)

# -----------------------------------------------------------------------------
# 番組
# -----------------------------------------------------------------------------
with tab2:
    programs = run(f"""
        SELECT
          PROGRAM_NAME,
          GENRE,
          TIME_SLOT,
          NETWORK_NAME,
          COUNT(DISTINCT COMMON_ID)                   AS VIEWING_DEVICES,
          COUNT(DISTINCT IP_ADDRESS)                  AS VIEWING_HOUSEHOLDS,
          ROUND(COUNT(DISTINCT IP_ADDRESS) * 2.2)     AS ESTIMATED_VIEWERS,
          ROUND(AVG(COMPLETION_RATE), 3)              AS AVG_COMPLETION_RATE
        FROM {MART}.MART_PROGRAM_VIEWING
        WHERE NETWORK_NAME IN ({network_filter})
          AND AIR_DATE BETWEEN '{date_from}' AND '{date_to}'
        GROUP BY PROGRAM_NAME, GENRE, TIME_SLOT, NETWORK_NAME
        ORDER BY VIEWING_DEVICES DESC
    """)

    top = programs.head(15)
    chart = (
        alt.Chart(top)
        .mark_bar()
        .encode(
            x=alt.X("VIEWING_DEVICES:Q", title="視聴台数"),
            y=alt.Y("PROGRAM_NAME:N", title="番組", sort="-x"),
            color=alt.Color("GENRE:N", title="ジャンル", scale=alt.Scale(scheme="tableau10")),
            tooltip=["PROGRAM_NAME:N", "GENRE:N", "TIME_SLOT:N",
                     "VIEWING_DEVICES:Q", "ESTIMATED_VIEWERS:Q"],
        )
        .properties(height=420, title="番組別の視聴台数（上位 15）")
    )
    st.altair_chart(styled(chart), use_container_width=True)

    st.caption(
        "推計視聴人数は視聴IP数に1回線あたりの想定人数2.2を掛けた参考値です。"
        "IP数は世帯数そのものではないため、正確な視聴人数ではありません。"
    )

    st.subheader("属性が分かっている範囲での傾向")
    seg = run(f"""
        SELECT
          GENDER_AGE_SEGMENT,
          GENRE,
          COUNT(DISTINCT COMMON_ID) AS REACH_DEVICES
        FROM {MART}.MART_PROGRAM_VIEWING
        WHERE NETWORK_NAME IN ({network_filter})
          AND AIR_DATE BETWEEN '{date_from}' AND '{date_to}'
          AND GENDER_AGE_SEGMENT IS NOT NULL
        GROUP BY GENDER_AGE_SEGMENT, GENRE
        ORDER BY GENDER_AGE_SEGMENT, GENRE
    """)
    chart = (
        alt.Chart(seg)
        .mark_rect()
        .encode(
            x=alt.X("GENRE:N", title="ジャンル"),
            y=alt.Y("GENDER_AGE_SEGMENT:N", title="セグメント"),
            color=alt.Color("REACH_DEVICES:Q", title="台数",
                            scale=alt.Scale(scheme="blues")),
            tooltip=["GENDER_AGE_SEGMENT:N", "GENRE:N", "REACH_DEVICES:Q"],
        )
        .properties(height=300, title="セグメント別・ジャンル別のリーチ")
    )
    st.altair_chart(styled(chart), use_container_width=True)
    st.warning(
        "これは属性が判明している 10 パーセントの中での傾向です。全体の姿ではありません。"
        "全体に広げるには、この 10 パーセントを正解データにして残りを推定する処理が必要になります。"
    )

    with st.expander("番組の一覧を表で見る"):
        st.dataframe(programs, use_container_width=True)

# -----------------------------------------------------------------------------
# 次に見た別の局
# -----------------------------------------------------------------------------
with tab3:
    st.markdown(
        "ある局の視聴後、30分以内に次に見た別の局です。この数字は 1 局のデータだけでは出せません。"
        "各局は自局が見られている間のログしか取得できないので、"
        "5 局分を共通 ID で束ねたあとで初めて分かります。"
    )

    zap = run(f"""
        SELECT
          FROM_NETWORK_NAME,
          TO_NETWORK_NAME,
          SUM(TRANSITION_COUNT) AS TRANSITIONS
        FROM {MART}.MART_ZAPPING_TRANSITION
        WHERE VIEW_DATE BETWEEN '{date_from}' AND '{date_to}'
          AND FROM_NETWORK_NAME IN ({network_filter})
          AND TO_NETWORK_NAME IN ({network_filter})
        GROUP BY FROM_NETWORK_NAME, TO_NETWORK_NAME
        ORDER BY TRANSITIONS DESC
    """)

    chart = (
        alt.Chart(zap)
        .mark_rect()
        .encode(
            x=alt.X("TO_NETWORK_NAME:N", title="移動先の局"),
            y=alt.Y("FROM_NETWORK_NAME:N", title="移動元の局"),
            color=alt.Color("TRANSITIONS:Q", title="移動回数",
                            scale=alt.Scale(scheme="blues")),
            tooltip=["FROM_NETWORK_NAME:N", "TO_NETWORK_NAME:N", "TRANSITIONS:Q"],
        )
        .properties(height=340, title="30分以内に次に見た別の局")
    )
    st.altair_chart(styled(chart), use_container_width=True)

    with st.expander("移動の一覧を表で見る"):
        st.dataframe(zap, use_container_width=True)

# -----------------------------------------------------------------------------
# フリークエンシー
# -----------------------------------------------------------------------------
with tab4:
    st.caption(
        "このタブはキャンペーン全期間・全局の集計です。"
        "上の期間・局フィルターは、キャンペーン単位に集約済みのため適用されません。"
    )
    st.markdown(
        "同じ受信機に何回コマーシャルが当たったかです。"
        "**リーチ × 平均フリークエンシー = インプレッション** の関係にあり、"
        "3 つのうち 2 つが決まれば残りが決まります。"
    )
    st.warning(
        "放送のコマーシャル接触は実測ではありません。視聴区間にスポットの放送時刻が"
        "入っていたかどうかで判定した推定値です。席を外していても接触として数えます。"
    )

    freq = run(f"""
        SELECT
          ADVERTISER,
          CATEGORY,
          MIN(CAMPAIGN_FROM)                          AS CAMPAIGN_FROM,
          MAX(CAMPAIGN_TO)                            AS CAMPAIGN_TO,
          COUNT(DISTINCT COMMON_ID)                   AS REACH_DEVICES,
          SUM(CONTACT_COUNT)                          AS IMPRESSIONS,
          ROUND(SUM(CONTACT_COUNT) / COUNT(DISTINCT COMMON_ID), 2) AS AVG_FREQUENCY
        FROM {MART}.MART_FREQUENCY
        GROUP BY ADVERTISER, CATEGORY
        ORDER BY IMPRESSIONS DESC
    """)

    chart = (
        alt.Chart(freq)
        .mark_circle()
        .encode(
            x=alt.X("REACH_DEVICES:Q", title="リーチ（台数）"),
            y=alt.Y("AVG_FREQUENCY:Q", title="平均フリークエンシー（回）"),
            size=alt.Size("IMPRESSIONS:Q", title="インプレッション"),
            color=alt.Color("CATEGORY:N", title="業種",
                            scale=alt.Scale(scheme="tableau10")),
            tooltip=["ADVERTISER:N", "REACH_DEVICES:Q", "AVG_FREQUENCY:Q",
                     "IMPRESSIONS:Q", "CAMPAIGN_FROM:T", "CAMPAIGN_TO:T"],
        )
        .properties(height=420, title="リーチと平均フリークエンシー（円の大きさがインプレッション）")
    )
    st.altair_chart(styled(chart), use_container_width=True)

    st.markdown(
        "右上にあるほど「広く、かつ何度も当たっている」ことになります。"
        "同じインプレッションでも、広く薄く当てているのか、狭く何度も当てているのかで"
        "置かれる位置が変わります。ここが出稿の設計の判断材料になります。"
    )

    st.subheader("接触回数の分布")
    band = run(f"""
        SELECT
          FREQUENCY_BAND,
          COUNT(*) AS DEVICES
        FROM {MART}.MART_FREQUENCY
        GROUP BY FREQUENCY_BAND
    """)
    band_order = ["1 回", "2 から 3 回", "4 から 7 回", "8 から 15 回", "16 回以上"]
    chart = (
        alt.Chart(band)
        .mark_bar(color=BLUE)
        .encode(
            x=alt.X("FREQUENCY_BAND:N", title="接触回数", sort=band_order),
            y=alt.Y("DEVICES:Q", title="コマーシャル × 台数の組み合わせ"),
            tooltip=["FREQUENCY_BAND:N", "DEVICES:Q"],
        )
        .properties(height=320)
    )
    st.altair_chart(styled(chart), use_container_width=True)

    st.caption(
        "1 回しか当たっていない組み合わせが多く、回数が増えるほど少なくなります。"
        "平均だけを見ていると、この偏りが見えません。"
    )

    with st.expander("広告主ごとの一覧を表で見る"):
        st.dataframe(freq, use_container_width=True)

# -----------------------------------------------------------------------------
# 毎分の推移
# -----------------------------------------------------------------------------
with tab5:
    st.markdown(
        "1 日を 1 分刻みで並べた視聴台数です。"
        "このグラフは from-to のままでは描けないという理由で、第 2 章で区間を 1 分ごとに展開しました。"
        "展開した行をそのまま使うのではなく、「局 × 分 × 台数」に集計した MART_MINUTE_AUDIENCE を参照しています。"
    )

    mc1, mc2 = st.columns(2)
    with mc1:
        minute_date = st.date_input(
            "日付", value=date_from, min_value=d_min, max_value=d_max, key="minute_date"
        )
    with mc2:
        minute_network = st.selectbox("局", selected_networks, key="minute_network")

    minutes = run(f"""
        SELECT MINUTE_AT, VIEWING_DEVICES
        FROM {MART}.MART_MINUTE_AUDIENCE
        WHERE NETWORK_NAME = '{minute_network}'
          AND VIEW_DATE = '{minute_date}'
        ORDER BY MINUTE_AT
    """)

    programs_on_day = run(f"""
        SELECT DISTINCT PROGRAM_NAME, PROGRAM_AIR_FROM, PROGRAM_AIR_TO
        FROM {MART}.MART_PROGRAM_VIEWING
        WHERE NETWORK_NAME = '{minute_network}'
          AND AIR_DATE = '{minute_date}'
        ORDER BY PROGRAM_AIR_FROM
    """)

    if minutes.empty:
        st.info("この日・この局の視聴データはありません。")
    else:
        line = (
            alt.Chart(minutes)
            .mark_line(color=BLUE, strokeWidth=1.5)
            .encode(
                x=alt.X("MINUTE_AT:T", title="時刻", axis=alt.Axis(format="%H:%M")),
                y=alt.Y("VIEWING_DEVICES:Q", title="視聴台数"),
                tooltip=[alt.Tooltip("MINUTE_AT:T", title="時刻", format="%H:%M"),
                         alt.Tooltip("VIEWING_DEVICES:Q", title="台数")],
            )
        )
        layers = [line]
        if not programs_on_day.empty:
            rules = (
                alt.Chart(programs_on_day)
                .mark_rule(color=GREY, strokeDash=[4, 4])
                .encode(
                    x=alt.X("PROGRAM_AIR_FROM:T", title="時刻"),
                    tooltip=[alt.Tooltip("PROGRAM_NAME:N", title="番組"),
                             alt.Tooltip("PROGRAM_AIR_FROM:T", title="開始", format="%H:%M"),
                             alt.Tooltip("PROGRAM_AIR_TO:T", title="終了", format="%H:%M")],
                )
            )
            layers.append(rules)
        chart = alt.layer(*layers).properties(
            height=360,
            title=f"{minute_network} {minute_date} の毎分の視聴台数（破線は番組の始まり）",
        )
        st.altair_chart(styled(chart), use_container_width=True)

        peak = minutes.loc[minutes["VIEWING_DEVICES"].idxmax()]
        st.caption(
            f"この日のピークは {pd.Timestamp(peak['MINUTE_AT']).strftime('%H:%M')} の "
            f"{int(peak['VIEWING_DEVICES']):,} 台です。番組の境で台数が動き、CM ブレークで少し凹む様子は、"
            "この粒度でないと見えません。リーチのような「見たかどうか」の指標は from-to のままで十分です。"
        )

        with st.expander("この日の番組表を見る"):
            st.dataframe(programs_on_day, use_container_width=True)

st.markdown("---")
st.caption(
    "指標の定義はセマンティックビュー BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING に"
    "置いてあります。このアプリの SQL も同じ計算式に揃えています。"
)
