-- =============================================================================
-- 第 6 章  アクセス権とマスキング
-- =============================================================================
-- 実行するロール: ACCOUNTADMIN と BCAST_ANALYST を切り替えます
-- 所要時間の目安: 15 分
--
-- このスクリプトでやること
--   1. 層でアクセス権を分ける（生データは限られた人、集計は広く）
--   2. IP アドレスに伏せ字をかける
--   3. （任意）局ごとに見える行を分ける
--
-- 5 つの局からデータを集める仕組みでは、誰が何を見られるかが
-- 技術の話より先に決まっていることがあります。ここで確認するのは
-- 「決めたことを Snowflake でどう表すか」です。
-- =============================================================================

-- =============================================================================
-- 1. 層でアクセス権を分ける
-- =============================================================================
-- 第 1 章で 2 つのロールを作り、次のように権限を渡してありました。
--
--   BCAST_ENGINEER   RAW / STG / INT / MART すべて
--   BCAST_ANALYST    MART だけ
--
-- 実際にどうなるかを見ます。
--
-- ここで 1 つ大事な前置きがあります。
-- Snowflake のユーザーには「副ロール」という設定があり、既定では
-- 使えるロールすべてが副ロールとして有効になっています。この状態だと
-- USE ROLE でロールを切り替えても、元のロールの権限がセッションに残ります。
-- つまり ACCOUNTADMIN を持っている人が BCAST_ANALYST に切り替えても、
-- 生データが見えたままになります。
--
-- 権限の効き方を確かめるときは、副ロールを切っておく必要があります。
-- 自分の設定は次で確認できます。

USE ROLE ACCOUNTADMIN;
SET my_user = (SELECT CURRENT_USER());
SELECT $my_user AS "変数の中身";
SHOW USERS;
SELECT "name" AS "ユーザー", "default_secondary_roles" AS "既定の副ロール"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = $my_user;
-- ["ALL"] と表示されたら、すべてのロールが副ロールとして有効です。

USE ROLE BCAST_ANALYST;
USE SECONDARY ROLES NONE;   -- これを入れないと、下の確認が意図どおりに動きません
USE WAREHOUSE BCAST_HANDSON_WH;

-- いま何のロールで動いているかを確認する
SELECT CURRENT_ROLE() AS "主ロール", CURRENT_SECONDARY_ROLES() AS "副ロール";

-- 集計データは見られる
SELECT COUNT(*) AS "行数" FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY;

-- 生データは見られない。次はエラーになります。
-- 「存在しないか権限がありません」という書き方になるので、
-- 権限がないことと存在しないことが区別されません。これは意図的な仕様です。
-- 見えてはいけないものについては、あるかないかも分からないほうが安全なためです。
SELECT COUNT(*) FROM BCAST_VIEWING_HANDSON.RAW.VIEWING_LOG_NW01;

-- 中間層も見られない
SELECT COUNT(*) FROM BCAST_VIEWING_HANDSON.STG.STG_VIEWING_LOG;

-- ただし、セマンティックビューは参照できます。
-- 元になっているテーブルへの権限がなくても、セマンティックビューへの
-- 権限だけで指標が見られます。
SELECT * FROM SEMANTIC_VIEW(
  BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  METRICS device_daily.reach_devices
  DIMENSIONS device_daily.network_name
)
ORDER BY 1;

-- =============================================================================
-- 2. IP アドレスに伏せ字をかける
-- =============================================================================
-- IP アドレスは外部のデータと突き合わせるための鍵になる一方で、
-- そのまま外に出すべきものではありません。
--
-- 列ごとに「誰が見たら何が見えるか」を決めるのがマスキングポリシーです。
-- 1 つ作って、列に当てるだけで効きます。

USE ROLE ACCOUNTADMIN;
USE SCHEMA BCAST_VIEWING_HANDSON.MART;

CREATE OR REPLACE MASKING POLICY MASK_IP_ADDRESS AS (VAL VARCHAR)
  RETURNS VARCHAR ->
    CASE
      -- 生データまで扱えるロールには、そのまま見せる
      WHEN IS_ROLE_IN_SESSION('BCAST_ENGINEER') THEN VAL
      -- それ以外には最後の区切りを隠す。地域の傾向は見えるが、
      -- 回線を特定することはできなくなる
      ELSE REGEXP_REPLACE(VAL, '\\.[0-9]+$', '.*')
    END
  COMMENT = 'IP アドレスの末尾を隠す。生データを扱えるロールにはそのまま見せる';

-- 列に当てる
ALTER TABLE BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY
  MODIFY COLUMN IP_ADDRESS SET MASKING POLICY MASK_IP_ADDRESS;

ALTER TABLE BCAST_VIEWING_HANDSON.MART.MART_PROGRAM_VIEWING
  MODIFY COLUMN IP_ADDRESS SET MASKING POLICY MASK_IP_ADDRESS;

-- -----------------------------------------------------------------------------
-- 効き方を見る
-- -----------------------------------------------------------------------------

-- 生データまで扱えるロール。そのまま見えます。
USE ROLE BCAST_ENGINEER;
USE SECONDARY ROLES NONE;
SELECT IP_ADDRESS, COUNT(*) AS "行数"
FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY
GROUP BY IP_ADDRESS
ORDER BY 2 DESC
LIMIT 5;

-- 集計だけのロール。末尾が隠れます。
USE ROLE BCAST_ANALYST;
USE SECONDARY ROLES NONE;
SELECT IP_ADDRESS, COUNT(*) AS "行数"
FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY
GROUP BY IP_ADDRESS
ORDER BY 2 DESC
LIMIT 5;

-- 集計そのものは変わりません。世帯数を数える処理は、
-- 伏せ字がかかっていても同じ値を返します。
SELECT COUNT(DISTINCT COMMON_ID) AS "台数"
FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY;

-- -----------------------------------------------------------------------------
-- どこに当たっているかを確認する
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES ALL;   -- 副ロールを元に戻す

SELECT
  POLICY_NAME    AS "ポリシー",
  REF_DATABASE_NAME || '.' || REF_SCHEMA_NAME || '.' || REF_ENTITY_NAME AS "対象",
  REF_COLUMN_NAME AS "列"
FROM TABLE(
  BCAST_VIEWING_HANDSON.INFORMATION_SCHEMA.POLICY_REFERENCES(
    POLICY_NAME => 'BCAST_VIEWING_HANDSON.MART.MASK_IP_ADDRESS'
  )
);

-- =============================================================================
-- 3. （任意）局ごとに見える行を分ける
-- =============================================================================
-- 各局には自局のデータだけを見せたい、という要件が出てくることがあります。
-- 行ごとに見える見えないを決めるのが行アクセスポリシーです。
--
-- 時間に余裕があるときだけ実行してください。以下はコメントを外すと動きます。

/*
USE ROLE ACCOUNTADMIN;
USE SCHEMA BCAST_VIEWING_HANDSON.MART;

-- 局ごとの担当ロールを作る
CREATE ROLE IF NOT EXISTS BCAST_NW01_VIEWER
  COMMENT = '第一放送ネットワークの担当者。自局の行だけが見える';
GRANT USAGE ON WAREHOUSE BCAST_HANDSON_WH TO ROLE BCAST_NW01_VIEWER;
GRANT USAGE ON DATABASE BCAST_VIEWING_HANDSON TO ROLE BCAST_NW01_VIEWER;
GRANT USAGE ON SCHEMA BCAST_VIEWING_HANDSON.MART TO ROLE BCAST_NW01_VIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA BCAST_VIEWING_HANDSON.MART TO ROLE BCAST_NW01_VIEWER;

SET current_user_name = (SELECT CURRENT_USER());
SELECT $current_user_name AS "変数の中身";
GRANT ROLE BCAST_NW01_VIEWER TO USER IDENTIFIER($current_user_name);

-- どのロールがどの局を見られるかの対応表
CREATE OR REPLACE TABLE NETWORK_ACCESS_MAP (
  ROLE_NAME  VARCHAR(40),
  NETWORK_ID VARCHAR(4)
) COMMENT = '局ごとの担当ロールの対応表';

INSERT INTO NETWORK_ACCESS_MAP VALUES ('BCAST_NW01_VIEWER', 'NW01');

-- 行アクセスポリシー
CREATE OR REPLACE ROW ACCESS POLICY RAP_NETWORK AS (NETWORK_ID VARCHAR)
  RETURNS BOOLEAN ->
    -- 生データまで扱えるロールと、集計を広く見るロールは全局を見られる
    IS_ROLE_IN_SESSION('BCAST_ENGINEER')
    OR IS_ROLE_IN_SESSION('BCAST_ANALYST')
    -- 局ごとの担当ロールは、対応表にある局の行だけ
    OR EXISTS (
      SELECT 1 FROM NETWORK_ACCESS_MAP m
      WHERE m.NETWORK_ID = NETWORK_ID
        AND IS_ROLE_IN_SESSION(m.ROLE_NAME)
    )
  COMMENT = '局ごとの担当ロールには自局の行だけを見せる';

ALTER TABLE MART_DEVICE_DAILY ADD ROW ACCESS POLICY RAP_NETWORK ON (NETWORK_ID);

-- 効き方を見る。全局が見えます。
USE ROLE BCAST_ANALYST;
SELECT NETWORK_NAME, COUNT(DISTINCT COMMON_ID) AS "台数"
FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY
GROUP BY NETWORK_NAME ORDER BY 1;

-- 第一放送ネットワークの担当ロール。1 局分だけになります。
USE ROLE BCAST_NW01_VIEWER;
SELECT NETWORK_NAME, COUNT(DISTINCT COMMON_ID) AS "台数"
FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY
GROUP BY NETWORK_NAME ORDER BY 1;
*/

-- =============================================================================
-- 覚えておきたいこと
-- =============================================================================
-- マスキングポリシーと行アクセスポリシーは列やテーブルに紐づいています。
-- dbt でテーブルを作り直すと外れます。ふだんの dbt run では
-- テーブルの中身を入れ替えるだけなので残りますが、
-- dbt run --full-refresh のようにテーブルそのものを作り直すと外れます。
--
-- 実運用では、モデルを作り直したあとにポリシーを当て直す処理を
-- パイプラインの最後に入れておきます。dbt の post-hook に書くのが
-- ひとつの方法です。
--
-- もう 1 つは副ロールです。既定では使えるロールすべてが副ロールとして
-- 有効になっているため、USE ROLE で切り替えても前の権限が残ります。
-- 権限の効き方を確かめるときは USE SECONDARY ROLES NONE を入れてください。
-- これを忘れると「ポリシーを当てたのに効いていない」と見えますが、
-- 実際には副ロールの権限で見えているだけということがよくあります。

-- =============================================================================
-- ハンズオンはここまでです。後片付けは sql/cleanup.sql を実行してください。
-- =============================================================================
