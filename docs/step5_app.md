# 第 5 章 可視化アプリを作る

所要時間の目安 10 分

## 目的

マート層をそのまま画面にします。

やることは「Snowsight で新規作成してコードを貼る」だけです。ローカルへのインストールもコマンドライン操作も必要ありません。

## 手順

1. Snowsight の左メニューで Projects、Streamlit を選びます
2. 右上の Streamlit App を選びます
3. 次のように設定します

| 項目 | 値 |
|---|---|
| App title | 放送視聴データ |
| App location | `BCAST_VIEWING_HANDSON` の `MART` |
| App warehouse | `BCAST_HANDSON_WH` |
| 画面右上のロール | `BCAST_ANALYST` |

ロールを `BCAST_ANALYST` にしてください。Streamlit は**作成したロールの権限で動きます**（所有者権限）。
マート層を参照できるロールで作らないと、起動時に
`Insufficient privileges to operate on table` で落ちます。

4. Create を選ぶと編集画面が開きます
5. 既定で入っているコードをすべて消し、[app/streamlit_app.py](../app/streamlit_app.py) の内容を貼り付けます
6. 右上の Run を選びます

## 画面の中身

4 つのタブがあります。

| タブ | 内容 | 見どころ |
|---|---|---|
| リーチの推移 | 日別・局別のリーチ、エリア別のリーチ | 第三放送ネットワークの 7 月 17 日が落ちている || 番組 | 番組別の視聴台数、セグメント別の傾向 | 属性が分かるのは 10 パーセントだけという注意書き |
| チャンネル移動 | 局から局への移動 | 5 局を束ねないと出ない数字 |
| 増分リーチ | 接触の内訳と増えた割合 | 放送と配信が 1 か所にないと計算できない指標 |

上部には全体の数字を 4 つ並べています。リーチの台数と世帯数が違うことがひと目で分かるようにしてあります。

## このアプリが持っていないもの

指標の定義です。

「リーチとは何か」は第 3 章のセマンティックビューに書いてあります。このアプリが持っているのは「どう見せるか」だけです。同じ定義をエージェントも参照しているので、画面で見た数字とエージェントが答えた数字は一致します。

言い換えると、画面を増やしても定義は増えません。ここが、画面ごとに集計ロジックを書く作り方との違いになります。

## 日本語の表示について

グラフには Altair を使っています。フォントを指定して日本語が崩れないようにしてあります。

```python
FONT = "Hiragino Sans, Noto Sans JP, Yu Gothic, sans-serif"

def styled(chart):
    return chart.configure_axis(labelFont=FONT, titleFont=FONT) \
                .configure_legend(labelFont=FONT, titleFont=FONT)
```

## 少し触ってみる

左の絞り込みで局や期間を変えてみてください。数字とグラフが連動して変わります。

`@st.cache_data(ttl=600)` を付けているので、同じ絞り込みに戻したときは Snowflake に問い合わせ直しません。動かすたびにウェアハウスが動くわけではない、ということです。

## うまく動かないとき

**`TypeError: ... got an unexpected keyword argument 'hide_index'` や `module 'streamlit' has no attribute 'divider'` と出る場合**

Streamlit in Snowflake の実行環境の Streamlit は、手元で `pip install streamlit` したものより古いことがあります。新しめの API（`st.dataframe(..., hide_index=True)` は 1.23 以降、`st.divider()` は 1.25 以降）を書くと、この形で落ちます。

Streamlit はスクリプト全体を上から下まで実行するので、**あるタブの中の 1 行が原因でも、全タブの下にエラーが出ます**。エラー文の `File ".../streamlit_app.py", line N` の行だけを直せば解消します。

同梱の [app/streamlit_app.py](../app/streamlit_app.py) は、古い実行環境でも動く書き方に寄せてあります。

**`Insufficient privileges to operate on table 'MART_DEVICE_DAILY'` と出る場合**

Streamlit は所有者権限で動きます。エラー文にある `The owner role ... must have SELECT granted on TABLE ...` が示すとおり、**アプリを作ったロールがマート層を読めていません**。

マート層のテーブルは `BCAST_ENGINEER` が作ったので、そのロールへの経路がないロール（たとえば `ACCOUNTADMIN` にカスタムロールを繋いでいない状態）でアプリを作ると再現します。次のどちらかで解消します。

```sql
-- 案 1: アプリを BCAST_ANALYST ロールで作り直す（推奨）

-- 案 2: カスタムロールを SYSADMIN の下にぶら下げる（第 1 章に含めてあります）
USE ROLE ACCOUNTADMIN;
GRANT ROLE BCAST_ENGINEER TO ROLE SYSADMIN;
GRANT ROLE BCAST_ANALYST  TO ROLE SYSADMIN;
```

カスタムロールを作ったら `SYSADMIN` の下に繋ぐ、というのが Snowflake の推奨構成です。ここを飛ばすと、管理者ロールでも他ロールが作ったオブジェクトに手が届きません。

## 付録について

[appendix/react-analyst-app](../appendix/react-analyst-app) に、セマンティックビューを REST API 経由で呼び出し、自作のフロントエンドに描画する Next.js アプリを同梱しています。

「用意された画面を使うのではなく、指標だけを API で取ってきて画面は自分で作る」という進め方が Snowflake で成立することを示すものです。ハンズオン本編では扱いません。

## 次へ

[第 6 章 アクセス権とマスキング](step6_rbac.md)
