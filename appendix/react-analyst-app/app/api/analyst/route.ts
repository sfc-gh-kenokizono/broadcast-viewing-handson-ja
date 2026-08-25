/**
 * POST /api/analyst
 *
 * 自然言語の質問を受け取り、次の 2 段階をサーバーサイドで実行します。
 *   1. Cortex Analyst REST API にセマンティックビューを指定して質問し、SQL を生成させる
 *   2. 生成された SQL を Snowflake で実行し、結果セットを返す
 *
 * フロントエンドはこのルートだけを叩きます。Snowflake の認証情報やトークンが
 * ブラウザに渡ることはありません。
 *
 * リクエスト: { "question": "局ごとのリーチを教えて" }
 */

import { askAnalyst } from "@/lib/analyst"
import { querySnowflake } from "@/lib/snowflake"
import {
  MAX_ROWS,
  QUERY_WAREHOUSE,
  SEMANTIC_VIEW,
  USE_CALLERS_RIGHTS,
} from "@/lib/semantic-model"
import type { AnalystApiResult, ResultColumn, ResultRow } from "@/lib/types"

export const dynamic = "force-dynamic"

/** 質問文の最大長。長すぎる入力を早めに弾く。 */
const MAX_QUESTION_LENGTH = 1000

/**
 * Analyst が生成した SQL が読み取り専用であることを確認します。
 *
 * Cortex Analyst はセマンティックビューに対する SELECT を生成する設計ですが、
 * 「API から受け取った文字列をそのまま実行する」箇所なので、
 * SELECT / WITH 以外は実行しない多重防御を入れておきます。
 */
function isReadOnlySql(sql: string): boolean {
  // 行コメント・ブロックコメントを除去してから先頭キーワードを判定する
  const stripped = sql
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/--[^\n]*/g, " ")
    .trim()
  if (!/^(select|with)\b/i.test(stripped)) return false
  // セミコロンで区切った複文を弾く（末尾のセミコロンのみは許容）
  if (stripped.replace(/;\s*$/, "").includes(";")) return false
  return true
}

/** Snowflake の Node.js SDK は TIMESTAMP 系を Date で返すため ISO 文字列に正規化する。 */
function toIso(value: Date): string {
  return value.toISOString()
}

/** SDK の生の行を、JSON で安全に返せる値に正規化する。 */
function normalizeValue(value: unknown): string | number | null {
  if (value === null || value === undefined) return null
  if (value instanceof Date) return toIso(value)
  if (typeof value === "number") return Number.isFinite(value) ? value : null
  if (typeof value === "boolean") return value ? "true" : "false"
  if (typeof value === "string") return value
  // NUMBER(38,0) などが Bignum 相当のオブジェクトで返る場合に備える
  if (typeof value === "bigint") return Number(value)
  if (typeof value === "object") {
    const asNumber = Number(value)
    if (!Number.isNaN(asNumber)) return asNumber
    return JSON.stringify(value)
  }
  return String(value)
}

/**
 * 正規化済みの行から列定義を組み立てる。
 * 非 null 値がすべて数値の列を "number" とみなし、グラフの Y 軸候補にする。
 */
function inferColumns(rows: ResultRow[]): ResultColumn[] {
  if (rows.length === 0) return []
  return Object.keys(rows[0]).map((name) => {
    let sawValue = false
    let allNumeric = true
    for (const row of rows) {
      const v = row[name]
      if (v === null) continue
      sawValue = true
      if (typeof v !== "number") {
        allNumeric = false
        break
      }
    }
    return { name, kind: sawValue && allNumeric ? "number" : "text" }
  })
}

export async function POST(request: Request) {
  const startedAt = Date.now()

  let question: string
  try {
    const body = (await request.json()) as { question?: unknown }
    if (typeof body.question !== "string" || body.question.trim() === "") {
      return Response.json({ error: "question を文字列で指定してください。" }, { status: 400 })
    }
    question = body.question.trim()
    if (question.length > MAX_QUESTION_LENGTH) {
      return Response.json(
        { error: `question が長すぎます（最大 ${MAX_QUESTION_LENGTH} 文字）。` },
        { status: 400 },
      )
    }
  } catch {
    return Response.json({ error: "リクエストボディを JSON として解析できませんでした。" }, { status: 400 })
  }

  // 1. Cortex Analyst に質問して SQL を生成させる
  let analyst: Awaited<ReturnType<typeof askAnalyst>>
  try {
    analyst = await askAnalyst(question, SEMANTIC_VIEW)
  } catch (e) {
    console.error(new Date().toISOString(), "[analyst] Cortex Analyst の呼び出しに失敗", e)
    return Response.json(
      { error: e instanceof Error ? e.message : "Cortex Analyst の呼び出しに失敗しました。" },
      { status: 502 },
    )
  }

  // 2. 生成された SQL を実行する（SQL が無い = 質問が曖昧だった場合はスキップ）
  let columns: ResultColumn[] = []
  let rows: ResultRow[] = []
  let truncated = false
  let executionError: string | null = null

  if (analyst.sql) {
    if (!isReadOnlySql(analyst.sql)) {
      executionError =
        "生成された SQL が読み取り専用（SELECT / WITH）ではなかったため実行しませんでした。"
      console.error(
        new Date().toISOString(),
        "[analyst] 読み取り専用でない SQL を拒否しました",
        analyst.sql.slice(0, 200),
      )
    } else {
      try {
        const rawRows = await querySnowflake(analyst.sql, {
          warehouse: QUERY_WAREHOUSE,
          ...(USE_CALLERS_RIGHTS ? { callersRights: true } : {}),
        })
        truncated = rawRows.length > MAX_ROWS
        rows = rawRows.slice(0, MAX_ROWS).map((row) => {
          const out: ResultRow = {}
          for (const [key, value] of Object.entries(row)) {
            out[key] = normalizeValue(value)
          }
          return out
        })
        columns = inferColumns(rows)
      } catch (e) {
        // SQL 実行が失敗しても、Analyst の説明文と SQL は返す（学習用に原因を見せたい）
        console.error(new Date().toISOString(), "[analyst] 生成された SQL の実行に失敗", e)
        executionError = e instanceof Error ? e.message : "生成された SQL の実行に失敗しました。"
      }
    }
  }

  const result: AnalystApiResult = {
    question,
    text: analyst.text,
    sql: analyst.sql,
    suggestions: analyst.suggestions,
    verifiedQueryName: analyst.verifiedQueryName,
    warnings: analyst.warnings,
    columns,
    rows,
    truncated,
    executionError,
    requestId: analyst.requestId,
    elapsedMs: Date.now() - startedAt,
  }

  return Response.json(result)
}
