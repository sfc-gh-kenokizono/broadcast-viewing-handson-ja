"use client"

/**
 * アナリストコンソール本体。
 *
 * 自然言語の質問を /api/analyst に投げ、返ってきた
 * 「解釈の説明文 / 生成された SQL / 実行結果」を描画します。
 * Snowflake への接続はすべてサーバーサイド（API ルート）で行うため、
 * このコンポーネントは Snowflake の認証情報を一切扱いません。
 */

import { useState } from "react"
import { useMutation } from "@tanstack/react-query"
import { Loader2, Search } from "lucide-react"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { ResultChart } from "@/components/result-chart"
import { ResultTable } from "@/components/result-table"
import { SqlBlock } from "@/components/sql-block"
import type { AnalystApiResult } from "@/lib/types"

async function askAnalyst(question: string): Promise<AnalystApiResult> {
  const res = await fetch("/api/analyst", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ question }),
  })
  const json = await res.json()
  if (!res.ok) {
    throw new Error(
      typeof json?.error === "string" ? json.error : "リクエストが失敗しました。",
    )
  }
  return json as AnalystApiResult
}

export function AnalystConsole({
  semanticView,
  sampleQuestions,
  callersRights,
}: {
  semanticView: string
  sampleQuestions: string[]
  callersRights: boolean
}) {
  const [question, setQuestion] = useState("")

  const mutation = useMutation({
    mutationFn: askAnalyst,
  })

  function submit(q: string) {
    const trimmed = q.trim()
    if (trimmed === "" || mutation.isPending) return
    setQuestion(trimmed)
    mutation.mutate(trimmed)
  }

  const result = mutation.data

  return (
    <div className="mx-auto w-full max-w-5xl space-y-6 px-4 py-8">
      <header className="space-y-2">
        <h1 className="text-2xl font-semibold tracking-tight">
          放送視聴データ アナリストコンソール
        </h1>
        <p className="text-sm text-muted-foreground">
          自然言語で質問すると、Cortex Analyst がセマンティックビューを解釈して SQL
          を生成し、その実行結果をこの画面に描画します。BI ツールの UI を使わず、
          セマンティックレイヤーだけを REST API で取得してフロントエンドを自作する構成です。
        </p>
        <div className="flex flex-wrap items-center gap-2 pt-1">
          <Badge variant="secondary" className="font-mono text-xs">
            {semanticView}
          </Badge>
          <Badge variant="outline" className="text-xs">
            {callersRights ? "呼び出しユーザー権限で実行" : "オーナー権限で実行"}
          </Badge>
        </div>
      </header>

      {/* 質問入力 */}
      <Card>
        <CardContent className="space-y-4 pt-6">
          <form
            onSubmit={(e) => {
              e.preventDefault()
              submit(question)
            }}
            className="flex flex-col gap-3 sm:flex-row"
          >
            <label htmlFor="question" className="sr-only">
              質問
            </label>
            <input
              id="question"
              type="text"
              value={question}
              onChange={(e) => setQuestion(e.target.value)}
              placeholder="例: 局ごとのリーチ台数を多い順に教えて"
              autoComplete="off"
              className="flex-1 rounded-md border border-input bg-background px-3 py-2 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
            <Button type="submit" disabled={mutation.isPending || question.trim() === ""}>
              {mutation.isPending ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden="true" />
              ) : (
                <Search className="mr-2 h-4 w-4" aria-hidden="true" />
              )}
              {mutation.isPending ? "問い合わせ中" : "質問する"}
            </Button>
          </form>

          <div className="space-y-2">
            <p className="text-xs font-medium text-muted-foreground">サンプル質問</p>
            <div className="flex flex-wrap gap-2">
              {sampleQuestions.map((q) => (
                <button
                  key={q}
                  type="button"
                  onClick={() => submit(q)}
                  disabled={mutation.isPending}
                  className="rounded-full border border-border px-3 py-1.5 text-xs text-foreground hover:bg-accent hover:text-accent-foreground disabled:opacity-50"
                >
                  {q}
                </button>
              ))}
            </div>
          </div>
        </CardContent>
      </Card>

      {/* 実行中 */}
      {mutation.isPending && (
        <Card>
          <CardContent className="space-y-3 pt-6">
            <Skeleton className="h-4 w-2/3" />
            <Skeleton className="h-4 w-1/2" />
            <Skeleton className="h-48 w-full" />
          </CardContent>
        </Card>
      )}

      {/* 呼び出し自体の失敗 */}
      {mutation.isError && (
        <Alert variant="destructive">
          <AlertTitle>問い合わせに失敗しました</AlertTitle>
          <AlertDescription>{mutation.error.message}</AlertDescription>
        </Alert>
      )}

      {/* 結果 */}
      {result && !mutation.isPending && (
        <div className="space-y-6">
          {/* Analyst の解釈 */}
          {result.text && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">回答</CardTitle>
              </CardHeader>
              <CardContent className="space-y-3">
                <p className="whitespace-pre-wrap text-sm leading-relaxed">{result.text}</p>
                <p className="text-xs text-muted-foreground">
                  応答時間 {(result.elapsedMs / 1000).toFixed(1)} 秒
                  {result.verifiedQueryName
                    ? ` / 検証済みクエリ「${result.verifiedQueryName}」を使用`
                    : ""}
                </p>
              </CardContent>
            </Card>
          )}

          {/* 質問が曖昧だった場合の候補 */}
          {result.suggestions.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">
                  質問が曖昧なため SQL を生成できませんでした
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-2">
                <p className="text-sm text-muted-foreground">
                  次のような質問ならこのセマンティックビューで回答できます。
                </p>
                <div className="flex flex-col items-start gap-2">
                  {result.suggestions.map((s) => (
                    <button
                      key={s}
                      type="button"
                      onClick={() => submit(s)}
                      className="text-left text-sm text-primary underline underline-offset-2 hover:no-underline"
                    >
                      {s}
                    </button>
                  ))}
                </div>
              </CardContent>
            </Card>
          )}

          {/* Analyst からの警告 */}
          {result.warnings.length > 0 && (
            <Alert>
              <AlertTitle>Cortex Analyst からの警告</AlertTitle>
              <AlertDescription>
                <ul className="list-disc space-y-1 pl-4">
                  {result.warnings.map((w) => (
                    <li key={w}>{w}</li>
                  ))}
                </ul>
              </AlertDescription>
            </Alert>
          )}

          {/* 生成された SQL */}
          {result.sql && <SqlBlock sql={result.sql} />}

          {/* SQL 実行だけが失敗した場合 */}
          {result.executionError && (
            <Alert variant="destructive">
              <AlertTitle>生成された SQL の実行に失敗しました</AlertTitle>
              <AlertDescription>{result.executionError}</AlertDescription>
            </Alert>
          )}

          {/* グラフ（数値列があり 2 行以上あるときだけ描く） */}
          {result.rows.length >= 2 && result.columns.some((c) => c.kind === "number") && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">グラフ</CardTitle>
              </CardHeader>
              <CardContent>
                <ResultChart columns={result.columns} rows={result.rows} />
              </CardContent>
            </Card>
          )}

          {/* 結果テーブル */}
          {result.sql && !result.executionError && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">結果</CardTitle>
              </CardHeader>
              <CardContent className="px-0">
                <ResultTable
                  columns={result.columns}
                  rows={result.rows}
                  truncated={result.truncated}
                />
              </CardContent>
            </Card>
          )}
        </div>
      )}
    </div>
  )
}
