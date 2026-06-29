#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="${ROOT_DIR}/.env"
CONFIG_FILE="${ROOT_DIR}/scripts/records.conf"

[[ -f "$ENV_FILE" ]] || {
    echo ".env not found"
    exit 1
}

[[ -f "$CONFIG_FILE" ]] || {
    echo "records.conf not found"
    exit 1
}

source "$ENV_FILE"

CURRENT_IP="$(curl -4 -fsSL "$WAN_IP_PROVIDER" | tr -d '\n')"

echo
echo "=========================================="
echo " Cloudflare DDNS"
echo "=========================================="
echo "Current IP : ${CURRENT_IP}"
echo

MAIL_BODY=""

get_zone_id() {

    case "$1" in
        nextchat.vn)
            echo "$CF_ZONE_NEXTCHAT"
            ;;
        kifu.id.vn)
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

while read -r ZONE HOST PROXIED
do

    [[ -z "${ZONE:-}" ]] && continue

    echo "------------------------------------------"
    echo "Checking : ${HOST}"

    ZONE_ID="$(get_zone_id "$ZONE")"

    if [[ -z "$ZONE_ID" ]]; then
        echo "ERROR: Unknown zone '${ZONE}'"
        continue
    fi

    RESPONSE="$(get_record "$ZONE_ID" "$HOST")"

    SUCCESS="$(jq -r '.success' <<< "$RESPONSE")"

    if [[ "$SUCCESS" != "true" ]]; then
        echo "Cloudflare API error"
        jq '.errors' <<< "$RESPONSE"
        continue
    fi

    RECORD_ID="$(jq -r '.result[0].id' <<< "$RESPONSE")"

    if [[ "$RECORD_ID" == "null" ]]; then
        echo "ERROR: DNS record does not exist."
        echo "Please create '${HOST}' in Cloudflare first."
        continue
    fi

    OLD_IP="$(jq -r '.result[0].content' <<< "$RESPONSE")"

    if [[ "$OLD_IP" == "$CURRENT_IP" ]]; then
        echo "No change."
        continue
    fi

    UPDATE="$(update_record "$ZONE_ID" "$RECORD_ID" "$HOST" "$PROXIED")"

    UPDATE_SUCCESS="$(jq -r '.success' <<< "$UPDATE")"

    if [[ "$UPDATE_SUCCESS" == "true" ]]; then

        echo "Updated:"
        echo "    ${OLD_IP}"
        echo " -> ${CURRENT_IP}"

        MAIL_BODY+=$'\n'
        MAIL_BODY+="${HOST}"
        MAIL_BODY+=$'\n'
        MAIL_BODY+="    ${OLD_IP} -> ${CURRENT_IP}"
        MAIL_BODY+=$'\n'

    else

        echo "Update failed"

        jq '.errors' <<< "$UPDATE"

    fi

done < <(

    grep -v '^[[:space:]]*#' "$CONFIG_FILE" |
    grep -v '^[[:space:]]*$'

)

echo "------------------------------------------"

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
echo "Finished."
echo