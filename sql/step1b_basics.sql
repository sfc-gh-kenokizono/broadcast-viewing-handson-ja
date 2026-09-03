-- =============================================================================
-- 第 1b 章  Snowflake そのものの動きを体感する（補足）
-- =============================================================================
-- 実行するロール: ACCOUNTADMIN
-- 所要時間の目安: 15 分
--
-- この章の位置づけ
--   第 2 章から先は「放送視聴データをどう作るか」という中身の話に入ります。
--   その前に、Snowflake という土台そのものが持っている動きを 5 つだけ
--   手で触っておきます。中身の話に入ってからでは立ち止まりにくいためです。
--   最後に補足として、届く前のデータがどう畳まれているかも小さく確かめます。
--
-- この章でやること
--   1. ウェアハウスの大きさを変えて、同じクエリの時間がどう変わるか見る
--   2. 同じクエリをもう一度実行して、結果キャッシュを見る
--   3. テーブルを消してしまってから、元に戻す（UNDROP）
--   4. 消していないが中身を壊してしまった場合に、過去の状態を読む（Time Travel）
--   5. 大きなテーブルをコピーせずに複製する（ゼロコピークローン）
--   6. （補足）60 秒ごとの信号を from-to の 1 行に畳む
--
-- 前提
--   第 1 章を実行し終わっていること。RAW スキーマに視聴ログが入っている状態です。
--   このファイルもワークスペースの左側の一覧から開いて、そのまま実行できます。
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE BCAST_HANDSON_WH;
USE SCHEMA BCAST_VIEWING_HANDSON.RAW;


-- =============================================================================
-- 1. ウェアハウスの大きさと処理時間
-- =============================================================================
-- ウェアハウスは「計算する機械」です。データの置き場所（テーブル）とは
-- 完全に分かれていて、大きさを変えてもデータには一切触りません。
-- ここが従来のデータベースと最も違う点です。
--
-- 何を実行するか
--   視聴区間を 10 秒単位に分解してから、局別・1 時間帯別の視聴受信機数を数えます。
--   105 万行の視聴区間が約 7,200 万行に膨らみ、そこから重複しない受信機を
--   数えるので、それなりに計算量のあるクエリです。
--   （第 2 章の dbt では、同じ考え方で 1 分単位に分解します）
--
-- 手順
--   1-1 を XSMALL で実行して、右下に出る実行時間を書き留めます
--   1-2 でウェアハウスを LARGE にします
--   1-3 で同じクエリを実行して、時間を比べます

-- 1-1 まず XSMALL のまま実行します
ALTER WAREHOUSE BCAST_HANDSON_WH SET WAREHOUSE_SIZE = 'XSMALL';

-- サイズ差だけを比べるため、この節では結果キャッシュを一時的に使いません。
-- これがないと、LARGE のクエリが前回結果を返し、正しい比較になりません。
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- このクエリがしていること
--
--   元の視聴ログ
--     C000123 / NW01 / 20:00 から 20:12 まで視聴
--
--             10 秒単位に展開
--                    ↓
--     C000123 / NW01 / 20:00
--     C000123 / NW01 / 20:00:10
--     C000123 / NW01 / 20:00:20
--                  ...
--     C000123 / NW01 / 20:11:50
--
--             局と 1 時間ごとに集計
--                    ↓
--     NW01 / 20:00 台 / 視聴受信機数 8,123 台
--
-- 最終的には、視聴受信機数が多い「局 × 1 時間」の上位 20 件を表示します。
-- この結果自体を後段で使うのではなく、同じ計算を XSMALL と LARGE で実行し、
-- ウェアハウスの大きさによる処理時間の違いを体験するためのクエリです。

WITH logs AS (
  -- 5 局に分かれている視聴ログを、1 つの縦長のデータにまとめます。
  -- UNION ALL は重複を消さずに全行をそのまま連結します。
  SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW01
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW02
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW03
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW04
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW05
),
interval_numbers AS (
  -- 視聴区間を10秒単位へ展開するため、8,641個の連番を用意します。
  -- 24時間の正常行では、このうち0から8,639までを使います。
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS INTERVAL_OFFSET
  FROM TABLE(GENERATOR(ROWCOUNT => 8641))
)
SELECT
  l.NETWORK_ID                                                    AS "局",
  -- 10秒単位に展開した時刻を、20:00、21:00のような1時間単位にまとめます。
  DATE_TRUNC('hour', DATEADD('second', n.INTERVAL_OFFSET * 10, l.VIEW_FROM)) AS "時間帯",
  -- 同じ受信機を何分見ていても、この局・時間帯では1台として数えます。
  COUNT(DISTINCT l.COMMON_ID)                                     AS "視聴受信機数"
FROM logs l
INNER JOIN interval_numbers n
  -- 12分間の視聴なら、0から71までの72個の番号と結合して72行に展開します。
  ON n.INTERVAL_OFFSET < GREATEST(1, CEIL(DATEDIFF('second', l.VIEW_FROM, l.VIEW_TO) / 10.0))
-- 終了が開始以前になっている異常行は、この比較用集計から除外します。
WHERE l.VIEW_TO > l.VIEW_FROM
  AND DATEDIFF('second', l.VIEW_FROM, l.VIEW_TO) <= 86400
GROUP BY 1, 2
-- 視聴受信機数が多い時間帯から並べ、結果を見やすい20件に絞ります。
ORDER BY "視聴受信機数" DESC
LIMIT 20;

-- ここで一度止まって、実行時間を書き留めてください。
-- Snowsight では結果の右上あたりに「Duration」として出ます。


-- 1-2 ウェアハウスを大きくします
-- データは動きません。機械を借り替えるだけなので、この文は 1 秒もかかりません。
ALTER WAREHOUSE BCAST_HANDSON_WH SET WAREHOUSE_SIZE = 'LARGE';

-- XSMALL から LARGE は 4 段階上がります。1 段上がるごとに計算資源が 2 倍、
-- つまり 16 倍です。1 時間あたりの料金も 16 倍になります。
-- 速くなった分だけ短時間で終わるので、「大きくすると必ず高くなる」わけでは
-- ありません。同じ仕事を 16 分の 1 の時間で終えられるなら、料金は同じです。
-- 実際には 16 倍ぴったりには速くならないので、そこを見てもらうのがこの節です。

SHOW WAREHOUSES LIKE 'BCAST_HANDSON_WH';


-- 1-3 まったく同じクエリを、LARGE で実行します
WITH logs AS (
  SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW01
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW02
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW03
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW04
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW05
),
interval_numbers AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS INTERVAL_OFFSET
  FROM TABLE(GENERATOR(ROWCOUNT => 8641))
)
SELECT
  l.NETWORK_ID                                                    AS "局",
  DATE_TRUNC('hour', DATEADD('second', n.INTERVAL_OFFSET * 10, l.VIEW_FROM)) AS "時間帯",
  COUNT(DISTINCT l.COMMON_ID)                                     AS "視聴受信機数"
FROM logs l
INNER JOIN interval_numbers n
  ON n.INTERVAL_OFFSET < GREATEST(1, CEIL(DATEDIFF('second', l.VIEW_FROM, l.VIEW_TO) / 10.0))
WHERE l.VIEW_TO > l.VIEW_FROM
  AND DATEDIFF('second', l.VIEW_FROM, l.VIEW_TO) <= 86400
GROUP BY 1, 2
ORDER BY "視聴受信機数" DESC
LIMIT 20;

-- 押さえておきたいこと
--   サイズを変えるのに、データの移動も、索引の作り直しも、停止時間も
--   ありません。重い集計を流す間だけ大きくして、終わったら戻す、という
--   使い方ができます。第 2 章の dbt も、この考え方で 8 並列で流しています。


-- =============================================================================
-- 2. 結果キャッシュ
-- =============================================================================
-- ここから結果キャッシュを使う設定に戻します。
ALTER SESSION SET USE_CACHED_RESULT = TRUE;

-- 2-1 まず1回実行し、再利用できる結果を作ります。
-- 設定をTRUEにしただけでは、まだこのクエリの結果は作られていません。
WITH logs AS (
  SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW01
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW02
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW03
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW04
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW05
),
interval_numbers AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS INTERVAL_OFFSET
  FROM TABLE(GENERATOR(ROWCOUNT => 8641))
)
SELECT
  l.NETWORK_ID                                                    AS "局",
  DATE_TRUNC('hour', DATEADD('second', n.INTERVAL_OFFSET * 10, l.VIEW_FROM)) AS "時間帯",
  COUNT(DISTINCT l.COMMON_ID)                                     AS "視聴受信機数"
FROM logs l
INNER JOIN interval_numbers n
  ON n.INTERVAL_OFFSET < GREATEST(1, CEIL(DATEDIFF('second', l.VIEW_FROM, l.VIEW_TO) / 10.0))
WHERE l.VIEW_TO > l.VIEW_FROM
  AND DATEDIFF('second', l.VIEW_FROM, l.VIEW_TO) <= 86400
GROUP BY 1, 2
ORDER BY "視聴受信機数" DESC
LIMIT 20;

-- 2-2 上のWITHからLIMITまでを、もう1回そのまま実行します。
-- 2回目は保存された結果を再利用するため、ほぼ0秒で返ります。
WITH logs AS (
  SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW01
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW02
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW03
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW04
  UNION ALL SELECT NETWORK_ID, COMMON_ID, VIEW_FROM, VIEW_TO FROM VIEWING_LOG_NW05
),
interval_numbers AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS INTERVAL_OFFSET
  FROM TABLE(GENERATOR(ROWCOUNT => 8641))
)
SELECT
  l.NETWORK_ID                                                    AS "局",
  DATE_TRUNC('hour', DATEADD('second', n.INTERVAL_OFFSET * 10, l.VIEW_FROM)) AS "時間帯",
  COUNT(DISTINCT l.COMMON_ID)                                     AS "視聴受信機数"
FROM logs l
INNER JOIN interval_numbers n
  ON n.INTERVAL_OFFSET < GREATEST(1, CEIL(DATEDIFF('second', l.VIEW_FROM, l.VIEW_TO) / 10.0))
WHERE l.VIEW_TO > l.VIEW_FROM
  AND DATEDIFF('second', l.VIEW_FROM, l.VIEW_TO) <= 86400
GROUP BY 1, 2
ORDER BY "視聴受信機数" DESC
LIMIT 20;

-- 2-2はほぼ0秒で返ります。ウェアハウスは計算していません。
--
-- なぜそうなるのか
--   同じクエリで、参照しているテーブルが 1 行も変わっていない場合、
--   Snowflake は前回の結果をそのまま返します。24 時間保持され、
--   使われるたびに保持期間が延びます。
--
-- どこに効くのか
--   結果キャッシュはアカウント全体で共有されます。ウェアハウスをまたぎ、
--   ユーザーをまたいで効きます。第 5 章で作るアプリのように、同じ集計を
--   多くの人が見る画面では、これがそのまま効きます。
--
-- 注意
--   元のテーブルが 1 行でも変わると無効になります。データが毎日入ってくる
--   仕組みでは、更新直後は効きません。

-- 実験が終わったので、ウェアハウスを元の大きさに戻します。
-- 戻し忘れると、以降のすべてのクエリが 16 倍の料金で動きます。
ALTER WAREHOUSE BCAST_HANDSON_WH SET WAREHOUSE_SIZE = 'XSMALL';


-- =============================================================================
-- 3. 消してしまったテーブルを元に戻す（UNDROP）
-- =============================================================================
-- ここからは事故の話です。
--
-- 状況設定
--   視聴ログの第一放送ネットワーク分を、うっかり削除してしまいました。
--   本来なら、バックアップを探して、復元を依頼して、待つことになります。

-- 3-1 まず、いま何行あるかを覚えておきます
SELECT COUNT(*) AS "削除前の行数" FROM VIEWING_LOG_NW01;

-- 3-2 消します
DROP TABLE VIEWING_LOG_NW01;

-- 3-3 本当に無くなったことを確認します。結果が 0 行なら消えています。
--     DESCRIBE TABLE を使うと意図どおりエラーになりますが、ファイル全体を
--     実行した場合はそこで停止するため、エラーを出さない SHOW を使います。
SHOW TABLES LIKE 'VIEWING_LOG_NW01' IN SCHEMA BCAST_VIEWING_HANDSON.RAW;

-- 3-4 元に戻します
UNDROP TABLE VIEWING_LOG_NW01;

-- 3-5 行数が 3-1 と同じことを確認します
SELECT COUNT(*) AS "復元後の行数" FROM VIEWING_LOG_NW01;

-- 押さえておきたいこと
--   バックアップから戻したのではありません。Snowflake は変更のたびに
--   古い状態を保持しているため、消した直後のテーブルはまだ内部に残っています。
--   このアカウントの保持期間は 1 日です。Enterprise 以上では最大 90 日まで
--   設定できます。DATABASE や SCHEMA も同じように UNDROP できます。


-- =============================================================================
-- 4. 消していないが、中身を壊してしまった場合（Time Travel）
-- =============================================================================
-- UNDROP は「消した」ときの話です。実務でより多いのは、
-- WHERE を書き忘れた UPDATE や DELETE で、消してはいないが中身が変わった、
-- という事故です。この場合は過去の時点を読みに行きます。

-- 4-1 事故を起こします。WHERE を付け忘れた想定で、全行消します。
DELETE FROM VIEWING_LOG_NW01;

-- 事故を起こした DELETE のクエリ ID を保存します。
-- この ID を使えば、経過時間に関係なく事故の直前を指定できます。
SET destructive_query_id = (SELECT LAST_QUERY_ID());

SELECT COUNT(*) AS "事故後の行数" FROM VIEWING_LOG_NW01;

-- 4-2 DELETE の直前の状態を読みます。
SELECT COUNT(*) AS "事故直前の行数"
FROM VIEWING_LOG_NW01 BEFORE(STATEMENT => $destructive_query_id);

-- 4-3 DELETE の直前の状態で書き戻します
INSERT INTO VIEWING_LOG_NW01
SELECT * FROM VIEWING_LOG_NW01 BEFORE(STATEMENT => $destructive_query_id);

SELECT COUNT(*) AS "復旧後の行数" FROM VIEWING_LOG_NW01;

-- 押さえておきたいこと
--   今回は「あのクエリの直前」を指す BEFORE(STATEMENT => 'クエリID') を
--   使っています。経過時間に依存しないため、作成直後のテーブルでも安全です。
--   ほかに、秒数で指定する AT(OFFSET => ...) や、時刻で指定する
--   AT(TIMESTAMP => ...) も使えます。
--   壊した本人が、他の人に頼まず、SELECT 文の書き方だけで復旧できます。


-- =============================================================================
-- 5. コピーせずに複製する（ゼロコピークローン）
-- =============================================================================
-- 状況設定
--   第 2 章から変換処理を書き始めます。本番のデータを触りながら試すのは
--   避けたいので、検証用の複製が欲しい、という場面です。

-- 5-1 複製します
CREATE OR REPLACE TABLE VIEWING_LOG_NW01_DEV CLONE VIEWING_LOG_NW01;

-- 5-2 行数が同じことを確認します
SELECT
  (SELECT COUNT(*) FROM VIEWING_LOG_NW01)     AS "本番",
  (SELECT COUNT(*) FROM VIEWING_LOG_NW01_DEV) AS "複製";

-- 5-3 複製の側だけを書き換えます
-- NW01の本来のCHANNEL_CODEは、地上波のチャンネルコードを表す「041」です。
-- 「999」は実在のチャンネルではなく、複製だけを変えたことが分かるようにするテスト値です。
UPDATE VIEWING_LOG_NW01_DEV SET CHANNEL_CODE = '999';

-- 5-4 本番が変わっていないことを確認します
-- 結果が「本番=041 / 複製=999」なら、複製へのUPDATEが本番に影響していません。
-- MINを使うのは、全行が同じチャンネルコードなので代表値を1つ表示するためです。
SELECT
  (SELECT MIN(CHANNEL_CODE) FROM VIEWING_LOG_NW01)     AS "本番のチャンネル値",
  (SELECT MIN(CHANNEL_CODE) FROM VIEWING_LOG_NW01_DEV) AS "複製のチャンネル値";

-- 押さえておきたいこと
--   5-1 は一瞬で終わります。行をコピーしていないためです。作られたのは
--   「同じデータを指す新しい名前」で、追加のストレージはゼロです。
--   書き換えた部分だけが、あとから実データとして増えていきます。
--
--   DATABASE 単位でもクローンできます。本番データベースをそのまま複製して
--   検証環境にする、という使い方が現実的にできます。
--   容量が 2 倍にならないので、遠慮なく作れます。

-- 検証用の複製は片付けます
DROP TABLE VIEWING_LOG_NW01_DEV;


-- =============================================================================
-- 6. （補足）60 秒ごとの信号を from-to の 1 行に畳む
-- =============================================================================
-- この章の 1 では、from-to の 1 行を 10 秒ごとの行に「展開」しました。
-- ここでは逆向きに、受信機が送ってくる細かい信号を from-to に「畳む」処理を、
-- 1 台分の小さなサンプルで試します。RAW のテーブルには触りません。
--
-- 受信機は視聴中、60 秒ごとに「いま NW01 を見ている」という信号を送ります。
-- 局側ではこれを次の 2 つのルールで 1 つの区間にまとめてから基盤へ渡します。
--
--   ルール 1  チャンネルが変わったら、新しい区間
--   ルール 2  前の信号から 60 秒より空いたら（TV を消した）、新しい区間
--
--   📡 60 秒ごとの信号（7 行）          📦 畳んだあと（3 行）
--   20:00 NW01                          NW01  20:00 → 20:03
--   20:01 NW01                          NW02  20:03 → 20:05
--   20:02 NW01                          NW01  20:10 → 20:12
--   20:03 NW02   ← ルール 1
--   20:04 NW02
--   20:10 NW01   ← ルール 2（5 分空いた）
--   20:11 NW01
--
-- 情報は何も減っていません。行数だけが小さくなります。
-- 第 1a 章で読み込んだ視聴ログは、この畳んだあとの形です。

-- 6-1 サンプルの信号を作ります（受信機 1 台、20:00 から 20:12 までの一部）
WITH signals AS (
  SELECT COLUMN1::TIMESTAMP_NTZ AS SIGNAL_AT, COLUMN2 AS NETWORK_ID
  FROM VALUES
    ('2026-07-05 20:00:00', 'NW01'),
    ('2026-07-05 20:01:00', 'NW01'),
    ('2026-07-05 20:02:00', 'NW01'),
    ('2026-07-05 20:03:00', 'NW02'),
    ('2026-07-05 20:04:00', 'NW02'),
    ('2026-07-05 20:10:00', 'NW01'),
    ('2026-07-05 20:11:00', 'NW01')
),

-- 6-2 1 つ前の信号と比べて、「区間の始まり」かどうかを判定します
flagged AS (
  SELECT
    SIGNAL_AT,
    NETWORK_ID,
    CASE
      WHEN LAG(NETWORK_ID) OVER (ORDER BY SIGNAL_AT) IS DISTINCT FROM NETWORK_ID THEN 1  -- ルール 1
      WHEN DATEDIFF('second', LAG(SIGNAL_AT) OVER (ORDER BY SIGNAL_AT), SIGNAL_AT) > 60 THEN 1  -- ルール 2
      ELSE 0
    END AS IS_NEW_INTERVAL
  FROM signals
),

-- 6-3 「始まり」の数を累計して、区間ごとの番号を振ります
numbered AS (
  SELECT
    SIGNAL_AT,
    NETWORK_ID,
    SUM(IS_NEW_INTERVAL) OVER (ORDER BY SIGNAL_AT ROWS UNBOUNDED PRECEDING) AS INTERVAL_NO
  FROM flagged
)

-- 6-4 区間番号ごとにまとめて、from-to の 1 行にします
-- VIEW_TO は最後の信号の 60 秒後です（最後の信号のあとも 60 秒は見ていたとみなす）
SELECT
  INTERVAL_NO                                   AS "区間",
  NETWORK_ID                                    AS "局",
  MIN(SIGNAL_AT)                                AS "VIEW_FROM",
  DATEADD('second', 60, MAX(SIGNAL_AT))         AS "VIEW_TO",
  COUNT(*)                                      AS "元の信号の行数"
FROM numbered
GROUP BY INTERVAL_NO, NETWORK_ID
ORDER BY INTERVAL_NO;

-- 押さえておきたいこと
--   7 行が 3 行になりました。1 のクエリと合わせると、
--
--     60 秒ごとの信号  ──畳む──▶  from-to  ──展開──▶  10 秒 / 1 分ごとの行
--
--   という両方向を手で確かめたことになります。どの形でも中身の情報は同じで、
--   変わるのは行数、つまり保存量と計算量だけです。
--   ふだんは行数の少ない from-to のまま持ち、時間軸を細かく刻む指標が
--   必要なときだけ展開する、という使い分けを第 2 章で見ていきます。


-- =============================================================================
-- この章のまとめ
-- =============================================================================
--   ウェアハウス      計算する機械。データと分かれているので、大きさを
--                     いつでも変えられる。止める必要がない。
--   結果キャッシュ    同じクエリはウェアハウスを動かさずに返る。
--                     アカウント全体で共有される。
--   UNDROP            消したテーブルを 1 行で戻せる。
--   Time Travel       消していないが壊した場合も、過去の時点を読める。
--   クローン           大きなテーブルを一瞬で、容量を増やさず複製できる。
--   （補足）畳む       60 秒ごとの信号は from-to に畳んで小さく持てる。
--                     展開と畳みのどちらでも情報は変わらない。
--
-- これらはすべて、設定も準備もなく最初から効いています。
-- 次の第 2 章から、この土台の上に放送視聴データの変換を作っていきます。
-- =============================================================================
