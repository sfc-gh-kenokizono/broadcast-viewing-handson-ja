# 第 3 章 セマンティックビューと検索サービス

所要時間の目安 20 分

## 目的

指標の定義を Snowflake 側に置きます。

第 2 章で作ったマート層は、まだ「数字のもと」でしかありません。「リーチとは何か」「フリークエンシーとは何か」を決めるのはこの章です。ここで一度決めてしまえば、可視化アプリでもエージェントでも同じ定義が使われるので、画面ごとに数字が違うという事態が起きなくなります。

あわせて、番組とコマーシャルの説明文を検索できるようにします。視聴ログは数値と ID だけなので、文章で探せる材料を別に用意しておくと、第 4 章のエージェントが数値の集計と文章の検索を組み合わせて答えられるようになります。

## 使うファイル

[sql/step3_semantic.sql](../sql/step3_semantic.sql)

ワークシートに貼り付けて、上から順に実行します。

## セマンティックビューの構成要素

5 つあります。

| 要素 | 役割 | このハンズオンでの例 |
|---|---|---|
| 論理テーブル | どの物理テーブルを使うか | `device_daily` は `MART_DEVICE_DAILY` |
| リレーションシップ | どのテーブルとどのテーブルが結合できるか | 広告接触は出稿に紐づく |
| ファクト | 行ごとの数値 | その日その局を見た分数 |
| ディメンション | 切り口 | 視聴日、局名、ジャンル、セグメント |
| メトリック | 集計した指標 | リーチ、フリークエンシー、増分リーチ |

書き方は次のようになります。

```sql
CREATE OR REPLACE SEMANTIC VIEW SV_BROADCAST_VIEWING
  TABLES (
    device_daily AS BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY
      WITH SYNONYMS = ('視聴実績', '日別視聴')
      COMMENT = '1 行が 1 台の受信機の 1 日 1 局分の視聴'
  )
  DIMENSIONS (
    device_daily.network_name AS NETWORK_NAME
      WITH SYNONYMS = ('局', '放送局', '局名')
      COMMENT = '視聴された放送局の名前'
  )
  METRICS (
    device_daily.reach_devices AS COUNT(DISTINCT device_daily.COMMON_ID)
      WITH SYNONYMS = ('リーチ', '到達台数', '視聴台数')
      COMMENT = '1 回以上視聴した受信機の台数。重複を除いて数えている'
  );
```

識別子は英字にして、日本語は `WITH SYNONYMS` と `COMMENT` に入れています。自然言語で質問したときに、この同義語と説明文が手がかりになります。「リーチ」でも「何台に届いたか」でも同じ指標に行き着くのは、同義語を並べているからです。

## リーチを COUNT(DISTINCT) で定義している理由

この章でいちばん大事なところです。

第 2 章でマート層を「1 行 = 1 台 × 1 日 × 1 局」という細かい粒度にしました。日別のリーチをあらかじめ計算して持たなかったのは、そうすると**足せなくなる**からです。

```
仮に日別のリーチを持っていたとすると

  7月1日  NW01  リーチ 3,000 台
  7月2日  NW01  リーチ 3,100 台
  ...

これを月合計しようとして 3,000 + 3,100 + ... と足すと、
両方の日に見た人を 2 回数えてしまいます。
```

細かい粒度で持ち、リーチを `COUNT(DISTINCT COMMON_ID)` として定義しておくと、日で見ても月で見ても局をまたいで見ても、そのつど重複を除いた正しい人数が出ます。

実際に確かめられます。日別に出した値を足した数と、期間全体で出した値は一致しません。

```sql
-- 日別
SELECT * FROM SEMANTIC_VIEW(
  BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  METRICS device_daily.reach_devices
  DIMENSIONS device_daily.view_date
);

-- 期間全体
SELECT * FROM SEMANTIC_VIEW(
  BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  METRICS device_daily.reach_devices
);
```

期間全体の値のほうが小さくなります。同じ人が複数の日に登場するためです。これが正しい挙動で、指標の定義を 1 か所に置いておくと、どの画面から見てもこの正しさが保たれます。

## 定義した指標

| 指標 | 意味 |
|---|---|
| リーチ（到達台数） | 1 回以上視聴した受信機の台数 |
| 到達世帯数 | 1 回以上視聴した世帯の数。1 つの回線に複数台あるので台数より少ない |
| 視聴回数 | 視聴した回数の合計。重複を除いていないので人数ではない |
| 総視聴時間 | 視聴した分数の合計 |
| 1 台あたりの視聴時間 | 総視聴時間を到達台数で割ったもの |
| 番組視聴台数 | その番組を視聴した受信機の台数 |
| 推計視聴人数 | 視聴世帯数に 1 世帯あたりの想定人数 2.2 を掛けた便宜的な値 |
| 平均視聴完了率 | 放送回をどれだけ見通したかの平均 |
| 接触リーチ | そのコマーシャルに 1 回以上接触した台数 |
| フリークエンシー | 1 台あたりの平均接触回数 |
| 放送のリーチ / 配信だけで届いた台数 / 合計リーチ | 増分リーチの内訳 |
| 増分リーチ | 配信を足すことで新たに届いた台数 |
| 増分リーチ率 | 放送のリーチに対して何パーセント広がったか |
| チャンネル移動回数 | チャンネルを移動した回数 |

「1 台あたりの視聴時間」「フリークエンシー」「増分リーチ率」の 3 つは、他の指標を組み合わせて作っています。こうした指標は論理テーブルの名前を付けずに定義します。

```sql
METRICS (
  ad_contact.total_contacts AS SUM(ad_contact.contacts),
  ad_contact.contact_reach AS COUNT(DISTINCT ad_contact.COMMON_ID),
  -- テーブル名を付けない。複数の指標を組み合わせた指標になる
  avg_frequency AS DIV0(ad_contact.total_contacts, ad_contact.contact_reach)
)
```

## 自然言語で質問したときの振る舞いを調整する

`AI_SQL_GENERATION` に指示を書いておくと、SQL の作り方を揃えられます。

```sql
AI_SQL_GENERATION '数値は小数第 1 位までに丸めてください。日付の範囲が指定されていない場合は
2026 年 7 月の全期間を対象にしてください。セグメントを使った集計を返すときは、パネル調査で
属性が判明している端末が全体の 10 パーセントであり、全体の姿ではないことを回答に添えてください。'
```

3 つめが実務的に効きます。属性が分かっているのは 10 パーセントだけという前提を、回答のたびに添えさせています。データの読み方を間違えないようにする工夫を、定義側に持たせられるということです。

## 検索サービス

視聴ログは数値と ID だけなので、文章として探せる材料が別に必要です。番組の概要文とコマーシャルの素材説明文をひとつのビューにまとめ、それを検索の対象にします。

```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE SVC_PROGRAM_CM_META
  ON CONTENT
  ATTRIBUTES DOC_TYPE, DOC_ID, TITLE, GENRE, TIME_SLOT, NETWORK_NAME, ADVERTISER, CATEGORY
  WAREHOUSE = BCAST_HANDSON_WH
  TARGET_LAG = '1 hour'
  AS SELECT ... FROM V_PROGRAM_CM_DOCS;
```

| 項目 | 意味 |
|---|---|
| `ON` | 検索の対象になる本文の列 |
| `ATTRIBUTES` | 絞り込みに使える列 |
| `TARGET_LAG` | 元のデータが変わったときに、どれだけの遅れまで許すか |

本文には番組名やジャンルも含めています。概要文だけを対象にすると「アニメ」のような語で当たりにくくなるためです。

試してみます。

```sql
SELECT PARSE_JSON(
  SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META',
    '{"query": "若い人向けのバラエティ番組", "columns": ["DOC_TYPE","TITLE","GENRE","TIME_SLOT"], "limit": 5}'
  )
)['results'] AS 検索結果;
```

番組名に「バラエティ」という語が入っていなくても、概要文の内容から近いものが返ります。

## 生データに触れないロールでも指標は見られる

セマンティックビューは、元になっているテーブルへの権限がなくても参照できます。

```sql
GRANT SELECT, REFERENCES ON SEMANTIC VIEW ... TO ROLE BCAST_ANALYST;
```

`BCAST_ANALYST` は `RAW` にも `STG` にも `INT` にも権限がありませんが、この 1 行だけで指標を見られるようになります。生データは限られた人だけ、指標は広く、という形が作れます。第 6 章でこの挙動を実際に確認します。

## 動作確認

スクリプトの最後にある確認クエリを実行してください。

1. 定義された指標と切り口の一覧（`SHOW SEMANTIC METRICS` / `SHOW SEMANTIC DIMENSIONS`）
2. 局別のリーチ
3. 同じ指標を日別に出す。日別の合計は期間全体の値と一致しないこと
4. 番組別の推計視聴人数
5. 増分リーチ
6. 検索サービスに 2 つの質問を投げる

Snowsight の左メニューから AI と ML、Cortex Analyst を開くと、作ったセマンティックビューを画面から試すこともできます。

## この章で使ったクレジット

```sql
SELECT
  SERVICE_TYPE                       AS "サービス種別",
  ROUND(SUM(CREDITS_USED), 6)        AS "クレジット"
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -1, CURRENT_TIMESTAMP())
GROUP BY SERVICE_TYPE
ORDER BY 2 DESC;
```

検索サービスは、索引を保持している間ずっと少しずつ課金されます。使い終わったら止めておくのが無駄がありません。

```sql
-- 止める
ALTER CORTEX SEARCH SERVICE BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META SUSPEND;
-- 再開する
ALTER CORTEX SEARCH SERVICE BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META RESUME;
```

## 次へ

[第 4 章 エージェントを作り自然言語で分析する](step4_cowork.md)
