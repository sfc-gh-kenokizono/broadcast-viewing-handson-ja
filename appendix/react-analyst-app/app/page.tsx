/**
 * トップページ。
 *
 * サーバーコンポーネントとして設定値（セマンティックビュー名・サンプル質問）を読み、
 * クライアントコンポーネントに渡します。設定値はサーバー側の環境変数由来なので、
 * ここで解決してから props で渡す形にしています。
 */

import { AnalystConsole } from "@/components/analyst-console"
import { SAMPLE_QUESTIONS, SEMANTIC_VIEW, USE_CALLERS_RIGHTS } from "@/lib/semantic-model"

export const dynamic = "force-dynamic"

export default function Page() {
  return (
    <main>
      <AnalystConsole
        semanticView={SEMANTIC_VIEW}
        sampleQuestions={SAMPLE_QUESTIONS}
        callersRights={USE_CALLERS_RIGHTS}
      />
    </main>
  )
}
