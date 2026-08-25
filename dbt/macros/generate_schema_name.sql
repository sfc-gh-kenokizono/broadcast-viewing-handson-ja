{#
  スキーマ名の決め方を上書きしています。

  dbt の既定では、モデルに schema を指定すると
  「接続先のスキーマ名 + 指定したスキーマ名」という連結になります。
  たとえば接続先が STG で、モデルに MART を指定すると STG_MART になります。

  このハンズオンでは RAW / STG / INT / MART の 4 つをそのまま使いたいので、
  指定した名前をそのまま採用するように変えています。
  dbt を既存の環境に持ち込むときによく最初に書く上書きです。
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
