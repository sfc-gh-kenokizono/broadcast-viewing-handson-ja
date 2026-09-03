# 第 6 章 アクセス権とマスキング

所要時間の目安 15 分

## 目的

決めたアクセス権を Snowflake でどう表すかを確認します。

5 つの局からデータを集める仕組みでは、誰が何を見られるかが技術の話より先に決まっていることがあります。この章で見るのは、その決めごとをどう実装するかです。

## 使うファイル

`sql/step6_rbac.sql`

ワークスペースの左側の一覧から `sql` フォルダを開き、このファイルを選んでファイル全体を実行します。コピーと貼り付けは必要ありません。権限がないことは、意図的なエラーではなく権限一覧で確認するため、途中で止まりません。

## 1. 層でアクセス権を分ける

第 1 章で 2 つのロールを作りました。

| ロール | 見られる層 |
|---|---|
| `BCAST_ENGINEER_ROLE` | `RAW` / `STG` / `INT` / `MART` すべて |
| `BCAST_ANALYST_ROLE` | `MART` だけ |

### 先に副ロールを切っておく

ここで 1 つ大事な前置きがあります。

Snowflake のユーザーには**副ロール**という設定があり、既定では使えるロールすべてが副ロールとして有効になっています。この状態だと `USE ROLE` でロールを切り替えても、元のロールの権限がセッションに残ります。つまり `ACCOUNTADMIN` を持っている人が `BCAST_ANALYST_ROLE` に切り替えても、生データが見えたままになります。

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
USE ROLE BCAST_ANALYST_ROLE;
USE SECONDARY ROLES NONE;

SELECT CURRENT_ROLE() AS "主ロール", CURRENT_SECONDARY_ROLES() AS "副ロール";
```

副ロールが空になっていれば、以降の確認が意図どおりに動きます。

これは実務でも引っかかるところです。ポリシーを当てたのに効いていないように見えるとき、実際には副ロールの権限で見えているだけ、ということがよくあります。

### 確かめる

```sql
-- 集計データは見られる
SELECT COUNT(*) FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY;

-- 権限一覧を確認する
SHOW GRANTS TO ROLE BCAST_ANALYST_ROLE;
```

結果に `MART` の権限はありますが、`RAW`、`STG`、`INT` の権限はありません。実際に生データを `SELECT` すると権限エラーになりますが、ハンズオンを途中停止させないため、このファイルではエラーを起こさず権限一覧で確認します。

### セマンティックビューは別扱い

同じ `BCAST_ANALYST_ROLE` でも、セマンティックビューは参照できます。

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
GRANT SELECT, REFERENCES ON SEMANTIC VIEW ... TO ROLE BCAST_ANALYST_ROLE;
```

生データには一切触れられないロールでも、決めた指標だけは見られる。この形が作れることが、指標の定義を Snowflake 側に置いておく利点のひとつになります。

## 2. IP アドレスに伏せ字をかける

IP アドレスは外部のデータと突き合わせるための鍵になる一方で、そのまま外に出すべきものではありません。

列ごとに「誰が見たら何が見えるか」を決めるのがマスキングポリシーです。

```sql
CREATE OR REPLACE MASKING POLICY MASK_IP_ADDRESS AS (VAL VARCHAR)
  RETURNS VARCHAR ->
    CASE
      WHEN IS_ROLE_IN_SESSION('BCAST_ENGINEER_ROLE') THEN VAL
      ELSE REGEXP_REPLACE(VAL, '\\.[0-9]+$', '.*')
    END;

ALTER TABLE MART_DEVICE_DAILY MODIFY COLUMN IP_ADDRESS SET MASKING POLICY MASK_IP_ADDRESS;
```

作るのが 1 つ、当てるのが 1 行です。アプリ側もクエリ側も何も書き換えていません。

### 効き方を見る

```sql
USE ROLE BCAST_ENGINEER_ROLE;
SELECT IP_ADDRESS FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY LIMIT 5;
-- 192.0.2.145 のようにそのまま見える

USE ROLE BCAST_ANALYST_ROLE;
SELECT IP_ADDRESS FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY LIMIT 5;
-- 192.0.2.* のように末尾が隠れる
```

末尾だけを隠しているので、地域の傾向は見えますが、回線を特定することはできません。何をどこまで隠すかは要件によります。

### 台数の集計は変わらない

```sql
SELECT COUNT(DISTINCT COMMON_ID) FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY;
```

伏せ字がかかっていても、`COMMON_ID` で台数を数える処理は同じ値を返します。データそのものは変わっていないためです。一方、マスク後の `IP_ADDRESS` は複数の値が同じ表示にまとまるため、`COUNT(DISTINCT IP_ADDRESS)` を回線数として使うことはできません。

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

各局には自局のデータだけを見せたい、という要件が出てくることがあります。行ごとに見える見えないを決めるのが行アクセスポリシーです。BI ツール側で行レベルの絞り込みをかけるのと同じ役割ですが、データの側に付けておけば、どのツールから読んでも SQL を直接打っても同じように効きます。

スクリプトの該当箇所はコメントにしてあります。時間に余裕があるときだけ外して実行してください。

やっていることは 3 つです。

1. 局ごとの担当ロールを作る
2. どのロールがどの局を見られるかの対応表を作る
3. その対応表を見て判定するポリシーをテーブルに当てる

```sql
CREATE OR REPLACE ROW ACCESS POLICY RAP_NETWORK AS (ROW_NETWORK_ID VARCHAR)
  RETURNS BOOLEAN ->
    IS_ROLE_IN_SESSION('BCAST_ENGINEER_ROLE')
    OR IS_ROLE_IN_SESSION('BCAST_ANALYST_ROLE')
    OR EXISTS (
      SELECT 1 FROM NETWORK_ACCESS_MAP m
      WHERE m.NETWORK_ID = ROW_NETWORK_ID
        AND IS_ROLE_IN_SESSION(m.ROLE_NAME)
    );

ALTER TABLE MART_DEVICE_DAILY ADD ROW ACCESS POLICY RAP_NETWORK ON (NETWORK_ID);
```

この任意デモでは `BCAST_NW01_VIEWER` に `MART_DEVICE_DAILY` だけを付与します。RAPを当てていない別のMART表を付与すると、そちらから全局分が見えるためです。対応表を別に持たせているので、局が増えたときはポリシーを書き換えず表に1行追加できます。

同じクエリを 2 つのロールで実行すると、返ってくる局の数が変わります。

```sql
USE ROLE BCAST_ANALYST_ROLE;      -- 5 局すべて
USE SECONDARY ROLES NONE;
USE ROLE BCAST_NW01_VIEWER;       -- 1 局だけ
USE SECONDARY ROLES NONE;
```

## 4. データシェアで集計データを別アカウントへ見せる（任意・2 人で）

局から基盤へ、基盤から広告会社へ。データを渡すたびにコピーを作って送ると、同じデータが何か所にも増え、更新のたびに配り直しが必要になります。Snowflake のデータシェアは、コピーを作らずに「見る権利」だけを渡します 🤝

隣の人とペアになって試します。スクリプトの該当箇所はコメントにしてあります。

```text
🅰 提供する人                                 🅱 受け取る人
CREATE SHARE BCAST_MART_SHARE;                 SHOW SHARES;            ← 🅰 のシェアが見える
GRANT USAGE / SELECT ... TO SHARE ...;         CREATE DATABASE BCAST_FROM_PARTNER
ALTER SHARE ... ADD ACCOUNTS = 🅱;               FROM SHARE <🅰の組織名>.<🅰のアカウント名>.BCAST_MART_SHARE;
                                               SELECT ... FROM BCAST_FROM_PARTNER.MART....  ← 見えた
```

**同じ名前のデータベースを全員が持っていても大丈夫です。** 受け取る側は `CREATE DATABASE <好きな名前> FROM SHARE ...` で自分で別の名前を付けるので、自分の `BCAST_VIEWING_HANDSON` とはぶつかりません。

手順は 3 つです。

1. 両者が `CURRENT_ORGANIZATION_NAME()` と `CURRENT_ACCOUNT_NAME()` で自分の識別子を確認して相手に伝える
2. 🅰 がシェアを作り、MART スキーマのテーブルだけを入れて、🅱 のアカウントを追加する
3. 🅱 が `SHOW SHARES` で確認し、別名でデータベースにして `SELECT` する

**確かめてほしいこと**

- 🅰 が `GRANT ... TO SHARE` したとき、データは 1 バイトも動いていません。🅱 が読むときも 🅰 のストレージを直接読んでいます
- 🅰 が dbt を再実行してマートを更新すると、🅱 にもそのまま反映されます。配り直しはありません。ただし dbt はテーブルを作り直すので、再実行のあとは `GRANT SELECT ON ALL TABLES IN SCHEMA ... TO SHARE` をもう一度流してください（第 6 章のポリシーと同じ注意です）
- 🅱 の画面では、自分の `BCAST_VIEWING_HANDSON` と相手の `BCAST_FROM_PARTNER` が並んで見えます
- 🅱 は読み取り専用です。相手のデータを書き換えることはできません

**条件**

- 2 つのアカウントが同じクラウド・同じリージョンにあること（AWS 東京同士であればトライアル同士でもできます）。別リージョンの相手にはリスティングとレプリケーションを使います
- 共有できるのはテーブルとセキュアビューです。普通のビューは入れられません。この教材では MART のテーブルだけを共有します
- 両者とも `ACCOUNTADMIN` で実行します

局 → 基盤（各局が視聴ログを共有する）も、基盤 → 広告会社（マートだけを共有する）も、この同じ仕組みで置き換えられます。役割を入れ替えてもう一度やると、両方向を体験できます。

終わったら 🅱 は `DROP DATABASE BCAST_FROM_PARTNER`、🅰 は `DROP SHARE BCAST_MART_SHARE` で片付けます。

## 覚えておきたいこと

### ポリシーはテーブルを作り直すと外れる

マスキングポリシーと行アクセスポリシーは、列やテーブルに紐づいています。**テーブルを作り直すと外れます。**

このプロジェクトのMARTはテーブルとして作り直すため、通常の `dbt run` でもポリシーが外れる可能性があります。dbtを再実行したあとは、ポリシーが残っているか必ず確認します。

実運用では、モデルを作り直したあとにポリシーを当て直す処理をパイプラインの最後に入れておきます。dbt の `post-hook` に書くのがひとつの方法です。

```yaml
models:
  bcast_dbt:
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
