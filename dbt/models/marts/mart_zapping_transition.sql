-- チャンネルの移動。
--
-- 1 台の受信機が、あるチャンネルから次のチャンネルへ移った回数を数えます。
--
-- ここがこのハンズオンの見どころのひとつです。各局は自局が見られている
-- 間のログしか取得できないため、局をまたいだ移動は 1 局のデータだけでは
-- 絶対に見えません。5 局分を共通 ID で束ねたあとで、初めて
-- 「この受信機は 20 時 15 分に 041 から 071 へ移った」と分かります。
--
-- 直前の視聴が終わってから 30 分以上空いている場合は、
-- チャンネルを移動したのではなく見るのをやめたと考えて除いています。

with sequenced as (

    select
        v.COMMON_ID,
        v.VIEW_DATE,
        v.NETWORK_ID,
        v.CHANNEL_CODE,
        v.VIEW_FROM,
        v.VIEW_TO,
        lag(v.CHANNEL_CODE) over (
            partition by v.COMMON_ID, v.VIEW_DATE order by v.VIEW_FROM
        ) as PREV_CHANNEL_CODE,
        lag(v.NETWORK_ID) over (
            partition by v.COMMON_ID, v.VIEW_DATE order by v.VIEW_FROM
        ) as PREV_NETWORK_ID,
        lag(v.VIEW_TO) over (
            partition by v.COMMON_ID, v.VIEW_DATE order by v.VIEW_FROM
        ) as PREV_VIEW_TO
    from {{ ref('stg_viewing_log') }} v

),

transitions as (

    select
        VIEW_DATE,
        PREV_NETWORK_ID   as FROM_NETWORK_ID,
        PREV_CHANNEL_CODE as FROM_CHANNEL_CODE,
        NETWORK_ID        as TO_NETWORK_ID,
        CHANNEL_CODE      as TO_CHANNEL_CODE,
        COMMON_ID,
        datediff('minute', PREV_VIEW_TO, VIEW_FROM) as GAP_MINUTES
    from sequenced
    where PREV_CHANNEL_CODE is not null
      and PREV_CHANNEL_CODE <> CHANNEL_CODE
      and datediff('minute', PREV_VIEW_TO, VIEW_FROM) <= 30

)

select
    t.VIEW_DATE,
    t.FROM_NETWORK_ID,
    fn.NETWORK_NAME as FROM_NETWORK_NAME,
    t.FROM_CHANNEL_CODE,
    t.TO_NETWORK_ID,
    tn.NETWORK_NAME as TO_NETWORK_NAME,
    t.TO_CHANNEL_CODE,
    count(*)                       as TRANSITION_COUNT,
    count(distinct t.COMMON_ID)    as TRANSITION_DEVICES,
    round(avg(t.GAP_MINUTES), 1)   as AVG_GAP_MINUTES
from transitions t
inner join {{ source('raw', 'NETWORK_MASTER') }} fn
    on t.FROM_NETWORK_ID = fn.NETWORK_ID
inner join {{ source('raw', 'NETWORK_MASTER') }} tn
    on t.TO_NETWORK_ID = tn.NETWORK_ID
group by
    t.VIEW_DATE,
    t.FROM_NETWORK_ID,
    fn.NETWORK_NAME,
    t.FROM_CHANNEL_CODE,
    t.TO_NETWORK_ID,
    tn.NETWORK_NAME,
    t.TO_CHANNEL_CODE
