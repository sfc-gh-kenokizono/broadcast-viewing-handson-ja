-- コマーシャルごと、受信機ごとの接触回数。
--
-- フリークエンシーは「同じ人に何回見せたか」です。この表は
-- 1 行が 1 つのコマーシャル × 1 台の受信機になっているので、
-- ここから先はリーチ（行数を数える）とフリークエンシー
-- （回数の平均を取る）の両方が出せます。
--
-- 放送と配信の内訳を分けて持っているので、増分リーチもここから計算できます。

select
    a.CM_ID,
    m.ADVERTISER,
    m.CATEGORY,
    a.COMMON_ID,
    count(*)                                         as CONTACT_COUNT,
    count_if(a.CHANNEL_TYPE = 'broadcast')           as BROADCAST_CONTACTS,
    count_if(a.CHANNEL_TYPE = 'streaming')           as STREAMING_CONTACTS,
    min(a.CONTACT_AT)                                as FIRST_CONTACT_AT,
    max(a.CONTACT_AT)                                as LAST_CONTACT_AT,
    -- 接触回数を見やすくまとめたもの
    case
        when count(*) = 1              then '1 回'
        when count(*) between 2 and 3  then '2 から 3 回'
        when count(*) between 4 and 7  then '4 から 7 回'
        when count(*) between 8 and 15 then '8 から 15 回'
        else '16 回以上'
    end                                              as FREQUENCY_BAND
from {{ ref('int_ad_contact') }} a
inner join {{ source('raw', 'CM_MASTER') }} m
    on a.CM_ID = m.CM_ID
group by
    a.CM_ID,
    m.ADVERTISER,
    m.CATEGORY,
    a.COMMON_ID
