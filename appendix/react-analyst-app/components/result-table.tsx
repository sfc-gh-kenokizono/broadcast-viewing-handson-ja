"use client"

/** SQL 実行結果のテーブル表示。 */

import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import type { ResultColumn, ResultRow } from "@/lib/types"

/** 数値は桁区切り、日付らしい ISO 文字列は日付部分だけを表示する。 */
function formatCell(value: string | number | null, kind: ResultColumn["kind"]): string {
  if (value === null) return "—"
  if (kind === "number" && typeof value === "number") {
    return value.toLocaleString("ja-JP", { maximumFractionDigits: 2 })
  }
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(value)) {
    // TIMESTAMP 列は ISO 文字列に正規化されている。日付だけを見せる。
    return value.slice(0, 10)
  }
  return String(value)
}

export function ResultTable({
  columns,
  rows,
  truncated,
}: {
  columns: ResultColumn[]
  rows: ResultRow[]
  truncated: boolean
}) {
  if (columns.length === 0 || rows.length === 0) {
    return (
      <p className="px-4 py-6 text-sm text-muted-foreground">
        結果が 0 行でした。質問の条件を変えて試してください。
      </p>
    )
  }

  return (
    <div className="overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            {columns.map((col) => (
              <TableHead
                key={col.name}
                className={col.kind === "number" ? "text-right" : undefined}
              >
                {col.name}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row, i) => (
            <TableRow key={i}>
              {columns.map((col) => (
                <TableCell
                  key={col.name}
                  className={
                    col.kind === "number" ? "text-right font-mono text-xs" : "text-sm"
                  }
                >
                  {formatCell(row[col.name] ?? null, col.kind)}
                </TableCell>
              ))}
            </TableRow>
          ))}
        </TableBody>
      </Table>
      <p className="px-4 py-3 text-xs text-muted-foreground">
        {rows.length.toLocaleString("ja-JP")} 行
        {truncated ? "（上限に達したため一部のみ表示しています）" : ""}
      </p>
    </div>
  )
}
