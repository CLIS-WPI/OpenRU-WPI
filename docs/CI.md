# CI runner and workflow security

This repository is **public**. The `replay-golden` job runs on a **self-hosted GPU
runner**, so the workflow and the runner are treated as a trust boundary: untrusted
code must never execute on the lab host.

## Current state (audited 2026-11-14)

| Check | Result |
|---|---|
| Repository visibility | public |
| Self-hosted runners registered | **0** (`gh api repos/CLIS-WPI/OpenRU-WPI/actions/runners` → `total_count: 0`) |
| `replay-golden` triggers | `push` to `main` and `workflow_dispatch` only |
| `pull_request` / `pull_request_target` | absent |
| Fork PR approval policy | `all_external_contributors` ("Require approval for all outside collaborators") |
| Default workflow token | read-only (`default_workflow_permissions: read`) |

Because no runner is registered, the workflow is inert: a push to `main` queues a job
that cannot start until a runner is attached. Do not attach one to the shared lab host
without following the rules below.

## Non-negotiable workflow rules

1. `replay-golden.yml` may trigger **only** on `push` to `main` and `workflow_dispatch`.
   Never add `pull_request` or `pull_request_target`; both run code from the PR branch.
2. Keep the repository setting **Require approval for all outside collaborators** for
   fork PR workflows (Settings → Actions → General → Fork pull request workflows).
   The API value is `all_external_contributors`.
3. Keep the default `GITHUB_TOKEN` read-only and do not expose repository or
   environment secrets to this job.
4. Pin third-party actions to a full commit SHA. The current `@v4` tags are acceptable
   only until the SHAs are recorded in a follow-up; a moved major tag is a
   supply-chain risk on a self-hosted runner.
5. Do not add `self-hosted` to any workflow that can be reached by a PR event.

## Runner setup

The runner must be isolated from the shared lab host. Preferred to least preferred:

1. **Dedicated VM or dedicated container host**, runner installed as an **ephemeral**
   runner (`config.sh --ephemeral`), one job per boot, workspace destroyed afterwards.
2. **Rootless Docker** inside that VM so the runner user does **not** need membership
   in the host `docker` group. `replay-golden` shells out to `docker compose` and
   `docker exec`, so rootless Docker or Podman is the way to keep the runner
   unprivileged.
3. If rootless containers are not possible, a **dedicated VM** where the runner user is
   in that VM's `docker` group is acceptable. The runner user must still not be root
   and must not be a member of the host's `docker` group or have passwordless sudo on
   the shared host.

Runner account and host hardening:

- Use a dedicated, non-login account (for example `openru-ci`) with no sudo and no
  `docker` group on the shared host.
- Do not mount `/home`, the Docker socket, or lab credentials into the runner.
- Give the VM only the resources the job needs: the GPU UUID from `docker/lab.env`,
  the OFH bridge, `testdata/golden/` and `testdata/pcap/` (or `OPENRU_GOLDEN_URL`).
- Restrict egress to GitHub and the golden host; the job needs no other network.
- Keep the runner off the NUMA1 measurement cores (`32-63`) while a measurement lock
  exists; the same `/tmp/openru-measure.lock` rule applies to CI runs.
- Re-register the runner token after every job; never store it in the repository.

Example registration (run on the dedicated VM, as the `openru-ci` user):

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -fsSL -o runner.tar.gz \
  https://github.com/actions/runner/releases/download/v2.320.0/actions-runner-linux-x64-2.320.0.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/CLIS-WPI/OpenRU-WPI \
  --token "<short-lived registration token>" \
  --labels self-hosted,gpu --name openru-gpu-ci --ephemeral --unattended
./run.sh
```

Generate the registration token from Settings → Actions → Runners → New self-hosted
runner; it expires quickly and must not be committed.

## Why this matters

A self-hosted runner executes the workflow's `run:` steps directly on its host. On a
public repository, a fork PR that can reach the runner can run arbitrary commands,
read the runner's filesystem and environment, reach the lab network, and persist
between jobs. This is why the workflow must never be PR-triggered, fork PRs require
maintainer approval, and the runner must be ephemeral and isolated. The GPU host is
shared with timing measurements; a compromised runner would invalidate those results
as well as expose the lab.

## Inert until a runner is registered

No runner is registered today. If `replay-golden` must run on every `main` push, the
human must attach the dedicated runner first. Until then, `main` pushes will leave a
queued job; alternatively disable the workflow with
`gh workflow disable replay-golden.yml` and enable it when the runner exists.
