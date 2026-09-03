-- 局ごと、1 分ごとの視聴台数。
--
-- int_viewing_minutes（約 1,208 万行、誰が・何分に）を「局 × 分」で数えて、
-- 「何台が見ていたか」だけを残します。行数は約 55 万行に縮みます。
--
--   展開した行（誰が・何分に）             縮めた行（局・何分・何台）
--   C000123  NW01  20:00                   NW01  20:00  8,123 台
--   C000456  NW01  20:00                   NW01  20:01  8,201 台
--   C000789  NW01  20:00                   ...
--   ...（1,208 万行）                      （66 万行）
--
-- なぜこの形にするのか
--   毎分の視聴台数カーブは、from-to のままでは描きにくい指標です。
--   一方で、展開した 1,208 万行を提供層にそのまま置くと、保存量も
--   参照時の計算量も M 倍のまま残ります。「誰が」を捨てて「何台」だけを
--   持てば、時間軸を刻んだグラフに必要な情報は残したまま小さくできます。
--
-- 使う場所
--   第 5 章の可視化アプリ「毎分の推移」タブ。日付と局を選ぶと、
--   その日の 1 分刻みの折れ線が描けます。番組の切り替わりや CM ブレークで
--   台数が動く様子は、この粒度でないと見えません。

select
    m.NETWORK_ID,
    n.NETWORK_NAME,
    m.VIEW_DATE,
    m.MINUTE_AT,
    count(distinct m.COMMON_ID) as VIEWING_DEVICES
from {{ ref('int_viewing_minutes') }} m
inner join {{ source('raw', 'NETWORK_MASTER') }} n
    on m.NETWORK_ID = n.NETWORK_ID
group by
    m.NETWORK_ID,
    n.NETWORK_NAME,
    m.VIEW_DATE,
    m.MINUTE_AT
