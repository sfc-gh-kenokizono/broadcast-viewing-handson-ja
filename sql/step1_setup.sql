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
--   ありません。第 0 章でワークスペースを作ってあるので、左側の一覧から
--   このファイルを開いて、そのまま上から実行できます。
--   コピーと貼り付けは必要ありません。
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
--
-- SET でセッション変数に入れ、$ を付けて参照します。
-- IDENTIFIER() は「文字列をオブジェクト名として扱う」という関数です。
-- これがないと、変数の中身ではなく current_user_name という名前のユーザーを
-- 探しにいってしまいます。
SET current_user_name = (SELECT CURRENT_USER());

-- 変数に何が入ったか確認しておきます
SELECT $current_user_name AS "変数の中身";

GRANT ROLE BCAST_ENGINEER TO USER IDENTIFIER($current_user_name);
GRANT ROLE BCAST_ANALYST  TO USER IDENTIFIER($current_user_name);

-- カスタムロールは SYSADMIN の下にぶら下げる（Snowflake の推奨構成）
-- ここを省くと、BCAST_ENGINEER が作ったテーブルに ACCOUNTADMIN でも到達できません。
-- Streamlit は所有者権限で動くため、アプリ作成ロールに参照経路がないと
-- 「Insufficient privileges to operate on table」で落ちます。
GRANT ROLE BCAST_ENGINEER TO ROLE SYSADMIN;
GRANT ROLE BCAST_ANALYST  TO ROLE SYSADMIN;

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
-- ここで作る GIT REPOSITORY は、第 0 章で作ったワークスペースとは別の仕組みです。
--
--   ワークスペース    画面でファイルを開いて編集・実行するための入れ物
--   GIT REPOSITORY   SQL からリポジトリの中身をステージとして参照するための入れ物
--
-- このあと data フォルダの CSV を COPY で読み込むので、SQL から参照できる
-- GIT REPOSITORY が必要になります。ワークスペースだけでは読み込めません。
--
-- API 統合は第 0 章で作ってあります。IF NOT EXISTS を付けているので、
-- ここを実行してもワークスペースの接続には影響しません。

USE SCHEMA BCAST_VIEWING_HANDSON.INTEGRATIONS;

CREATE API INTEGRATION IF NOT EXISTS BCAST_GIT_API
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/sfc-gh-kenokizono')
  ENABLED = TRUE;

GRANT USAGE ON INTEGRATION BCAST_GIT_API TO ROLE BCAST_ENGINEER;
GRANT USAGE ON SCHEMA BCAST_VIEWING_HANDSON.INTEGRATIONS TO ROLE BCAST_ENGINEER;

-- 公開リポジトリなので GIT_CREDENTIALS を指定しません
CREATE OR REPLACE GIT REPOSITORY BCAST_REPO
  API_INTEGRATION = BCAST_GIT_API
  ORIGIN = 'https://github.com/sfc-gh-kenokizono/broadcast-viewing-handson-ja.git';

GRANT READ ON GIT REPOSITORY BCAST_REPO TO ROLE BCAST_ENGINEER;

-- リポジトリの最新の内容を取り込む
ALTER GIT REPOSITORY BCAST_REPO FETCH;

-- 中身が見えることを確認する。CSV が並んでいれば接続できています。
LS @BCAST_REPO/branches/main/data/;

-- -----------------------------------------------------------------------------
-- リポジトリの CSV を内部ステージに移す
-- -----------------------------------------------------------------------------
-- Git リポジトリのステージは「コードを置く場所」であり、そこから直接
-- COPY INTO でテーブルに読み込むことはできません（Unsupported feature になります）。
-- COPY FILES で内部ステージに移してから読み込みます。
-- ウェアハウスを使わないサーバーレスの処理なので、数秒で終わります。

CREATE OR REPLACE STAGE BCAST_RAW_STAGE
  COMMENT = 'リポジトリから取り込んだ CSV の置き場所';

COPY FILES
  INTO @BCAST_RAW_STAGE
  FROM @BCAST_REPO/branches/main/data/;

GRANT READ ON STAGE BCAST_RAW_STAGE TO ROLE BCAST_ENGINEER;

-- 11 ファイルが並んでいれば成功です
LS @BCAST_RAW_STAGE;

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
  CREATIVE_DESC  VARCHAR(400) COMMENT '素材の説明文。第 3 章で検索サービスの対象にする',
  CAMPAIGN_FROM  DATE COMMENT '出稿期間の開始日',
  CAMPAIGN_TO    DATE COMMENT '出稿期間の終了日'
) COMMENT = 'コマーシャルのマスタ。出稿は 2 週間から 4 週間の期間で行われる';

CREATE OR REPLACE TABLE CM_SPOT (
  SPOT_ID     VARCHAR(12),
  CM_ID       VARCHAR(8),
  NETWORK_ID  VARCHAR(4),
  AIR_AT      TIMESTAMP_NTZ
) COMMENT = 'コマーシャルが放送された時刻';

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

COPY INTO VIEWING_LOG_NW01 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/viewing_log_nw01.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO VIEWING_LOG_NW02 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/viewing_log_nw02.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO VIEWING_LOG_NW03 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/viewing_log_nw03.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO VIEWING_LOG_NW04 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/viewing_log_nw04.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO VIEWING_LOG_NW05 FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/viewing_log_nw05.csv.gz FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);

COPY INTO NETWORK_MASTER      FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/network_master.csv.gz      FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO PROGRAM_MASTER      FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/program_master.csv.gz      FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO PROGRAM_SCHEDULE    FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/program_schedule.csv.gz    FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO CM_MASTER           FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/cm_master.csv.gz           FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO CM_SPOT             FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/cm_spot.csv.gz             FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);
COPY INTO PANEL_DEMOGRAPHICS  FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_RAW_STAGE/panel_demographics.csv.gz  FILE_FORMAT = (FORMAT_NAME = CSV_UTF8);

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
UNION ALL SELECT 'PANEL_DEMOGRAPHICS', COUNT(*) FROM PANEL_DEMOGRAPHICS
ORDER BY TABLE_NAME;

-- 視聴区間の合計は 1,050,648 行になります。局ごとに行数が違うのは、局の規模の差を表しているためです。

-- -----------------------------------------------------------------------------
-- 生データに混ざっている、計算を狂わせる行を数える
-- -----------------------------------------------------------------------------
-- 届いたログには、放送設備の不具合や再送によって、そのままでは計算に使えない行が
-- 混ざっています。次のクエリは「何がどれだけ混ざっているか」を数えます。
--
-- なぜ数えるのか
--   このまま集計すると、指標が実際とずれます。混ざり方ごとに、ずれ方が違います。
--
--   終了が開始より前
--     終了 - 開始 で視聴時間を出すと、マイナスになります。
--     合計すると、他の行の視聴時間を打ち消して、全体が実際より短く出ます。
--
--   視聴が 24 時間を超える
--     受信機がつけっぱなしのまま記録が切れなかった行です。
--     1 件で 1 日分以上を占めるため、平均視聴時間が大きく引き上げられます。
--     第 2 章で 1 分単位に分解するので、1 行が 1,440 行以上に膨らみます。
--
--   重複した行
--     同じ視聴が 2 回記録されています。
--     リーチ（台数）は変わりませんが、視聴時間とインプレッションが多めに出ます。
--     「台数は合っているのに接触回数だけ多い」という、気づきにくいずれ方です。
--
-- 全体に対する割合は 0.1 パーセント未満です。少ないので放置してよさそうに見えますが、
-- 平均や合計は極端な値に引っ張られるため、この 1 件が数字を動かします。
-- 第 2 章のクレンジングで除外し、除外後の行数を確認します。

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

-- 次のようになります。
--   全行数 1,050,648 / 終了が開始より前 200 / 24 時間超 148 / 重複 313
--
-- この 661 行を除いた 1,049,987 行が、第 2 章のクレンジング後の行数になります。
-- 第 2 章で実際にその数字が出ることを確認します。

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
-- 補足: 非公開リポジトリを使う場合
-- =============================================================================
-- 自分のリポジトリに置き換えて実施する場合など、非公開リポジトリを参照するには
-- 認証情報をシークレットとして登録し、それを API 統合とリポジトリの両方から
-- 指定します。シークレットに入れた値は SQL から取り出すことはできません。
--
-- CREATE OR REPLACE SECRET BCAST_GIT_SECRET
--   TYPE = password
--   USERNAME = '<GitHub のユーザー名>'
--   PASSWORD = '<GitHub の個人アクセストークン>';
--
-- CREATE OR REPLACE API INTEGRATION BCAST_GIT_API
--   API_PROVIDER = git_https_api
--   API_ALLOWED_PREFIXES = ('https://github.com/<ユーザー名または組織名>')
--   ALLOWED_AUTHENTICATION_SECRETS = (BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_GIT_SECRET)
--   ENABLED = TRUE;
--
-- GRANT READ ON SECRET BCAST_GIT_SECRET TO ROLE BCAST_ENGINEER;
--
-- CREATE OR REPLACE GIT REPOSITORY BCAST_REPO
--   API_INTEGRATION = BCAST_GIT_API
--   GIT_CREDENTIALS = BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_GIT_SECRET
--   ORIGIN = 'https://github.com/<ユーザー名または組織名>/broadcast-viewing-handson-ja.git';
--
-- この場合、第 2 章でワークスペースを作るときにも同じシークレットを選びます。

-- =============================================================================
-- 第 1 章はここまでです。第 2 章（dbt）は docs/step2_dbt.md に進んでください。
-- =============================================================================
