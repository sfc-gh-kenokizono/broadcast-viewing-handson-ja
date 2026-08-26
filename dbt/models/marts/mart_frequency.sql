-- コマーシャルごと、受信機ごとの接触回数。
--
-- 1 行が 1 つのコマーシャル × 1 台の受信機になっているので、ここから先は
-- リーチ（行数を数える）、フリークエンシー（回数の平均を取る）、
-- インプレッション（回数を合計する）の 3 つがすべて出せます。
-- この 3 つは リーチ × 平均フリークエンシー = インプレッション の関係にあります。
--
-- 注意
--   放送のコマーシャル接触は実測値ではありません。視聴区間にスポットの放送時刻が
--   入っていたかどうかで判定した推定値です。席を外していても接触として数えます。

select
    a.CM_ID,
    m.ADVERTISER,
    m.CATEGORY,
    m.CAMPAIGN_FROM,
    m.CAMPAIGN_TO,
    a.COMMON_ID,
    count(*)                                         as CONTACT_COUNT,
    min(a.AIR_AT)                                    as FIRST_CONTACT_AT,
    max(a.AIR_AT)                                    as LAST_CONTACT_AT,
    -- 接触回数を見やすくまとめたもの
    case
        when count(*) = 1              then '1 回'
        when count(*) between 2 and 3  then '2 から 3 回'
        when count(*) between 4 and 7  then '4 から 7 回'
        when count(*) between 8 and 15 then '8 から 15 回'
        else '16 回以上'
    end                                              as FREQUENCY_BAND
from {{ ref('int_cm_contact') }} a
inner join {{ source('raw', 'CM_MASTER') }} m
    on a.CM_ID = m.CM_ID
group by
    a.CM_ID,
    m.ADVERTISER,
    m.CATEGORY,
    m.CAMPAIGN_FROM,
    m.CAMPAIGN_TO,
    a.COMMON_ID
