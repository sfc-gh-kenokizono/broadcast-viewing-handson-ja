-- 3 階層の ID を名寄せする。
--
-- 各局 ID   受信機 1 台につき局ごとに別の値。局をまたいで一致しない
-- 共通 ID   受信機 1 台につき 1 つ。5 局横断で一致する
-- IP アドレス 世帯（回線）の粒度。複数の受信機が同じ値を持つことがある
--
-- 同じ生データでも、どの ID で数えるかによって答えが変わります。
-- そこがこの層でいちばん大事なところです。

with device as (

    select
        COMMON_ID,
        max(IP_ADDRESS)                   as IP_ADDRESS,
        max(POSTAL_CODE)                 as POSTAL_CODE,
        min(VIEW_DATE)                   as FIRST_SEEN_DATE,
        max(VIEW_DATE)                   as LAST_SEEN_DATE,
        count(*)                         as VIEWING_SESSIONS,
        sum(VIEW_MINUTES)                as TOTAL_VIEW_MINUTES,
        count(distinct VIEW_DATE)        as ACTIVE_DAYS,
        -- この受信機が何局に登場したか。1 なら 1 局しか見ていない
        count(distinct NETWORK_ID)       as NETWORK_COUNT,
        -- 各局 ID は局ごとに別の値なので、登場した局数と同じ数になる
        count(distinct STATION_DEVICE_ID) as STATION_DEVICE_ID_COUNT,
        listagg(distinct NETWORK_ID, ',') within group (order by NETWORK_ID) as NETWORKS_SEEN
    from {{ ref('stg_viewing_log') }}
    group by COMMON_ID

),

ip_scale as (

    -- 1 つの IP アドレスに何台の受信機がぶら下がっているか。
    -- 2 台以上あるものは、集合住宅などで回線を共有している状態に相当します。
    -- IP アドレスを世帯の代わりに使うことの限界がここに出ます。
    select
        IP_ADDRESS,
        count(distinct COMMON_ID) as DEVICES_PER_IP
    from device
    group by IP_ADDRESS

)

select
    d.COMMON_ID,
    d.IP_ADDRESS,
    d.POSTAL_CODE,
    left(d.POSTAL_CODE, 3)          as POSTAL_AREA,
    i.DEVICES_PER_IP,
    d.NETWORK_COUNT,
    d.STATION_DEVICE_ID_COUNT,
    d.NETWORKS_SEEN,
    d.FIRST_SEEN_DATE,
    d.LAST_SEEN_DATE,
    d.ACTIVE_DAYS,
    d.VIEWING_SESSIONS,
    d.TOTAL_VIEW_MINUTES,
    -- パネル調査で属性が分かっている端末だけ値が入る。残りは NULL
    p.GENDER_AGE_SEGMENT,
    iff(p.GENDER_AGE_SEGMENT is not null, true, false) as IS_PANEL
from device d
inner join ip_scale i
    on d.IP_ADDRESS = i.IP_ADDRESS
left join {{ source('raw', 'PANEL_DEMOGRAPHICS') }} p
    on d.COMMON_ID = p.COMMON_ID
