#!/bin/bash
# Retention of the AiGotchi game's logs (card #55, owner «Б»): their own day indices unity-events-aigotchi-YYYY.MM.DD,
# deleted 90 days after the day in the name. Other games stay in unity-events as they are.
#
# Vector (vector/vector.yaml) names the day index by its receive time "timestamp" (UTC). The prefix keeps the indices
# under unity-events*, so the Kibana index pattern and the transform app-users-first-seen still see AiGotchi.
#
# Order on the logs server, from the lead's machine (the password stays in the node01 container):
#   ssh root@<server> 'bash -s check'   < aigotchi-retention.sh  # read-only
#   ssh root@<server> 'bash -s apply'   < aigotchi-retention.sh  # policy and template, before Vector's deploy
#   deploy vector.yaml (push → Coolify)                           # new AiGotchi events go to the day indices
#   ssh root@<server> 'bash -s migrate' < aigotchi-retention.sh  # once: old AiGotchi events out of unity-events
#   ssh root@<server> 'bash -s verify'  < aigotchi-retention.sh  # read-only
# Locally: ES=127.0.0.1:<port> ES_PASSWORD=<local password> bash aigotchi-retention.sh <command>
set -euo pipefail
ES=${ES:-localhost:9200}
P=${ES_PASSWORD:-$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
  "$(docker ps -q --filter name=node01- | head -1)" | sed -n 's/^ELASTIC_PASSWORD=//p')}
es() { curl -sS -m 600 -u "elastic:$P" -H 'Content-Type: application/json' -X "$1" "$ES/$2" ${3:+-d "$3"}; echo; }
GAME='{"term":{"game.keyword":"AiGotchi"}}'
DAYS='"aggs":{"days":{"date_histogram":{"field":"timestamp","calendar_interval":"day","min_doc_count":1}}}'
DAYS_PATH='filter_path=hits.total.value,aggregations.days.buckets.key_as_string,aggregations.days.buckets.doc_count'

case "${1:-}" in
check)
  es GET '_cat/indices/unity-events*?v&s=index&h=index,health,docs.count,store.size,creation.date.string'
  es GET 'unity-events/_mapping/field/game,timestamp,deviceId,first_start_at?filter_path=*.mappings.*.mapping' # game.keyword; date first_start_at rejects ""
  es GET "unity-events/_search?size=0&track_total_hits=true&$DAYS_PATH" "{\"query\":$GAME,$DAYS}" # AiGotchi by day
  es GET '_ilm/status'
  es GET '_ilm/policy/unity-events-aigotchi-90d'    # 404 before apply
  es GET '_index_template/unity-events-aigotchi'    # 404 before apply
  es GET '_cluster/settings?include_defaults=true&filter_path=*.action.auto_create_index,*.cluster.max_shards_per_node'
  es GET '_cluster/health?filter_path=status,active_shards,unassigned_shards' # one index per day adds shards
  es GET '.kibana/_search?size=100&q=type:index-pattern&filter_path=hits.hits._source.index-pattern.title'
  es GET '_transform/app-users-first-seen/_stats?filter_path=transforms.state,transforms.checkpointing.last.checkpoint'
  ;;
apply)
  # Delete phase only; the age counts from the date in the index name (index.lifecycle.parse_origination_date), so a
  # day's logs live 90 days whenever they were written, migrated ones included.
  es PUT '_ilm/policy/unity-events-aigotchi-90d' '{"policy":{"phases":{"delete":{"min_age":"90d","actions":{"delete":{}}}}}}'
  # The mapping of unity-events as it is now: the same field types every day (a dynamic mapping per day could take a
  # date-looking string for a date and then reject the day's other events) and no conflicts in unity-events*.
  m=$(es GET 'unity-events/_mapping')
  m=${m#'{"unity-events":{"mappings":'}
  m=${m%'}}'}
  [[ "$m" == '{'* ]] || { echo "unexpected unity-events mapping: nothing applied" >&2; exit 1; }
  es PUT '_index_template/unity-events-aigotchi' "{\"index_patterns\":[\"unity-events-aigotchi-*\"],\"priority\":100,
    \"template\":{\"settings\":{\"index.lifecycle.name\":\"unity-events-aigotchi-90d\",
    \"index.lifecycle.parse_origination_date\":true},\"mappings\":$m}}"
  ;;
migrate)
  # Only after Vector's deploy: then no AiGotchi event lands in unity-events any more and the set below is final.
  recent=$(es GET 'unity-events/_count' "{\"query\":{\"bool\":{\"filter\":[$GAME,{\"range\":{\"timestamp\":{\"gte\":\"now-5m\"}}}]}}}")
  [[ "$recent" == *'"count":0,'* ]] || { echo "AiGotchi still lands in unity-events ($recent): deploy Vector first" >&2; exit 1; }
  before=$(es GET 'unity-events/_count' "{\"query\":$GAME}" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
  # Each event goes to the index of its day; the source _id is kept, so a rerun overwrites instead of duplicating.
  out=$(es POST '_reindex?wait_for_completion=true' "{\"source\":{\"index\":\"unity-events\",\"query\":$GAME},
    \"dest\":{\"index\":\"unity-events-aigotchi-migrated\"},\"script\":{\"lang\":\"painless\",
    \"source\":\"ctx._index = 'unity-events-aigotchi-' + ctx._source.timestamp.substring(0, 10).replace('-', '.')\"}}")
  echo "$out"
  total=$(sed -n 's/.*"total":\([0-9]*\).*/\1/p' <<<"$out")
  created=$(sed -n 's/.*"created":\([0-9]*\).*/\1/p' <<<"$out")
  updated=$(sed -n 's/.*"updated":\([0-9]*\).*/\1/p' <<<"$out")
  if [[ "$out" != *'"failures":[]'* || -z "$total" || "$total" != "$before" || "$total" != $((created + updated)) ]]; then
    echo "reindex incomplete (unity-events had $before): nothing deleted from unity-events" >&2
    exit 1
  fi
  es POST 'unity-events/_delete_by_query?wait_for_completion=true&refresh=true' "{\"query\":$GAME}"
  ;;
verify)
  es GET '_cat/indices/unity-events*?v&s=index&h=index,docs.count,creation.date.string'
  es GET 'unity-events-aigotchi-*/_ilm/explain?filter_path=indices.*.managed,indices.*.policy,indices.*.age,indices.*.phase,indices.*.step_info'
  es GET 'unity-events/_count' "{\"query\":$GAME}"   # 0 after migrate
  es GET "unity-events-aigotchi-*/_search?size=0&track_total_hits=true&$DAYS_PATH" "{$DAYS}" # = check's days, ≤ 90 days old
  ;;
*)
  echo "usage: aigotchi-retention.sh check|apply|migrate|verify" >&2
  exit 2
  ;;
esac
