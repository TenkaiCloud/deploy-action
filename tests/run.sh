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
	python3 "$root/tests/mock_tenkai.py" "$port" "$secret" "$@" >"$work/requests" &
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

tenkai 409 started
deploy
check "fails when Tenkai refuses the Deployment" exits 1
check "says why Tenkai refused" logs "mutation_in_progress: Another Deployment of this Web Application is in progress"
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

if ((failures > 0)); then
	echo "$failures checks failed"
	exit 1
fi

echo "All checks passed"
