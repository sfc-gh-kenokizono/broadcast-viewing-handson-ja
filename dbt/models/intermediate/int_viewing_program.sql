-- 視聴区間がどの番組の時間帯に重なっていたかを判定する。
--
-- 視聴ログには番組 ID が入っていません。届くのは「どのチャンネルを
-- いつからいつまで見たか」だけです。そこで番組の放送枠と時刻の範囲で
-- 突き合わせて、あとから番組を割り当てます。
--
-- 1 つの視聴区間が 2 つの番組にまたがることもあるため、
-- その場合は番組ごとに行が分かれます。重複ではなく、意図した挙動です。
-- 重なりが 1 分未満のものは、チャンネルを通り過ぎただけとみなして落とします。

select
    v.COMMON_ID,
    v.IP_ADDRESS,
    v.NETWORK_ID,
    v.CHANNEL_CODE,
    v.VIEW_DATE,
    s.PROGRAM_ID,
    s.AIR_DATE,
    greatest(v.VIEW_FROM, s.AIR_FROM)                                          as OVERLAP_FROM,
    least(v.VIEW_TO, s.AIR_TO)                                                 as OVERLAP_TO,
    datediff('second', greatest(v.VIEW_FROM, s.AIR_FROM),
                       least(v.VIEW_TO, s.AIR_TO)) / 60.0                      as OVERLAP_MINUTES,
    -- その放送回をどれだけ見通したか。1 に近いほど最後まで見ている
    datediff('second', greatest(v.VIEW_FROM, s.AIR_FROM), least(v.VIEW_TO, s.AIR_TO))
        / nullif(datediff('second', s.AIR_FROM, s.AIR_TO), 0)                  as COMPLETION_RATE
from {{ ref('stg_viewing_log') }} v
inner join {{ source('raw', 'PROGRAM_SCHEDULE') }} s
    on v.NETWORK_ID = s.NETWORK_ID
   and v.VIEW_FROM < s.AIR_TO
   and v.VIEW_TO   > s.AIR_FROM
where datediff('second', greatest(v.VIEW_FROM, s.AIR_FROM), least(v.VIEW_TO, s.AIR_TO)) >= 60
