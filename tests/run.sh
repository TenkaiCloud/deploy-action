#!/usr/bin/env bash
#
# Runs deploy.sh against a Tenkai that answers from a script, and checks how each run ends.

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
port=18473
secret=tenkai_deploy_test
work=$(mktemp -d)
failures=0
server=""

stop_server() {
	if [[ -n "$server" ]]; then
		kill "$server" 2>/dev/null
		wait "$server" 2>/dev/null
		server=""
	fi
}

trap 'stop_server; rm -rf "$work"' EXIT

# Starts a Tenkai that answers the trigger with a status, then each read with the next answer.
tenkai() {
	stop_server
	MOCK_TENKAI_BODY="$work/sent.tar.gz" python3 "$root/tests/mock_tenkai.py" "$port" "$secret" "$@" >"$work/requests" &
	server=$!

	until curl --silent --output /dev/null "http://127.0.0.1:$port/"; do
		sleep 0.1
	done

	: >"$work/requests"
}

# Runs the action with the environment given as NAME=value arguments. Keeps its exit status, log and outputs.
deploy() {
	: >"$work/outputs"
	env TENKAI_DEPLOY_HOOK_URL="http://127.0.0.1:$port/deploy-hooks/resource" \
		TENKAI_DEPLOY_HOOK_SECRET="$secret" TENKAI_INTERVAL=1 GITHUB_OUTPUT="$work/outputs" "$@" \
		"$root/deploy.sh" >"$work/log" 2>&1
	exit_status=$?
}

check() {
	local name=$1
	shift

	if "$@"; then
		echo "ok   $name"
	else
		echo "FAIL $name"
		sed 's/^/     | /' "$work/log"
		failures=$((failures + 1))
	fi
}

exits() { [[ "$exit_status" == "$1" ]]; }
logs() { grep --quiet --fixed-strings -- "$1" "$work/log"; }
outputs() { grep --quiet --line-regexp --fixed-strings -- "$1" "$work/outputs"; }
posts() { [[ "$(grep --count '^POST' "$work/requests")" == "$1" ]]; }
# The POST, as the path of the hook followed by its query, if any, then the Content-Type and the length of the body.
sent() {
	local query=""
	[[ "$1" == \?* ]] && query=${1%% *}
	grep --quiet --line-regexp --fixed-strings -- "POST /deploy-hooks/resource$query ${1#"$query" }" "$work/requests"
}
reads() { [[ "$(grep --count '^GET' "$work/requests")" == "$1" ]]; }

tenkai 202 started started succeeded
deploy
check "succeeds when the Deployment succeeds" exits 0
check "reads the Deployment until it ends" reads 3
check "gives the status as an output" outputs "status=succeeded"
check "gives the Deployment as an output" outputs "deployment_id=0199b1c2-0000-7000-8000-000000000001"
check "prints each phase once" [ "$(grep --count 'Checking health' "$work/log")" == 1 ]
check "masks the secret" logs "::add-mask::$secret"

tenkai 202 started failed
deploy
check "fails when the Deployment fails" exits 1
check "says why the Deployment failed" logs "::error::The Deployment failed. Image build failed"
check "gives the failed status as an output" outputs "status=failed"

check "sends no body without a path" sent "- 0"

tenkai 409:mutation_in_progress started
deploy
check "fails when Tenkai refuses the Deployment" exits 1
check "says why Tenkai refused" logs "mutation_in_progress: Tenkai refused with mutation_in_progress"
check "reads nothing after a refusal" reads 0

tenkai 202 started
deploy TENKAI_WAIT=false
check "stops once the Deployment is queued when it does not wait" exits 0
check "reads nothing when it does not wait" reads 0
check "gives the started status when it does not wait" outputs "status=started"

tenkai 202 started
deploy TENKAI_TIMEOUT=2
check "fails when the Deployment does not end in time" exits 1
check "says the Deployment still runs" logs "did not end within 2 seconds"

tenkai 202 503 503 succeeded
deploy
check "reads again when Tenkai is unavailable for a moment" exits 0

tenkai 202 503
deploy
check "gives up when Tenkai stays unavailable" exits 1
check "stops after five failed reads" reads 5

tenkai 202 404
deploy
check "fails at once when Tenkai refuses the read" exits 1
check "does not read again after a refused read" reads 1

tenkai 202 succeeded
deploy TENKAI_DEPLOY_HOOK_SECRET=tenkai_deploy_wrong
check "fails with a wrong secret" exits 1
check "says the secret is wrong" logs "invalid_deploy_hook_secret"

tenkai 202 succeeded
deploy TENKAI_INTERVAL=0
check "refuses an interval of zero" exits 1

tenkai 202 succeeded
deploy TENKAI_PULL_REQUEST=12 TENKAI_IMAGE_TAG=pr-12
check "deploys an image into a preview" exits 0
check "names the pull request and the tag in the query" sent "?pull_request=12&image_tag=pr-12 - 0"
check "reads the Deployment of the preview" reads 1

tenkai 202 succeeded
deploy TENKAI_PULL_REQUEST=12 TENKAI_IMAGE_TAG="pr 12&x=1"
check "encodes the tag in the query" sent "?pull_request=12&image_tag=pr%2012%26x%3D1 - 0"

tenkai 202 succeeded
deploy TENKAI_PULL_REQUEST=12
check "refuses a pull request without a tag" exits 1
check "says to set both" logs "Set pull_request and image_tag together"
check "sends nothing without a tag" posts 0

tenkai 202 succeeded
deploy TENKAI_PULL_REQUEST=pr-12 TENKAI_IMAGE_TAG=pr-12
check "refuses a pull request that is not a number" exits 1
check "sends nothing for a pull request that is not a number" posts 0

for refused in 422:invalid_image_tag 404:preview_not_found 409:preview_not_open 422:invalid_preview_request \
	409:preview_image_changed 409:preview_ambiguous; do
	error=${refused#*:}
	tenkai "$refused"
	deploy TENKAI_PULL_REQUEST=12 TENKAI_IMAGE_TAG=pr-12
	check "fails when Tenkai refuses the preview with $error" exits 1
	check "gives what Tenkai said of $error and what to do" logs "$error: Tenkai refused with $error. "

	if [[ "$error" == preview_not_found ]]; then
		check "says which pull request has no preview" logs "pull request #12 has an open preview"
	fi
done

# A built site, with a file in a directory, and a directory without files.
site="$work/dist"
mkdir -p "$site/assets" "$site/empty"
echo '<div id=app>' >"$site/index.html"
echo 'mount();' >"$site/assets/app.js"

tenkai 202 succeeded
deploy TENKAI_PATH="$site"
check "deploys the files of a path" exits 0
check "sends them as application/gzip" sent "application/gzip $(wc -c <"$work/sent.tar.gz" | tr -d ' ')"
check "packs the content of the directory at the root of the archive" \
	[ "$(tar -tzf "$work/sent.tar.gz" | sort | tr '\n' ' ')" == "./ ./assets/ ./assets/app.js ./empty/ ./index.html " ]
check "packs the files as they are" [ "$(tar -xzOf "$work/sent.tar.gz" ./assets/app.js)" == "mount();" ]

tenkai 422:invalid_archive
deploy TENKAI_PATH="$site"
check "fails when Tenkai refuses the files" exits 1
check "says why Tenkai refused the files" logs "::error::Tenkai did not queue the Deployment. invalid_archive: Tenkai refused with invalid_archive"

ln "$site/index.html" "$site/copy.html"
tenkai 202 succeeded
deploy TENKAI_PATH="$site"
check "deploys a hard-linked file" exits 0
check "packs each hard-linked file as a regular file" [ "$(tar -tvzf "$work/sent.tar.gz" | grep --count '^h')" == 0 ]
check "packs the content of a hard-linked file" [ "$(tar -xzOf "$work/sent.tar.gz" ./copy.html)" == "<div id=app>" ]
rm "$site/copy.html"

ln -s /etc/passwd "$site/leak"
tenkai 202 succeeded
deploy TENKAI_PATH="$site"
check "refuses a path that holds a link" exits 1
check "names the link" logs "$site/leak"
check "sends nothing when the path holds a link" posts 0

# A path that is a link to the site: the checks read the tree that tar packs, through the link.
ln -s "$site" "$work/output"
tenkai 202 succeeded
deploy TENKAI_PATH="$work/output"
check "refuses a linked path that holds a link" exits 1
check "sends nothing when a linked path holds a link" posts 0
rm "$work/output"

rm "$site/leak"

# A path through a link then ..: the system resolves the link before the .., as tar did, so another site with the
# same name next to the link is not the one sent.
mkdir -p "$work/release/build" "$work/release/dist"
echo '<div id=release>' >"$work/release/dist/index.html"
ln -s "$work/release/build" "$work/link"
tenkai 202 succeeded
deploy TENKAI_PATH="$work/link/../dist"
check "deploys the directory a path names through a link" exits 0
check "sends the site the link leads to" [ "$(tar -xzOf "$work/sent.tar.gz" ./index.html)" == "<div id=release>" ]
rm -r "$work/link" "$work/release"

tenkai 202 succeeded
deploy TENKAI_PATH="$site/index.html"
check "refuses a path that is not a directory" exits 1
check "sends nothing when the path is not a directory" posts 0

# Random bytes do not compress, so the archive weighs more than 100 MB.
head -c $((100 * 1024 * 1024 + 1)) /dev/urandom >"$site/video.bin"
tenkai 202 succeeded
deploy TENKAI_PATH="$site"
check "refuses an archive over 100 MB" exits 1
check "says the archive is too large" logs "Tenkai takes an archive under 100 MB"
check "sends nothing over 100 MB" posts 0
rm "$site/video.bin"

if ((failures > 0)); then
	echo "$failures checks failed"
	exit 1
fi

echo "All checks passed"
