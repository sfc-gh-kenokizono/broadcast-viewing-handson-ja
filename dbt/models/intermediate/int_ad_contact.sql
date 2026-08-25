-- 放送と配信の接触を 1 つに揃える。
--
-- 増分リーチを出すには、放送で届いた人と配信で届いた人を
-- 同じ形にして並べる必要があります。ここで揃えておくと、
-- あとは重複を除いて数えるだけになります。
--
-- 実務上の注意
--   このハンズオンでは放送と配信のどちらも共通 ID で突き合わせています。
--   実際には配信側の識別子は広告識別子など別のものになるため、
--   その対応付けをどう作るかが設計上の論点になります。

select
    CM_ID,
    COMMON_ID,
    AIR_AT       as CONTACT_AT,
    'broadcast'  as CHANNEL_TYPE,
    NETWORK_ID,
    null         as DEVICE_TYPE
from {{ ref('int_cm_contact') }}

union all

select
    CM_ID,
    COMMON_ID,
    IMP_AT       as CONTACT_AT,
    'streaming'  as CHANNEL_TYPE,
    null         as NETWORK_ID,
    DEVICE_TYPE
from {{ source('raw', 'STREAMING_AD_LOG') }}
