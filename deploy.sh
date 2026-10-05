#!/usr/bin/env bash
#
# Asks Tenkai for a Deployment through a Deploy Hook, then reads the Deployment until it ends.
# Exits 0 when the Deployment succeeded, or was queued and TENKAI_WAIT is "false". Exits 1 otherwise.

set -euo pipefail

: "${TENKAI_DEPLOY_HOOK_URL:?Set the deploy_hook_url input}"
: "${TENKAI_DEPLOY_HOOK_SECRET:?Set the deploy_hook_secret input}"
wait_for_end="${TENKAI_WAIT:-true}"
timeout="${TENKAI_TIMEOUT:-900}"
interval="${TENKAI_INTERVAL:-5}"
# How many reads in a row may fail before the step gives up: a 5xx, a 429 or a network error.
max_failed_reads=5

if ! [[ "$timeout" =~ ^[0-9]+$ && "$interval" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::timeout and interval are numbers of seconds, and interval is at least 1"
	exit 1
fi

# The secret is a step input, which GitHub does not mask unless it came from a secret.
echo "::add-mask::$TENKAI_DEPLOY_HOOK_SECRET"

body=$(mktemp)
trap 'rm -f "$body"' EXIT

# Sends a request with the secret and prints the HTTP status. The body goes to "$body". Prints 000 when
# Tenkai did not answer.
request() {
	curl --silent --show-error --max-time 30 --output "$body" --write-out '%{http_code}' \
		--header "Authorization: Bearer $TENKAI_DEPLOY_HOOK_SECRET" "$@" || true
}

# What Tenkai says of a refusal, or the HTTP status when the body is not the JSON of a refusal.
refusal() {
	jq --exit-status --raw-output 'select(.error and .message) | "\(.error): \(.message)"' "$body" 2>/dev/null ||
		echo "HTTP $1"
}

output() {
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		echo "$1=$2" >>"$GITHUB_OUTPUT"
	fi
}

status=$(request --request POST "$TENKAI_DEPLOY_HOOK_URL")

if [[ "$status" != "202" ]]; then
	echo "::error::Tenkai did not queue the Deployment. $(refusal "$status")"
	exit 1
fi

deployment_id=$(jq --raw-output '.deployment.id' "$body")
deployment_url=$(jq --raw-output '.deployment.url' "$body")
output deployment_id "$deployment_id"
output deployment_url "$deployment_url"
echo "Tenkai queued Deployment $deployment_id"

if [[ "$wait_for_end" != "true" ]]; then
	output status started
	exit 0
fi

deadline=$((SECONDS + timeout))
failed_reads=0
phase=""

while true; do
	status=$(request "$deployment_url")

	if [[ "$status" == "200" ]]; then
		failed_reads=0
		deployment_status=$(jq --raw-output '.deployment.statusName' "$body")
		phase_now=$(jq --raw-output '.deployment.phaseLabel' "$body")

		if [[ "$phase_now" != "$phase" ]]; then
			phase="$phase_now"
			echo "$phase"
		fi

		if [[ "$deployment_status" == "succeeded" ]]; then
			output status succeeded
			echo "The Deployment succeeded"
			exit 0
		fi

		if [[ "$deployment_status" == "failed" ]]; then
			output status failed
			echo "::error::The Deployment failed. $(jq --raw-output '.deployment.statusDetails' "$body")"
			exit 1
		fi
	elif [[ "$status" == "000" || "$status" == "429" || "$status" == 5* ]]; then
		failed_reads=$((failed_reads + 1))

		if ((failed_reads >= max_failed_reads)); then
			echo "::error::Tenkai did not answer $max_failed_reads reads in a row. The Deployment may still run. $(refusal "$status")"
			exit 1
		fi
	else
		# A secret rotated or revoked since, or a Deployment that is gone: reading again changes nothing.
		echo "::error::Tenkai refused to tell how the Deployment goes. $(refusal "$status")"
		exit 1
	fi

	if ((SECONDS + interval > deadline)); then
		echo "::error::The Deployment did not end within $timeout seconds. It still runs on Tenkai."
		exit 1
	fi

	sleep "$interval"
done
