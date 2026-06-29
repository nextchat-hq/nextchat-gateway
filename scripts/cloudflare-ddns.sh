#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="${ROOT_DIR}/.env"
CONFIG_FILE="${ROOT_DIR}/scripts/records.conf"

[[ -f "$ENV_FILE" ]] || {
    echo ".env not found"
    exit 1
}

source "$ENV_FILE"

CURRENT_IP="$(curl -4 -fsSL "$WAN_IP_PROVIDER" | tr -d '\n')"

echo
echo "=========================================="
echo "Cloudflare DDNS"
echo "Current IP : ${CURRENT_IP}"
echo "=========================================="

MAIL_BODY=""

get_zone_id() {

    case "$1" in
        nextchat)
            echo "$CF_ZONE_NEXTCHAT"
            ;;

        kifu)
            echo "$CF_ZONE_KIFU"
            ;;

        *)
            echo ""
            ;;
    esac

}

get_record() {

    local zone_id="$1"
    local host="$2"

    curl -fsSL \
        -H "Authorization: Bearer ${CF_DNS_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${host}"

}

update_record() {

    local zone_id="$1"
    local record_id="$2"
    local host="$3"
    local proxied="$4"

    curl -fsSL \
        -X PUT \
        -H "Authorization: Bearer ${CF_DNS_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
        --data "{
            \"type\":\"A\",
            \"name\":\"${host}\",
            \"content\":\"${CURRENT_IP}\",
            \"ttl\":120,
            \"proxied\":${proxied}
        }"

}

while IFS=',' read -r ZONE HOST PROXIED || [[ -n "$ZONE" ]]
do

    [[ -z "${ZONE// }" ]] && continue

    [[ "$ZONE" =~ ^# ]] && continue

    echo
    echo "Checking ${HOST}"

    ZONE_ID="$(get_zone_id "$ZONE")"

    if [[ -z "$ZONE_ID" ]]; then
        echo "Unknown zone: ${ZONE}"
        continue
    fi

    RESPONSE="$(get_record "$ZONE_ID" "$HOST")"

    SUCCESS="$(jq -r '.success' <<< "$RESPONSE")"

    if [[ "$SUCCESS" != "true" ]]; then
        echo "Cloudflare API error"
        continue
    fi

    RECORD_ID="$(jq -r '.result[0].id' <<< "$RESPONSE")"
    OLD_IP="$(jq -r '.result[0].content' <<< "$RESPONSE")"

    if [[ "$RECORD_ID" == "null" ]]; then
        echo "Record not found."
        continue
    fi

    if [[ "$OLD_IP" == "$CURRENT_IP" ]]; then
        echo "No change."
        continue
    fi

    UPDATE="$(update_record "$ZONE_ID" "$RECORD_ID" "$HOST" "$PROXIED")"

    UPDATE_SUCCESS="$(jq -r '.success' <<< "$UPDATE")"

    if [[ "$UPDATE_SUCCESS" == "true" ]]; then

        echo "Updated."

        MAIL_BODY+=$'\n'
        MAIL_BODY+="${HOST}"
        MAIL_BODY+=$'\n'
        MAIL_BODY+="    ${OLD_IP} → ${CURRENT_IP}"
        MAIL_BODY+=$'\n'

    else

        echo "Update failed."

        jq '.errors' <<< "$UPDATE"

    fi

done < <(
    grep -v '^[[:space:]]*#' "$CONFIG_FILE" |
    grep -v '^[[:space:]]*$'
)

if [[ -n "$MAIL_BODY" ]]; then

mail -s "[NextChat] Cloudflare DDNS Updated" "$DDNS_ALERT_EMAIL" <<EOF
Cloudflare DDNS updated

${MAIL_BODY}

Server : $(hostname)

Time   : $(date)

IP     : ${CURRENT_IP}

EOF

fi

echo
echo "Done."
echo