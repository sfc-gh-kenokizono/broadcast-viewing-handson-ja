"use client"

/**
 * 生成された SQL の折りたたみ表示。
 *
 * <details> を使うため、開閉に JavaScript の状態管理を必要としません。
 */

import { useState } from "react"
import { ChevronRight, Copy, Check } from "lucide-react"

export function SqlBlock({ sql }: { sql: string }) {
  const [copied, setCopied] = useState(false)

  async function handleCopy() {
    try {
      await navigator.clipboard.writeText(sql)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      // クリップボードが使えない環境（非 HTTPS など）では何もしない
    }
  }

  return (
    <details className="group rounded-lg border border-border bg-card">
      <summary className="flex cursor-pointer list-none items-center gap-2 px-4 py-3 text-sm font-medium">
        <ChevronRight
          className="h-4 w-4 shrink-0 text-muted-foreground transition-transform group-open:rotate-90"
          aria-hidden="true"
        />
        生成された SQL を表示
      </summary>
      <div className="border-t border-border">
        <div className="flex items-center justify-end px-3 py-2">
          <button
            type="button"
            onClick={handleCopy}
            className="inline-flex items-center gap-1.5 rounded-md border border-border px-2.5 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-accent-foreground"
          >
            {copied ? (
              <Check className="h-3.5 w-3.5" aria-hidden="true" />
            ) : (
              <Copy className="h-3.5 w-3.5" aria-hidden="true" />
            )}
            {copied ? "コピーしました" : "SQL をコピー"}
          </button>
        </div>
        <pre className="overflow-x-auto px-4 pb-4 text-xs leading-relaxed">
          <code>{sql}</code>
        </pre>
      </div>
    </details>
  )
}
