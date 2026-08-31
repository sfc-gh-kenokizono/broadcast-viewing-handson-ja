# 第 2 章 dbt でデータを変換する

所要時間の目安 40 分

## 目的

生データから指標までのパイプラインを dbt で組み、Snowflake の中で動かします。

この章のいちばんの見どころは、**同じ生データから 3 通りの数字が出る**ことです。どの ID で数えるかによって答えが変わります。それを自分の手で確認します。

## dbt を Snowflake の中で動かすということ

dbt Core をお使いになったことがあれば、書くもの（`dbt_project.yml`、`profiles.yml`、`models/` 配下の SQL）はそのままです。違うのは動かす場所です。

| | dbt Core | Snowflake の中で動かす場合 |
|---|---|---|
| 実行環境 | 自分で用意した端末やサーバー | Snowflake が用意する。インストール不要 |
| 接続情報 | `profiles.yml` に account と user を書く | いまログインしている文脈で動くので不要 |
| 実行 | `dbt run` をコマンドで打つ | ワークスペースのボタン、または `EXECUTE DBT PROJECT` |
| スケジュール | 別途オーケストレーターを用意 | Snowflake のタスク |
| ライセンス料 | — | かかりません。ウェアハウスの使用料だけです |

## 1. 使うファイル

第 0 章で作ったワークスペースに、すでに入っています。左側の一覧の `dbt` フォルダがそれです。

**この章では新しくワークスペースを作りません。** 第 0 章で作ったものをそのまま使います。

## 2. プロジェクトの構成を見る

```
dbt/
├── dbt_project.yml                     層ごとのスキーマとマテリアライズの指定
├── profiles.yml                        接続設定
├── macros/
│   └── generate_schema_name.sql        スキーマ名の決め方の上書き
└── models/
    ├── staging/                        クレンジング
    │   └── stg_viewing_log.sql
    ├── intermediate/                   中間処理
    │   ├── int_device_identity.sql
    │   ├── int_viewing_program.sql
    │   ├── int_cm_contact.sql
    │   └── int_viewing_minutes.sql
    └── marts/                          指標のもとになるファクト
        ├── mart_device_daily.sql
        ├── mart_program_viewing.sql
        ├── mart_frequency.sql
        └── mart_zapping_transition.sql
```

### 何をもって「dbt プロジェクト」になるのか

ここが分かりにくいところなので、先に整理します。

**ワークスペースに「dbt 用」という種類はありません。** ワークスペースはただのファイル置き場です。dbt プロジェクトになるかどうかは、**中に置いてあるファイルで決まります**。

具体的には、次の 3 つが揃っているフォルダを Snowflake が dbt プロジェクトとして認識します。

| ファイル | 役割 |
|---|---|
| `dbt_project.yml` | プロジェクトの定義。これがある**フォルダ**がプロジェクトの単位になります |
| `profiles.yml` | 接続設定。どのロール、ウェアハウス、データベースで動かすか |
| `models/` の中の `.sql` | 変換の中身 |

このリポジトリの `dbt` フォルダには 3 つとも入っています。**つまり、取り込んだ時点ですでに dbt プロジェクトです。** 追加の変換作業はありません。

初期画面にある「dbt プロジェクト」ボタンとの違いは、次のとおりです。

| 入口 | 何が起きるか | 使う場面 |
|---|---|---|
| 「dbt プロジェクト」ボタン | `dbt_project.yml` などの**ひな形を新規作成**する | ゼロから作り始めるとき |
| From Git repository | リポジトリのファイルを取り込む。**その中に `dbt_project.yml` が入っていれば、そのまま dbt プロジェクト** | 既存のプロジェクトを持ち込むとき ← 今回 |

どちらの入口を通っても、行き着く先は「`dbt_project.yml` があるフォルダがワークスペースの中にある」という同じ状態です。**そのあとの動かし方も同じです。**

### 出てくる名前の整理

画面上に似た名前が並ぶので、先に区別しておきます。

| 何の名前か | 値 | どこに出るか |
|---|---|---|
| ワークスペース名 | `broadcast-viewing-handson-ja` | 画面左上。リポジトリを取り込んだ入れ物の名前 |
| **dbt プロジェクト名** | **`bcast_dbt`** | **操作パネルの Project セレクタ** |
| フォルダ名 | `dbt` | 左のファイル一覧 |
| プロファイル名 | `bcast` | `profiles.yml` の中。画面には出ません |
| ターゲット名 | `dev` | 操作パネルの Profile セレクタ |

dbt プロジェクト名は `dbt_project.yml` の `name` で決まります。`dbt_project.yml` の `models:` の下のキーも、この `name` と一致させる必要があります。ここがずれていると、層ごとのスキーマ指定が効きません。

```yaml
name: 'bcast_dbt'

models:
  bcast_dbt:          # name と同じにする
    staging:
      +schema: STG
```

> **`dbt` という名前は使えません**
>
> フォルダ名と合わせて `name: 'dbt'` にしたくなりますが、これは失敗します。
>
> ```
> dbt found more than one package with the name "dbt" included in this project.
> Package names must be unique in a project.
> ```
>
> dbt 自身が `dbt` という名前のパッケージを持っているため、衝突します。`dbt_utils` のような一般的な名前も避けたほうが安全です。**プロジェクト名には、そのプロジェクトを指す固有の名前を付けます。**

画面下部のバーに `dbt` と表示されていれば、Snowflake がプロジェクトを認識できています。

### 最初に見ていただきたい 2 つのファイル

**`profiles.yml`** — `account` と `user` が空文字になっています。ワークスペースで実行するときは、いまログインしているアカウントとユーザーの文脈でそのまま動くためです。

**`macros/generate_schema_name.sql`** — dbt の既定では、モデルにスキーマを指定すると「接続先のスキーマ名 + 指定した名前」という連結になります。接続先が `STG` でモデルに `MART` を指定すると `STG_MART` になってしまいます。ここでは指定した名前をそのまま使うように上書きしています。既存の dbt プロジェクトを持ち込むときに最初に書くことが多い上書きです。

### 依存パッケージについて

このプロジェクトには `packages.yml` を置いていません。外部のパッケージを使っていないので、`dbt deps` を実行する必要がなく、そのための外部通信の設定（ネットワークルールと外部アクセス統合）も要りません。

実際のプロジェクトで `dbt_utils` などを使う場合は、`dbt deps` を実行するために外部アクセス統合を 1 度だけ作り、dbt を実行するロールに使用権限を渡します。設定は 1 回で済み、以降は選ぶだけです。

## 3. その前に dbt は何をするツールなのか

操作の前に、これを押さえておくと迷いません。dbt がやることは 3 つです。

| # | やること | 具体的に |
|---|---|---|
| 1 | **SQL を組み立てる** | `{{ ref('stg_viewing_log') }}` のような書き方を、実際のテーブル名に置き換える |
| 2 | **実行の順序を決める** | 「A は B を参照している」という関係を読み取り、B → A の順に実行する |
| 3 | **できたものを検証する** | 「この列は NULL でない」などの宣言と、実際のデータを突き合わせる |

2 つめが dbt を使う最大の理由です。9 個のモデルの実行順序を人が管理する必要がありません。`ref()` と `source()` で「何を参照しているか」を書いておけば、**順序は dbt が決めます**。

### 作業の流れ

この 3 つに対応して、操作も 3 段階になります。

```
コンパイル  →  実行  →  テスト
（組み立て）   （作る）   （検証）
```

| 段階 | コマンド | 何をするか | データベースへの影響 |
|---|---|---|---|
| 1 | **コンパイル** | SQL を組み立てるだけ。`ref()` を実テーブル名に解決し、依存関係を確定させる | **なし。何も作りません** |
| 2 | **実行** | 組み立てた SQL を実際に実行し、ビューとテーブルを作る | ある |
| 3 | **テスト** | できたものが宣言どおりかを検証する | なし（SELECT するだけ） |

### なぜコンパイルを先にやるのか

**実行は時間とお金がかかりますが、コンパイルはほぼタダです。**

参照先の名前を間違えている、`ref()` の綴りが違う、循環参照になっている —— こうした間違いは、実行しなくても分かります。105 万行を処理し始めてから「モデル 7 個目で参照先の名前が違いました」と言われるより、先に落としたほうが早いです。

実務でも、CI（プルリクエストのたびに自動で検証する仕組み）ではまずコンパイルを走らせます。

### ビルドという選択肢

コマンド一覧に **ビルド** があります。これは**実行とテストを、依存関係の順にまとめてやる**ものです。

```
実行 → テスト        モデルを全部作ってから、テストを全部やる
ビルド              モデル A を作る → A をテスト → 通ったら B を作る → ...
```

違いは、**テストが落ちたときに下流を止めるかどうか**です。ビルドなら、おかしなモデルの上に次のモデルを積むことがありません。本番の運用ではビルドを使います。

出てくる件数もこれで説明がつきます。

| コマンド | 対象 | 件数 |
|---|---|---|
| 実行 | モデルだけ | 9 |
| テスト | テストだけ | 16 |
| ビルド | モデル＋テスト | **25** |

このハンズオンでは、何が起きているかを分けて見たいので、コンパイル・実行・テストを別々に実行します。

## 4. 操作パネルの場所

ワークスペースを開いた直後は「ワークスペースへようこそ」という案内画面が出ています。**この状態では dbt の操作パネルが出てきません。** エディタでファイルを開くと出てきます。

1. 左のファイル一覧で `dbt` → `models` → `staging` → `stg_viewing_log.sql` を開きます
2. **エディタの上**に、青いボタンと `∨`（下向き矢印）が現れます
3. `∨` を押すと「操作を選択」が開きます

### 操作の一覧

7 つ出てきます。dbt の元のコマンド名との対応です。

| 画面の表示 | 元のコマンド | 何をするか |
|---|---|---|
| **コンパイル** | `compile` | SQL を組み立てる。何も作らない |
| **実行** | `run` | モデルを作る |
| **テスト** | `test` | 宣言どおりかを検証する |
| **ビルド** | `build` | 実行とテストを依存順にまとめてやる |
| 再試行 | `retry` | 前回失敗したところから再開する |
| リスト | `list` | 対象になるモデルの一覧を出す |
| 表示 | `show` | クエリの結果を数行だけ覗く |

このハンズオンで使うのは上の 4 つです。**再試行**は、途中で失敗したときに最初からやり直さずに済むので、覚えておくと役に立ちます。

### ボタンのラベルで対象が分かります

ボタンには「**コンパイル ファイル**」のように、操作と**対象**が出ます。

| ラベル | 対象 |
|---|---|
| 「〜 ファイル」 | いま開いているファイル（1 モデルだけ） |
| 「〜 プロジェクト」 | プロジェクト全体（9 モデル） |

モデルのファイルを開いていると、対象はそのファイルになります。**プロジェクト全体を動かしたいときは、`dbt_project.yml` を開いた状態で操作してください。** 実行前にラベルを見て、意図した対象になっているか確認する習慣をつけると安全です。

### 結果を見る場所

**エディタの下**にタブがあります。

| タブ | 何が見えるか |
|---|---|
| **出力** | Snowflake 上で実行された命令（緑色）と、dbt の出力そのまま |
| **DAG** | モデルの依存関係の図 |

`dbt deps`（依存パッケージの取得）は不要です。このプロジェクトは外部パッケージを使っていないので、そのための外部通信の設定も要りません。

## 5. コンパイルして DAG を確認する

`dbt_project.yml` を開いた状態で、操作から **コンパイル** を選び、ボタンを押します。

出力タブに次のような行が出ます。

```
Found 9 models, 16 data tests, 11 sources
Completed successfully
```

**9 モデル・16 テスト・11 ソース**が認識されていれば成功です。ここで数が合わないなら、ファイルが欠けているか、置き場所が違います。

### DAG を開いて何を確認するのか

下のタブで **DAG** を選びます。左から右にデータが流れる図が出ます。

このハンズオンのモデルは次の形になっています。

```
RAW 11 テーブル
   │
   ├─ VIEWING_LOG_NW01〜05 ──→ stg_viewing_log ──┬──→ int_device_identity ──┐
   │                                              │                          ├──→ mart_device_daily
   │                                              │                          │
   │                                              ├──→ int_viewing_program ──┴──→ mart_program_viewing
   │                                              │
   │  CM_SPOT ─────────────────────────────────────┼──→ int_cm_contact ─────────→ mart_frequency
   │                                              │
   │                                              ├──→ mart_zapping_transition
   │                                              │
   │                                              └──→ int_viewing_minutes （下流なし）
```

確認したいことは 5 つあります。

**① 層の順序が意図どおりか**

生データ → `stg_` → `int_` → `mart_` の順に並んでいるか。逆流や飛び越しがないか。設計どおりに組めているかが一目で分かります。

**② `stg_viewing_log` に何本ぶら下がっているか**

数えると **6 本**（`int_` が 4 つ、`mart_zapping_transition`、`mart_device_daily`）です。

これは「**このモデルを直すと、下流の 6 個に影響する**」という意味です。クレンジングの条件をひとつ変えるだけで、リーチもフリークエンシーもザッピングも全部変わります。影響範囲がこうして見えるのが DAG の一番の使いどころです。

**③ `int_viewing_minutes` に下流がないこと**

図の右端が行き止まりになっています。**1 分単位に分解したテーブルは、どのマートからも参照されていません。**

これは意図的です。毎分の視聴推移のような指標を出すための素材として置いてあります。第 9 節で直接クエリして行数を確認します。

ただし実務では、この「行き止まり」は**確認すべき合図**です。12,117,641 行のテーブルを毎回作っていて、誰も使っていないなら、それは払う必要のないコストです。**DAG は使われていないモデルを見つける道具にもなります。** お客様の環境で最初に見る観点として使えます。

**④ ノードをクリックして SQL を開く**

四角をクリックすると、そのモデルの SQL が開きます。図から実装に飛べるので、「この数字はどこで作られているのか」を追うときに便利です。

**⑤ 組み立て後の SQL を見る**

SQL を開いた状態で、右上の **View Compiled SQL** を選びます。左右に並びます。

```
左（書いたもの）        from {{ ref('stg_viewing_log') }}
右（組み立て後）        from BCAST_VIEWING_HANDSON.STG.stg_viewing_log
```

`ref()` が実際のテーブル名に置き換わっています。**この置き換えが dbt の正体です。** 「テーブル名を直接書かない」というだけの仕組みで、依存関係の管理と環境の切り替えが両方できるようになります。

実行後にもう一度 DAG を開くと、各ノードに**前回の実行時間**が表示されます。どのモデルが遅いかを探すときに使います。

## 6. 実行する

### 6-1. 先にウェアハウスを LARGE にする 🚀

dbt は 9 個のモデルをまとめて作ります。待つだけの時間を短くするため、ここでは
**計算を担当するウェアハウスを、一時的に LARGE にします。**

左側のファイル一覧から `sql/step2a_dbt_scale_up.sql` を開き、**ファイル全体を実行**してください。

```text
XSMALL  = 小さな計算機。料金は低いが、重い処理では待ちやすい
LARGE   = 大きな計算機。料金は高いが、並列に計算できる量が多い
```

💡 **データは変わりません。** 大きさを変えるのは計算機だけです。テーブルをコピーしたり、
作り直したりする操作ではありません。

### 6-2. dbt を実行する

`dbt_project.yml` を開いた状態で、操作から **実行** を選び、ボタンを押します。

9 個のモデルが依存関係の順に作られます。処理中は出力タブを眺めながら待ちます。
実行時間はアカウントの状態によって変わるため、特定の秒数にならなくても問題ありません。

出力タブに、モデルごとの結果が順番に流れます。

```
1 of 9 START sql view model STG.stg_viewing_log .......... [RUN]
1 of 9 OK created sql view model STG.stg_viewing_log ..... [SUCCESS 1 in 2.31s]
...
Finished running 5 table models, 4 view models
Completed successfully
Done. PASS=9 WARN=0 ERROR=0 SKIP=0
```

**`PASS=9 ERROR=0`** が正解です。

> **どのロールで動くのか**
>
> 実行とビルドは、`profiles.yml` に書いたロールで動きます。このプロジェクトでは `BCAST_ENGINEER_ROLE` です。**画面右上で選んでいるロールではありません。**
>
> 第 1 章で自分自身に `BCAST_ENGINEER_ROLE` を付与しているので、そのまま動きます。付与していないと権限エラーになります。「画面のロールを変えたのに直らない」という詰まり方をするので、覚えておくとよい挙動です。

### モデル 1 つだけを実行する

モデルのファイルを開いた状態で再生ボタン（または `Cmd + Enter`）を押すと、そのモデルだけが実行されます（`dbt run --select <モデル名>` に相当）。ふつうの SQL ファイルとして実行されるのではありません。

1 つのモデルを直しながら試すときに使います。ただし**下流は作り直されない**ので、直したあとは全体を実行し直してください。

### できあがったものを確認する

ワークスペースの中に SQL ファイルを新規作成して実行してください。

```sql
SHOW VIEWS  IN SCHEMA BCAST_VIEWING_HANDSON.STG;
SHOW VIEWS  IN SCHEMA BCAST_VIEWING_HANDSON.INT;
SHOW TABLES IN SCHEMA BCAST_VIEWING_HANDSON.MART;
```

| スキーマ | できるもの | 数 |
|---|---|---|
| `STG` | ビュー | 1 |
| `INT` | ビュー 3 + テーブル 1（`int_viewing_minutes`） | 4 |
| `MART` | テーブル | 4 |

`STG` と `INT` は基本的にビューです。参照されたときに計算します。`MART` は可視化アプリやエージェントが繰り返し参照するので、計算結果を持たせています。`int_viewing_minutes` だけ `INT` でもテーブルにしているのは、1,212 万行の分解を毎回やり直すのが無駄だからです。

### マート層の粒度について

マート層はあらかじめ集計した表にしてありません。細かい粒度のまま持っています。

| モデル | 1 行が何を表すか |
|---|---|
| `mart_device_daily` | 1 台 × 1 日 × 1 局 |
| `mart_program_viewing` | 1 番組の放送回 × 1 台 |
| `mart_frequency` | 1 つのコマーシャル × 1 台 |
| `mart_zapping_transition` | 1 日 × 移動元の局 × 移動先の局 |

日別のリーチをあらかじめ計算して持っていないのは、そうすると**足せなくなる**からです。日別のリーチを月合計しようとして足し算すると、両方の日に見た人を 2 回数えてしまいます。

細かい粒度で持っておけば、リーチを「重複を除いて数える」形で定義できます。その定義を置く場所が第 3 章のセマンティックビューになります。

## 7. テストを実行する

`dbt_project.yml` を開いた状態で、操作から **テスト** を選び、ボタンを押します。

### テストは何をしているのか

`_staging.yml` `_intermediate.yml` `_marts.yml` に書いた宣言と、実際にできたデータを突き合わせます。**テスト用の SQL を書く必要はありません。** 宣言すると、dbt が検証用の SELECT を組み立てて実行します。

このプロジェクトで使っている宣言は 3 種類です。

| 宣言 | 意味 | 落ちるとどういうことか |
|---|---|---|
| `not_null` | 空の値がない | 名寄せキーが欠けている。集計から漏れる行がある |
| `unique` | 重複がない | 1 台のはずが複数行ある。台数を数えると多く出る |
| `accepted_values` | 決めた値以外が入っていない | 想定外の局コードが混ざっている。取り込みか変換の誤り |

全部で **16 件**です。出力タブに次のように出ます。

```
Finished running 16 data tests
Completed successfully
Done. PASS=16 WARN=0 ERROR=0 SKIP=0
```

**`PASS=16 ERROR=0`** が正解です。

### テストが終わったら XSMALL に戻す 💰

左側のファイル一覧から `sql/step2b_dbt_scale_down.sql` を開き、**ファイル全体を実行**してください。

```text
LARGEでdbtを短時間に処理 🚀
        ↓
終わったらXSMALLへ戻す 💰
```

この後のセマンティックビュー、AI、アプリの章は XSMALL で十分です。
戻し忘れてもデータは壊れませんが、必要以上に大きな計算機を使い続けることになります。

### とくに見てほしいテスト

`int_device_identity` の `COMMON_ID` に `unique` を付けてあります。名寄せが正しくできていれば、**1 台の受信機は 1 行**になっているはずです。

ここが落ちるということは、名寄せのロジックが間違っていて 1 台が複数行になっている、という意味です。**そのまま進めばリーチが実際より多く出ます。** 数字だけ見ていても気づけない誤りを、テストで止められます。

### テストが落ちたらどうするか

出力タブに、失敗したテストの名前と**確認用のクエリ**が出ます。そのクエリを SQL ファイルに貼って実行すると、問題のある行そのものが見えます。

「テストが通らない」ではなく「**どの行がおかしいか**」まで一気に降りられるのが、この仕組みの実用的なところです。

## 8. 同じデータから 3 通りの数字が出ることを確認する

ここがこの章の中心です。

```sql
WITH per_network AS (
  -- 局ごとに重複を除いて数えてから、それを足し合わせる
  SELECT NETWORK_NAME, COUNT(DISTINCT COMMON_ID) AS REACH_DEVICES
  FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY
  GROUP BY NETWORK_NAME
)
SELECT
  (SELECT SUM(VIEWING_SESSIONS)       FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY) AS "視聴区間の件数",
  (SELECT SUM(REACH_DEVICES)          FROM per_network)                                  AS "局ごとに数えた台数の合計",
  (SELECT COUNT(DISTINCT COMMON_ID)   FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY) AS "共通IDで数えた台数",
  (SELECT COUNT(DISTINCT IP_ADDRESS)  FROM BCAST_VIEWING_HANDSON.MART.MART_DEVICE_DAILY) AS "IPアドレスで数えた世帯数";
```

4 つの数字が出ます。左から右へ、順に小さくなります。

| 数え方 | 意味 |
|---|---|
| 視聴区間の件数 | 重複をまったく除いていない。いちばん多い |
| 局ごとに数えた台数の合計 | 局の中では重複を除いたが、局をまたいだ重複は残っている |
| 共通 ID で数えた台数 | 5 局横断で名寄せした受信機の台数 |
| IP アドレスで数えた世帯数 | 世帯の粒度。1 つの回線に複数台あるので、台数より少ない |

**局ごとに数えた台数を足し合わせた数字と、共通 ID で数えた台数の差**が、局をまたいだ重複です。各局が別々に数えた合計と、集約して数えた値がこれだけ違うということです。

### 各局 ID では名寄せできないことを確認する

```sql
SELECT
  COUNT(DISTINCT COMMON_ID)         AS "共通IDの数",
  COUNT(DISTINCT STATION_DEVICE_ID) AS "各局IDの数"
FROM BCAST_VIEWING_HANDSON.STG.STG_VIEWING_LOG;
```

各局 ID の数のほうが何倍も多くなります。同じ受信機でも局ごとに別の値が付いているためです。局から届いた ID をそのまま数えると、台数を大幅に多く見積もることになります。

### 1 つの IP アドレスに何台ぶら下がっているか

```sql
SELECT
  DEVICES_PER_IP        AS "同じ回線の台数",
  COUNT(*)              AS "IPアドレスの数"
FROM BCAST_VIEWING_HANDSON.INT.INT_DEVICE_IDENTITY
GROUP BY DEVICES_PER_IP
ORDER BY DEVICES_PER_IP;
```

1 台の回線がほとんどですが、2 台以上ある回線もあります。集合住宅で同じ回線を複数世帯が使っている状況に相当します。IP アドレスを世帯の代わりに使うと、この分がまとめて 1 世帯として数えられます。外部データとの突合に IP アドレスを使う場合は、この限界を織り込んでおく必要があります。

## 9. 局をまたいだチャンネル移動を見る

```sql
SELECT
  FROM_CHANNEL_CODE       AS "移動元",
  TO_CHANNEL_CODE         AS "移動先",
  SUM(TRANSITION_COUNT)   AS "移動回数"
FROM BCAST_VIEWING_HANDSON.MART.MART_ZAPPING_TRANSITION
GROUP BY FROM_CHANNEL_CODE, TO_CHANNEL_CODE
ORDER BY "移動回数" DESC
LIMIT 10;
```

「041 から 071 へ」のような、局をまたいだ移動が出てきます。

この数字は 1 局のデータだけでは絶対に出ません。各局は自局が見られている間のログしか取得できないので、移動先がどこだったかは自局には見えないためです。5 局分を共通 ID で束ねた `stg_viewing_log` を作ったからこそ計算できています。

## 10. 1 分単位に分解すると行数がどうなるか

```sql
SELECT
  (SELECT COUNT(*) FROM BCAST_VIEWING_HANDSON.STG.STG_VIEWING_LOG)   AS "分解前の行数",
  (SELECT COUNT(*) FROM BCAST_VIEWING_HANDSON.INT.INT_VIEWING_MINUTES) AS "分解後の行数",
  ROUND(
    (SELECT AVG(VIEW_MINUTES) FROM BCAST_VIEWING_HANDSON.STG.STG_VIEWING_LOG), 1
  ) AS "平均の視聴区間長（分）";
```

```
分解前の行数    1,050,000
分解後の行数   12,117,641
平均の視聴区間長   11.3 分
```

分解後の行数は、分解前の行数に平均の視聴区間長を掛けた値とほぼ一致します。**平均が M 分なら行数はおよそ M 倍**という関係です。

大事なのは次の 2 点です。

1. **事実は何も変わっていません**。同じ視聴を、区間で表すか分で表すかの違いだけです
2. **増えるのは変換後の層だけ**です。受け取る生データの量は変わりません

平均の視聴区間長が 30 分なら 30 倍、60 分なら 60 倍になります。実際の設計では、毎分の粒度が必要な指標だけを分解し、全件を常に分の形で持たないようにします。番組ごと、分ごと、属性ごとといった集計した単位まで縮約してから持てば、行数を抑えられます。

見積もりを立てるときは、生データの量ではなく、**どの指標のためにどこまで粒度を上げるか**が効いてきます。

## 11. 番組別の視聴実績を見る

```sql
SELECT
  PROGRAM_NAME                              AS "番組名",
  GENRE                                     AS "ジャンル",
  COUNT(DISTINCT COMMON_ID)                 AS "視聴台数",
  COUNT(DISTINCT IP_ADDRESS)                AS "視聴世帯数",
  ROUND(COUNT(DISTINCT IP_ADDRESS) * 2.2)   AS "推計視聴人数"
FROM BCAST_VIEWING_HANDSON.MART.MART_PROGRAM_VIEWING
GROUP BY PROGRAM_NAME, GENRE
ORDER BY "視聴台数" DESC
LIMIT 10;
```

視聴ログには番組 ID が入っていません。番組の放送枠と時刻の範囲で突き合わせて、あとから番組を割り当てています（`int_viewing_program`）。

推計視聴人数は、視聴世帯数に 1 世帯あたりの想定人数 2.2 を掛けた便宜的な値です。このデータには世帯の人数が入っていないためです。実際にはパネル調査などを正解データにして受信機ごとに人数と属性を割り当てる処理で求めますが、そこは差し替えられる 1 か所として単純な係数にしてあります。

## 12. リーチとフリークエンシーとインプレッション

```sql
SELECT
  ADVERTISER                                     AS "広告主",
  MIN(CAMPAIGN_FROM)                             AS "出稿開始",
  MAX(CAMPAIGN_TO)                               AS "出稿終了",
  COUNT(DISTINCT COMMON_ID)                      AS "リーチ",
  ROUND(SUM(CONTACT_COUNT) / COUNT(DISTINCT COMMON_ID), 2) AS "フリークエンシー",
  SUM(CONTACT_COUNT)                             AS "インプレッション"
FROM BCAST_VIEWING_HANDSON.MART.MART_FREQUENCY
GROUP BY ADVERTISER
ORDER BY "インプレッション" DESC
LIMIT 10;
```

この 3 つは独立した指標ではありません。

```
リーチ × 平均フリークエンシー = インプレッション
```

3 つのうち 2 つが決まれば残りが決まる関係です。上の結果で掛け算して確かめてみてください。

ここで注意が 1 つあります。**フリークエンシーの分母は接触した台数**です。全台数（2 万台）で割ってしまうと、接触していない台を分母に入れることになり、上の関係式が成り立ちません。

また、放送の接触は**推定値**です。「誰がコマーシャルを見たか」というログは存在しないので、視聴区間にスポットの放送時刻が入っていたかで判定しています。席を外していても接触として数えます。この数字を社外に出すときには、必ず断り書きが必要になります。

### 出稿期間で絞ってみる

コマーシャルには 2 週間から 4 週間の出稿期間があります。`CAMPAIGN_FROM` と `CAMPAIGN_TO` で絞れば、キャンペーン単位の数字になります。実務で広告主に返すのはこの形です。

## 13. 属性が分かっている範囲だけの集計

```sql
SELECT
  GENDER_AGE_SEGMENT        AS "セグメント",
  GENRE                     AS "ジャンル",
  COUNT(DISTINCT COMMON_ID) AS "リーチ台数"
FROM BCAST_VIEWING_HANDSON.MART.MART_PROGRAM_VIEWING
WHERE GENDER_AGE_SEGMENT IS NOT NULL
GROUP BY GENDER_AGE_SEGMENT, GENRE
ORDER BY GENDER_AGE_SEGMENT, "リーチ台数" DESC;
```

属性が分かっているのが全体の何割なのかを確かめておきます。

```sql
SELECT
  COUNT(*)                                              AS "全端末",
  COUNT_IF(GENDER_AGE_SEGMENT IS NOT NULL)              AS "属性が分かる端末",
  ROUND(COUNT_IF(GENDER_AGE_SEGMENT IS NOT NULL) * 100.0
        / COUNT(*), 1)                                  AS "割合（％）"
FROM BCAST_VIEWING_HANDSON.INT.INT_DEVICE_IDENTITY;
```

セグメントによって、よく見られているジャンルが違うことが分かります。

ただしこれは属性が分かっている 10 パーセントの中での傾向です。全体の姿ではありません。全体に属性を広げるには、この 10 パーセントを正解データにして残りの 90 パーセントを推定する処理が必要になります。そこは別のテーマなので、この教材では分かっている範囲だけを集計しています。

この割合を先に見ておくのは、さっきの数字が何割を見たものなのかを取り違えないようにするためです。

## 14. この章で使ったクレジット

```sql
SELECT
  ROUND(SUM(TOTAL_ELAPSED_TIME) / 1000, 1)  AS "合計秒数",
  COUNT(*)                                  AS "クエリ数",
  ROUND(SUM(BYTES_SCANNED) / POWER(1024, 3), 3) AS "スキャンしたGB"
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE WAREHOUSE_NAME = 'BCAST_HANDSON_WH'
  AND START_TIME >= DATEADD('hour', -2, CURRENT_TIMESTAMP());
```

## 任意 スケジュール実行を設定する

所要時間の目安 10 分

「Snowflake でのスケジューラーは何にあたるのか」への答えがここです。作った dbt プロジェクトを Snowflake のオブジェクトとして登録し、タスクで定期実行します。

### プロジェクトを登録する

1. エディタ右側の Connect から Deploy dbt project を選びます
2. データベースは `BCAST_VIEWING_HANDSON`、スキーマは `MART` を選びます
3. Create dbt Object を選び、名前を `BCAST_DBT_PROJECT` にして Deploy を選びます

出力タブに、実行された SQL が表示されます。

```sql
create or replace DBT PROJECT "BCAST_VIEWING_HANDSON"."MART"."BCAST_DBT_PROJECT"
  from snow://workspace/...
```

### スケジュールを作る

1. Connect のメニューから Create schedule を選びます
2. 名前を `RUN_BCAST_DBT`、頻度を毎日 6 時などに設定します
3. Operation は `run`、Profile は `dev` を選び、Create を選びます

作られたタスクの定義を見てみてください。

```sql
CREATE OR REPLACE TASK BCAST_VIEWING_HANDSON.MART.RUN_BCAST_DBT
  WAREHOUSE = BCAST_HANDSON_WH
  SCHEDULE = 'USING CRON 0 6 * * * Asia/Tokyo'
AS
  EXECUTE DBT PROJECT BCAST_DBT_PROJECT ARGS='run --target dev';
```

やっていることは「決めた時刻に dbt を実行する」だけです。オーケストレーターを別に用意する必要はありません。

作ったタスクは既定で停止状態です。動かす場合は次を実行します。今日のところは設定を確認するだけで、実行しなくてかまいません。

```sql
ALTER TASK BCAST_VIEWING_HANDSON.MART.RUN_BCAST_DBT RESUME;
```

止めるときは次のとおりです。

```sql
ALTER TASK BCAST_VIEWING_HANDSON.MART.RUN_BCAST_DBT SUSPEND;
```

## 次へ

[第 3a 章 セマンティックビューと検索サービス](step3a_semantic.md)
