# 第 6 章 アクセス権とマスキング

所要時間の目安 15 分

## 目的

決めたアクセス権を Snowflake でどう表すかを確認します。

5 つの局からデータを集める仕組みでは、誰が何を見られるかが技術の話より先に決まっていることがあります。この章で見るのは、その決めごとをどう実装するかです。

## 使うファイル

`sql/step6_rbac.sql`

ワークスペースの左側の一覧から `sql` フォルダを開き、このファイルを選んで上から順に実行します。コピーと貼り付けは必要ありません。

## 1. 層でアクセス権を分ける

第 1 章で 2 つのロールを作りました。

| ロール | 見られる層 |
|---|---|
| `BCAST_ENGINEER` | `RAW` / `STG` / `INT` / `MART` すべて |
| `BCAST_ANALYST` | `MART` だけ |

### 先に副ロールを切っておく

ここで 1 つ大事な前置きがあります。

Snowflake のユーザーには**副ロール**という設定があり、既定では使えるロールすべてが副ロールとして有効になっています。この状態だと `USE ROLE` でロールを切り替えても、元のロールの権限がセッションに残ります。つまり `ACCOUNTADMIN` を持っている人が `BCAST_ANALYST` に切り替えても、生データが見えたままになります。

自分の設定を確認します。

```sql
USE ROLE ACCOUNTADMIN;
SET my_user = (SELECT CURRENT_USER());
SHOW USERS;
SELECT "name", "default_secondary_roles"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "name" = $my_user;
```

`["ALL"]` と表示されたら、すべてのロールが副ロールとして有効です。権限の効き方を確かめるときは、副ロールを切ってください。

```sql
USE ROLE BCAST_ANALYST;
USE SECONDARY ROLES NONE;

SELECT CURRENT_ROLE() AS "主ロール", CURRENT_SECONDARY_ROLES() AS "副ロール";
```

副ロールが空になっていれば、以降の確認が意図どおりに動きます。

これは実務でも引っかかるところです。ポリシーを当てたのに効いていないように見えるとき、実際には副ロールの権限で見えているだけ、ということがよくあります。

### 確かめる

```sql
-- 集計データは見られる
SELECT COUNT(*) FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY;

-- 生データは見られない
SELECT COUNT(*) FROM BCAST_VIEWING_HANDSON.RAW.VIEWING_LOG_NW01;
```

2 つめはエラーになります。メッセージは「存在しないか権限がありません」という書き方です。権限がないことと、そもそも存在しないことが区別されません。これは意図的な仕様で、見えてはいけないものについては、あるかないかも分からないほうが安全という考え方です。

### セマンティックビューは別扱い

同じ `BCAST_ANALYST` でも、セマンティックビューは参照できます。

```sql
SELECT * FROM SEMANTIC_VIEW(
  BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING
  METRICS device_daily.reach_devices
  DIMENSIONS device_daily.network_name
);
```

セマンティックビューを参照するとき、元になっているテーブルへの権限は必要ありません。セマンティックビューへの権限だけで足ります。

これは第 3 章で 1 行渡しただけの結果です。

```sql
GRANT SELECT, REFERENCES ON SEMANTIC VIEW ... TO ROLE BCAST_ANALYST;
```

生データには一切触れられないロールでも、決めた指標だけは見られる。この形が作れることが、指標の定義を Snowflake 側に置いておく利点のひとつになります。

## 2. IP アドレスに伏せ字をかける

IP アドレスは外部のデータと突き合わせるための鍵になる一方で、そのまま外に出すべきものではありません。

列ごとに「誰が見たら何が見えるか」を決めるのがマスキングポリシーです。

```sql
CREATE OR REPLACE MASKING POLICY MASK_IP_ADDRESS AS (VAL VARCHAR)
  RETURNS VARCHAR ->
    CASE
      WHEN IS_ROLE_IN_SESSION('BCAST_ENGINEER') THEN VAL
      ELSE REGEXP_REPLACE(VAL, '\\.[0-9]+$', '.*')
    END;

ALTER TABLE MART_DEVICE_DAILY MODIFY COLUMN IP_ADDRESS SET MASKING POLICY MASK_IP_ADDRESS;
```

作るのが 1 つ、当てるのが 1 行です。アプリ側もクエリ側も何も書き換えていません。

### 効き方を見る

```sql
USE ROLE BCAST_ENGINEER;
SELECT IP_ADDRESS FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY LIMIT 5;
-- 192.0.2.145 のようにそのまま見える

USE ROLE BCAST_ANALYST;
SELECT IP_ADDRESS FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY LIMIT 5;
-- 192.0.2.* のように末尾が隠れる
```

末尾だけを隠しているので、地域の傾向は見えますが、回線を特定することはできません。何をどこまで隠すかは要件によります。

### 集計は変わらない

```sql
SELECT COUNT(DISTINCT COMMON_ID) FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY;
```

伏せ字がかかっていても、台数を数える処理は同じ値を返します。見せ方を変えただけで、データそのものは変わっていないためです。

### どこに当たっているかを確認する

```sql
SELECT POLICY_NAME, REF_ENTITY_NAME, REF_COLUMN_NAME
FROM TABLE(
  BCAST_VIEWING_HANDSON.INFORMATION_SCHEMA.POLICY_REFERENCES(
    POLICY_NAME => 'BCAST_VIEWING_HANDSON.MART.MASK_IP_ADDRESS'
  )
);
```

ポリシーが増えてきたときに、どこに何が当たっているかを追えるようにしておくのが実務では大事になります。

## 3. 局ごとに見える行を分ける（任意）

各局には自局のデータだけを見せたい、という要件が出てくることがあります。行ごとに見える見えないを決めるのが行アクセスポリシーです。

スクリプトの該当箇所はコメントにしてあります。時間に余裕があるときだけ外して実行してください。

やっていることは 3 つです。

1. 局ごとの担当ロールを作る
2. どのロールがどの局を見られるかの対応表を作る
3. その対応表を見て判定するポリシーをテーブルに当てる

```sql
CREATE OR REPLACE ROW ACCESS POLICY RAP_NETWORK AS (NETWORK_ID VARCHAR)
  RETURNS BOOLEAN ->
    IS_ROLE_IN_SESSION('BCAST_ENGINEER')
    OR IS_ROLE_IN_SESSION('BCAST_ANALYST')
    OR EXISTS (
      SELECT 1 FROM NETWORK_ACCESS_MAP m
      WHERE m.NETWORK_ID = NETWORK_ID
        AND IS_ROLE_IN_SESSION(m.ROLE_NAME)
    );

ALTER TABLE MART_DEVICE_DAILY ADD ROW ACCESS POLICY RAP_NETWORK ON (NETWORK_ID);
```

対応表を別に持たせているところが要点です。局が増えたときにポリシーを書き換える必要がなく、表に 1 行足すだけで済みます。

同じクエリを 2 つのロールで実行すると、返ってくる局の数が変わります。

```sql
USE ROLE BCAST_ANALYST;      -- 5 局すべて
USE ROLE BCAST_NW01_VIEWER;  -- 1 局だけ
```

## 覚えておきたいこと

### ポリシーはテーブルを作り直すと外れる

マスキングポリシーと行アクセスポリシーは、列やテーブルに紐づいています。**テーブルを作り直すと外れます。**

ふだんの `dbt run` はテーブルの中身を入れ替えるだけなので残りますが、`dbt run --full-refresh` のようにテーブルそのものを作り直すと外れます。

実運用では、モデルを作り直したあとにポリシーを当て直す処理をパイプラインの最後に入れておきます。dbt の `post-hook` に書くのがひとつの方法です。

```yaml
models:
  bcast_viewing:
    marts:
      +post-hook:
        - "ALTER TABLE {{ this }} MODIFY COLUMN IP_ADDRESS SET MASKING POLICY ..."
```

ここを忘れると、パイプラインを直したつもりで伏せ字が外れているという事故につながります。ポリシーを当てたら、当て直しの処理も同時に用意しておくのが安全です。

### 副ロールを切らないと効いていないように見える

上でも触れましたが、実務で最も引っかかるのがここです。既定では使えるロールすべてが副ロールとして有効なので、`USE ROLE` で切り替えても前の権限が残ります。

ポリシーを当てたのに効かない、と思ったときは次の順で確認してください。

1. `CURRENT_SECONDARY_ROLES()` で副ロールが空かどうか
2. `POLICY_REFERENCES` でポリシーが目的の列に当たっているか
3. ポリシーの条件式（`IS_ROLE_IN_SESSION` は副ロールも含めて判定します）

## ハンズオンはここまでです

## 後片付け

[sql/cleanup.sql](../sql/cleanup.sql) を実行すると、作成したオブジェクトをすべて削除します。

環境を残しておきたい場合は、次の 2 つだけ止めておくと課金が抑えられます。

```sql
ALTER CORTEX SEARCH SERVICE BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META SUSPEND;
ALTER WAREHOUSE BCAST_HANDSON_WH SUSPEND;
```

検索サービスは索引を保持している間ずっと少しずつ課金されるので、使わない期間は止めておくのが無駄がありません。
