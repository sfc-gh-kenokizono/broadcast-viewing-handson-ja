-- =============================================================================
-- 第 1 章  セットアップとデータの取り込み
-- =============================================================================
-- 実行するロール: ACCOUNTADMIN
-- 所要時間の目安: 15 分
--
-- このスクリプトでやること
--   1. ロールを 2 つ作る（生データまで見られる人と、集計データだけ見られる人）
--   2. データベース、ウェアハウス、4 つのスキーマを作る
--   3. GitHub リポジトリに接続する
--   4. リポジトリの CSV を RAW スキーマに読み込む
--
-- 事前に決めておくこと
--   GitHub のユーザー名と個人アクセストークン（リポジトリの読み取り権限）
--   下の <> の 3 か所を書き換えてから実行してください。
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- =============================================================================
-- 1. ロールを作る
-- =============================================================================
-- 生データを含む層は限られた人だけが見られるようにし、集計済みの層は
-- 広く使えるようにする、という 2 段構えにします。第 6 章でこの差を確認します。

CREATE ROLE IF NOT EXISTS BCAST_ENGINEER
  COMMENT = '生データから集計までを扱う。dbt の実行もこのロール';
CREATE ROLE IF NOT EXISTS BCAST_ANALYST
  COMMENT = '集計済みの層だけを参照する';

-- 自分自身に両方のロールを付与する（ロールを切り替えて挙動の違いを見るため）
SET current_user_name = (SELECT CURRENT_USER());
GRANT ROLE BCAST_ENGINEER TO USER IDENTIFIER($current_user_name);
GRANT ROLE BCAST_ANALYST  TO USER IDENTIFIER($current_user_name);

-- Cortex の機能を使うための権限
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE BCAST_ENGINEER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE BCAST_ANALYST;

-- =============================================================================
-- 2. データベース、ウェアハウス、スキーマを作る
-- =============================================================================

CREATE WAREHOUSE IF NOT EXISTS BCAST_HANDSON_WH
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = '放送視聴データハンズオン用';

CREATE DATABASE IF NOT EXISTS BCAST_VIEWING_HANDSON;

CREATE SCHEMA IF NOT EXISTS BCAST_VIEWING_HANDSON.RAW
  COMMENT = '受け取ったままの原本。加工しない';
CREATE SCHEMA IF NOT EXISTS BCAST_VIEWING_HANDSON.STG
  COMMENT = 'クレンジング済み';
CREATE SCHEMA IF NOT EXISTS BCAST_VIEWING_HANDSON.INT
  COMMENT = '中間処理。ID の名寄せ、番組枠との結合、1 分単位への分解';
CREATE SCHEMA IF NOT EXISTS BCAST_VIEWING_HANDSON.MART
  COMMENT = '提供用。指標の算出';
CREATE SCHEMA IF NOT EXISTS BCAST_VIEWING_HANDSON.INTEGRATIONS
  COMMENT = 'GitHub 接続に必要なオブジェクト';

-- dbt の実行ログを残せるようにする（第 2 章の任意項目で使います）
ALTER SCHEMA BCAST_VIEWING_HANDSON.STG  SET LOG_LEVEL = 'INFO';
ALTER SCHEMA BCAST_VIEWING_HANDSON.STG  SET TRACE_LEVEL = 'ALWAYS';
ALTER SCHEMA BCAST_VIEWING_HANDSON.INT  SET LOG_LEVEL = 'INFO';
ALTER SCHEMA BCAST_VIEWING_HANDSON.INT  SET TRACE_LEVEL = 'ALWAYS';
ALTER SCHEMA BCAST_VIEWING_HANDSON.MART SET LOG_LEVEL = 'INFO';
ALTER SCHEMA BCAST_VIEWING_HANDSON.MART SET TRACE_LEVEL = 'ALWAYS';

-- -----------------------------------------------------------------------------
-- 権限の付与
-- -----------------------------------------------------------------------------
GRANT USAGE ON WAREHOUSE BCAST_HANDSON_WH TO ROLE BCAST_ENGINEER;
GRANT USAGE ON WAREHOUSE BCAST_HANDSON_WH TO ROLE BCAST_ANALYST;

GRANT USAGE ON DATABASE BCAST_VIEWING_HANDSON TO ROLE BCAST_ENGINEER;
GRANT USAGE ON DATABASE BCAST_VIEWING_HANDSON TO ROLE BCAST_ANALYST;

-- エンジニアは 4 つの層すべてを扱える
GRANT ALL ON SCHEMA BCAST_VIEWING_HANDSON.RAW  TO ROLE BCAST_ENGINEER;
GRANT ALL ON SCHEMA BCAST_VIEWING_HANDSON.STG  TO ROLE BCAST_ENGINEER;
GRANT ALL ON SCHEMA BCAST_VIEWING_HANDSON.INT  TO ROLE BCAST_ENGINEER;
GRANT ALL ON SCHEMA BCAST_VIEWING_HANDSON.MART TO ROLE BCAST_ENGINEER;
GRANT SELECT ON ALL TABLES IN SCHEMA BCAST_VIEWING_HANDSON.RAW TO ROLE BCAST_ENGINEER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA BCAST_VIEWING_HANDSON.RAW TO ROLE BCAST_ENGINEER;

-- アナリストは集計済みの層だけ。RAW / STG / INT には触れられない
GRANT USAGE ON SCHEMA BCAST_VIEWING_HANDSON.MART TO ROLE BCAST_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA BCAST_VIEWING_HANDSON.MART TO ROLE BCAST_ANALYST;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA BCAST_VIEWING_HANDSON.MART TO ROLE BCAST_ANALYST;

-- =============================================================================
-- 3. GitHub リポジトリに接続する
-- =============================================================================
-- 非公開リポジトリなので、認証情報をシークレットとして登録し、
-- API 統合からそのシークレットを使えるようにします。
-- シークレットに入れた値は SQL から取り出すことはできません。

USE SCHEMA BCAST_VIEWING_HANDSON.INTEGRATIONS;

CREATE OR REPLACE SECRET BCAST_GIT_SECRET
  TYPE = password
  USERNAME = '<GitHub のユーザー名>'
  PASSWORD = '<GitHub の個人アクセストークン>';

CREATE OR REPLACE API INTEGRATION BCAST_GIT_API
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/<GitHub のユーザー名または組織名>')
  ALLOWED_AUTHENTICATION_SECRETS = (BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_GIT_SECRET)
  ENABLED = TRUE;

GRANT USAGE ON INTEGRATION BCAST_GIT_API TO ROLE BCAST_ENGINEER;
GRANT USAGE ON SCHEMA BCAST_VIEWING_HANDSON.INTEGRATIONS TO ROLE BCAST_ENGINEER;
GRANT READ ON SECRET BCAST_GIT_SECRET TO ROLE BCAST_ENGINEER;

CREATE OR REPLACE GIT REPOSITORY BCAST_REPO
  API_INTEGRATION = BCAST_GIT_API
  GIT_CREDENTIALS = BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_GIT_SECRET
  ORIGIN = 'https://github.com/<GitHub のユーザー名または組織名>/broadcast-viewing-handson-ja.git';

GRANT READ ON GIT REPOSITORY BCAST_REPO TO ROLE BCAST_ENGINEER;

-- リポジトリの最新の内容を取り込む
ALTER GIT REPOSITORY BCAST_REPO FETCH;

-- 中身が見えることを確認する。CSV が並んでいれば接続できています。
LS @BCAST_REPO/branches/main/data/;

-- =============================================================================
-- 4. RAW スキーマにテーブルを作る
-- =============================================================================

USE WAREHOUSE BCAST_HANDSON_WH;
USE SCHEMA BCAST_VIEWING_HANDSON.RAW;

CREATE OR REPLACE FILE FORMAT CSV_UTF8
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  ENCODING = 'UTF8'
  COMPRESSION = GZIP
  NULL_IF = ('', 'NULL')
  EMPTY_FIELD_AS_NULL = TRUE
  COMMENT = '日本語を含む CSV を読むための設定';

-- -----------------------------------------------------------------------------
-- 各局から届く非特定視聴データ
-- 1 行が 1 視聴区間（VIEW_FROM から VIEW_TO まで）です。
-- 局ごとに別のテーブルとして受け取ります。局をまたいで一致する値は
-- COMMON_ID と IP_ADDRESS だけで、STATION_DEVICE_ID は局ごとに異なります。
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE VIEWING_LOG_NW01 (
  NETWORK_ID         VARCHAR(4)    COMMENT '放送ネットワークの ID',
  STATION_DEVICE_ID  VARCHAR(24)   COMMENT 'デバイス ID（各局 ID）。局をまたいで一致しない',
  COMMON_ID          VARCHAR(12)   COMMENT '共通 ID。5 局横断の非特定リンクキー',
  IP_ADDRESS         VARCHAR(15)   COMMENT 'IP アドレス。世帯（回線）の粒度',
  POSTAL_CODE        VARCHAR(8)    COMMENT '郵便番号',
  CHANNEL_CODE       VARCHAR(3)    COMMENT '視聴チャンネル',
  VIEW_FROM          TIMESTAMP_NTZ COMMENT '視聴の開始時刻',
  VIEW_TO            TIMESTAMP_NTZ COMMENT '視聴の終了時刻'
) COMMENT = '第一放送ネットワークから届いた非特定視聴データ';

CREATE OR REPLACE TABLE VIEWING_LOG_NW02 LIKE VIEWING_LOG_NW01;
CREATE OR REPLACE TABLE VIEWING_LOG_NW03 LIKE VIEWING_LOG_NW01;
CREATE OR REPLACE TABLE VIEWING_LOG_NW04 LIKE VIEWING_LOG_NW01;
CREATE OR REPLACE TABLE VIEWING_LOG_NW05 LIKE VIEWING_LOG_NW01;

-- -----------------------------------------------------------------------------
-- マスタ類
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE NETWORK_MASTER (
  NETWORK_ID    VARCHAR(4),
  NETWORK_NAME  VARCHAR(40),
  CHANNEL_CODE  VARCHAR(3)
) COMMENT = '局のマスタ';

CREATE OR REPLACE TABLE PROGRAM_MASTER (
  PROGRAM_ID    VARCHAR(8),
  PROGRAM_NAME  VARCHAR(60),
  NETWORK_ID    VARCHAR(4),
  GENRE         VARCHAR(20),
  TIME_SLOT     VARCHAR(20),
  DURATION_MIN  NUMBER(4,0),
  SYNOPSIS      VARCHAR(400) COMMENT '番組の概要文。第 3 章で検索サービスの対象にする'
) COMMENT = '番組のマスタ';

CREATE OR REPLACE TABLE PROGRAM_SCHEDULE (
  PROGRAM_ID  VARCHAR(8),
  NETWORK_ID  VARCHAR(4),
  AIR_DATE    DATE,
  AIR_FROM    TIMESTAMP_NTZ,
  AIR_TO      TIMESTAMP_NTZ
) COMMENT = '番組の放送枠。視聴ログには番組 ID が入っていないため、時刻の範囲で結合する';

CREATE OR REPLACE TABLE CM_MASTER (
  CM_ID          VARCHAR(8),
  ADVERTISER     VARCHAR(40),
  CATEGORY       VARCHAR(20),
  DURATION_SEC   NUMBER(4,0),
  CREATIVE_DESC  VARCHAR(400) COMMENT '素材の説明文。第 3 章で検索サービスの対象にする'
) COMMENT = 'コマーシャルのマスタ';

CREATE OR REPLACE TABLE CM_SPOT (
  SPOT_ID     VARCHAR(12),
  CM_ID       VARCHAR(8),
  NETWORK_ID  VARCHAR(4),
  AIR_AT      TIMESTAMP_NTZ
) COMMENT = 'コマーシャルが放送された時刻';

-- -----------------------------------------------------------------------------
-- 配信側のデータ
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE STREAMING_LOG (
  COMMON_ID    VARCHAR(12),
  IP_ADDRESS   VARCHAR(15),
  PROGRAM_ID   VARCHAR(8),
  DEVICE_TYPE  VARCHAR(12),
  VIEW_FROM    TIMESTAMP_NTZ,
  VIEW_TO      TIMESTAMP_NTZ
) COMMENT = '配信側の番組視聴ログ';

CREATE OR REPLACE TABLE STREAMING_AD_LOG (
  IMP_ID       VARCHAR(14),
  CM_ID        VARCHAR(8),
  COMMON_ID    VARCHAR(12),
  DEVICE_TYPE  VARCHAR(12),
  IMP_AT       TIMESTAMP_NTZ
) COMMENT = '配信側の広告表示ログ。放送側の接触と突き合わせて増分リーチを出す';

-- -----------------------------------------------------------------------------
-- パネル調査で属性が判明している端末
-- 全体の 10 パーセントだけです。残りの 90 パーセントは属性が分かりません。
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE PANEL_DEMOGRAPHICS (
  COMMON_ID           VARCHAR(12),
  GENDER_AGE_SEGMENT  VARCHAR(4) COMMENT 'T / F1 / F2 / F3 / M1 / M2 / M3',
  SURVEY_DATE         DATE
) COMMENT = 'パネル調査による属性。一部の端末にしか値がない';

-- =============================================================================
-- 5. CSV を読み込む
-- =============================================================================
-- ON_ERROR は既定の ABORT_STATEMENT のままにしています。読み込みに失敗した行を
-- 黙って捨てると、あとの集計がずれた理由が分からなくなるためです。

COPY INTO VIEWING_LOG_NW01 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/viewing_log_nw01.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO VIEWING_LOG_NW02 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/viewing_log_nw02.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO VIEWING_LOG_NW03 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/viewing_log_nw03.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO VIEWING_LOG_NW04 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/viewing_log_nw04.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO VIEWING_LOG_NW05 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/viewing_log_nw05.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);

COPY INTO NETWORK_MASTER      FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/network_master.csv.gz      FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO PROGRAM_MASTER      FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/program_master.csv.gz      FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO PROGRAM_SCHEDULE    FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/program_schedule.csv.gz    FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO CM_MASTER           FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/cm_master.csv.gz           FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO CM_SPOT             FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/cm_spot.csv.gz             FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO STREAMING_LOG       FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/streaming_log.csv.gz       FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO STREAMING_AD_LOG    FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/streaming_ad_log.csv.gz    FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO PANEL_DEMOGRAPHICS  FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/data/panel_demographics.csv.gz  FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);

-- =============================================================================
-- 6. 読み込めたことを確認する
-- =============================================================================

SELECT 'VIEWING_LOG_NW01'    AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM VIEWING_LOG_NW01
UNION ALL SELECT 'VIEWING_LOG_NW02',   COUNT(*) FROM VIEWING_LOG_NW02
UNION ALL SELECT 'VIEWING_LOG_NW03',   COUNT(*) FROM VIEWING_LOG_NW03
UNION ALL SELECT 'VIEWING_LOG_NW04',   COUNT(*) FROM VIEWING_LOG_NW04
UNION ALL SELECT 'VIEWING_LOG_NW05',   COUNT(*) FROM VIEWING_LOG_NW05
UNION ALL SELECT 'NETWORK_MASTER',     COUNT(*) FROM NETWORK_MASTER
UNION ALL SELECT 'PROGRAM_MASTER',     COUNT(*) FROM PROGRAM_MASTER
UNION ALL SELECT 'PROGRAM_SCHEDULE',   COUNT(*) FROM PROGRAM_SCHEDULE
UNION ALL SELECT 'CM_MASTER',          COUNT(*) FROM CM_MASTER
UNION ALL SELECT 'CM_SPOT',            COUNT(*) FROM CM_SPOT
UNION ALL SELECT 'STREAMING_LOG',      COUNT(*) FROM STREAMING_LOG
UNION ALL SELECT 'STREAMING_AD_LOG',   COUNT(*) FROM STREAMING_AD_LOG
UNION ALL SELECT 'PANEL_DEMOGRAPHICS', COUNT(*) FROM PANEL_DEMOGRAPHICS
ORDER BY TABLE_NAME;

-- 視聴区間の合計は 500,648 行になります。局ごとに行数が違うのは、局の規模の差を表しているためです。

-- -----------------------------------------------------------------------------
-- 生データをそのまま使うと困ることの確認
-- -----------------------------------------------------------------------------
-- 届いたデータには、そのままでは使えない行が混ざっています。
-- 第 2 章のクレンジングで除外します。

SELECT
  COUNT(*)                                                                AS "全行数",
  COUNT_IF(VIEW_TO <= VIEW_FROM)                                          AS "終了が開始より前",
  COUNT_IF(DATEDIFF('hour', VIEW_FROM, VIEW_TO) > 24)                     AS "視聴が24時間を超える",
  COUNT(*) - COUNT(DISTINCT NETWORK_ID || STATION_DEVICE_ID || VIEW_FROM || VIEW_TO) AS "重複した行"
FROM (
  SELECT * FROM VIEWING_LOG_NW01
  UNION ALL SELECT * FROM VIEWING_LOG_NW02
  UNION ALL SELECT * FROM VIEWING_LOG_NW03
  UNION ALL SELECT * FROM VIEWING_LOG_NW04
  UNION ALL SELECT * FROM VIEWING_LOG_NW05
);

-- -----------------------------------------------------------------------------
-- 局ごとの日別の件数
-- -----------------------------------------------------------------------------
-- NW03 の 2026 年 7 月 17 日の行がないことが分かります。
-- 一部の局のデータが届かない日があっても止まらない仕組みが必要になる、
-- という運用上の論点がここに現れます。

SELECT NETWORK_ID, VIEW_FROM::DATE AS "視聴日", COUNT(*) AS "件数"
FROM (
  SELECT NETWORK_ID, VIEW_FROM FROM VIEWING_LOG_NW01
  UNION ALL SELECT NETWORK_ID, VIEW_FROM FROM VIEWING_LOG_NW02
  UNION ALL SELECT NETWORK_ID, VIEW_FROM FROM VIEWING_LOG_NW03
  UNION ALL SELECT NETWORK_ID, VIEW_FROM FROM VIEWING_LOG_NW04
  UNION ALL SELECT NETWORK_ID, VIEW_FROM FROM VIEWING_LOG_NW05
)
WHERE VIEW_FROM::DATE BETWEEN '2026-07-15' AND '2026-07-19'
GROUP BY 1, 2
ORDER BY 2, 1;

-- =============================================================================
-- 第 1 章はここまでです。第 2 章（dbt）は docs/step2_dbt.md に進んでください。
-- =============================================================================
