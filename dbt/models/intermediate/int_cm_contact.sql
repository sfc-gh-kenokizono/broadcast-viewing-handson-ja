-- 放送されたコマーシャルに、どの受信機が接触したかを判定する。
--
-- コマーシャルが流れた瞬間に、その局を見ていた区間が重なっていれば接触とみなします。
-- 放送実績の時刻が視聴区間の中に入っているかどうかだけを見ています。

select
    sp.SPOT_ID,
    sp.CM_ID,
    sp.NETWORK_ID,
    sp.AIR_AT,
    sp.AIR_AT::date  as CONTACT_DATE,
    v.COMMON_ID,
    v.IP_ADDRESS
from {{ source('raw', 'CM_SPOT') }} sp
inner join {{ source('raw', 'CM_MASTER') }} cm
    on sp.CM_ID = cm.CM_ID
   and cm.IS_ANALYSIS_TARGET
inner join {{ ref('stg_viewing_log') }} v
    on v.NETWORK_ID = sp.NETWORK_ID
   and sp.AIR_AT >= v.VIEW_FROM
   and sp.AIR_AT <  v.VIEW_TO
