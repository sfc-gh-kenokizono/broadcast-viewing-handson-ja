-- 受信機ごと、日ごと、局ごとの視聴実績。
--
-- なぜこの粒度にするのか
--   リーチは「1 回以上見た人の数」なので、重複を除いた数え方になります。
--   ここで日別のリーチをあらかじめ計算して持ってしまうと、その値を
--   月合計しようとしたときに同じ人を何度も数えることになります。
--
--   そこで、マート層は「1 行 = 1 台 × 1 日 × 1 局」という細かい粒度で持ち、
--   リーチはセマンティックビュー側で COUNT(DISTINCT 共通 ID) として定義します。
--   こうすると、日で見ても月で見ても局をまたいで見ても、正しい人数が出ます。
--
-- 属性は 10 パーセントの端末にしか入っていません。残りは NULL のままです。

select
    v.VIEW_DATE,
    v.NETWORK_ID,
    n.NETWORK_NAME,
    v.CHANNEL_CODE,
    v.COMMON_ID,
    v.IP_ADDRESS,
    d.POSTAL_AREA,
    d.DEVICES_PER_IP,
    d.GENDER_AGE_SEGMENT,
    d.IS_PANEL,
    count(*)                       as VIEWING_SESSIONS,
    round(sum(v.VIEW_MINUTES), 2)  as VIEW_MINUTES
from {{ ref('stg_viewing_log') }} v
inner join {{ source('raw', 'NETWORK_MASTER') }} n
    on v.NETWORK_ID = n.NETWORK_ID
inner join {{ ref('int_device_identity') }} d
    on v.COMMON_ID = d.COMMON_ID
group by
    v.VIEW_DATE,
    v.NETWORK_ID,
    n.NETWORK_NAME,
    v.CHANNEL_CODE,
    v.COMMON_ID,
    v.IP_ADDRESS,
    d.POSTAL_AREA,
    d.DEVICES_PER_IP,
    d.GENDER_AGE_SEGMENT,
    d.IS_PANEL
