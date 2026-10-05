# Tenkai Deploy

Deploy a Web Application on [Tenkai](https://tenkai.cloud) from a GitHub Actions workflow. The action calls the Deploy Hook of the Web Application, waits for the Deployment to end and fails the job when the Deployment fails.

## Before you start

Enable the Deploy Hook of the Web Application in Tenkai, in its **Configuration** tab. Tenkai gives you a URL and a secret, and shows the secret once. Add both to the secrets of your repository:

- `TENKAI_DEPLOY_HOOK_URL`
- `TENKAI_DEPLOY_HOOK_SECRET`

Whoever holds the secret can deploy this Web Application to Production. It cannot deploy another one.

## Usage

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    steps:
      - uses: TenkaiCloud/deploy-action@v1
        with:
          deploy_hook_url: ${{ secrets.TENKAI_DEPLOY_HOOK_URL }}
          deploy_hook_secret: ${{ secrets.TENKAI_DEPLOY_HOOK_SECRET }}
```

Tenkai deploys the Web Application as it is configured: its Build Source, its revision and its Variables. The action sends nothing of your repository. To deploy an image the workflow builds, publish the image first, then run this action in a later step.

## Inputs

| Name                 | Default | Description                                                                               |
| -------------------- | ------- | ----------------------------------------------------------------------------------------- |
| `deploy_hook_url`    |         | The URL of the Deploy Hook. Required.                                                     |
| `deploy_hook_secret` |         | The secret of the Deploy Hook. Required.                                                  |
| `wait`               | `true`  | Wait for the Deployment to end. With `false`, the step stops once Tenkai queued it.       |
| `timeout`            | `900`   | How many seconds to wait for the Deployment to end before the step fails.                 |
| `interval`           | `5`     | How many seconds to wait between two reads of the Deployment.                             |

## Outputs

| Name             | Description                                                                              |
| ---------------- | ---------------------------------------------------------------------------------------- |
| `deployment_id`  | The identifier of the Deployment Tenkai queued.                                          |
| `deployment_url` | The URL that tells how the Deployment goes, read with the secret of the Deploy Hook.     |
| `status`         | `succeeded` or `failed`. `started` when the action did not wait.                         |

## When the step fails

- **Tenkai did not queue the Deployment.** The log gives the code and the message of Tenkai. `mutation_in_progress` means another Deployment of the Web Application runs: add a `concurrency` group to the workflow so two runs do not deploy at once. `invalid_deploy_hook_secret` means the secret was rotated or revoked.
- **The Deployment failed.** The log gives the reason. Open the Web Application in Tenkai to read the logs of the Deployment.
- **The Deployment did not end in time.** It still runs on Tenkai. Raise `timeout` if your builds are long.

A step that fails does not cancel the Deployment, and cancelling the workflow does not either.

## Requirements

The action runs `bash`, `curl` and `jq`, which the runners hosted by GitHub have. It works on Linux and macOS runners.
