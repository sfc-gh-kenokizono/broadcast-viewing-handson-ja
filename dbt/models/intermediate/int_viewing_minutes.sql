{{ config(materialized = 'table') }}

-- 視聴区間（from-to）を 1 分単位に「展開」する。
--
-- 同じ視聴を表す 3 つの形
--
--   📡 60 秒ごとの信号（受信機が局に送る形）      12 行
--   📦 from-to（局が畳んで基盤へ渡す形）           1 行   ← RAW / STG はこれ
--   📂 1 分ごとの行（この層で展開した形）          12 行
--
--   分解前（1 行）  C000123  041  20:00 から 20:12
--   分解後（12 行） C000123  041  20:00 / 20:01 / ... / 20:11
--
-- 中身の情報はどの形でも同じです。変わるのは行数だけです。
--
-- なぜ展開するのか
--   「毎分の視聴台数のカーブを描きたい」のように、時間軸を細かく刻んで
--   並べる指標は、分の側に行があると GROUP BY 分 で素直に集計できます。
--   区間のままでも出せますが、1 分ごとに「この分を含む区間はどれか」を
--   全体に対して範囲条件で問うことになり、SQL も実行も重くなりがちです。
--
-- 展開しないで済む指標
--   リーチ、フリークエンシー、CM 接触、番組視聴、チャンネル遷移は
--   「区間と時刻の重なり判定」で答えられるので、from-to のまま算出します。
--   この教材の他のマートはすべてそうしています。
--
-- 気をつけること
--   平均の視聴区間長を M 分とすると、行数はおよそ M 倍になります。
--   このデータは平均が約 11.4 分で、1 行が平均 11.5 行に広がり、105 万行が約 1,208 万行になります。
--   増えるのはこの層から下だけで、受け取る生データの量は変わりません。
--
--   実際の設計では、展開は必要な指標に限り、展開した行を全件そのまま
--   持ち続けないのが基本です。この教材でも、下流の mart_minute_audience で
--   「局 × 分 × 視聴台数」に集計して約 55 万行に縮めてから提供層に置きます。
--
-- ここだけはビューではなくテーブルにしています。
-- 参照するたびに分解し直すと、その都度同じ計算を繰り返すことになるためです。

with minute_numbers as (

    -- 0 から 1440 までの連番。1 日の分数より 1 つ多く用意しておく
    select row_number() over (order by seq4()) - 1 as MINUTE_OFFSET
    from table(generator(rowcount => 1441))

)

select
    v.COMMON_ID,
    v.IP_ADDRESS,
    v.NETWORK_ID,
    v.CHANNEL_CODE,
    v.VIEW_DATE,
    dateadd('minute', n.MINUTE_OFFSET, date_trunc('minute', v.VIEW_FROM)) as MINUTE_AT
from {{ ref('stg_viewing_log') }} v
inner join minute_numbers n
    on n.MINUTE_OFFSET < greatest(1, datediff('minute', v.VIEW_FROM, v.VIEW_TO))
