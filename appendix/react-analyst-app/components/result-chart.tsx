"use client"

/**
 * 結果セットの自動可視化。
 *
 * 列の型から X 軸（カテゴリ列）と Y 軸（数値列）を推定してグラフを描きます。
 *
 * 実装上の注意: 線と棒（面）を混在させる場合は必ず ComposedChart を使うこと。
 * Recharts の AreaChart / BarChart は子要素の <Line> を黙って無視するため、
 * エラーも警告も出ないまま線が消えます。ここでは 1 系列のときも
 * ComposedChart で統一し、系列が増えても壊れないようにしています。
 */

import {
  Bar,
  CartesianGrid,
  ComposedChart,
  Legend,
  Line,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts"
import { ChartTooltip, formatTick, getYAxisWidth } from "@/components/chart-utils"
import type { ResultColumn, ResultRow } from "@/lib/types"

/** グラフに描く最大カテゴリ数。これを超えたら先頭のみ描画する。 */
const MAX_POINTS = 30
/** 描画する最大系列数。 */
const MAX_SERIES = 3

const SERIES_COLORS = ["#29b5e8", "#7d44cf", "#f59e0b"]

interface ChartPlan {
  xKey: string
  seriesKeys: string[]
  data: Record<string, string | number | null>[]
  truncated: boolean
}

/**
 * 列定義から描画プランを作る。グラフ化に向かない結果（数値列が無い、
 * 行が 1 行しかない、カテゴリ列が無い）では null を返して描画を諦める。
 */
function planChart(columns: ResultColumn[], rows: ResultRow[]): ChartPlan | null {
  if (rows.length < 2) return null

  const numericCols = columns.filter((c) => c.kind === "number")
  const textCols = columns.filter((c) => c.kind === "text")
  if (numericCols.length === 0) return null

  // X 軸は最初のテキスト列（日付や局名など）。テキスト列が無ければ
  // 数値列の 1 本目を X に使い、残りを系列にする。
  const xKey = textCols[0]?.name ?? numericCols[0].name
  const seriesKeys = numericCols
    .filter((c) => c.name !== xKey)
    .slice(0, MAX_SERIES)
    .map((c) => c.name)
  if (seriesKeys.length === 0) return null

  const sliced = rows.slice(0, MAX_POINTS)
  const data = sliced.map((row) => {
    const point: Record<string, string | number | null> = {
      [xKey]: formatAxisLabel(row[xKey] ?? null),
    }
    for (const key of seriesKeys) {
      const v = row[key]
      // 欠損は null のまま渡す。0 で埋めると値の無い期間が「0 の実測値」に見えてしまう。
      point[key] = typeof v === "number" ? v : null
    }
    return point
  })

  return { xKey, seriesKeys, data, truncated: rows.length > MAX_POINTS }
}

/** X 軸ラベル。ISO タイムスタンプは日付部分だけに短縮する。 */
function formatAxisLabel(value: string | number | null): string {
  if (value === null) return "—"
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(value)) {
    return value.slice(0, 10)
  }
  return String(value)
}

export function ResultChart({
  columns,
  rows,
}: {
  columns: ResultColumn[]
  rows: ResultRow[]
}) {
  const plan = planChart(columns, rows)
  if (!plan) return null

  const { xKey, seriesKeys, data, truncated } = plan
  const yAxisWidth = getYAxisWidth(data, seriesKeys[0])

  return (
    <div className="space-y-2">
      <div className="h-80 w-full">
        <ResponsiveContainer width="100%" height="100%">
          <ComposedChart data={data} margin={{ top: 8, right: 16, bottom: 8, left: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" vertical={false} />
            <XAxis
              dataKey={xKey}
              tick={{ fontSize: 11, fill: "var(--muted-foreground)" }}
              interval="preserveStartEnd"
              angle={data.length > 8 ? -30 : 0}
              textAnchor={data.length > 8 ? "end" : "middle"}
              height={data.length > 8 ? 64 : 32}
            />
            <YAxis
              width={yAxisWidth}
              tickFormatter={formatTick}
              tick={{ fontSize: 11, fill: "var(--muted-foreground)" }}
            />
            <Tooltip content={<ChartTooltip />} />
            {seriesKeys.length > 1 && <Legend wrapperStyle={{ fontSize: 12 }} />}
            {/* 1 本目は棒、2 本目以降は線。混在させるため ComposedChart が必須。 */}
            <Bar
              dataKey={seriesKeys[0]}
              fill={SERIES_COLORS[0]}
              radius={[3, 3, 0, 0]}
              maxBarSize={48}
            />
            {seriesKeys.slice(1).map((key, i) => (
              <Line
                key={key}
                type="monotone"
                dataKey={key}
                stroke={SERIES_COLORS[(i + 1) % SERIES_COLORS.length]}
                strokeWidth={2}
                dot={false}
                connectNulls={false}
              />
            ))}
          </ComposedChart>
        </ResponsiveContainer>
      </div>
      {truncated && (
        <p className="text-xs text-muted-foreground">
          グラフは先頭 {MAX_POINTS} 件のみ表示しています。
        </p>
      )}
    </div>
  )
}
