-- 30 分以内に次に見た別チャンネル。
--
-- 1 台の受信機が、あるチャンネルの視聴を終えたあと、30 分以内に
-- 別のチャンネルを見始めた回数を数えます。
--
-- ここがこのハンズオンの見どころのひとつです。各局は自局が見られている
-- 間のログしか取得できないため、局をまたいだ移動は 1 局のデータだけでは
-- 絶対に見えません。5 局分を共通 ID で束ねたあとで、初めて
-- 「この受信機は 041 のあと、30 分以内に 071 を見た」と分かります。
--
-- 30 分を超えて空いている場合は、連続した行動とはみなさず除きます。
-- 間隔が 0 分なら直接のチャンネル変更、正の値なら一度 TV を見ていない
-- 時間を挟んだ「次の視聴」です。

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
      and datediff('minute', PREV_VIEW_TO, VIEW_FROM) >= 0
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
