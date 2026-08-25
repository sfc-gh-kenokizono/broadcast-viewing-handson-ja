/** API ルートとクライアントコンポーネントで共有する型。 */

/** 結果テーブルの 1 列のメタ情報。 */
export interface ResultColumn {
  name: string
  /** number なら数値列（グラフの Y 軸候補）。 */
  kind: "number" | "text"
}

/** 結果行。値は文字列 / 数値 / null に正規化済み。 */
export type ResultRow = Record<string, string | number | null>

/** POST /api/analyst のレスポンス。 */
export interface AnalystApiResult {
  question: string
  /** Analyst による解釈の説明文。 */
  text: string | null
  /** 生成された SQL。曖昧な質問だった場合は null。 */
  sql: string | null
  /** 質問が曖昧だった場合の代替質問候補。 */
  suggestions: string[]
  /** 使われた検証済みクエリ（VQR）の名前。 */
  verifiedQueryName: string | null
  /** Analyst からの警告。 */
  warnings: string[]
  /** SQL 実行結果の列定義。SQL 未生成 / 実行失敗時は空配列。 */
  columns: ResultColumn[]
  /** SQL 実行結果の行。 */
  rows: ResultRow[]
  /** 行数が MAX_ROWS で切り詰められたか。 */
  truncated: boolean
  /** SQL 実行だけが失敗した場合のエラーメッセージ（Analyst の応答は返す）。 */
  executionError: string | null
  /** Analyst の request_id。フィードバック API に渡す際に使えます。 */
  requestId: string | null
  /** 実行に要した時間（ミリ秒）。 */
  elapsedMs: number
}
