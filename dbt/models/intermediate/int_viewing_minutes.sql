{{ config(materialized = 'table') }}

-- 視聴区間を 1 分単位に分解する。
--
-- 事実は何も変わりません。粒度だけを上げています。
--
--   分解前（1 行）  C000123  041  20:00 から 20:12
--   分解後（12 行） C000123  041  20:00 / 20:01 / ... / 20:11
--
-- なぜやるのか
--   毎分の視聴人数のような指標は、分の側から数えられる形にしておくと
--   素直に集計できます。区間のままだと、ある時刻の視聴者数を出すたびに
--   範囲条件で全体を見に行くことになります。
--
-- 気をつけること
--   平均の視聴区間長を M 分とすると、行数はおよそ M 倍になります。
--   このデータは平均が約 11 分なので、105 万行が約 1,187 万行になります。
--   増えるのはこの層から下だけで、受け取る生データの量は変わりません。
--   実際の設計では、必要な指標に限って分解し、全件を常に持たないのが基本になります。
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
