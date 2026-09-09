#!/usr/bin/env bash
set -euo pipefail

SITES_FILE="${SITES_FILE:-config/sites.tsv}"
SERVICE_ACCOUNT_JSON="${SERVICE_ACCOUNT_JSON:-$HOME/.secret/gsc-service-account.json}"
OUTPUT_FILE="${OUTPUT_FILE:-data/rank_history.tsv}"
TARGET_DATE="${TARGET_DATE:-}"
ROW_LIMIT="${ROW_LIMIT:-25000}"
VERBOSE="${VERBOSE:-0}"

TOKEN_URI="https://oauth2.googleapis.com/token"
SCOPE="https://www.googleapis.com/auth/webmasters.readonly"
TEMP_FILES=()

cleanup_temp_files() {
  local file

  for file in "${TEMP_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f "$file"
  done
  return 0
}
trap cleanup_temp_files EXIT

usage() {
  cat <<'USAGE'
Usage:
  ./check_rank.sh
  ./check_rank.sh --list-sites

Environment variables:
  SITES_FILE            Site-to-keywords TSV file.
                        Format: <site_url><tab><keywords_file>
                        Default: config/sites.tsv
  SERVICE_ACCOUNT_JSON  Google service account JSON key.
                        Default: ~/.secret/gsc-service-account.json
  OUTPUT_FILE           TSV output file.
                        Default: data/rank_history.tsv
  TARGET_DATE           Date to fetch in YYYY-MM-DD.
                        Default: 3 days ago
  ROW_LIMIT             Maximum rows to fetch per site.
                        Default: 25000
  VERBOSE               Print no-data messages to stderr when set to 1.
                        Default: 0

Example:
  TARGET_DATE='2026-09-07' ./check_rank.sh
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

base64_urlencode() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

default_target_date() {
  if date -v-3d '+%Y-%m-%d' >/dev/null 2>&1; then
    date -v-3d '+%Y-%m-%d'
  else
    date -d '3 days ago' '+%Y-%m-%d'
  fi
}

validate_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "TARGET_DATE must be YYYY-MM-DD: $1"
}

validate_row_limit() {
  [[ "$ROW_LIMIT" =~ ^[1-9][0-9]*$ ]] || die "ROW_LIMIT must be a positive integer: $ROW_LIMIT"
}

ensure_output_dir() {
  local output_dir

  output_dir="$(dirname "$OUTPUT_FILE")"
  if [[ "$output_dir" != "." ]]; then
    mkdir -p "$output_dir"
  fi
}

trim() {
  local value

  value="$1"
  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s\n' "$value"
}

check_prerequisites() {
  require_command curl
  require_command jq
  require_command openssl

  [[ -f "$SERVICE_ACCOUNT_JSON" ]] || die "service account JSON not found: $SERVICE_ACCOUNT_JSON"
  [[ -f "$SITES_FILE" ]] || die "sites file not found: $SITES_FILE"
  [[ -s "$SITES_FILE" ]] || die "sites file is empty: $SITES_FILE"

  jq -e '.client_email and .private_key' "$SERVICE_ACCOUNT_JSON" >/dev/null \
    || die "service account JSON must contain client_email and private_key"
}

create_jwt_assertion() {
  local now exp client_email private_key_file header claims signing_input signature

  now="$(date '+%s')"
  exp="$((now + 3600))"
  client_email="$(jq -r '.client_email' "$SERVICE_ACCOUNT_JSON")"
  private_key_file="$(mktemp)"
  TEMP_FILES+=("$private_key_file")

  jq -r '.private_key' "$SERVICE_ACCOUNT_JSON" >"$private_key_file"
  chmod 600 "$private_key_file"

  header="$(printf '{"alg":"RS256","typ":"JWT"}' | base64_urlencode)"
  claims="$(
    jq -cn \
      --arg iss "$client_email" \
      --arg scope "$SCOPE" \
      --arg aud "$TOKEN_URI" \
      --argjson iat "$now" \
      --argjson exp "$exp" \
      '{iss:$iss,scope:$scope,aud:$aud,iat:$iat,exp:$exp}' \
      | base64_urlencode
  )"
  signing_input="${header}.${claims}"
  signature="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$private_key_file" -binary | base64_urlencode)"

  printf '%s.%s\n' "$signing_input" "$signature"
}

get_access_token() {
  local assertion response response_file http_code

  assertion="$(create_jwt_assertion)"
  response_file="$(mktemp)"
  TEMP_FILES+=("$response_file")

  if ! http_code="$(
    curl -sS \
      -o "$response_file" \
      -w '%{http_code}' \
      -X POST "$TOKEN_URI" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
      --data-urlencode "assertion=$assertion"
  )"; then
    die "failed to call OAuth token endpoint"
  fi

  response="$(<"$response_file")"
  [[ "$http_code" == "200" ]] || die "failed to get access token: HTTP $http_code: $response"

  jq -er '.access_token' <<<"$response" \
    || die "failed to get access token: $response"
}

list_sites() {
  local access_token response response_file http_code

  access_token="$1"
  response_file="$(mktemp)"
  TEMP_FILES+=("$response_file")

  if ! http_code="$(
    curl -sS \
      -o "$response_file" \
      -w '%{http_code}' \
      -H "Authorization: Bearer ${access_token}" \
      'https://searchconsole.googleapis.com/webmasters/v3/sites'
  )"; then
    die "failed to call Search Console sites endpoint"
  fi

  response="$(<"$response_file")"
  [[ "$http_code" == "200" ]] || die "Search Console sites API error: HTTP $http_code: $response"

  jq -r '
    (.siteEntry // [])
    | sort_by(.siteUrl)
    | .[]
    | [.siteUrl, .permissionLevel]
    | @tsv
  ' <<<"$response"
}

query_site_positions() {
  local access_token site_url output_file site_path request response response_file http_code

  access_token="$1"
  site_url="$2"
  output_file="$3"
  site_path="$(jq -rn --arg value "$site_url" '$value|@uri')"

  request="$(
    jq -cn \
      --arg date "$TARGET_DATE" \
      --argjson row_limit "$ROW_LIMIT" \
      '{
        startDate: $date,
        endDate: $date,
        rowLimit: $row_limit,
        dimensions: ["query"],
        dimensionFilterGroups: [
          {
            filters: [
              {
                dimension: "country",
                operator: "equals",
                expression: "jpn"
              }
            ]
          }
        ]
      }'
  )"

  response_file="$(mktemp)"
  TEMP_FILES+=("$response_file")

  if ! http_code="$(
    curl -sS \
      -o "$response_file" \
      -w '%{http_code}' \
      -X POST "https://searchconsole.googleapis.com/webmasters/v3/sites/${site_path}/searchAnalytics/query" \
      -H "Authorization: Bearer ${access_token}" \
      -H 'Content-Type: application/json' \
      --data "$request"
  )"; then
    die "failed to call Search Console API for site: $site_url"
  fi

  response="$(<"$response_file")"
  [[ "$http_code" == "200" ]] || die "Search Console API error for site '$site_url': HTTP $http_code: $response"

  jq -e 'type == "object"' <<<"$response" >/dev/null \
    || die "unexpected API response for site: $site_url"

  jq -r '
    (.rows // [])
    | .[]
    | select((.keys[0] // "") != "" and .position != null)
    | [.keys[0], (.position | tostring)]
    | @tsv
  ' <<<"$response" >"$output_file"
}

match_keywords_to_positions() {
  local site_url keywords_file positions_file

  site_url="$1"
  keywords_file="$2"
  positions_file="$3"

  awk -F '\t' -v OFS='\t' -v date="$TARGET_DATE" -v site="$site_url" -v verbose="$VERBOSE" '
    function trim_value(value) {
      gsub(/^[ \t\r\n]+/, "", value)
      gsub(/[ \t\r\n]+$/, "", value)
      return value
    }
    FNR == NR {
      positions[$1] = $2
      normalized_positions[tolower($1)] = $2
      next
    }
    {
      keyword = trim_value($0)
      if (keyword == "" || keyword ~ /^#/) {
        next
      }
      if (keyword in positions) {
        position = positions[keyword]
      } else if (tolower(keyword) in normalized_positions) {
        position = normalized_positions[tolower(keyword)]
      } else {
        position = "NA"
        if (verbose == "1") {
          printf "no data: %s\n", keyword > "/dev/stderr"
        }
      }
      print date, site, keyword, position
    }
  ' "$positions_file" "$keywords_file"
}

display_results() {
  local results_file

  results_file="$1"

  awk -F '\t' '
    function rank_key(position) {
      if (position == "ERROR") {
        return 1000000001
      }
      if (position == "NA") {
        return 1000000000
      }
      return position + 0
    }
    {
      if (!seen_site[$2]++) {
        site_order++
      }
      printf "%06d\t%010.4f\t%06d\t%s\n", site_order, rank_key($4), NR, $0
    }
  ' "$results_file" | sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3n | cut -f4- | awk -F '\t' -v target_date="$TARGET_DATE" -v sites_file="$SITES_FILE" '
    function print_separator() {
      printf "%s\n", "--------------------------------------------------------------------------------"
    }
    function print_header(site) {
      print_separator()
      printf "Site: %s\n", site
      print_separator()
      printf "%-12s  %14s  %s\n", "Date", "GSC平均掲載順位", "Query"
      printf "%-12s  %14s  %s\n", "------------", "--------------", "-----"
    }
    BEGIN {
      printf "\nDate: %s\n", target_date
      printf "Sites: %s\n\n", sites_file
    }
    {
      date = $1
      site = $2
      query = $3
      position = $4

      if (site != current_site) {
        if (current_site != "") {
          printf "\n"
        }
        current_site = site
        print_header(site)
      }

      if (position != "NA" && position != "ERROR") {
        position = sprintf("%.2f", position)
      }
      printf "%-12s  %14s  %s\n", date, position, query
    }
    END {
      print_separator()
    }
  '
  printf '\n'
}

save_results() {
  local results_file merged_tmp

  results_file="$1"
  merged_tmp="$(mktemp)"
  TEMP_FILES+=("$merged_tmp")

  if [[ -f "$OUTPUT_FILE" ]]; then
    awk -F '\t' -v OFS='\t' '
      NF >= 4 {
        key = $1 OFS $2 OFS $3
        rows[key] = $0
        if (!(key in seen)) {
          order[++count] = key
          seen[key] = 1
        }
      }
      END {
        for (i = 1; i <= count; i++) {
          print rows[order[i]]
        }
      }
    ' "$OUTPUT_FILE" "$results_file" >"$merged_tmp"
  else
    cp "$results_file" "$merged_tmp"
  fi

  mv "$merged_tmp" "$OUTPUT_FILE"
}

main() {
  local access_token site_url keywords_file keyword output_tmp positions_tmp sites_tmp line_no row_count

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ -z "$TARGET_DATE" ]]; then
    TARGET_DATE="$(default_target_date)"
  fi

  validate_date "$TARGET_DATE"
  validate_row_limit
  check_prerequisites
  ensure_output_dir

  printf 'Authenticating with Google API... ' >&2
  access_token="$(get_access_token)"
  printf 'done\n' >&2

  if [[ "${1:-}" == "--list-sites" ]]; then
    list_sites "$access_token"
    exit 0
  fi

  printf 'Checking accessible Search Console sites... ' >&2
  sites_tmp="$(mktemp)"
  TEMP_FILES+=("$sites_tmp")
  list_sites "$access_token" >"$sites_tmp"
  printf 'done\n' >&2

  output_tmp="$(mktemp)"
  TEMP_FILES+=("$output_tmp")

  line_no=0
  while IFS=$'\t' read -r site_url keywords_file extra || [[ -n "$site_url" ]]; do
    line_no="$((line_no + 1))"
    site_url="$(trim "$site_url")"
    keywords_file="$(trim "${keywords_file:-}")"
    [[ -z "$site_url" ]] && continue
    [[ "$site_url" == \#* ]] && continue
    [[ -n "${keywords_file:-}" ]] || die "$SITES_FILE:$line_no: missing keywords file"
    [[ -z "${extra:-}" ]] || die "$SITES_FILE:$line_no: too many columns"
    [[ -f "$keywords_file" ]] || die "$SITES_FILE:$line_no: keywords file not found: $keywords_file"
    [[ -s "$keywords_file" ]] || die "$SITES_FILE:$line_no: keywords file is empty: $keywords_file"

    printf 'Fetching %s (%s): ' "$site_url" "$keywords_file" >&2

    if ! awk -F '\t' -v site="$site_url" '$1 == site { found=1 } END { exit !found }' "$sites_tmp"; then
      printf 'not accessible\n' >&2
      printf 'warning: site is not accessible by this service account: %s\n' "$site_url" >&2
      while IFS= read -r keyword || [[ -n "$keyword" ]]; do
        keyword="$(trim "$keyword")"
        [[ -z "$keyword" ]] && continue
        [[ "$keyword" == \#* ]] && continue
        printf '%s\t%s\t%s\tERROR\n' "$TARGET_DATE" "$site_url" "$keyword" >>"$output_tmp"
      done <"$keywords_file"
      continue
    fi

    positions_tmp="$(mktemp)"
    TEMP_FILES+=("$positions_tmp")
    query_site_positions "$access_token" "$site_url" "$positions_tmp"
    match_keywords_to_positions "$site_url" "$keywords_file" "$positions_tmp" >>"$output_tmp"
    row_count="$(wc -l <"$positions_tmp" | tr -d ' ')"
    printf '# done (%s GSC query row(s))\n' "$row_count" >&2
  done <"$SITES_FILE"

  if [[ -s "$output_tmp" ]]; then
    save_results "$output_tmp"
    display_results "$output_tmp"
    printf 'saved %s row(s) to %s\n' "$(wc -l <"$output_tmp" | tr -d ' ')" "$OUTPUT_FILE"
  else
    printf 'no rows returned for %s\n' "$TARGET_DATE"
  fi
}

main "$@"
