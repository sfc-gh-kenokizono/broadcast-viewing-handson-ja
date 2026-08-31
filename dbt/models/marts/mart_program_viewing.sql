-- 番組ごと、放送回ごと、受信機ごとの視聴実績。
--
-- mart_device_daily と同じ考え方で、番組別の集計も
-- 「1 行 = 1 番組の放送回 × 1 台」という粒度で持ちます。
-- 視聴台数や推計視聴人数は、セマンティックビュー側で重複を除いて数えます。
--
-- 視聴ログに番組 ID は入っていません。番組の放送枠と時刻の範囲で
-- 突き合わせて割り当てています（int_viewing_program）。

select
    vp.PROGRAM_ID,
    p.PROGRAM_NAME,
    p.GENRE,
    p.TIME_SLOT,
    vp.NETWORK_ID,
    n.NETWORK_NAME,
    vp.AIR_DATE,
    vp.PROGRAM_AIR_FROM,
    vp.PROGRAM_AIR_TO,
    vp.COMMON_ID,
    vp.IP_ADDRESS,
    d.POSTAL_AREA,
    d.DEVICES_PER_IP,
    d.GENDER_AGE_SEGMENT,
    d.IS_PANEL,
    round(least(
        sum(vp.OVERLAP_MINUTES),
        datediff('second', vp.PROGRAM_AIR_FROM, vp.PROGRAM_AIR_TO) / 60.0
    ), 2) as VIEW_MINUTES,
    round(least(
        sum(vp.OVERLAP_MINUTES)
            / nullif(datediff('second', vp.PROGRAM_AIR_FROM, vp.PROGRAM_AIR_TO) / 60.0, 0),
        1
    ), 3) as COMPLETION_RATE
from {{ ref('int_viewing_program') }} vp
inner join {{ source('raw', 'PROGRAM_MASTER') }} p
    on vp.PROGRAM_ID = p.PROGRAM_ID
inner join {{ source('raw', 'NETWORK_MASTER') }} n
    on vp.NETWORK_ID = n.NETWORK_ID
inner join {{ ref('int_device_identity') }} d
    on vp.COMMON_ID = d.COMMON_ID
group by
    vp.PROGRAM_ID,
    p.PROGRAM_NAME,
    p.GENRE,
    p.TIME_SLOT,
    vp.NETWORK_ID,
    n.NETWORK_NAME,
    vp.AIR_DATE,
    vp.PROGRAM_AIR_FROM,
    vp.PROGRAM_AIR_TO,
    vp.COMMON_ID,
    vp.IP_ADDRESS,
    d.POSTAL_AREA,
    d.DEVICES_PER_IP,
    d.GENDER_AGE_SEGMENT,
    d.IS_PANEL