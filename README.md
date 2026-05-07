# Hetzner Ephemeral GitHub Runner

One-click scripting task for creating a short-lived Hetzner Cloud VPS that registers as a GitHub self-hosted runner, runs checks for the repository from task 1, and then gets deleted to avoid ongoing costs.

Default target repository:

```text
IRozinko/self-improvement
```

## What this project provides

- One-click Bash deployment script.
- Hetzner Cloud API based server creation.
- No public SSH access.
- Firewall without inbound access rules.
- Ephemeral GitHub self-hosted runner registration.
- GitHub Actions workflow dispatch.
- Automatic server and firewall cleanup after the test run.
- Test workflow that checks out and validates the task 1 repository.

## Architecture

```text
Local machine
  -> scripts/deploy-and-run.sh
  -> Hetzner Cloud API
  -> temporary Hetzner VPS
  -> cloud-init installs GitHub Actions runner
  -> GitHub Actions workflow runs on self-hosted runner
  -> target repository is checked out and tested
  -> VPS and firewall are deleted
```

## Security model

The VPS is not intended for interactive login. There are no SSH keys, no opened SSH port, and no inbound firewall rules.

The runner communicates outbound to GitHub over HTTPS. Provisioning is done through Hetzner cloud-init and the Hetzner Cloud API.

Optional tunnel providers such as Tailscale or Cloudflare Tunnel can be added later, but they are not required for this implementation because the machine is disposable and controlled through cloud-init/API only.

## Required local tools

- `bash`
- `curl`
- `jq`

## Required environment variables

Before running the script, configure:

```bash
export HCLOUD_TOKEN="..."
export GITHUB_TOKEN="..."
```

The GitHub credential must be allowed to create repository self-hosted runner registration tokens, dispatch workflows, and read workflow runs for this repository.

## One-click run

```bash
chmod +x scripts/deploy-and-run.sh
./scripts/deploy-and-run.sh
```

## Useful overrides

```bash
RUNNER_REPO="IRozinko/hetzner-ephemeral-runner"
TARGET_REPO="IRozinko/self-improvement"
TARGET_REF="main"
RUNNER_WORKFLOW_REF="main"
SERVER_TYPE="cx23"
LOCATION="fsn1"
IMAGE="ubuntu-24.04"
```

Before this branch is merged, run with:

```bash
RUNNER_WORKFLOW_REF="feature/hetzner-ephemeral-runner" ./scripts/deploy-and-run.sh
```

## Cost control

The script deletes the server and firewall in a `trap`, even if the workflow fails or the script is interrupted.

Hetzner bills cloud servers hourly up to the monthly cap. The exact price depends on the current Hetzner Cloud price list, selected location, server type, VAT, and whether IPv4 is enabled. Since the server exists only for the duration of a test run, one run should normally cost only cents or less.

## Test workflow

The workflow lives in:

```text
.github/workflows/run-target-tests.yml
```

It runs on the temporary self-hosted runner and executes:

```text
scripts/test-target-repo.sh
```

The test script validates Node.js project setup, installs dependencies, checks JavaScript syntax, and runs `npm test` if the target repository defines it.
