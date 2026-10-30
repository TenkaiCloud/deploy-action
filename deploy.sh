#!/usr/bin/env bash
#
# Asks Tenkai for a Deployment through a Deploy Hook, then reads the Deployment until it ends. With TENKAI_PATH, sends
# the content of that directory as the tar.gz of a Web Application of Static Files. With TENKAI_PULL_REQUEST and
# TENKAI_IMAGE_TAG, deploys that tag of the image of the Web Application into the preview of the pull request.
# Exits 0 when the Deployment succeeded, or was queued and TENKAI_WAIT is "false". Exits 1 otherwise.

set -euo pipefail

: "${TENKAI_DEPLOY_HOOK_URL:?Set the deploy_hook_url input}"
: "${TENKAI_DEPLOY_HOOK_SECRET:?Set the deploy_hook_secret input}"
wait_for_end="${TENKAI_WAIT:-true}"
timeout="${TENKAI_TIMEOUT:-900}"
interval="${TENKAI_INTERVAL:-5}"
path="${TENKAI_PATH:-}"
pull_request="${TENKAI_PULL_REQUEST:-}"
image_tag="${TENKAI_IMAGE_TAG:-}"
# The size of the archive Tenkai accepts. Tenkai stops reading beyond it, so the step checks it before it sends.
max_archive_bytes=$((100 * 1024 * 1024))
# How many reads in a row may fail before the step gives up: a 5xx, a 429 or a network error.
max_failed_reads=5

if ! [[ "$timeout" =~ ^[0-9]+$ && "$interval" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::timeout and interval are numbers of seconds, and interval is at least 1"
	exit 1
fi

if [[ -n "$pull_request" || -n "$image_tag" ]]; then
	if [[ -z "$pull_request" || -z "$image_tag" ]]; then
		echo "::error::Set pull_request and image_tag together to deploy into the preview of a pull request"
		exit 1
	fi

	if ! [[ "$pull_request" =~ ^[1-9][0-9]*$ ]]; then
		echo "::error::pull_request is the number of the pull request, such as 12, and $pull_request is not one"
		exit 1
	fi

	if [[ -n "$path" ]]; then
		echo "::error::A preview deploys an image, which takes no path. Leave path out, or pull_request and image_tag"
		exit 1
	fi
fi

# The secret is a step input, which GitHub does not mask unless it came from a secret.
echo "::add-mask::$TENKAI_DEPLOY_HOOK_SECRET"

body=$(mktemp)
archive=$(mktemp)
trap 'rm -f "$body" "$archive"' EXIT

# Sends a request with the secret and prints the HTTP status. The body goes to "$body". Prints 000 when
# Tenkai did not answer.
request() {
	curl --silent --show-error --max-time 30 --output "$body" --write-out '%{http_code}' \
		--header "Authorization: Bearer $TENKAI_DEPLOY_HOOK_SECRET" "$@" || true
}

# What Tenkai says of a refusal, or the HTTP status when the body is not the JSON of a refusal, with what to do for a
# refusal of a preview.
refusal() {
	local said error

	if ! said=$(jq --exit-status --raw-output 'select(.error and .message) | "\(.error): \(.message)"' "$body" 2>/dev/null); then
		echo "HTTP $1"
		return
	fi

	error=${said%%:*}

	case "$error" in
	invalid_image_tag)
		said+=". Set image_tag to the tag you pushed of the image the Web Application deploys, such as pr-$pull_request, without the name of the image"
		;;
	invalid_preview_request)
		said+=". Set pull_request and image_tag together"
		;;
	preview_not_found)
		said+=". Check that previews are on for the project and that pull request #$pull_request has an open preview. A preview opened before Tenkai deployed images takes them once the pull request is closed and reopened"
		;;
	preview_not_open)
		said+=". The first preview of a project waits about a minute for its database. Run the job again"
		;;
	preview_image_changed)
		said+=". Close and reopen the pull request so its preview copies the image the Web Application deploys now"
		;;
	preview_ambiguous)
		said+=". Name the image after the repository of the pull request, as ghcr.io/<owner>/<repository>"
		;;
	esac

	echo "$said"
}

output() {
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		echo "$1=$2" >>"$GITHUB_OUTPUT"
	fi
}

files=()

if [[ -n "$path" ]]; then
	# The directory itself, through the links of the path, so the checks below read the tree that tar packs. An empty
	# CDPATH keeps cd from resolving a relative path elsewhere, and -P follows a link before the .. after it, as tar does.
	if ! site=$(CDPATH="" cd -P -- "$path" 2>/dev/null && pwd -P); then
		echo "::error::path must be a directory, and $path is not one"
		exit 1
	fi

	# Tenkai takes regular files and directories only, so the archive keeps no link to a file outside the directory.
	others=$(find "$site" -mindepth 1 ! -type f ! -type d | head -n 5)

	if [[ -n "$others" ]]; then
		echo "::error::$path holds entries that are neither files nor directories, such as links. Tenkai takes files and directories only: ${others//$'\n'/, }"
		exit 1
	fi

	# Tenkai refuses the hard-link entry tar writes for the second path of a file. GNU tar, on Linux runners, writes
	# each path as a regular file instead. The bsdtar of macOS cannot, so the step refuses hard links there.
	tar_options=()

	if tar --version 2>/dev/null | grep --quiet 'GNU tar'; then
		tar_options=(--hard-dereference)
	else
		linked=$(find "$site" -type f -links +1 | head -n 5)

		if [[ -n "$linked" ]]; then
			echo "::error::$path holds hard links, which the tar of this runner cannot pack as files. Copy them, or deploy from a Linux runner: ${linked//$'\n'/, }"
			exit 1
		fi
	fi

	# The content of the directory at the root of the archive, as ./index.html. COPYFILE_DISABLE keeps the tar of
	# macOS from adding the ._ files of extended attributes.
	COPYFILE_DISABLE=1 tar ${tar_options[@]+"${tar_options[@]}"} -czf "$archive" -C "$site" .
	archive_bytes=$(wc -c <"$archive" | tr -d ' ')

	if ((archive_bytes > max_archive_bytes)); then
		echo "::error::The archive of $path weighs $((archive_bytes / 1024 / 1024)) MB. Tenkai takes an archive under 100 MB."
		exit 1
	fi

	echo "Sending $path, $(((archive_bytes + 1023) / 1024)) KB packed"
	# The upload may take longer than a read.
	files=(--max-time 600 --header "Content-Type: application/gzip" --data-binary "@$archive")
fi

url="$TENKAI_DEPLOY_HOOK_URL"

if [[ -n "$pull_request" ]]; then
	query=$(jq --null-input --raw-output --arg pr "$pull_request" --arg tag "$image_tag" \
		'"pull_request=\($pr | @uri)&image_tag=\($tag | @uri)"')
	url+="?$query"
	echo "Deploying image tag $image_tag into the preview of pull request #$pull_request"
fi

# The expansion stays empty under set -u in the bash 3 of macOS.
status=$(request --request POST ${files[@]+"${files[@]}"} "$url")

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
