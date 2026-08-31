with sequenced as (

    select
        COMMON_ID,
        NETWORK_ID,
        VIEW_FROM,
        VIEW_TO,
        max(VIEW_TO) over (
            partition by COMMON_ID
            order by VIEW_FROM, VIEW_TO
            rows between unbounded preceding and 1 preceding
        ) as PREVIOUS_MAX_VIEW_TO
    from {{ ref('stg_viewing_log') }}

)

select *
from sequenced
where VIEW_FROM < PREVIOUS_MAX_VIEW_TO