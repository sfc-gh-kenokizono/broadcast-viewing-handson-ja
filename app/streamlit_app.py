"""放送視聴データの可視化アプリ

Snowsight の Projects、Streamlit から新規作成し、このファイルの内容を貼り付けて実行します。
ローカルへのインストールやコマンドライン操作は必要ありません。

参照するのはマート層だけです。指標の定義はセマンティックビューに置いてあるので、
このアプリが持っているのは「どう見せるか」だけになります。
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
st.caption("非特定視聴データにもとづく視聴実績。対象期間は 2026 年 7 月 1 日から 7 月 31 日です。")

networks = run(f"SELECT DISTINCT NETWORK_NAME FROM {MART}.MART_DEVICE_DAILY ORDER BY 1")
network_list = networks["NETWORK_NAME"].tolist()

with st.sidebar:
    st.header("絞り込み")
    selected_networks = st.multiselect("局", network_list, default=network_list)
    date_from, date_to = st.date_input(
        "期間",
        value=(pd.Timestamp("2026-07-01").date(), pd.Timestamp("2026-07-31").date()),
        min_value=pd.Timestamp("2026-07-01").date(),
        max_value=pd.Timestamp("2026-07-31").date(),
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
c2.metric("リーチ（世帯数）", f"{int(summary['REACH_HOUSEHOLDS']):,}")
c3.metric("視聴回数", f"{int(summary['SESSIONS']):,}")
c4.metric("総視聴時間（分）", f"{int(summary['MINUTES']):,}")

st.info(
    "台数と世帯数が違うのは、1 つの回線に複数の受信機がぶら下がっていることがあるためです。"
    "世帯の代わりに IP アドレスを使うと、その分がまとめて 1 つとして数えられます。"
)

tab1, tab2, tab3, tab4 = st.tabs(["リーチの推移", "番組", "チャンネル移動", "増分リーチ"])

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

    st.markdown(
        "第三放送ネットワークの 7 月 17 日が落ち込んでいます。"
        "視聴が減ったのではなく、その日のログが届かなかったためです。"
        "5 つの局からデータを集める仕組みでは、どこか 1 局が遅れたり落ちたりすることが必ず起こります。"
    )

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
        "推計視聴人数は視聴世帯数に 1 世帯あたりの想定人数 2.2 を掛けた便宜的な値です。"
        "このデータには世帯の人数が入っていないため、固定の係数を使っています。"
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
        st.dataframe(programs, use_container_width=True, hide_index=True)

# -----------------------------------------------------------------------------
# チャンネル移動
# -----------------------------------------------------------------------------
with tab3:
    st.markdown(
        "局をまたいだチャンネル移動です。この数字は 1 局のデータだけでは出せません。"
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
        .properties(height=340, title="局から局へのチャンネル移動")
    )
    st.altair_chart(styled(chart), use_container_width=True)

    with st.expander("移動の一覧を表で見る"):
        st.dataframe(zap, use_container_width=True, hide_index=True)

# -----------------------------------------------------------------------------
# 増分リーチ
# -----------------------------------------------------------------------------
with tab4:
    st.markdown(
        "放送だけで届いていた人に配信を足したとき、重複を除いてどれだけ広がるかです。"
        "放送と配信のデータが 1 か所にそろっていないと計算できません。"
        "別々の場所にあると、どちらでも届いた人を 1 人として数えられないためです。"
    )

    inc = run(f"""
        SELECT
          ADVERTISER,
          CATEGORY,
          BROADCAST_ONLY_REACH,
          BOTH_REACH,
          STREAMING_ONLY_REACH,
          BROADCAST_REACH,
          COMBINED_REACH,
          INCREMENTAL_REACH,
          INCREMENTAL_REACH_PCT,
          COMBINED_FREQUENCY
        FROM {MART}.MART_INCREMENTAL_REACH
        ORDER BY BROADCAST_REACH DESC
    """)

    breakdown = inc.melt(
        id_vars=["ADVERTISER"],
        value_vars=["BROADCAST_ONLY_REACH", "BOTH_REACH", "STREAMING_ONLY_REACH"],
        var_name="KIND",
        value_name="DEVICES",
    )
    label = {
        "BROADCAST_ONLY_REACH": "放送のみ接触",
        "BOTH_REACH": "両方に接触",
        "STREAMING_ONLY_REACH": "配信のみ接触",
    }
    breakdown["KIND"] = breakdown["KIND"].map(label)

    chart = (
        alt.Chart(breakdown)
        .mark_bar()
        .encode(
            x=alt.X("DEVICES:Q", title="台数", stack="zero"),
            y=alt.Y("ADVERTISER:N", title="広告主", sort="-x"),
            color=alt.Color("KIND:N", title="接触の種類",
                            scale=alt.Scale(domain=list(label.values()),
                                            range=[DEEP, AMBER, BLUE])),
            tooltip=["ADVERTISER:N", "KIND:N", "DEVICES:Q"],
        )
        .properties(height=520, title="接触の内訳")
    )
    st.altair_chart(styled(chart), use_container_width=True)

    st.subheader("配信を足して増えた割合")
    chart = (
        alt.Chart(inc)
        .mark_bar(color=GREEN)
        .encode(
            x=alt.X("INCREMENTAL_REACH_PCT:Q", title="増えた割合（パーセント）"),
            y=alt.Y("ADVERTISER:N", title="広告主", sort="-x"),
            tooltip=["ADVERTISER:N", "BROADCAST_REACH:Q",
                     "INCREMENTAL_REACH:Q", "INCREMENTAL_REACH_PCT:Q"],
        )
        .properties(height=520)
    )
    st.altair_chart(styled(chart), use_container_width=True)

    with st.expander("増分リーチの一覧を表で見る"):
        st.dataframe(inc, use_container_width=True, hide_index=True)

st.divider()
st.caption(
    "指標の定義はセマンティックビュー BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING に"
    "置いてあります。このアプリとエージェントは同じ定義を参照しています。"
)
