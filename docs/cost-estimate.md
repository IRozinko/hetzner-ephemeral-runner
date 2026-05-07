# Cost Estimate

The goal of this task is to avoid a permanently running self-hosted runner.

## Cost strategy

Instead of keeping a VPS online all month, the script:

1. creates the smallest practical Hetzner Cloud server for the test run;
2. registers it as an ephemeral GitHub self-hosted runner;
3. runs the workflow;
4. deletes the server and firewall immediately after completion.

## Expected cost

Hetzner Cloud servers are billed hourly up to the monthly cap. The assignment mentions a minimal server around 2.99 EUR/month. The exact current price depends on the active Hetzner price list, region, server type, VAT, and IPv4 pricing.

For short CI runs, the practical cost is calculated from the hourly server lifetime. If a test run takes only a few minutes, the effective monthly cost for occasional testing should normally remain in the cents range rather than the full monthly server price.

## Recommended defaults

```text
SERVER_TYPE=cx23
LOCATION=fsn1
IMAGE=ubuntu-24.04
```

The server type can be overridden when running the script.

## Cleanup guarantee

The deployment script uses a shell `trap` to delete the temporary server and firewall on normal exit, workflow failure, interruption, or script error.
