/**
 * Cortex Analyst REST API クライアント（サーバーサイド専用）。
 *
 * エンドポイント: POST {account_url}/api/v2/cortex/analyst/message
 * 参考: https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/rest-api
 *
 * このアプリではストリーミングを使いません（stream を送らない = 非ストリーミング）。
 * 非ストリーミングなら SSE の組み立てが不要で、レスポンスを 1 回の JSON として
 * そのまま扱えるため、「セマンティックレイヤーだけ API で取る」構造が読みやすくなります。
 *
 * 認証は lib/snowflake.ts の getRestApiAuthHeader() に委ねます。
 *   - SPCS 上: /snowflake/session/token のサービストークン（Bearer）
 *   - ローカル: ~/.snowflake の既定接続の OAuth トークン
 * いずれもコードには秘密情報を持ちません。
 */

import { getRestApiAuthHeader, getSnowflakeBaseUrl } from "@/lib/snowflake"

/** レスポンスの content[] 要素。type は text / sql / suggestions のいずれか。 */
export interface AnalystContentBlock {
  type: string
  /** type === "text" のとき、Analyst による解釈の説明文。 */
  text?: string
  /** type === "sql" のとき、生成された SQL。 */
  statement?: string
  /** type === "suggestions"（ドキュメント上は "suggestion" 表記もある）のとき。 */
  suggestions?: string[]
  /** 検証済みクエリ（VQR）が使われた場合の情報。 */
  confidence?: {
    verified_query_used?: {
      name?: string
      question?: string
      sql?: string
      verified_at?: number
      verified_by?: string
    } | null
  }
}

export interface AnalystApiResponse {
  request_id?: string
  message?: {
    role?: string
    content?: AnalystContentBlock[]
  }
  warnings?: { message?: string }[]
}

/** content[] を解釈して、UI が必要とする形に平坦化した結果。 */
export interface AnalystResult {
  requestId: string | null
  /** Analyst の説明テキスト（複数ブロックあれば連結）。 */
  text: string | null
  /** 生成された SQL。曖昧な質問だった場合は null。 */
  sql: string | null
  /** 質問が曖昧で SQL を作れなかった場合の代替質問候補。 */
  suggestions: string[]
  /** 使われた検証済みクエリの名前（あれば）。 */
  verifiedQueryName: string | null
  warnings: string[]
}

const ANALYST_PATH = "/api/v2/cortex/analyst/message"

/**
 * 自然言語の質問を Cortex Analyst に投げ、生成された SQL と説明文を受け取ります。
 *
 * @param question ユーザーが入力した日本語の質問
 * @param semanticView セマンティックビューの完全修飾名
 */
export async function askAnalyst(question: string, semanticView: string): Promise<AnalystResult> {
  const baseUrl = getSnowflakeBaseUrl()
  if (!baseUrl) {
    throw new Error(
      "Snowflake アカウントの URL を解決できませんでした。SPCS 上では自動設定されます。" +
        "ローカル開発では ~/.snowflake の接続設定、または SNOWFLAKE_ACCOUNT_URL を設定してください。",
    )
  }

  // リクエストボディ。semantic_view にビュー名を渡す形式を使う
  // （semantic_model_file / semantic_model / semantic_models のいずれか 1 つが必須）。
  const body = {
    messages: [
      {
        role: "user",
        content: [{ type: "text", text: question }],
      },
    ],
    semantic_view: semanticView,
  }

  const res = await fetch(`${baseUrl}${ANALYST_PATH}`, {
    method: "POST",
    headers: {
      Authorization: getRestApiAuthHeader(),
      "Content-Type": "application/json",
      // SPCS のサービストークンを使う場合、このヘッダーが必要。
      "X-Snowflake-Authorization-Token-Type": "OAUTH",
    },
    body: JSON.stringify(body),
    cache: "no-store",
  })

  if (!res.ok) {
    const detail = await res.text().catch(() => "")
    throw new Error(
      `Cortex Analyst API が ${res.status} ${res.statusText} を返しました。${detail.slice(0, 500)}`,
    )
  }

  const json = (await res.json()) as AnalystApiResponse
  return flattenAnalystResponse(json)
}

/**
 * content[] を走査して text / sql / suggestions を取り出します。
 *
 * ドキュメントでは type の値として "suggestions"（例）と "suggestion"（説明文）の
 * 両方の表記が現れるため、両方を受け付けます。将来 content type が増えても
 * 落ちないよう、知らない type は単に無視します。
 */
export function flattenAnalystResponse(json: AnalystApiResponse): AnalystResult {
  const blocks = json.message?.content ?? []

  const texts: string[] = []
  let sql: string | null = null
  const suggestions: string[] = []
  let verifiedQueryName: string | null = null

  for (const block of blocks) {
    switch (block.type) {
      case "text":
        if (block.text) texts.push(block.text)
        break
      case "sql":
        if (block.statement) sql = block.statement
        verifiedQueryName = block.confidence?.verified_query_used?.name ?? verifiedQueryName
        break
      case "suggestion":
      case "suggestions":
        if (Array.isArray(block.suggestions)) suggestions.push(...block.suggestions)
        break
      default:
        // 未知の content type は無視（前方互換のため）
        break
    }
  }

  return {
    requestId: json.request_id ?? null,
    text: texts.length > 0 ? texts.join("\n\n") : null,
    sql,
    suggestions,
    verifiedQueryName,
    warnings: (json.warnings ?? [])
      .map((w) => w.message)
      .filter((m): m is string => typeof m === "string" && m.length > 0),
  }
}
