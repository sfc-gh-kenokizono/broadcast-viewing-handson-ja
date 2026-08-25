# 第 2 章 dbt でデータを変換する

所要時間の目安 40 分

## 目的

生データから指標までのパイプラインを dbt で組み、Snowflake の中で動かします。

この章のいちばんの見どころは、**同じ生データから 3 通りの数字が出る**ことです。どの ID で数えるかによって答えが変わります。それを自分の手で確認します。

## dbt を Snowflake の中で動かすということ

dbt Core をお使いになったことがあれば、書くもの（`dbt_project.yml`、`profiles.yml`、`models/` 配下の SQL）はそのままです。違うのは動かす場所です。

| | dbt Core | Snowflake の中で動かす場合 |
|---|---|---|
| 実行環境 | 自分で用意した端末やサーバー | Snowflake が用意する。インストール不要 |
| 接続情報 | `profiles.yml` に account と user を書く | いまログインしている文脈で動くので不要 |
| 実行 | `dbt run` をコマンドで打つ | ワークスペースのボタン、または `EXECUTE DBT PROJECT` |
| スケジュール | 別途オーケストレーターを用意 | Snowflake のタスク |
| ライセンス料 | — | かかりません。ウェアハウスの使用料だけです |

## 1. ワークスペースを作る

1. Snowsight の左メニューで Projects、Workspaces を選びます
2. 画面上部のワークスペース一覧から Create Workspace、From Git repository を選びます
3. 次のように入力します

| 項目 | 値 |
|---|---|
| Repository URL | `https://github.com/<ユーザー名>/broadcast-viewing-handson-ja.git` |
| Workspace name | `bcast_viewing` |
| API integration | `BCAST_GIT_API` |
| 認証方式 | Personal access token |
| Credentials secret | `BCAST_VIEWING_HANDSON` の `INTEGRATIONS` にある `BCAST_GIT_SECRET` |

4. Create を選びます

リポジトリの中身が左側に表示されます。`dbt` フォルダの中が dbt プロジェクトです。

## 2. プロジェクトの構成を見る

```
dbt/
├── dbt_project.yml                     層ごとのスキーマとマテリアライズの指定
├── profiles.yml                        接続設定
├── macros/
│   └── generate_schema_name.sql        スキーマ名の決め方の上書き
└── models/
    ├── staging/                        クレンジング
    │   ├── stg_viewing_log.sql
    │   └── stg_streaming_log.sql
    ├── intermediate/                   中間処理
    │   ├── int_device_identity.sql
    │   ├── int_viewing_program.sql
    │   ├── int_cm_contact.sql
    │   ├── int_ad_contact.sql
    │   └── int_viewing_minutes.sql
    └── marts/                          指標のもとになるファクト
        ├── mart_device_daily.sql
        ├── mart_program_viewing.sql
        ├── mart_frequency.sql
        ├── mart_incremental_reach.sql
        └── mart_zapping_transition.sql
```

### 最初に見ていただきたい 2 つのファイル

**`profiles.yml`** — `account` と `user` が空文字になっています。ワークスペースで実行するときは、いまログインしているアカウントとユーザーの文脈でそのまま動くためです。

**`macros/generate_schema_name.sql`** — dbt の既定では、モデルにスキーマを指定すると「接続先のスキーマ名 + 指定した名前」という連結になります。接続先が `STG` でモデルに `MART` を指定すると `STG_MART` になってしまいます。ここでは指定した名前をそのまま使うように上書きしています。既存の dbt プロジェクトを持ち込むときに最初に書くことが多い上書きです。

### 依存パッケージについて

このプロジェクトには `packages.yml` を置いていません。外部のパッケージを使っていないので、`dbt deps` を実行する必要がなく、そのための外部通信の設定（ネットワークルールと外部アクセス統合）も要りません。

実際のプロジェクトで `dbt_utils` などを使う場合は、`dbt deps` を実行するために外部アクセス統合を 1 度だけ作り、dbt を実行するロールに使用権限を渡します。設定は 1 回で済み、以降は選ぶだけです。

## 3. コンパイルして依存関係を見る

1. 画面上部の Project で `dbt` を選びます
2. Profile で `dev` を選びます
3. コマンドの一覧から Compile を選び、実行ボタンを押します
4. エディタの下にある DAG タブを開きます

生データから指標までの流れが図で表示されます。四角をクリックすると、そのモデルの SQL が開きます。SQL を開いた状態で右上の View Compiled SQL を選ぶと、`ref` や `source` が実際のテーブル名に置き換わった SQL が横に並びます。

## 4. 実行する

コマンドの一覧から Run を選び、実行ボタンを押します。12 個のモデルが順番に作られます。XSMALL のウェアハウスで 1 分程度です。

できあがったものを確認します。ワークスペースの中に SQL ファイルを新規作成して実行してください。

```sql
SHOW VIEWS  IN SCHEMA BCAST_VIEWING_HANDSON.STG;
SHOW VIEWS  IN SCHEMA BCAST_VIEWING_HANDSON.INT;
SHOW TABLES IN SCHEMA BCAST_VIEWING_HANDSON.MART;
```

`STG` と `INT` はビュー、`MART` はテーブルになっています。マートは可視化アプリやエージェントが繰り返し参照するので、計算結果を持たせています。

### マート層の粒度について

マート層はあらかじめ集計した表にしてありません。細かい粒度のまま持っています。

| モデル | 1 行が何を表すか |
|---|---|
| `mart_device_daily` | 1 台 × 1 日 × 1 局 |
| `mart_program_viewing` | 1 番組の放送回 × 1 台 |
| `mart_frequency` | 1 つのコマーシャル × 1 台 |
| `mart_incremental_reach` | 1 つのコマーシャル |
| `mart_zapping_transition` | 1 日 × 移動元の局 × 移動先の局 |

日別のリーチをあらかじめ計算して持っていないのは、そうすると**足せなくなる**からです。日別のリーチを月合計しようとして足し算すると、両方の日に見た人を 2 回数えてしまいます。

細かい粒度で持っておけば、リーチを「重複を除いて数える」形で定義できます。その定義を置く場所が第 3 章のセマンティックビューになります。

## 5. テストを実行する

コマンドの一覧から Test を選びます。列が空でないか、キーが重複していないか、決めた値以外が入っていないかを確認します。

`int_device_identity` の `COMMON_ID` に `unique` のテストを付けてあります。名寄せが正しくできていれば、共通 ID は 1 行になっているはずです。

## 6. 同じデータから 3 通りの数字が出ることを確認する

ここがこの章の中心です。

```sql
WITH per_network AS (
  -- 局ごとに重複を除いて数えてから、それを足し合わせる
  SELECT NETWORK_NAME, COUNT(DISTINCT COMMON_ID) AS REACH_DEVICES
  FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY
  GROUP BY NETWORK_NAME
)
SELECT
  (SELECT SUM(VIEWING_SESSIONS)       FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY) AS "視聴区間の件数",
  (SELECT SUM(REACH_DEVICES)          FROM per_network)                                  AS "局ごとに数えた台数の合計",
  (SELECT COUNT(DISTINCT COMMON_ID)   FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY) AS "共通IDで数えた台数",
  (SELECT COUNT(DISTINCT IP_ADDRESS)  FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY) AS "IPアドレスで数えた世帯数";
```

4 つの数字が出ます。左から右へ、順に小さくなります。

| 数え方 | 意味 |
|---|---|
| 視聴区間の件数 | 重複をまったく除いていない。いちばん多い |
| 局ごとに数えた台数の合計 | 局の中では重複を除いたが、局をまたいだ重複は残っている |
| 共通 ID で数えた台数 | 5 局横断で名寄せした受信機の台数 |
| IP アドレスで数えた世帯数 | 世帯の粒度。1 つの回線に複数台あるので、台数より少ない |

**局ごとに数えた台数を足し合わせた数字と、共通 ID で数えた台数の差**が、局をまたいだ重複です。各局が別々に数えた合計と、集約して数えた値がこれだけ違うということです。

### 各局 ID では名寄せできないことを確認する

```sql
SELECT
  COUNT(DISTINCT COMMON_ID)         AS "共通IDの数",
  COUNT(DISTINCT STATION_DEVICE_ID) AS "各局IDの数"
FROM BCAST_VIEWING_HANDSON.STG.STG_VIEWING_LOG;
```

各局 ID の数のほうが何倍も多くなります。同じ受信機でも局ごとに別の値が付いているためです。局から届いた ID をそのまま数えると、台数を大幅に多く見積もることになります。

### 1 つの IP アドレスに何台ぶら下がっているか

```sql
SELECT
  DEVICES_PER_IP        AS "同じ回線の台数",
  COUNT(*)              AS "IPアドレスの数"
FROM BCAST_VIEWING_HANDSON.INT.INT_DEVICE_IDENTITY
GROUP BY DEVICES_PER_IP
ORDER BY DEVICES_PER_IP;
```

1 台の回線がほとんどですが、2 台以上ある回線もあります。集合住宅で同じ回線を複数世帯が使っている状況に相当します。IP アドレスを世帯の代わりに使うと、この分がまとめて 1 世帯として数えられます。外部データとの突合に IP アドレスを使う場合は、この限界を織り込んでおく必要があります。

## 7. 局をまたいだチャンネル移動を見る

```sql
SELECT
  FROM_CHANNEL_CODE       AS "移動元",
  TO_CHANNEL_CODE         AS "移動先",
  SUM(TRANSITION_COUNT)   AS "移動回数"
FROM BCAST_VIEWING_HANDSON.MART.MART_ZAPPING_TRANSITION
GROUP BY FROM_CHANNEL_CODE, TO_CHANNEL_CODE
ORDER BY "移動回数" DESC
LIMIT 10;
```

「041 から 071 へ」のような、局をまたいだ移動が出てきます。

この数字は 1 局のデータだけでは絶対に出ません。各局は自局が見られている間のログしか取得できないので、移動先がどこだったかは自局には見えないためです。5 局分を共通 ID で束ねた `stg_viewing_log` を作ったからこそ計算できています。

## 8. 1 分単位に分解すると行数がどうなるか

```sql
SELECT
  (SELECT COUNT(*) FROM BCAST_VIEWING_HANDSON.STG.STG_VIEWING_LOG)   AS "分解前の行数",
  (SELECT COUNT(*) FROM BCAST_VIEWING_HANDSON.INT.INT_VIEWING_MINUTES) AS "分解後の行数",
  ROUND(
    (SELECT AVG(VIEW_MINUTES) FROM BCAST_VIEWING_HANDSON.STG.STG_VIEWING_LOG), 1
  ) AS "平均の視聴区間長（分）";
```

```
分解前の行数      499,989
分解後の行数    5,260,560
平均の視聴区間長   10.5 分
```

分解後の行数は、分解前の行数に平均の視聴区間長を掛けた値とほぼ一致します。**平均が M 分なら行数はおよそ M 倍**という関係です。

大事なのは次の 2 点です。

1. **事実は何も変わっていません**。同じ視聴を、区間で表すか分で表すかの違いだけです
2. **増えるのは変換後の層だけ**です。受け取る生データの量は変わりません

平均の視聴区間長が 30 分なら 30 倍、60 分なら 60 倍になります。実際の設計では、毎分の粒度が必要な指標だけを分解し、全件を常に分の形で持たないようにします。番組ごと、分ごと、属性ごとといった集計した単位まで縮約してから持てば、行数を抑えられます。

見積もりを立てるときは、生データの量ではなく、**どの指標のためにどこまで粒度を上げるか**が効いてきます。

## 9. 番組別の視聴実績を見る

```sql
SELECT
  PROGRAM_NAME                              AS "番組名",
  GENRE                                     AS "ジャンル",
  COUNT(DISTINCT COMMON_ID)                 AS "視聴台数",
  COUNT(DISTINCT IP_ADDRESS)                AS "視聴世帯数",
  ROUND(COUNT(DISTINCT IP_ADDRESS) * 2.2)   AS "推計視聴人数"
FROM BCAST_VIEWING_HANDSON.MART.MART_PROGRAM_VIEWING
GROUP BY PROGRAM_NAME, GENRE
ORDER BY "視聴台数" DESC
LIMIT 10;
```

視聴ログには番組 ID が入っていません。番組の放送枠と時刻の範囲で突き合わせて、あとから番組を割り当てています（`int_viewing_program`）。

推計視聴人数は、視聴世帯数に 1 世帯あたりの想定人数 2.2 を掛けた便宜的な値です。このデータには世帯の人数が入っていないためです。実際にはパネル調査などを正解データにして受信機ごとに人数と属性を割り当てる処理で求めますが、そこは差し替えられる 1 か所として単純な係数にしてあります。

## 10. 増分リーチを見る

```sql
SELECT
  ADVERTISER              AS "広告主",
  BROADCAST_REACH         AS "放送のリーチ",
  STREAMING_ONLY_REACH    AS "配信だけで届いた人",
  COMBINED_REACH          AS "合計のリーチ",
  INCREMENTAL_REACH_PCT   AS "増えた割合（％）",
  COMBINED_FREQUENCY      AS "フリークエンシー"
FROM BCAST_VIEWING_HANDSON.MART.MART_INCREMENTAL_REACH
ORDER BY BROADCAST_REACH DESC
LIMIT 10;
```

放送だけで届いていた人に配信を足したとき、重複を除いてどれだけ広がるかが出ます。

この指標は、放送と配信のデータが 1 か所にそろっていないと計算できません。別々の場所にあると、どちらでも届いた人を 1 人として数えられないためです。

## 11. 属性が分かっている範囲だけの集計

```sql
SELECT
  GENDER_AGE_SEGMENT        AS "セグメント",
  GENRE                     AS "ジャンル",
  COUNT(DISTINCT COMMON_ID) AS "リーチ台数"
FROM BCAST_VIEWING_HANDSON.MART.MART_PROGRAM_VIEWING
WHERE GENDER_AGE_SEGMENT IS NOT NULL
GROUP BY GENDER_AGE_SEGMENT, GENRE
ORDER BY GENDER_AGE_SEGMENT, "リーチ台数" DESC;
```

属性が分かっているのが全体の何割なのかを確かめておきます。

```sql
SELECT
  COUNT(*)                                              AS "全端末",
  COUNT_IF(GENDER_AGE_SEGMENT IS NOT NULL)              AS "属性が分かる端末",
  ROUND(COUNT_IF(GENDER_AGE_SEGMENT IS NOT NULL) * 100.0
        / COUNT(*), 1)                                  AS "割合（％）"
FROM BCAST_VIEWING_HANDSON.INT.INT_DEVICE_IDENTITY;
```

セグメントによって、よく見られているジャンルが違うことが分かります。

ただしこれは属性が分かっている 10 パーセントの中での傾向です。全体の姿ではありません。全体に属性を広げるには、この 10 パーセントを正解データにして残りの 90 パーセントを推定する処理が必要になります。そこは別のテーマなので、この教材では分かっている範囲だけを集計しています。

この割合を先に見ておくのは、さっきの数字が何割を見たものなのかを取り違えないようにするためです。

## 12. この章で使ったクレジット

```sql
SELECT
  ROUND(SUM(TOTAL_ELAPSED_TIME) / 1000, 1)  AS "合計秒数",
  COUNT(*)                                  AS "クエリ数",
  ROUND(SUM(BYTES_SCANNED) / POWER(1024, 3), 3) AS "スキャンしたGB"
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE WAREHOUSE_NAME = 'BCAST_HANDSON_WH'
  AND START_TIME >= DATEADD('hour', -2, CURRENT_TIMESTAMP());
```

## 任意 スケジュール実行を設定する

所要時間の目安 10 分

「Snowflake でのスケジューラーは何にあたるのか」への答えがここです。作った dbt プロジェクトを Snowflake のオブジェクトとして登録し、タスクで定期実行します。

### プロジェクトを登録する

1. エディタ右側の Connect から Deploy dbt project を選びます
2. データベースは `BCAST_VIEWING_HANDSON`、スキーマは `MART` を選びます
3. Create dbt Object を選び、名前を `BCAST_DBT_PROJECT` にして Deploy を選びます

出力タブに、実行された SQL が表示されます。

```sql
create or replace DBT PROJECT "BCAST_VIEWING_HANDSON"."MART"."BCAST_DBT_PROJECT"
  from snow://workspace/...
```

### スケジュールを作る

1. Connect のメニューから Create schedule を選びます
2. 名前を `RUN_BCAST_DBT`、頻度を毎日 6 時などに設定します
3. Operation は `run`、Profile は `dev` を選び、Create を選びます

作られたタスクの定義を見てみてください。

```sql
CREATE OR REPLACE TASK BCAST_VIEWING_HANDSON.MART.RUN_BCAST_DBT
  WAREHOUSE = BCAST_HANDSON_WH
  SCHEDULE = 'USING CRON 0 6 * * * Asia/Tokyo'
AS
  EXECUTE DBT PROJECT BCAST_DBT_PROJECT ARGS='run --target dev';
```

やっていることは「決めた時刻に dbt を実行する」だけです。オーケストレーターを別に用意する必要はありません。

作ったタスクは既定で停止状態です。動かす場合は次を実行します。今日のところは設定を確認するだけで、実行しなくてかまいません。

```sql
ALTER TASK BCAST_VIEWING_HANDSON.MART.RUN_BCAST_DBT RESUME;
```

止めるときは次のとおりです。

```sql
ALTER TASK BCAST_VIEWING_HANDSON.MART.RUN_BCAST_DBT SUSPEND;
```

## 次へ

[第 3 章 セマンティックビューと検索サービス](step3_semantic.md)
