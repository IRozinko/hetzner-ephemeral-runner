#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

RUNNER_REPO="${RUNNER_REPO:-IRozinko/hetzner-ephemeral-runner}"
TARGET_REPO="${TARGET_REPO:-IRozinko/self-improvement}"
TARGET_REF="${TARGET_REF:-main}"
RUNNER_WORKFLOW_REF="${RUNNER_WORKFLOW_REF:-main}"
WORKFLOW_FILE="${WORKFLOW_FILE:-run-target-tests.yml}"
SERVER_TYPE="${SERVER_TYPE:-cx23}"
LOCATION="${LOCATION:-fsn1}"
IMAGE="${IMAGE:-ubuntu-24.04}"
SERVER_NAME="${SERVER_NAME:-gha-ephemeral-$(date +%s)}"
RUNNER_LABEL="${RUNNER_LABEL:-hetzner-ephemeral-$(date +%s)}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-1800}"
HCLOUD_API="https://api.hetzner.cloud/v1"
GITHUB_API="https://api.github.com"

SERVER_ID=""
FIREWALL_ID=""
RUN_ID=""

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "Missing required environment variable: ${name}"
}

hcloud() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
      -H "Content-Type: application/json" \
      "${HCLOUD_API}${path}" \
      --data "$body"
  else
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
      "${HCLOUD_API}${path}"
  fi
}

github() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      "${GITHUB_API}${path}" \
      --data "$body"
  else
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${GITHUB_API}${path}"
  fi
}

cleanup() {
  local exit_code=$?
  set +e

  if [[ -n "$SERVER_ID" ]]; then
    log "Deleting Hetzner server ${SERVER_ID}"
    hcloud DELETE "/servers/${SERVER_ID}" >/dev/null || true
  fi

  if [[ -n "$FIREWALL_ID" ]]; then
    log "Deleting Hetzner firewall ${FIREWALL_ID}"
    hcloud DELETE "/firewalls/${FIREWALL_ID}" >/dev/null || true
  fi

  if [[ $exit_code -eq 0 ]]; then
    log "Finished successfully"
  else
    log "Finished with exit code ${exit_code}"
  fi

  exit "$exit_code"
}

trap cleanup EXIT INT TERM

validate_inputs() {
  need_cmd curl
  need_cmd jq
  require_env HCLOUD_TOKEN
  require_env GITHUB_TOKEN

  [[ "$RUNNER_REPO" == */* ]] || fail "RUNNER_REPO must be in owner/repo format"
  [[ "$TARGET_REPO" == */* ]] || fail "TARGET_REPO must be in owner/repo format"
}

create_firewall() {
  log "Creating firewall with no inbound rules"

  local body
  body=$(jq -n --arg name "${SERVER_NAME}-fw" '{
    name: $name,
    rules: [
      {direction: "out", protocol: "tcp", port: "1-65535", destination_ips: ["0.0.0.0/0", "::/0"]},
      {direction: "out", protocol: "udp", port: "1-65535", destination_ips: ["0.0.0.0/0", "::/0"]},
      {direction: "out", protocol: "icmp", destination_ips: ["0.0.0.0/0", "::/0"]}
    ]
  }')

  FIREWALL_ID=$(hcloud POST /firewalls "$body" | jq -r '.firewall.id')
  [[ -n "$FIREWALL_ID" && "$FIREWALL_ID" != "null" ]] || fail "Failed to create firewall"

  log "Firewall created: ${FIREWALL_ID}"
}

create_runner_registration_token() {
  log "Creating GitHub Actions runner registration token"
  github POST "/repos/${RUNNER_REPO}/actions/runners/registration-token" | jq -r '.token'
}

build_cloud_init() {
  local runner_token="$1"

  cat <<EOF
#cloud-config
package_update: true
package_upgrade: false
packages:
  - curl
  - tar
  - gzip
  - git
  - jq
  - ca-certificates
  - nodejs
  - npm
users:
  - default
runcmd:
  - useradd -m -s /bin/bash runner || true
  - mkdir -p /opt/actions-runner
  - cd /opt/actions-runner && curl -fsSL -o actions-runner-linux-x64.tar.gz https://github.com/actions/runner/releases/download/v2.328.0/actions-runner-linux-x64-2.328.0.tar.gz
  - cd /opt/actions-runner && tar xzf actions-runner-linux-x64.tar.gz
  - chown -R runner:runner /opt/actions-runner
  - cd /opt/actions-runner && sudo -u runner ./config.sh --unattended --url https://github.com/${RUNNER_REPO} --token ${runner_token} --name ${SERVER_NAME} --labels ${RUNNER_LABEL} --ephemeral --work _work
  - cd /opt/actions-runner && ./svc.sh install runner
  - cd /opt/actions-runner && ./svc.sh start
EOF
}

create_server() {
  local runner_token="$1"
  log "Creating Hetzner server ${SERVER_NAME} (${SERVER_TYPE}, ${LOCATION})"

  local user_data
  user_data=$(build_cloud_init "$runner_token")

  local body
  body=$(jq -n \
    --arg name "$SERVER_NAME" \
    --arg server_type "$SERVER_TYPE" \
    --arg image "$IMAGE" \
    --arg location "$LOCATION" \
    --arg user_data "$user_data" \
    --argjson firewall_id "$FIREWALL_ID" \
    '{
      name: $name,
      server_type: $server_type,
      image: $image,
      location: $location,
      start_after_create: true,
      automount: false,
      user_data: $user_data,
      public_net: {enable_ipv4: true, enable_ipv6: true},
      firewalls: [{firewall: $firewall_id}]
    }')

  SERVER_ID=$(hcloud POST /servers "$body" | jq -r '.server.id')
  [[ -n "$SERVER_ID" && "$SERVER_ID" != "null" ]] || fail "Failed to create server"

  log "Server created: ${SERVER_ID}"
}

wait_for_runner_online() {
  log "Waiting for self-hosted runner label ${RUNNER_LABEL} to become online"

  local start_ts
  start_ts=$(date +%s)

  while true; do
    local status
    status=$(github GET "/repos/${RUNNER_REPO}/actions/runners" \
      | jq -r --arg label "$RUNNER_LABEL" '.runners[]? | select(any(.labels[]?; .name == $label)) | .status' \
      | head -n 1)

    if [[ "$status" == "online" ]]; then
      log "Runner is online"
      return 0
    fi

    if (( $(date +%s) - start_ts > RUN_TIMEOUT_SECONDS )); then
      fail "Runner did not become online within timeout"
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done
}

dispatch_workflow() {
  log "Dispatching workflow ${WORKFLOW_FILE} on ref ${RUNNER_WORKFLOW_REF}"

  local body
  body=$(jq -n \
    --arg ref "$RUNNER_WORKFLOW_REF" \
    --arg runner_label "$RUNNER_LABEL" \
    --arg target_repo "$TARGET_REPO" \
    --arg target_ref "$TARGET_REF" \
    '{ref: $ref, inputs: {runner_label: $runner_label, target_repo: $target_repo, target_ref: $target_ref}}')

  github POST "/repos/${RUNNER_REPO}/actions/workflows/${WORKFLOW_FILE}/dispatches" "$body" >/dev/null
}

wait_for_workflow_run() {
  log "Waiting for workflow run to appear"

  local start_ts
  start_ts=$(date +%s)

  while true; do
    RUN_ID=$(github GET "/repos/${RUNNER_REPO}/actions/runs?event=workflow_dispatch&branch=${RUNNER_WORKFLOW_REF}&per_page=20" \
      | jq -r --arg label "$RUNNER_LABEL" '.workflow_runs[]? | select(.name == "Run Target Repository Tests") | .id' \
      | head -n 1)

    if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
      log "Workflow run detected: ${RUN_ID}"
      return 0
    fi

    if (( $(date +%s) - start_ts > 120 )); then
      fail "Workflow run did not appear"
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done
}

wait_for_workflow_completion() {
  log "Waiting for workflow run ${RUN_ID} to finish"

  local start_ts
  start_ts=$(date +%s)

  while true; do
    local run status conclusion html_url
    run=$(github GET "/repos/${RUNNER_REPO}/actions/runs/${RUN_ID}")
    status=$(jq -r '.status' <<<"$run")
    conclusion=$(jq -r '.conclusion' <<<"$run")
    html_url=$(jq -r '.html_url' <<<"$run")

    log "Workflow status=${status}, conclusion=${conclusion}, url=${html_url}"

    if [[ "$status" == "completed" ]]; then
      [[ "$conclusion" == "success" ]] || fail "Workflow completed with conclusion: ${conclusion}"
      return 0
    fi

    if (( $(date +%s) - start_ts > RUN_TIMEOUT_SECONDS )); then
      fail "Workflow run timeout"
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done
}

main() {
  validate_inputs
  create_firewall
  local runner_token
  runner_token=$(create_runner_registration_token)
  [[ -n "$runner_token" && "$runner_token" != "null" ]] || fail "Failed to create runner registration token"
  create_server "$runner_token"
  wait_for_runner_online
  dispatch_workflow
  wait_for_workflow_run
  wait_for_workflow_completion
}

main "$@"
