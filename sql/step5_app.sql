-- =============================================================================
-- 第 5 章 可視化アプリを作る
-- =============================================================================
-- このファイルでやること
--   1. リポジトリの app フォルダを内部ステージに移す
--   2. そのステージを指す Streamlit アプリを作る
--
-- 事前に決めておくこと
--   ありません。ワークスペースの左側の一覧からこのファイルを開いて、
--   そのまま上から実行できます。コードのコピーと貼り付けは必要ありません。
--
-- なぜ SQL で作るのか
--   画面から作る場合は、アプリのコードを貼り付けることになります。
--   リポジトリにコードがあるので、そこから直接作ったほうが確実です。
--   実務でも、アプリのコードはリポジトリで管理して、そこから配置します。
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE BCAST_HANDSON_WH;
USE SCHEMA BCAST_VIEWING_HANDSON.MART;

-- =============================================================================
-- 1. アプリのコードを内部ステージに移す
-- =============================================================================
-- 第 1 章で CSV を読み込んだときと同じ理由です。
-- Git リポジトリのステージはコードを置く場所なので、そこを直接
-- アプリの置き場所として指定することはできません。
-- COPY FILES で内部ステージに移します。

CREATE OR REPLACE STAGE BCAST_APP_STAGE
  COMMENT = 'Streamlit アプリのコードの置き場所';

COPY FILES
  INTO @BCAST_APP_STAGE
  FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/app/;

-- streamlit_app.py が並んでいれば成功です
LS @BCAST_APP_STAGE;

-- =============================================================================
-- 2. アプリを作る
-- =============================================================================
-- ROOT_LOCATION がコードの置き場所、MAIN_FILE が入口のファイルです。
-- QUERY_WAREHOUSE はアプリの中で SQL を実行するときに使うウェアハウスです。

CREATE OR REPLACE STREAMLIT BCAST_VIEWING_APP
  ROOT_LOCATION = '@BCAST_VIEWING_HANDSON.MART.BCAST_APP_STAGE'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = BCAST_HANDSON_WH
  COMMENT = '放送視聴データの可視化アプリ';

-- アナリストにも見せる
GRANT USAGE ON STREAMLIT BCAST_VIEWING_APP TO ROLE BCAST_ANALYST_ROLE;

SHOW STREAMLITS LIKE 'BCAST_VIEWING_APP';

-- =============================================================================
-- 3. 開く
-- =============================================================================
-- Snowsight の左メニューで Projects の下の Streamlit を選ぶと、
-- BCAST_VIEWING_APP が一覧に出てきます。選ぶと起動します。
--
-- Streamlit は所有者権限で動きます。
-- ここでは ACCOUNTADMIN で作っているので、ACCOUNTADMIN の権限で動きます。
-- 第 1 章でカスタムロールを SYSADMIN の下にぶら下げているため、
-- ACCOUNTADMIN から BCAST_ENGINEER_ROLE が作ったテーブルに到達できます。
-- あの GRANT を省くと、ここで
-- 「Insufficient privileges to operate on table」で落ちます。

-- =============================================================================
-- コードを直したときの反映
-- =============================================================================
-- リポジトリのコードを直した場合は、次の順で反映します。
--
-- ALTER GIT REPOSITORY BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO FETCH;
-- COPY FILES INTO @BCAST_APP_STAGE
--   FROM @BCAST_VIEWING_HANDSON.INTEGRATIONS.BCAST_REPO/branches/main/app/;
--
-- そのあとアプリの画面を再読み込みしてください。
--
-- 画面上で直したい場合は、アプリの画面から Edit を選ぶと編集できます。
-- ただしその変更はリポジトリには戻りません。

-- =============================================================================
-- 第 5 章はここまでです。第 6 章は docs/step6_rbac.md に進んでください。
-- =============================================================================
