#!/bin/bash
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"query": "{ globalStat(id: \"global\") { id totalSBTs totalCommunities totalActivities } }"}' \
  https://api.studio.thegraph.com/query/1704882/mysbt-v-2-3/v2.3.0
