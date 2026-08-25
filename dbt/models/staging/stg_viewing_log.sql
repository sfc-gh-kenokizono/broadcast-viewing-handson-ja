-- 5 局から届いた視聴区間を 1 つにまとめ、クレンジングする。
--
-- ここがこのハンズオンで最初の、そしていちばん意味のある変換です。
-- 各局は自局が見られている間のログしか取得できないため、
-- 1 台の受信機がチャンネルをどう移動したかは、5 局分を共通 ID で束ねて
-- 初めて見えるようになります。
--
-- 除外しているもの
--   1. 終了時刻が開始時刻と同じか、それより前の行
--   2. 視聴時間が 24 時間を超える行
--   3. まったく同じ内容の重複行
--
-- 局ごとに個別のクレンジングをするのではなく、同じ定義でまとめて処理します。

with unioned as (

    select * from {{ source('raw', 'VIEWING_LOG_NW01') }}
    union all
    select * from {{ source('raw', 'VIEWING_LOG_NW02') }}
    union all
    select * from {{ source('raw', 'VIEWING_LOG_NW03') }}
    union all
    select * from {{ source('raw', 'VIEWING_LOG_NW04') }}
    union all
    select * from {{ source('raw', 'VIEWING_LOG_NW05') }}

),

deduplicated as (

    -- 同じ内容の行が複数届くことがあるため、ここで 1 行にまとめる
    select distinct
        NETWORK_ID,
        STATION_DEVICE_ID,
        COMMON_ID,
        IP_ADDRESS,
        POSTAL_CODE,
        CHANNEL_CODE,
        VIEW_FROM,
        VIEW_TO
    from unioned

)

select
    NETWORK_ID,
    STATION_DEVICE_ID,
    COMMON_ID,
    IP_ADDRESS,
    POSTAL_CODE,
    CHANNEL_CODE,
    VIEW_FROM,
    VIEW_TO,
    VIEW_FROM::date                                  as VIEW_DATE,
    datediff('second', VIEW_FROM, VIEW_TO)           as VIEW_SECONDS,
    datediff('second', VIEW_FROM, VIEW_TO) / 60.0    as VIEW_MINUTES
from deduplicated
where VIEW_TO > VIEW_FROM
  and datediff('hour', VIEW_FROM, VIEW_TO) <= 24
