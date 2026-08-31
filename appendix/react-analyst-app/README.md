# 付録: 放送視聴データ アナリストコンソール（React + Cortex Analyst REST API）

放送視聴データハンズオンの **付録** です。ハンズオン本編では実行しません。

## これは何か

Cortex Analyst の REST API を直接呼び出して、セマンティックビューに日本語で質問し、
**生成された SQL とその実行結果を自作のフロントエンドに描画する** Web アプリです。

Snowflake App Runtime（`APPLICATION SERVICE`）上で動く Next.js アプリとして構成しています。

このアプリが示したいのは次の 1 点です。

> BI ツールの UI を使わず、**セマンティックレイヤーだけを API で取得して、フロントエンドは自作する**
> という構成が Snowflake で成立する。

セマンティックビューに「リーチ台数とは何か」「フリークエンシーとは何か」という定義を 1 か所で持たせ、
アプリ側は SQL を書きません。質問文を投げて、返ってきた SQL と結果を描画するだけです。
同じセマンティックビューを Snowsight / Snowflake Intelligence / このアプリの 3 か所から
参照しても、指標の定義は 1 つに保たれます。

## 画面の構成

| 要素 | 内容 |
|------|------|
| 質問入力欄 | 日本語の自然言語で質問を入力 |
| サンプル質問ボタン | よく使う 5 つの質問をワンクリックで実行 |
| 回答 | Cortex Analyst が「質問をどう解釈したか」を説明するテキスト |
| 生成された SQL | 折りたたみ表示。コピーボタン付き |
| グラフ | 結果セットから X 軸（カテゴリ列）と Y 軸（数値列）を自動推定して描画 |
| 結果テーブル | 実行結果の全列・全行（上限 500 行） |

質問が曖昧で Analyst が SQL を生成できなかった場合は、代替の質問候補が
クリック可能なリンクとして表示されます。

## 前提

Snowflake 側に以下が作成済みであること（ハンズオン本編の SQL で作成されます）。

| 種別 | 名前 |
|------|------|
| セマンティックビュー | `BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING` |
| 検索サービス | `BCAST_VIEWING_HANDSON.MART.SVC_PROGRAM_CM_META` |
| ウェアハウス | `BCAST_HANDSON_WH` |
| ロール | `BCAST_ANALYST_ROLE` |

必要な権限:

- Cortex Analyst を使うための権限（`SNOWFLAKE.CORTEX_USER` データベースロール）
- セマンティックビューへの `SELECT`、およびその参照先テーブルへの `SELECT`
- ウェアハウスへの `USAGE`

## セットアップ

### 1. 依存関係のインストール

```bash
cd appendix/react-analyst-app
npm install
```

初回の `npm install` で `package-lock.json` が生成されます。これをコミットしたら、
`app.yml` の install コマンドを再現性の高い `["npm", "ci", "--include=dev"]` に
切り替えることを推奨します。

### 2. ローカル開発

```bash
npm run dev
```

Snowflake の認証情報は `~/.snowflake/config.toml` の既定接続から自動的に読まれます。
`snow` CLI を設定済みなら追加設定は不要です。特定の接続を使う場合:

```bash
SNOWFLAKE_CONNECTION_NAME=my_connection npm run dev
```

起動後、dev サーバーの出力に表示されたポート（3000 が使用中の場合は自動で繰り上がります）
にブラウザでアクセスしてください。

オブジェクト名を変えた場合は、コードを編集せず `.env.local` で差し替えられます。

```bash
# .env.local
BCAST_SEMANTIC_VIEW=MY_DB.MY_SCHEMA.MY_SEMANTIC_VIEW
BCAST_WAREHOUSE=MY_WH
BCAST_CALLERS_RIGHTS=false
```

### 3. デプロイ

`snowflake.yml` は `snow app setup` で生成しています。**そのままでは動きません** ——
生成時に参照したアカウントのパラメータが入っているため、デプロイ先に合わせて
次の 3 つを確認・修正してください。

```yaml
entities:
  react_analyst_app:
    identifier:
      database: APPS          # ← アプリを作成するデータベースに変更
      schema: PUBLIC          # ← スキーマに変更
    query_warehouse: APP_WAREHOUSE   # ← 例: BCAST_HANDSON_WH に変更
```

修正したらデプロイします。

```bash
snow app deploy --verbose
```

完了すると `.snowflakecomputing.app` のエンドポイント URL が表示されます。
以降の運用コマンド:

```bash
snow app open          # ブラウザで開く
snow app events        # アプリのログを見る（MONITOR 権限が必要）
snow app teardown --force   # アプリを削除する
```

## Cortex Analyst API の呼び出し方

サーバーサイド（`app/api/analyst/route.ts`）だけが Snowflake と通信します。

```
POST {account_url}/api/v2/cortex/analyst/message
```

リクエストボディ（`lib/analyst.ts`）:

```json
{
  "messages": [
    { "role": "user", "content": [{ "type": "text", "text": "局ごとのリーチ台数を多い順に教えて" }] }
  ],
  "semantic_view": "BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING"
}
```

レスポンスの `message.content[]` を走査して取り出します。

| `type` | 取り出すフィールド | 用途 |
|--------|-------------------|------|
| `text` | `text` | 解釈の説明文 |
| `sql` | `statement` | 生成された SQL |
| `suggestions` | `suggestions` | 質問が曖昧なときの代替質問候補 |

`stream` は送っていないため非ストリーミング応答です（1 回の JSON で完結するので
SSE の組み立てが不要）。処理の流れは 2 段階です。

1. Analyst に質問して SQL を生成させる（REST API）
2. 生成された SQL を Snowflake で実行して結果を返す（Node.js ドライバ）

## 認証

コードに秘密情報は一切持ちません。

| 実行環境 | 認証方法 |
|----------|----------|
| App Runtime（SPCS）上 | `/snowflake/session/token` のサービストークンを `Bearer` として送信。`X-Snowflake-Authorization-Token-Type: OAUTH` を併送 |
| ローカル開発 | `~/.snowflake` の既定接続（`snow` CLI の設定）を使用 |

いずれも `lib/snowflake.ts` の `getRestApiAuthHeader()` / `getSnowflakeBaseUrl()` が
環境を自動判定します。

既定では、Analyst の呼び出しも SQL の実行も **オーナー権限**（アプリのサービス ID）です。
行アクセスポリシーやマスキングポリシーを効かせたい場合は、`BCAST_CALLERS_RIGHTS=true`
にすると **SQL の実行のみ** 呼び出しユーザーの権限で行われます。この場合、
アプリのオーナーロールに caller grants が必要です。

## 注意点

- **これは付録です。** ハンズオン本編の所要時間には含まれていません。
- **セマンティックビューの品質がそのまま回答品質になります。** 期待した SQL が
  生成されない場合は、アプリではなくセマンティックビュー側（synonym、
  メトリックの説明、検証済みクエリ）を改善してください。
- **生成された SQL は読み取り専用チェックを通してから実行しています。**
  `SELECT` / `WITH` 以外、および複文は実行を拒否します（`app/api/analyst/route.ts`）。
- **結果は 500 行、グラフは先頭 30 件まで** に制限しています。
- **グラフは `ComposedChart` を使っています。** Recharts の `AreaChart` / `BarChart` は
  子要素の `<Line>` を警告なく無視するため、棒と線を混在させる場合は
  `ComposedChart` が必須です。
- **`next.config.mjs` の `turbopack.root` / `outputFileTracingRoot` は外さないでください。**
  Next.js が親ディレクトリのロックファイルを見つけてワークスペースルートを
  再解決すると、`/` が 404 になりチャンク URL が壊れます。
- **standalone 出力の注意。** `node .next/standalone/server.js` をローカルで直接実行しないでください。
  standalone サーバーは `.next/static` と `public` を配信しないため、
  スタイルが当たらず全アセットが 404 になります（コンソールに分かりやすい
  エラーが出ないため気づきにくい）。ローカルでは `npm run dev` または
  `npm run start` を使ってください。App Runtime へのデプロイ時は
  `snow app deploy` がこのコピーを行います。
- **局名は架空です。** データに登場する「第一放送ネットワーク」〜「第五放送ネットワーク」は
  すべて架空の名称で、実在の放送局とは関係ありません。

## ファイル構成

```
appendix/react-analyst-app/
├── app.yml                     App Runtime の実行定義（install / run / profile / 環境変数）
├── snowflake.yml               デプロイ定義（snow app setup が生成）
├── app/
│   ├── api/analyst/route.ts    Analyst 呼び出し + SQL 実行（サーバーサイド）
│   ├── layout.tsx
│   └── page.tsx                設定値を読んでクライアントに渡すだけ
├── components/
│   ├── analyst-console.tsx     画面本体（質問入力・サンプル質問・結果描画）
│   ├── result-chart.tsx        ComposedChart による自動可視化
│   ├── result-table.tsx        結果テーブル
│   └── sql-block.tsx           生成 SQL の折りたたみ表示
└── lib/
    ├── analyst.ts              Cortex Analyst REST クライアント
    ├── semantic-model.ts       参照するオブジェクト名とサンプル質問
    ├── snowflake.ts            Snowflake 接続・認証（テンプレート提供）
    └── types.ts                API とクライアントで共有する型
```

## 参考

- [Cortex Analyst REST API](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/rest-api)
- [Cortex Analyst](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst)
- [セマンティックビューの概要](https://docs.snowflake.com/en/user-guide/views-semantic/overview)
