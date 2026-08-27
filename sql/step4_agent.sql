-- =============================================================================
-- 第 4 章  エージェントを作り自然言語で分析する
-- =============================================================================
-- 実行するロール: BCAST_ENGINEER（権限付与の部分だけ ACCOUNTADMIN）
-- 所要時間の目安: 20 分
--
-- このスクリプトでやること
--   1. エージェントを作る（第 3 章で作った 2 つの部品を道具として持たせる）
--   2. 使えるようにする権限を渡す
--   3. Snowsight の画面と CoWork で試す
--
-- エージェントは自分でデータを持ちません。持っているのは
--   ・セマンティックビュー（数値の集計ができる）
--   ・検索サービス（文章を探せる）
-- の 2 つの道具だけです。質問の内容を見て、どちらを使うか、
-- あるいは両方を順番に使うかを決めて動きます。
-- =============================================================================

USE ROLE BCAST_ENGINEER;
USE WAREHOUSE BCAST_HANDSON_WH;
USE SCHEMA BCAST_VIEWING_HANDSON.MART;

-- =============================================================================
-- 1. エージェントを作る
-- =============================================================================
-- 設定の中身は YAML で書きます。囲みには $ を 2 つ並べた記号を使います。
-- 名前を付けた囲み（$spec$ のような書き方）は Snowflake では使えません。
--
-- models を省略すると、そのアカウントで使える中からいちばん品質の高い
-- モデルが自動で選ばれます。新しいモデルが出たときに自動で切り替わるので、
-- 特に理由がなければ auto のままにしておくのが無駄がありません。

CREATE OR REPLACE AGENT BCAST_VIEWING_AGENT
  COMMENT = '地上波 5 局の非特定視聴データについて、自然言語で質問に答えるエージェント'
  PROFILE = '{"display_name": "放送視聴データ分析", "color": "blue"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto

orchestration:
  budget:
    seconds: 120
    tokens: 32000

instructions:
  response: |
    あなたは放送局と広告会社に向けた視聴データの分析担当者です。日本語で答えてください。

    答え方の決まり
    - 数字を出すときは、必ず対象期間と対象範囲（局、番組、エリアなど）を添えてください。
    - 複数行になる結果は表で示してください。
    - リーチは重複を除いた台数です。日別の値を足し合わせた数と期間全体の値は一致しません。
      期間をまたぐ質問に答えるときは、足し算ではなく期間全体で計算した値を返してください。
    - 性年代のセグメント別の集計を返すときは、属性が判明しているのは全体の 10 パーセントで
      あり、全体の姿ではないことを必ず添えてください。
    - 推計視聴人数は視聴世帯数に想定人数 2.2 を掛けた便宜的な値であることを、
      その数字を出すときに 1 行添えてください。
    - コマーシャルへの接触の数字を出すときは、放送の接触が実測でなく、
      視聴区間にスポットの放送時刻が入っていたかで判定した推定値であることを
      添えてください。
    - リーチ、フリークエンシー、インプレッションは
      リーチ × 平均フリークエンシー = インプレッション の関係にあります。
      フリークエンシーの分母は接触した台数であり、全台数ではありません。
    - データに無いことを聞かれたら、無いと正直に答えてください。推測で埋めないでください。

  orchestration: |
    質問の性質で道具を使い分けてください。

    - 台数、人数、回数、時間、割合、推移、比較など、数えられることを聞かれたとき
      → ViewingMetrics を使う
    - 「どんな番組か」「どんな内容のコマーシャルか」のように、文章の内容を探すとき
      → ProgramCmSearch を使う
    - 「若い人向けのバラエティ番組のリーチは？」のように両方が必要なとき
      → まず ProgramCmSearch で該当する番組を特定し、その番組名を使って
        ViewingMetrics で集計する

    番組名や広告主の名前があいまいなときは、先に ProgramCmSearch で候補を探してから
    集計に進んでください。

  sample_questions:
    - question: "局ごとのリーチを教えてください"
    - question: "7 月にいちばん多く見られた番組は何ですか"
    - question: "広告主ごとのリーチと平均フリークエンシー、インプレッションを比べてください"
    - question: "若い人向けのバラエティ番組を探して、その番組のリーチを教えてください"
    - question: "どの局からどの局へのチャンネル移動が多いですか"

tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "ViewingMetrics"
      description: |
        地上波 5 局の視聴指標を集計する道具です。
        扱えるもの: リーチ（到達台数、到達世帯数）、視聴回数、視聴時間、
        番組別の視聴台数と推計視聴人数、コマーシャルの接触リーチと
        フリークエンシーとインプレッション、局をまたいだチャンネル移動の回数。
        切り口: 視聴日、局、チャンネル、エリア（郵便番号の上 3 桁）、性年代のセグメント、
        番組名、ジャンル、時間帯、広告主、業種、コマーシャルの出稿期間。
        対象期間は 2026 年 5 月 1 日から 7 月 31 日です。
        使わない場面: 番組やコマーシャルの内容そのものを知りたいだけのとき。

  - tool_spec:
      type: "cortex_search"
      name: "ProgramCmSearch"
      description: |
        番組の概要文と、コマーシャルの素材の説明文を探す道具です。
        「家族が出てくるコマーシャル」「子ども向けのアニメ」のように、
        数値では表せない内容から番組やコマーシャルを見つけるときに使います。
        DOC_TYPE は「番組」か「コマーシャル」のどちらかです。
        使わない場面: 台数や回数などの数字を出したいとき。

  - tool_spec:
      type: "data_to_chart"
      name: "data_to_chart"
      description: "集計結果からグラフを作ります"

tool_resources:
  ViewingMetrics:
    semantic_view: "BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING"
    execution_environment:
      type: "warehouse"
      warehouse: "BCAST_HANDSON_WH"
      query_timeout: 120

  ProgramCmSearch:
    search_service: "BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META"
    max_results: "5"
    id_column: "DOC_ID"
    title_column: "TITLE"
    columns_and_descriptions:
      CONTENT:
        description: "番組の概要文またはコマーシャルの素材説明文。番組名やジャンル、放送する局、時間帯も本文に含まれている"
        type: "string"
        searchable: true
        filterable: false
      DOC_TYPE:
        description: "文書の種別。値は「番組」または「コマーシャル」のいずれか"
        type: "string"
        searchable: false
        filterable: true
      GENRE:
        description: "番組のジャンル。ドラマ、バラエティ、アニメ、ニュース、スポーツ、音楽、映画、情報のいずれか。コマーシャルの場合は空"
        type: "string"
        searchable: false
        filterable: true
      TIME_SLOT:
        description: "番組の放送時間帯。朝、昼、夕方、ゴールデン、深夜のいずれか。コマーシャルの場合は空"
        type: "string"
        searchable: false
        filterable: true
      NETWORK_NAME:
        description: "番組を放送する局の名前。第一放送ネットワークから第五放送ネットワークのいずれか"
        type: "string"
        searchable: false
        filterable: true
      ADVERTISER:
        description: "コマーシャルの広告主の名前。番組の場合は空"
        type: "string"
        searchable: false
        filterable: true
      CATEGORY:
        description: "広告主の業種。清涼飲料、自動車、通信、小売、金融、食品、化粧品、教育、旅行、住宅のいずれか。番組の場合は空"
        type: "string"
        searchable: false
        filterable: true
$$;

-- =============================================================================
-- 2. 使えるようにする権限を渡す
-- =============================================================================
-- エージェントを動かすには 3 つそろっている必要があります。
--   ・エージェント自体を使う権限
--   ・エージェントが持つ道具（セマンティックビュー、検索サービス）を使う権限
--   ・Cortex を使う権限
-- 第 1 章と第 3 章で 2 つめと 3 つめは渡してあるので、ここでは 1 つめだけです。

USE ROLE ACCOUNTADMIN;

GRANT USAGE ON AGENT BCAST_VIEWING_HANDSON.MART.BCAST_VIEWING_AGENT TO ROLE BCAST_ANALYST;
GRANT USAGE ON AGENT BCAST_VIEWING_HANDSON.MART.BCAST_VIEWING_AGENT TO ROLE BCAST_ENGINEER;

-- ここが引っかかりやすいところです。
-- CoWork から使うときの権限は、いま画面で選んでいるロールではなく
-- そのユーザーの既定のロールで判定されます。既定のロールと既定のウェアハウスが
-- 設定されていないと、画面のロールを切り替えても動きません。
--
-- 自分の設定を確認する
-- 既定のロールと既定のウェアハウスはユーザーの属性なので、
-- SHOW USERS の結果から自分の行を取り出して見ます。
SET my_user = (SELECT CURRENT_USER());
SELECT $my_user AS "変数の中身";
SHOW USERS;
SELECT
  "name"              AS "ユーザー",
  "default_role"      AS "既定のロール",
  "default_warehouse" AS "既定のウェアハウス"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = $my_user;

-- 空になっている場合は次のように指定します。
-- ALTER USER IDENTIFIER($my_user) SET DEFAULT_ROLE = 'BCAST_ENGINEER';
-- ALTER USER IDENTIFIER($my_user) SET DEFAULT_WAREHOUSE = 'BCAST_HANDSON_WH';

-- =============================================================================
-- 3. CoWork の一覧に出るかどうかを確認する
-- =============================================================================
-- ほとんどのアカウントでは、エージェントを作ると CoWork に自動で出てきます。
-- ただし、以前から Snowflake Intelligence のオブジェクトが作られている
-- アカウントでは、そこに明示的に追加する必要があります。
--
-- まず、そのオブジェクトがあるかどうかを見ます。

SHOW SNOWFLAKE INTELLIGENCES;

-- 行が返ってきた場合だけ、次を実行します（<名前> は上の結果に置き換えてください）。
-- 行が返ってこなければ何もする必要はありません。
--
-- ALTER SNOWFLAKE INTELLIGENCE <名前>
--   ADD AGENT BCAST_VIEWING_HANDSON.MART.BCAST_VIEWING_AGENT;
-- GRANT USAGE ON SNOWFLAKE INTELLIGENCE <名前> TO ROLE BCAST_ANALYST;

-- =============================================================================
-- 4. 動作確認
-- =============================================================================

USE ROLE BCAST_ENGINEER;

-- 作られたことの確認
SHOW AGENTS IN SCHEMA BCAST_VIEWING_HANDSON.MART;
DESCRIBE AGENT BCAST_VIEWING_HANDSON.MART.BCAST_VIEWING_AGENT;

-- ここから先は画面で操作します。
--   Snowsight の左メニューから AI と ML、Agents を開き、
--   放送視聴データ分析 を選んで、画面下の入力欄に質問を打ちます。
--
--   CoWork で試す場合は https://ai.snowflake.com を開きます。
--
-- 質問の例は docs/step4_cowork.md にまとめています。

-- =============================================================================
-- 第 4 章はここまでです。第 5 章（可視化アプリ）は docs/step5_app.md へ。
-- =============================================================================
