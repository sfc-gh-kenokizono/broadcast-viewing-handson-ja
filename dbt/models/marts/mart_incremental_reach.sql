-- 増分リーチ。
--
-- 放送だけで届いていた人に配信を足したとき、重複を除いてどれだけ広がるか。
-- 4 つの区分に分けて数えます。
--
--   放送のみ接触   放送で届いた。配信では届いていない
--   配信のみ接触   配信で届いた。放送では届いていない  ← ここが増えた分
--   両方に接触     どちらでも届いた。重複しているので 1 人として数える
--
-- この指標は、放送と配信のデータが 1 か所にそろっていないと計算できません。
-- 別々の場所にあると、どちらでも届いた人を 1 人として数えられないためです。

with contact as (

    select
        CM_ID,
        ADVERTISER,
        CATEGORY,
        COMMON_ID,
        BROADCAST_CONTACTS > 0 as HAS_BROADCAST,
        STREAMING_CONTACTS > 0 as HAS_STREAMING,
        BROADCAST_CONTACTS,
        STREAMING_CONTACTS
    from {{ ref('mart_frequency') }}

)

select
    CM_ID,
    ADVERTISER,
    CATEGORY,
    count_if(HAS_BROADCAST and not HAS_STREAMING)             as BROADCAST_ONLY_REACH,
    count_if(HAS_STREAMING and not HAS_BROADCAST)             as STREAMING_ONLY_REACH,
    count_if(HAS_BROADCAST and HAS_STREAMING)                 as BOTH_REACH,
    count_if(HAS_BROADCAST)                                   as BROADCAST_REACH,
    count_if(HAS_STREAMING)                                   as STREAMING_REACH,
    count(*)                                                  as COMBINED_REACH,
    count(*) - count_if(HAS_BROADCAST)                        as INCREMENTAL_REACH,
    round(div0(count(*) - count_if(HAS_BROADCAST),
               count_if(HAS_BROADCAST)) * 100, 1)             as INCREMENTAL_REACH_PCT,
    round(div0(sum(BROADCAST_CONTACTS), count_if(HAS_BROADCAST)), 2) as BROADCAST_FREQUENCY,
    round(div0(sum(STREAMING_CONTACTS), count_if(HAS_STREAMING)), 2) as STREAMING_FREQUENCY,
    round(div0(sum(BROADCAST_CONTACTS) + sum(STREAMING_CONTACTS), count(*)), 2) as COMBINED_FREQUENCY
from contact
group by CM_ID, ADVERTISER, CATEGORY
