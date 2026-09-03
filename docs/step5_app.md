# 第 5 章 可視化アプリを作る

所要時間の目安 10 分

## 目的

マート層をそのまま画面にします。

Git リポジトリのコードからアプリを作ります。ローカルへのインストールも、コードの貼り付けも必要ありません。

## 使うファイル

`sql/step5_app.sql`

ワークスペースの左側の一覧から `sql` フォルダを開き、このファイルを選んで上から順に実行します。**アプリのコードをコピーして貼り付ける必要はありません。**

## 手順

このファイルがやることは 2 つです。

| # | やること | 何が起きるか |
|---|---|---|
| 1 | `COPY FILES` で `app` フォルダを内部ステージに移す | リポジトリにある `streamlit_app.py` がステージに置かれます |
| 2 | `CREATE STREAMLIT` でアプリを作る | そのステージを指すアプリができます |

実行が終わったら、Snowsight の左メニューで **Projects » Streamlit** を選びます。`BCAST_VIEWING_APP` が一覧に出てくるので、選ぶと起動します。

### なぜ画面から作らないのか

画面から作る場合は、アプリのコードを貼り付けることになります。リポジトリにコードがあるので、**そこから直接作ったほうが確実**です。実務でも、アプリのコードはリポジトリで管理して、そこから配置します。

第 1 章で CSV を読み込んだときと同じ理由で、Git リポジトリのステージを直接アプリの置き場所には指定できません。`COPY FILES` で内部ステージに移してから指定します。

### 所有者権限について

Streamlit は**作成したロールの権限で動きます**（所有者権限）。このファイルは `ACCOUNTADMIN` で実行するので、`ACCOUNTADMIN` の権限で動きます。

第 1 章でカスタムロールを `SYSADMIN` の下にぶら下げているため、`ACCOUNTADMIN` から `BCAST_ENGINEER_ROLE` が作ったテーブルに到達できます。**あの `GRANT ROLE` を省くと、ここで `Insufficient privileges to operate on table` で落ちます。**

権限の設計を間違えると動かない、という形で現れる箇所です。

### コードを直したときの反映

リポジトリのコードを直した場合は、次の順で反映します。

```sql
ALTER GIT REPOSITORY BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO FETCH;

CREATE OR REPLACE STAGE BCAST_VIEWING_HANDSON.MART.BCAST_APP_STAGE;

COPY FILES INTO @BCAST_VIEWING_HANDSON.MART.BCAST_APP_STAGE
  FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/app/;

CREATE OR REPLACE STREAMLIT BCAST_VIEWING_HANDSON.MART.BCAST_VIEWING_APP
  ROOT_LOCATION = '@BCAST_VIEWING_HANDSON.MART.BCAST_APP_STAGE'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = BCAST_HANDSON_WH;
```

そのあとアプリの画面を再読み込みしてください。

画面上で直したい場合は、アプリの画面から Edit を選ぶと編集できます。ただしその変更はリポジトリには戻りません。

### 参考 ワークスペースから作る方法もあります

ワークスペースの `+ Add new` から Streamlit アプリを作ることもできます。この場合は実行基盤がコンテナ（コンピュートプール）になり、ウェアハウスではなくコンピュートプールの使用時間で課金されます。新しく作り始めるときはこちらが便利です。

このハンズオンでは、既存のコードをリポジトリから配置する形にしたいので、SQL で作る方法を採っています。

## 画面の中身

5 つのタブがあります。

| タブ | 内容 | 見どころ |
|---|---|---|
| リーチの推移 | 日別・局別のリーチ、エリア別のリーチ | 局や日によるリーチの違い |
| 番組 | 番組別の視聴台数、セグメント別の傾向 | 属性が分かるのは 10 パーセントだけという注意書き |
| 次に見た別の局 | 30分以内に次に見た別の局 | 5 局を束ねないと出ない数字 |
| フリークエンシー | リーチと平均フリークエンシーの散布図、接触回数の分布 | リーチ × フリークエンシー = インプレッションの関係。接触は推定値である注意書き |
| 毎分の推移 | 選んだ日・局の 1 分刻みの視聴台数カーブと番組の境 | **from-to のままでは描けないグラフ**。第 2 章で 1 分ごとに展開した理由がここで分かる |

上部には全体の数字を 4 つ並べています。リーチの台数とIP数が違うことがひと目で分かるようにしてあります。IP数は世帯数そのものではなく、世帯到達の代理指標です。

### 「毎分の推移」タブについて

このタブだけが、第 2 章で 1 分ごとに展開したデータを使っています。

```text
台数 ▲
      │      ╭──╮       ╭───╮
      │  ╭───╯  ╰─╮╭────╯   ╰──╮      ← CM ブレークで少し凹む
      │──╯        ╰╯            ╰───
      └──┬────────┬──────────┬──────▶ 時刻
       20:00    20:30      21:00
        番組A   │  番組B   │  番組C   ← 破線は番組の始まり
```

リーチは「見たかどうか」なので from-to のままで数えられます。一方「20:31 に何台見ていたか」を 1 分ごとに並べるには、分の側に行が要ります。ただし参照しているのは展開した 1,208 万行そのものではなく、「局 × 分 × 台数」に集計した `MART_MINUTE_AUDIENCE`（約 55 万行）です。展開したものは集計して小さく持つ、という第 2 章の方針がここにつながっています。

番組の境の破線は `MART_PROGRAM_VIEWING` の放送時刻から取っています。番組が変わった瞬間に台数が動き、CM ブレークで少し凹む様子は、この粒度でないと見えません。

## 指標の定義との関係

「リーチとは何か」という正式な定義は、第 3 章のセマンティックビューに書いてあります。アプリはマート層へ直接 SQL を実行しますが、`COUNT(DISTINCT COMMON_ID)` など同じ計算式に揃えています。

## 日本語の表示について

グラフには Altair を使っています。フォントを指定して日本語が崩れないようにしてあります。

```python
FONT = "Hiragino Sans, Noto Sans JP, Yu Gothic, sans-serif"

def styled(chart):
    return chart.configure_axis(labelFont=FONT, titleFont=FONT) \
                .configure_legend(labelFont=FONT, titleFont=FONT)
```

## 少し触ってみる

左の絞り込みで局や期間を変えてみてください。全体、リーチ、番組、次に見た別の局が連動して変わります。フリークエンシータブはキャンペーン全期間・全局の集計なので、フィルターの対象外であることを画面に表示します。毎分の推移タブは、タブの中で日付と局を 1 つだけ選びます。ゴールデン帯（19 時〜22 時）に注目して、番組の境と CM ブレークで台数が動く様子を見てください。

`@st.cache_data(ttl=600)` を付けているので、同じ絞り込みに戻したときは Snowflake に問い合わせ直しません。動かすたびにウェアハウスが動くわけではない、ということです。

## うまく動かないとき

**`TypeError: ... got an unexpected keyword argument 'hide_index'` や `module 'streamlit' has no attribute 'divider'` と出る場合**

Streamlit in Snowflake の実行環境の Streamlit は、手元で `pip install streamlit` したものより古いことがあります。新しめの API（`st.dataframe(..., hide_index=True)` は 1.23 以降、`st.divider()` は 1.25 以降）を書くと、この形で落ちます。

Streamlit はスクリプト全体を上から下まで実行するので、**あるタブの中の 1 行が原因でも、全タブの下にエラーが出ます**。エラー文の `File ".../streamlit_app.py", line N` の行だけを直せば解消します。

同梱の [app/streamlit_app.py](../app/streamlit_app.py) は、古い実行環境でも動く書き方に寄せてあります。

**`Insufficient privileges to operate on table 'MART_DEVICE_DAILY'` と出る場合**

Streamlit は所有者権限で動きます。エラー文にある `The owner role ... must have SELECT granted on TABLE ...` が示すとおり、**アプリを作ったロールがマート層を読めていません**。

マート層のテーブルは `BCAST_ENGINEER_ROLE` が作ったので、そのロールへの経路がないロール（たとえば `ACCOUNTADMIN` にカスタムロールを繋いでいない状態）でアプリを作ると再現します。次のどちらかで解消します。

```sql
-- 案 1: アプリを BCAST_ANALYST_ROLE ロールで作り直す（推奨）

-- 案 2: カスタムロールを SYSADMIN の下にぶら下げる（第 1 章に含めてあります）
USE ROLE ACCOUNTADMIN;
GRANT ROLE BCAST_ENGINEER_ROLE TO ROLE SYSADMIN;
GRANT ROLE BCAST_ANALYST_ROLE  TO ROLE SYSADMIN;
```

カスタムロールを作ったら `SYSADMIN` の下に繋ぐ、というのが Snowflake の推奨構成です。ここを飛ばすと、管理者ロールでも他ロールが作ったオブジェクトに手が届きません。

## 付録について

[appendix/react-analyst-app](../appendix/react-analyst-app) に、セマンティックビューを REST API 経由で呼び出し、自作のフロントエンドに描画する Next.js アプリを同梱しています。

「用意された画面を使うのではなく、指標だけを API で取ってきて画面は自分で作る」という進め方が Snowflake で成立することを示すものです。ハンズオン本編では扱いません。

## 次へ

[第 6 章 アクセス権とマスキング](step6_rbac.md)
