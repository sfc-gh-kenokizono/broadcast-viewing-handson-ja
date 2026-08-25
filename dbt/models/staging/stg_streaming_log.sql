-- 配信側の番組視聴ログを整える。
-- 放送側と同じ考え方で、成立していない区間を落として視聴日と秒数を足す。

select
    COMMON_ID,
    IP_ADDRESS,
    PROGRAM_ID,
    DEVICE_TYPE,
    VIEW_FROM,
    VIEW_TO,
    VIEW_FROM::date                        as VIEW_DATE,
    datediff('second', VIEW_FROM, VIEW_TO) as VIEW_SECONDS
from {{ source('raw', 'STREAMING_LOG') }}
where VIEW_TO > VIEW_FROM
