-- =============================================================================
-- 第 3a 章  セマンティックビューと検索サービス
-- =============================================================================
-- 実行するロール: BCAST_ENGINEER_ROLE
-- 所要時間の目安: 20 分
--
-- このファイルは「すべて実行」しないでください。
-- 2 節の【ここで画面操作】の手前まで実行し、画面で検索サービスを作ってから続きを実行します。
--
-- このスクリプトでやること
--   1. マート層の上にセマンティックビューを作る（指標の定義を Snowflake 側に置く）
--   2. 番組とコマーシャルの説明文をひとつのビューにまとめる（検索の材料）
--      → 検索サービスそのものは Snowsight の画面で作ります（docs/step3a_semantic.md）
--   3. 集計データだけを見るロールに、両方を使う権限を渡す
--
-- 画面で作るのが間に合わない場合は、ファイル末尾の
-- 「UI を使わず SQL で一気に作成する場合はこちら」を実行してください。
--
-- なぜセマンティックビューを作るのか
--   「リーチ」「フリークエンシー」「インプレッション」が何を指すのかを、
--   一度ここで決めてしまうためです。以降は可視化アプリでもエージェントでも
--   同じ定義が使われるので、画面ごとに数字が違うという事態が起きません。
-- =============================================================================

USE ROLE BCAST_ENGINEER_ROLE;
USE WAREHOUSE BCAST_HANDSON_WH;
USE SCHEMA BCAST_VIEWING_HANDSON.MART;

-- =============================================================================
-- 1. セマンティックビュー
-- =============================================================================
-- 構成要素は 5 つです。
--
--   論理テーブル       どの物理テーブルを使うか
--   リレーションシップ どのテーブルとどのテーブルが結合できるか
--   ファクト           行ごとの数値
--   ディメンション     切り口
--   メトリック         集計した指標
--
-- リーチを COUNT(DISTINCT ...) で定義しているところが要点です。
-- マート層を「1 行 = 1 台 × 1 日 × 1 局」の粒度で持っているので、
-- 日で見ても月で見ても局をまたいで見ても、重複を除いた正しい人数が出ます。
-- 日別のリーチをあらかじめ計算して持っていると、それを合計したときに
-- 同じ人を何度も数えてしまいます。
--
-- 識別子は英字にして、日本語は WITH SYNONYMS と COMMENT に入れています。
-- 自然言語で質問したときに、この同義語と説明文が手がかりになります。

CREATE OR REPLACE SEMANTIC VIEW SV_BROADCAST_VIEWING

  TABLES (
    device_daily AS BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY
      WITH SYNONYMS = ('視聴実績', '日別視聴', '受信機の視聴')
      COMMENT = '1 行が 1 台の受信機の 1 日 1 局分の視聴。リーチの計算に使う',

    program_viewing AS BCAST_VIEWING_HANDSON.MART.MART_PROGRAM_VIEWING
      WITH SYNONYMS = ('番組視聴', '番組別の視聴')
      COMMENT = '1 行が 1 つの番組の放送回を 1 台が視聴した記録',

    cm_contact AS BCAST_VIEWING_HANDSON.MART.MART_FREQUENCY
      WITH SYNONYMS = ('広告接触', 'コマーシャル接触', 'キャンペーン')
      COMMENT = '1 行が 1 つのコマーシャルと 1 台の受信機の組み合わせ。接触回数を持つ。放送の接触は実測でなく、視聴区間にスポットの放送時刻が入っていたかで判定した推定値',

    zapping AS BCAST_VIEWING_HANDSON.MART.MART_ZAPPING_TRANSITION
      WITH SYNONYMS = ('次に見た別チャンネル', 'チャンネル遷移')
      COMMENT = '視聴終了から30分以内に次に見た別チャンネルの集計。間隔0分は直接変更、正の間隔は非視聴時間を挟む'
  )

  FACTS (
    device_daily.session_count AS VIEWING_SESSIONS
      COMMENT = 'その日その局を見た回数',
    device_daily.minutes AS VIEW_MINUTES
      COMMENT = 'その日その局を見た分数',
    program_viewing.program_minutes AS VIEW_MINUTES
      COMMENT = 'その番組を見た分数',
    program_viewing.completion AS COMPLETION_RATE
      COMMENT = 'その放送回をどれだけ見通したか。1 に近いほど最後まで見ている',
    cm_contact.contacts AS CONTACT_COUNT
      COMMENT = 'そのコマーシャルに接触した回数'
  )

  DIMENSIONS (
    -- 視聴実績の切り口
    device_daily.view_date AS VIEW_DATE
      WITH SYNONYMS = ('視聴日', '日付', '放送日')
      COMMENT = '視聴した日',
    device_daily.network_name AS NETWORK_NAME
      WITH SYNONYMS = ('局', '放送局', 'ネットワーク', '局名')
      COMMENT = '視聴された放送局の名前',
    device_daily.channel_code AS CHANNEL_CODE
      WITH SYNONYMS = ('チャンネル', 'チャンネル番号')
      COMMENT = '視聴チャンネル',
    device_daily.postal_area AS POSTAL_AREA
      WITH SYNONYMS = ('エリア', '地域', '郵便番号の上3桁')
      COMMENT = '郵便番号の上 3 桁。おおまかな地域',
    device_daily.segment AS GENDER_AGE_SEGMENT
      WITH SYNONYMS = ('セグメント', '性年代', '属性')
      COMMENT = 'パネル調査で判明している性年代。T は 13 から 19 歳、F は女性、M は男性。全体の 10 パーセントの端末にしか値がなく、それ以外は空になる',
    device_daily.devices_per_ip AS DEVICES_PER_IP
      WITH SYNONYMS = ('同一回線の台数', '世帯内の台数')
      COMMENT = '同じ IP アドレスを共有している受信機の台数',

    -- 番組の切り口
    program_viewing.program_name AS PROGRAM_NAME
      WITH SYNONYMS = ('番組', '番組名', 'タイトル')
      COMMENT = '番組の名前',
    program_viewing.genre AS GENRE
      WITH SYNONYMS = ('ジャンル', '番組ジャンル')
      COMMENT = 'ドラマ、バラエティ、アニメ、ニュース、スポーツ、音楽、映画、情報のいずれか',
    program_viewing.time_slot AS TIME_SLOT
      WITH SYNONYMS = ('時間帯', '放送枠')
      COMMENT = '朝、昼、夕方、ゴールデン、深夜のいずれか',
    program_viewing.air_date AS AIR_DATE
      WITH SYNONYMS = ('放送日')
      COMMENT = 'その番組が放送された日',
    program_viewing.program_network_name AS NETWORK_NAME
      WITH SYNONYMS = ('番組の局', '放送した局')
      COMMENT = 'その番組を放送した局の名前',
    program_viewing.program_segment AS GENDER_AGE_SEGMENT
      WITH SYNONYMS = ('番組視聴者のセグメント', '視聴者の性年代')
      COMMENT = 'その番組を見た端末の性年代。パネル分にしか値がない',

    -- 広告接触の切り口
    cm_contact.cm_id AS CM_ID
      WITH SYNONYMS = ('コマーシャルID', 'CM素材ID')
      COMMENT = 'コマーシャル素材を一意に識別するID',
    cm_contact.advertiser AS ADVERTISER
      WITH SYNONYMS = ('広告主', 'スポンサー')
      COMMENT = '広告主の名前',
    cm_contact.category AS CATEGORY
      WITH SYNONYMS = ('業種', '広告のカテゴリ')
      COMMENT = '広告主の業種',
    cm_contact.frequency_band AS FREQUENCY_BAND
      WITH SYNONYMS = ('接触回数帯', 'フリークエンシーの区分')
      COMMENT = '接触回数を区分にまとめたもの',
    cm_contact.campaign_from AS CAMPAIGN_FROM
      WITH SYNONYMS = ('出稿開始日', 'キャンペーン開始日')
      COMMENT = 'そのコマーシャルの出稿期間の開始日',
    cm_contact.campaign_to AS CAMPAIGN_TO
      WITH SYNONYMS = ('出稿終了日', 'キャンペーン終了日')
      COMMENT = 'そのコマーシャルの出稿期間の終了日。出稿は 2 週間から 4 週間で行われる',

    -- 次に見た別チャンネルの切り口
    zapping.zapping_date AS VIEW_DATE
      WITH SYNONYMS = ('移動した日')
      COMMENT = 'チャンネルを移動した日',
    zapping.from_network_name AS FROM_NETWORK_NAME
      WITH SYNONYMS = ('移動元の局', '移動前の局')
      COMMENT = '移動する前に見ていた局',
    zapping.to_network_name AS TO_NETWORK_NAME
      WITH SYNONYMS = ('移動先の局', '移動後の局')
      COMMENT = '移動した先の局'
  )

  METRICS (
    -- リーチ。重複を除いて数えるので、どの切り口で見ても正しい人数になる
    device_daily.reach_devices AS COUNT(DISTINCT device_daily.COMMON_ID)
      WITH SYNONYMS = ('リーチ', '到達台数', '視聴台数', '何台に届いたか')
      COMMENT = '1 回以上視聴した受信機の台数。重複を除いて数えている',
    device_daily.reach_households AS COUNT(DISTINCT device_daily.IP_ADDRESS)
      WITH SYNONYMS = ('到達IP数', '視聴IP数', '世帯到達の代理指標')
      COMMENT = '1回以上視聴したIPアドレスの数。世帯数そのものではなく代理指標',
    device_daily.total_sessions AS SUM(device_daily.session_count)
      WITH SYNONYMS = ('視聴回数', '視聴区間の件数')
      COMMENT = '視聴回数の合計。重複を除いていないので人数ではない',
    device_daily.total_minutes AS SUM(device_daily.minutes)
      WITH SYNONYMS = ('総視聴時間', '視聴分数の合計')
      COMMENT = '視聴した分数の合計',
    minutes_per_device AS ROUND(DIV0(device_daily.total_minutes, device_daily.reach_devices), 1)
      WITH SYNONYMS = ('1台あたりの視聴時間', '平均視聴時間')
      COMMENT = '1 台あたりの平均視聴分数',

    -- 番組の指標
    program_viewing.program_reach_devices AS COUNT(DISTINCT program_viewing.COMMON_ID)
      WITH SYNONYMS = ('番組視聴台数', '番組のリーチ')
      COMMENT = 'その番組を視聴した受信機の台数',
    program_viewing.program_reach_households AS COUNT(DISTINCT program_viewing.IP_ADDRESS)
      WITH SYNONYMS = ('番組視聴IP数', '番組の世帯到達の代理指標')
      COMMENT = 'その番組を視聴したIPアドレスの数。世帯数そのものではない',
    program_viewing.estimated_viewers AS ROUND(COUNT(DISTINCT program_viewing.IP_ADDRESS) * 2.2, 1)
      WITH SYNONYMS = ('推計視聴人数', '視聴人数')
      COMMENT = '視聴IP数に1回線あたりの想定人数2.2を掛けた参考値。IP数は世帯数そのものではない',
    program_viewing.program_total_minutes AS SUM(program_viewing.program_minutes)
      WITH SYNONYMS = ('番組の総視聴時間')
      COMMENT = 'その番組が視聴された分数の合計',
    program_viewing.avg_completion_rate AS AVG(program_viewing.completion)
      WITH SYNONYMS = ('平均視聴完了率', '見通した割合')
      COMMENT = '放送回をどれだけ見通したかの平均',

    -- 広告接触の指標
    -- リーチ、フリークエンシー、インプレッションは
    -- リーチ × 平均フリークエンシー = インプレッション の関係にある。
    -- 3 つのうち 2 つが決まれば残りが決まるので、定義をここに 1 つだけ置く。
    cm_contact.contact_reach AS COUNT(DISTINCT cm_contact.COMMON_ID)
      WITH SYNONYMS = ('接触リーチ', '広告が届いた台数', 'CMのリーチ')
      COMMENT = 'そのコマーシャルに 1 回以上接触した受信機の台数。重複を除いて数えている',
    cm_contact.impressions AS SUM(cm_contact.contacts)
      WITH SYNONYMS = ('インプレッション', '総接触回数', '延べ接触回数', 'のべ接触')
      COMMENT = '接触回数の合計。同じ受信機への複数回の接触をすべて数えた延べの回数。リーチ × 平均フリークエンシーと一致する',
    avg_frequency AS ROUND(DIV0(cm_contact.impressions, cm_contact.contact_reach), 2)
      WITH SYNONYMS = ('フリークエンシー', '平均接触回数', '同じ人に何回見せたか')
      COMMENT = '接触した 1 台あたりの平均接触回数。分母は接触した台数であり、全台数ではない',

    -- 次に見た別チャンネルの指標
    zapping.transitions AS SUM(zapping.TRANSITION_COUNT)
      WITH SYNONYMS = ('30分以内に次に見た別チャンネルの回数', 'チャンネル遷移回数')
      COMMENT = '視聴終了から30分以内に別チャンネルを見始めた回数の合計'
  )

  COMMENT = '地上波5局の非特定視聴データにもとづく視聴指標。リーチ、フリークエンシー、インプレッション、番組別視聴、30分以内に次に見た別チャンネルを扱う'

  AI_SQL_GENERATION '数値は小数第 1 位までに丸めてください。日付の範囲が指定されていない場合は 2026 年 5 月 1 日から 7 月 31 日までの全期間を対象にしてください。セグメントを使った集計を返すときは、パネル調査で属性が判明している端末が全体の 10 パーセントであり、全体の姿ではないことを回答に添えてください。コマーシャルへの接触を含む集計を返すときは、放送の接触が視聴区間とスポットの放送時刻の重なりによる推定値であることを回答に添えてください。';

-- =============================================================================
-- 2. 番組とコマーシャルの説明文をひとつのビューにまとめる
-- =============================================================================
-- 視聴ログは数値と ID だけなので、文章として検索できる材料が別に必要です。
-- 番組の概要文とコマーシャルの素材説明文をひとつのビューにまとめ、
-- このあと Snowsight の画面で作る検索サービスの対象にします。
--
-- これがあると「若い人向けのバラエティ番組を教えて」のような、
-- 数値では表せない質問に答えられるようになります。

CREATE OR REPLACE VIEW V_PROGRAM_CM_DOCS
  COMMENT = '番組とコマーシャルの説明文をまとめたもの。検索サービスの対象'
AS
SELECT
    '番組'                                  AS DOC_TYPE,
    p.PROGRAM_ID                            AS DOC_ID,
    p.PROGRAM_NAME                          AS TITLE,
    p.GENRE                                 AS GENRE,
    p.TIME_SLOT                             AS TIME_SLOT,
    n.NETWORK_NAME                          AS NETWORK_NAME,
    NULL::VARCHAR(40)                       AS ADVERTISER,
    NULL::VARCHAR(20)                       AS CATEGORY,
    -- 検索の対象になる本文。題名やジャンルも本文に含めておくと
    -- 「アニメ」のような語でも当たりやすくなる
    p.PROGRAM_NAME || '。' || p.GENRE || 'の番組。主な放送枠は' || n.NETWORK_NAME
      || 'の' || p.TIME_SLOT || '帯、標準' || p.DURATION_MIN || '分。' || p.SYNOPSIS AS CONTENT
FROM BCAST_VIEWING_HANDSON.RAW.PROGRAM_MASTER p
JOIN BCAST_VIEWING_HANDSON.RAW.NETWORK_MASTER n
  ON p.NETWORK_ID = n.NETWORK_ID

UNION ALL

SELECT
    'コマーシャル'                          AS DOC_TYPE,
    c.CM_ID                                 AS DOC_ID,
    c.ADVERTISER                            AS TITLE,
    NULL::VARCHAR(20)                       AS GENRE,
    NULL::VARCHAR(20)                       AS TIME_SLOT,
    NULL::VARCHAR(40)                       AS NETWORK_NAME,
    c.ADVERTISER                            AS ADVERTISER,
    c.CATEGORY                              AS CATEGORY,
    c.ADVERTISER || 'の' || c.CATEGORY || 'のコマーシャル。'
      || c.DURATION_SEC || '秒。' || c.CREATIVE_DESC AS CONTENT
FROM BCAST_VIEWING_HANDSON.RAW.CM_MASTER c
WHERE c.IS_ANALYSIS_TARGET;

-- ビューの中身を確認します。番組 60 件＋コマーシャル 20 件 = 80 行です。
SELECT DOC_TYPE, COUNT(*) AS "件数" FROM V_PROGRAM_CM_DOCS GROUP BY DOC_TYPE;

-- 【ここで画面操作】検索サービスを Snowsight で作ります
-- ---------------------------------------------------------------------------
--   左メニュー AI と ML → Cortex Search → 右上の 作成
--   設定値は docs/step3a_semantic.md の「検索サービスを画面で作る」の表を見て入力します。
--     サービス名        SVC_PROGRAM_CM_META
--     対象              BCAST_VIEWING_HANDSON.MART.V_PROGRAM_CM_DOCS
--     検索列            CONTENT
--     属性列            DOC_TYPE, DOC_ID, TITLE, GENRE, TIME_SLOT, NETWORK_NAME, ADVERTISER, CATEGORY
--     サービスに含む列  すべて
--     ターゲットラグ    1 時間
--     ウェアハウス      BCAST_HANDSON_WH
--   作成後、下の 3 節に進む前に次でできたことを確認します。
-- ---------------------------------------------------------------------------
SHOW CORTEX SEARCH SERVICES IN SCHEMA BCAST_VIEWING_HANDSON.MART;

-- 画面で作るのが間に合わない場合は、ファイル末尾の保険の SQL を実行してからここに戻ってください。

-- =============================================================================
-- 3. 集計データだけを見るロールに権限を渡す
-- =============================================================================
-- セマンティックビューは、元になっているテーブルへの権限がなくても
-- 参照できます。生データには触れないロールでも、指標だけは見られる
-- という形が作れます。

USE ROLE ACCOUNTADMIN;

GRANT SELECT, REFERENCES ON SEMANTIC VIEW BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  TO ROLE BCAST_ANALYST_ROLE;
GRANT USAGE ON CORTEX SEARCH SERVICE BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META
  TO ROLE BCAST_ANALYST_ROLE;

-- エンジニアのロールにも渡しておきます。検索サービスは画面で ACCOUNTADMIN が作ったので、
-- この GRANT がないと次の 4 節（エンジニアロールでの検索）が止まります。
GRANT SELECT, REFERENCES ON SEMANTIC VIEW BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  TO ROLE BCAST_ENGINEER_ROLE;
GRANT USAGE ON CORTEX SEARCH SERVICE BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META
  TO ROLE BCAST_ENGINEER_ROLE;

-- =============================================================================
-- 4. 動作確認
-- =============================================================================

USE ROLE BCAST_ENGINEER_ROLE;

-- 定義された指標と切り口の一覧
SHOW SEMANTIC METRICS IN BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING;
SHOW SEMANTIC DIMENSIONS IN BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING;

-- 局別のリーチ
SELECT * FROM SEMANTIC_VIEW(
  BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  METRICS device_daily.reach_devices, device_daily.reach_households, device_daily.total_minutes
  DIMENSIONS device_daily.network_name
)
ORDER BY 1;

-- 同じ指標を日別に出す。日別の合計は月の値とは一致しません。
-- 同じ人が複数の日に登場するので、重複を除くと月の人数は日の合計より少なくなります。
SELECT * FROM SEMANTIC_VIEW(
  BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  METRICS device_daily.reach_devices
  DIMENSIONS device_daily.view_date, device_daily.network_name
)
ORDER BY 1, 2
LIMIT 20;

-- 番組別の推計視聴人数
SELECT * FROM SEMANTIC_VIEW(
  BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  METRICS program_viewing.program_reach_devices, program_viewing.estimated_viewers
  DIMENSIONS program_viewing.program_name, program_viewing.genre
)
ORDER BY 3 DESC NULLS LAST
LIMIT 10;

-- 広告主別のリーチ、フリークエンシー、インプレッション
-- リーチ × フリークエンシー = インプレッション になっていることを確認する
SELECT * FROM SEMANTIC_VIEW(
  BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  METRICS cm_contact.contact_reach, avg_frequency, cm_contact.impressions
  DIMENSIONS cm_contact.advertiser
)
ORDER BY 2 DESC NULLS LAST
LIMIT 10;

-- 検索サービスを試す
SELECT PARSE_JSON(
  SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META',
    '{"query": "若い人向けのバラエティ番組", "columns": ["DOC_TYPE","TITLE","GENRE","TIME_SLOT"], "limit": 5}'
  )
)['results'] AS "検索結果";

SELECT PARSE_JSON(
  SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META',
    '{"query": "家族で車で出かける様子のコマーシャル", "columns": ["DOC_TYPE","TITLE","CATEGORY"], "limit": 5}'
  )
)['results'] AS "検索結果";

-- =============================================================================
-- 第 3 章はここまでです。第 4 章（エージェント）は docs/step4_cowork.md へ。
-- =============================================================================


-- =============================================================================
-- 保険：UI を使わず SQL で一気に作成する場合はこちら
-- =============================================================================
-- 画面での作成が間に合わないときや、もう一度作り直したいときに使います。
-- 画面で入力する値と完全に同じ内容です。実行したあとは 3 節に戻ってください。
--
--   ON         検索の対象になる本文の列（画面の「検索列」）
--   ATTRIBUTES 絞り込みに使える列（画面の「属性列」）
--   TARGET_LAG 元のデータが変わったときにどれだけの遅れまで許すか（画面の「ターゲットラグ」）

/*
USE ROLE BCAST_ENGINEER_ROLE;
USE WAREHOUSE BCAST_HANDSON_WH;
USE SCHEMA BCAST_VIEWING_HANDSON.MART;

CREATE OR REPLACE CORTEX SEARCH SERVICE SVC_PROGRAM_CM_META
  ON CONTENT
  ATTRIBUTES DOC_TYPE, DOC_ID, TITLE, GENRE, TIME_SLOT, NETWORK_NAME, ADVERTISER, CATEGORY
  WAREHOUSE = BCAST_HANDSON_WH
  TARGET_LAG = '1 hour'
  COMMENT = '番組の概要文とコマーシャルの素材説明文の検索'
  AS
    SELECT DOC_TYPE, DOC_ID, TITLE, GENRE, TIME_SLOT, NETWORK_NAME, ADVERTISER, CATEGORY, CONTENT
    FROM BCAST_VIEWING_HANDSON.MART.V_PROGRAM_CM_DOCS;

SHOW CORTEX SEARCH SERVICES IN SCHEMA BCAST_VIEWING_HANDSON.MART;
*/
