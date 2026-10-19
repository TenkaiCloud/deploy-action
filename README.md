# Tenkai Deploy

Deploy a Web Application on [Tenkai](https://tenkai.cloud) from a GitHub Actions workflow. The action calls the Deploy Hook of the Web Application, sends the files of a Static Files Web Application, waits for the Deployment to end and fails the job when the Deployment fails.

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

Tenkai deploys the Web Application as it is configured: its Build Source, its revision and its Variables. Without `path`, the action sends nothing of your repository. To deploy an image the workflow builds, publish the image first, then run this action in a later step.

### Deploy Static Files

For a Web Application whose Build Source is Static Files, build the site in the job, then give the output directory as `path`. The action sends the content of the directory, with `index.html` at its root:

```yaml
name: Deploy

on:
  push:
    branches: [main]

concurrency: deploy

jobs:
  deploy:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-node@v6
        with:
          node-version: 24
          cache: npm

      - run: npm ci

      - run: npm run build

      - uses: TenkaiCloud/deploy-action@v1
        with:
          deploy_hook_url: ${{ secrets.TENKAI_DEPLOY_HOOK_URL }}
          deploy_hook_secret: ${{ secrets.TENKAI_DEPLOY_HOOK_SECRET }}
          path: dist
```

Tenkai takes files and directories only: the step fails when the directory holds a symbolic link. It packs a hard-linked file as a regular file on Linux runners, and fails on one on macOS runners, whose tar cannot. The archive must stay under 100 MB, and the files under 512 MB and 50,000 entries.

## Inputs

| Name                 | Default | Description                                                                               |
| -------------------- | ------- | ----------------------------------------------------------------------------------------- |
| `deploy_hook_url`    |         | The URL of the Deploy Hook. Required.                                                     |
| `deploy_hook_secret` |         | The secret of the Deploy Hook. Required.                                                  |
| `path`               |         | The directory to deploy to a Static Files Web Application, such as `dist`.                |
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

- **Tenkai did not queue the Deployment.** The log gives the code and the message of Tenkai. `mutation_in_progress` means another Deployment of the Web Application runs: add a `concurrency` group to the workflow so two runs do not deploy at once. `invalid_deploy_hook_secret` means the secret was rotated or revoked. `static_files_required` means the Web Application deploys Static Files and needs `path`, and `static_files_not_accepted` that it does not and takes no `path`. `invalid_archive` and `archive_too_large` tell what Tenkai refused in the files, such as a directory without `index.html` at its root.
- **The Deployment failed.** The log gives the reason. Open the Web Application in Tenkai to read the logs of the Deployment.
- **The Deployment did not end in time.** It still runs on Tenkai. Raise `timeout` if your builds are long.

A step that fails does not cancel the Deployment, and cancelling the workflow does not either.

## Requirements

The action runs `bash`, `curl`, `jq` and `tar`, which the runners hosted by GitHub have. It works on Linux and macOS runners.
