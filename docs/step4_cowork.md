# 第 4 章 エージェントを作り自然言語で分析する

所要時間の目安 20 分

## 目的

第 3 章で作った 2 つの部品を道具として持たせたエージェントを作り、自然言語で質問できる状態にします。

エージェント自身はデータを持ちません。持っているのは次の 2 つだけです。

| 道具 | できること |
|---|---|
| セマンティックビュー | 数値を集計する |
| 検索サービス | 文章を探す |

質問の内容を見て、どちらを使うか、あるいは両方を順番に使うかを決めて動きます。

## 使うファイル

| ファイル | 使い方 |
|---|---|
| `sql/step4_agent.sql` | 確認と権限付与。末尾に SQL で一気に作る保険がある |
| [`docs/step4_ref_agent_texts.md`](step4_ref_agent_texts.md) | 画面に貼り付ける文章（コピペ用） |

この章では、エージェントを **Snowsight の画面で作ります**。どんな項目があって、どこに何を書くのかを目で見てもらうためです。長い文章はコピペ用のファイルから写します。間に合わなかった人は、SQL ファイル末尾の保険を実行すれば同じものができます。

```text
① 画面でエージェントを作る          ← このページの表 + step4_ref_agent_texts.md
② sql/step4_agent.sql を上から実行  ← 確認、権限、CoWork の確認
③ 質問してみる                      ← このページの「質問の例」
```

## 画面でエージェントを作る

```text
Snowsight → 左メニュー AI と ML → Agents
 → 右上の Create agent
```

画面右上のロールが `ACCOUNTADMIN` になっていることを確認してから進めます。画面の項目名は英語表示の場合を括弧で添えています。

### 基本設定（About）

| 項目 | 値 |
|---|---|
| データベースとスキーマ | `BCAST_VIEWING_HANDSON` / `MART` |
| エージェントオブジェクト名 | `BCAST_VIEWING_AGENT` |
| 表示名（Display name） | `放送視聴データ分析` |
| 説明（Description） | コピペ用 → **1. 基本設定** |
| 質問の例（Example questions） | コピペ用 → **1. 基本設定**の 5 つを 1 つずつ |

→ **Create** をクリックするとエージェントの編集画面に入ります。以降は左のタブを順に埋めます。

### 道具 1（Tools → Cortex Analyst → + Add）

| 項目 | 値 |
|---|---|
| セマンティックビュー | `BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING` |
| 名前（Name） | `ViewingMetrics` |
| 説明（Description） | コピペ用 → **2. 道具 1** |
| ウェアハウス | `BCAST_HANDSON_WH` |
| クエリタイムアウト | `120` |

→ **Add** をクリック

### 道具 2（Tools → Cortex Search → + Add）

| 項目 | 値 |
|---|---|
| 検索サービス | `BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META` |
| 名前（Name） | `ProgramCmSearch` |
| 説明（Description） | コピペ用 → **3. 道具 2** |
| ID 列（ID column） | `DOC_ID` |
| タイトル列（Title column） | `TITLE` |
| 最大結果数（Max results） | `5` |
| フィルター | 追加しない |

→ **Add** をクリック

グラフを描かせたい場合は、同じ Tools の画面で **Data to chart** も追加しておきます（既定で入っている場合はそのまま）。

### オーケストレーション（Orchestration）

| 項目 | 値 |
|---|---|
| モデル（Model） | `Auto`（既定のまま） |
| 道具の使い分けの指示（Orchestration instructions） | コピペ用 → **4. オーケストレーション** |
| 答え方の指示（Response instructions） | コピペ用 → **4. オーケストレーション** |

`Auto` にしておくと、そのアカウントで使える中からいちばん品質の高いモデルが自動で選ばれます。新しいモデルが出たときに自動で切り替わるので、特に理由がなければこのままが手がかかりません。

### アクセス（Access）

| 項目 | 値 |
|---|---|
| ロール | `BCAST_ANALYST_ROLE`と`BCAST_ENGINEER_ROLE` を追加 |

→ 右上の **Save** をクリック

ここで追加するロールは、SQL の `GRANT USAGE ON AGENT` と同じ意味です。あとで `sql/step4_agent.sql` の 2 節でも同じ GRANT を実行しますが、二重になっても問題ありません。

### できたことを確認する

ワークスペースに戻り、`sql/step4_agent.sql` を上から実行します。最初の `SHOW AGENTS` で 1 行返れば成功です。

### 画面が間に合わないとき

`sql/step4_agent.sql` の末尾に「保険：UI を使わず SQL で一気に作成する場合はこちら」があります。`/* */` の中の SQL だけを選んで実行します。画面で入力する値と完全に同じ内容です。

設定の中身は YAML です。囲みには `$` を 2 つ並べた記号を使います。

```sql
CREATE OR REPLACE AGENT BCAST_VIEWING_AGENT
  COMMENT = '...'
  PROFILE = '{"display_name": "放送視聴データ分析", "color": "blue"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto
instructions:
  response: |
    ...
  orchestration: |
    ...
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "ViewingMetrics"
      description: |
        ...
tool_resources:
  ViewingMetrics:
    semantic_view: "BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING"
$$;
```

画面の各タブがこの YAML のどこに対応するかを知っておくと、あとで直すときに便利です。

| 画面 | YAML |
|---|---|
| 説明・質問の例 | `COMMENT` / `instructions.sample_questions` |
| 道具の名前と説明 | `tools[].tool_spec` |
| 道具の参照先（セマンティックビュー、検索サービス） | `tool_resources` |
| 使い分けの指示 | `instructions.orchestration` |
| 答え方の指示 | `instructions.response` |
| アクセス | `GRANT USAGE ON AGENT` |

## 精度を決めるのは 2 か所

エージェントの答えの質は、モデルよりも次の 2 か所で決まります。

### 1. 道具の説明文

エージェントはこの説明文だけを見て、どの道具を使うかを決めます。何ができるか、何を扱うか、**どういうときに使わないか**まで書いておくと、選び間違いが減ります。

```yaml
description: |
  地上波 5 局の視聴指標を集計する道具です。
  扱えるもの: リーチ（到達台数、到達IP数）、視聴回数、視聴時間、...
  切り口: 視聴日、局、チャンネル、エリア、性年代のセグメント、...
  対象期間は 2026 年 5 月 1 日から 7 月 31 日です。
  使わない場面: 番組やコマーシャルの内容そのものを知りたいだけのとき。
```

### 2. 答え方の指示

データの読み方を間違えないようにする決まりを、ここに書いておきます。このハンズオンでは次の 4 つを入れています。

- リーチは重複を除いた台数なので、日別の値を足し合わせないこと
- 性年代の集計を返すときは、属性が判明しているのは全体の 10 パーセントだと添えること
- 推計視聴人数は想定人数 2.2 を掛けた便宜的な値だと添えること
- コマーシャルの接触は、視聴区間とスポット時刻の重なりによる**推定値**だと添えること

エージェントに数字を出させるとき、いちばん怖いのは数字そのものより**読み方の取り違え**です。定義側と指示側の両方に書いておくと、どちらから来ても同じ注意書きが付きます。

画面で作ったあとに直したいときは、同じ Agents の画面でエージェントを開き **Edit** から変更できます。文章を書き換えて Save すればすぐに反映され、作り直す必要はありません。

## 権限

エージェントを動かすには 3 つそろっている必要があります。

| 必要なもの | どこで渡したか |
|---|---|
| エージェント自体を使う権限 | この章 |
| 道具（セマンティックビュー、検索サービス）を使う権限 | 第 3 章 |
| Cortex を使う権限 | 第 1 章 |

### 引っかかりやすいところ

CoWork から使うときの権限は、**画面で選んでいるロールではなく、そのユーザーの既定のロール**で判定されます。既定のロールと既定のウェアハウスが設定されていないと、画面でロールを切り替えても動きません。

```sql
SHOW PARAMETERS LIKE 'DEFAULT%' FOR USER IDENTIFIER(CURRENT_USER());
```

空になっている場合は設定してください。

```sql
ALTER USER IDENTIFIER(CURRENT_USER()) SET DEFAULT_ROLE = 'BCAST_ENGINEER_ROLE';
ALTER USER IDENTIFIER(CURRENT_USER()) SET DEFAULT_WAREHOUSE = 'BCAST_HANDSON_WH';
```

## CoWork の一覧に出ない場合

ほとんどのアカウントでは、エージェントを作ると CoWork に自動で出てきます。ただし以前から Snowflake Intelligence のオブジェクトが作られているアカウントでは、そこに明示的に追加しないと出てきません。権限の問題と誤診しやすいところなので、まず存在を確認します。

```sql
SHOW SNOWFLAKE INTELLIGENCES;
```

行が返ってきた場合だけ、追加が必要です。

```sql
ALTER SNOWFLAKE INTELLIGENCE <名前> ADD AGENT BCAST_VIEWING_HANDSON.MART.BCAST_VIEWING_AGENT;
GRANT USAGE ON SNOWFLAKE INTELLIGENCE <名前> TO ROLE BCAST_ANALYST_ROLE;
```

## 試す

2 つの入口があります。どちらも同じエージェントを呼んでいるので、動きも権限も回答も同じです。

| 入口 | 場所 |
|---|---|
| Snowsight のプレイグラウンド | AI と ML、Agents、放送視聴データ分析 |
| CoWork | `https://ai.snowflake.com` |

作りながら確認するならプレイグラウンドのほうが手数が少ないです。

## 質問の例

順番に投げていくと、道具の使い分けが見えます。

### 1. 数値の集計だけで答えられる質問

```
局ごとのリーチを教えてください
```

セマンティックビューだけが使われます。回答に対象期間が添えられているかを見てください。

```
7 月にいちばん多く見られた番組は何ですか。上位 5 つを教えてください
```

```
広告主ごとのリーチと平均フリークエンシー、インプレッションを比べてください
```

リーチ × 平均フリークエンシー = インプレッション になっているかを確かめてください。同じ定義を使っているので、どの聞き方をしても矛盾しない数字が返ります。

さらに、接触の数字を返したときに**放送の接触が推定値であるという断り書き**が付いているかも見てください。数字だけを返すのでなく、その数字の性格を添えさせるのが、社外に出す指標を扱うときの要点になります。

### 2. 文章の検索が必要な質問

```
子ども向けのアニメ番組にはどんなものがありますか
```

検索サービスが使われます。番組名に「子ども」という語が入っていなくても、概要文の内容から近いものが返ります。

```
家族が車で出かける様子のコマーシャルはありますか
```

### 3. 両方が必要な質問

```
若い人向けのバラエティ番組を探して、その番組のリーチを教えてください
```

まず検索サービスで番組を特定し、その番組名を使ってセマンティックビューで集計します。**文章から入って数字に着地する**流れがここで見えます。

### 4. 注意書きが付くかを確認する質問

```
性年代のセグメントごとに、ジャンル別のリーチを教えてください
```

「属性が判明しているのは全体の 10 パーセントです」という注意書きが付くはずです。付かない場合は、指示が効いていないということなので、答え方の指示（Response instructions）を見直します。

### 5. データに無いことを聞く

```
視聴者の年収別にリーチを出せますか
```

このデータには年収の情報がありません。無いと答えるかどうかを見てください。推測で埋めてこないことが確認できれば、業務で使える前提が 1 つ満たされます。

## グラフを作らせる

`data_to_chart` という道具も持たせています。

```
局ごとの日別リーチを折れ線グラフにしてください
```

集計結果からグラフが作られます。

## 質問がうまく通らないとき

| 症状 | 見るところ |
|---|---|
| 道具の選び方を間違える | 道具の説明（Tools の Description）。何に使うか、何に使わないかを具体的に書く |
| 指標を取り違える | セマンティックビューの `WITH SYNONYMS`。呼び方の候補を増やす |
| 注意書きが付かない | 答え方の指示（Response instructions） |
| 番組名が当たらない | 検索サービスの本文。題名やジャンルも本文に含めているか |
| そもそも動かない | 既定のロールと既定のウェアハウス |

## この章で使ったクレジット

```sql
SELECT
  AGENT_NAME                     AS "エージェント",
  COUNT(*)                       AS "質問数",
  SUM(TOKENS)                    AS "トークン",
  ROUND(SUM(TOKEN_CREDITS), 4)   AS "クレジット"
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
WHERE START_TIME >= DATEADD('day', -1, CURRENT_TIMESTAMP())
GROUP BY AGENT_NAME;
```

CoWork から投げた質問はこのビューには入りません。CoWork の分は `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` に記録されます。同じエージェントでも入口によって記録先が違うので、費用を見るときは両方を見る必要があります。

## 次へ

[第 5 章 可視化アプリを作る](step5_app.md)
