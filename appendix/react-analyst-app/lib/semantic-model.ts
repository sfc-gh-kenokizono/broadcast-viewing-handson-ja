/**
 * このアプリが参照する Snowflake 側のオブジェクト定義。
 *
 * セマンティックビューとウェアハウスは環境変数で上書きできます。
 * 別のアカウント / 別の名前でハンズオンを構築した場合は、コードを書き換えずに
 * app.yml の environment_variables（デプロイ時）または .env.local（ローカル開発時）で
 * 差し替えてください。
 */

/** Cortex Analyst に渡すセマンティックビューの完全修飾名。 */
export const SEMANTIC_VIEW =
  process.env.BCAST_SEMANTIC_VIEW ?? "BCAST_VIEWING_HANDSON.MART.SV_BROADCAST_VIEWING"

/** 生成された SQL を実行するウェアハウス。 */
export const QUERY_WAREHOUSE = process.env.BCAST_WAREHOUSE ?? "BCAST_HANDSON_WH"

/**
 * true にすると、生成された SQL の実行を「呼び出しユーザーの権限」で行います。
 * 行アクセスポリシーやマスキングポリシーを検証したい場合に有効化してください。
 * 既定は false（アプリのサービスID = オーナー権限で実行）です。
 */
export const USE_CALLERS_RIGHTS = process.env.BCAST_CALLERS_RIGHTS === "true"

/** 結果テーブル / グラフに描画する最大行数。 */
export const MAX_ROWS = 500

/** 画面に並べるサンプル質問。 */
export const SAMPLE_QUESTIONS: string[] = [
  "局ごとのリーチ台数を多い順に教えて",
  "7月に最もリーチが大きかった番組は？",
  "配信を足すとリーチはどれだけ広がった？",
  "ジャンル別の推計視聴人数を多い順に見せて",
  "第一放送ネットワークから他局への流出が多い組み合わせは？",
]
