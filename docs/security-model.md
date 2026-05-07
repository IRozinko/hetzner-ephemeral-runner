# Security Model

## No public SSH access

The temporary VPS is not designed for interactive SSH administration.

The deployment script does not attach SSH keys to the server and creates a firewall without inbound rules. That means port 22 is not exposed to the public internet.

## Outbound-only runner

The GitHub Actions runner connects outbound to GitHub over HTTPS. This is enough for runner registration, job pickup, log upload, and artifact communication.

## Ephemeral lifecycle

The runner is registered with the `--ephemeral` flag. After a single job, GitHub removes the runner automatically.

The Hetzner server is then deleted by the local deployment script.

## Secrets handling

The script expects credentials to be provided through environment variables. They are not written to repository files.

The server receives only a short-lived GitHub runner registration token through cloud-init. This token is used during initial runner registration.

## Optional tunnels

A tunnel provider such as Tailscale or Cloudflare Tunnel can be added if interactive troubleshooting is needed. For the default implementation, no tunnel is required because the server is disposable and managed through cloud-init/API.
