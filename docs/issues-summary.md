# Daytona BYOC Issues Summary

This file replaces the longer draft issue notes. Each paragraph captures the
operator-visible limitation and the expected upstream direction.

## Runner Credential Chain

The runner currently requires non-empty `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` at startup and constructs storage clients from static credentials, so EKS IRSA, GKE Workload Identity, Azure Workload Identity, EC2 instance profiles, and other default-provider-chain flows are not production-functional for runner storage today. BYOC installs should use static S3-shaped credentials until the runner accepts SDK default-chain credentials and passes ambient credential state through to storage and mount subprocesses.

## Runner Volume Mounts

`volume.share` cannot work with the stock runner image alone because the runner invokes a fixed `mount-s3` command, the published Alpine/musl image does not include a compatible mount tool, mount subprocesses receive a stripped environment, and `systemd-run` can be required when the host runtime path is visible. The chart provides shared mount propagation, backend shims, and preflight checks, but operators still need a runner image with the selected mount binary until upstream makes the backend pluggable and documents or ships the required runtime tools.

## Sandbox Egress Policy

Sandbox containers are attached to host Docker bridges and can otherwise reach private cluster ranges, node services, and metadata endpoints. The chart-side `services.runner.networkPolicy` enforcer blocks those paths with host iptables rules, but this is node-wide and not visible to Daytona Cloud; the upstream direction is a runner/API-owned policy model with default private-range protections and organization-level allowlists.

## Snapshot Scheduling Affinity

Snapshot placement currently uses a hard warm-runner filter, so if only one runner has a snapshot ready, same-snapshot sandbox creates can all land on that runner while other healthy runners sit idle. A better upstream model would keep warm runners preferred but not exclusive, or expose explicit prewarm controls so operators can warm more runners without relying on database-side workarounds.

## Runner-Manager Cannot Spawn VM-Backed (Windows / linux-vm) Runners

`services.runnermanager`'s spawned pods -- which per `docs/troubleshooting.md` are the only runners actually registered with Daytona Cloud in a normal (non-`mainContainer`) install -- cannot serve a VM-backed sandbox class today, confirmed 2026-09-14 by disassembling the published `daytonaio/daytona-runner-manager:v0.207.0` image (its source repo could not be located under either the `daytona` or `daytonaio` GitHub orgs, including archived repos, nor found by its own Go module path `github.com/daytonaio/runner-manager` -- whoever owns it needs to be found before any of this can actually be implemented). Three gaps, all in `pkg/provider/k8s/managed_runner.go`:

1. **No privileged/device support.** `(*K8sProvider).createRunnerPod` never references `SecurityContext`, `Privileged`, `HostPath`, or `/dev/kvm` -- the only structured pod data it builds are two label maps (`component`, `app`, `daytona.io/runner`, `daytona.io/managed-runner`, `daytona.io/runner-id`). A VM runner (CLH/QEMU, see `runner-vm`) needs `/dev/kvm` device access and cannot run under the default unprivileged security context.
2. **No node targeting.** Same function, same result: zero references to `NodeSelector`, `Toleration`, or `Affinity`. A config field for pod anti-affinity (`RUNNER_POD_ANTI_AFFINITY_TOPOLOGY_KEY`, `envconfig`-tagged) exists but is not read anywhere in `createRunnerPod` -- dead config as far as pod placement goes. There is no way to steer spawned pods onto a bare-metal, KVM-capable node pool.
3. **Registration never sets `sandboxClass`.** `(*K8sProvider).registerRunner` builds a `CreateRunner` request (the vendored `daytonaio/daytona` `api-client-go` DTO, `model_create_runner.go`) with exactly two fields populated -- `name` and `regionId` -- then calls `RunnersAPIService.CreateRunner`. This is the pre-`sandboxClass` request shape; every runner-manager-spawned pod registers as the default (`container`) class regardless of what image it actually runs, independent of gaps 1 and 2.

Expected upstream direction: three additive, backward-compatible changes to `runner-manager`, matching its existing `RUNNER_POD_*` env var convention --
- an opt-in `RUNNER_POD_PRIVILEGED` (or equivalent security-context/device-mount config) so spawned pods can request `/dev/kvm`,
- `RUNNER_POD_NODE_SELECTOR` / `RUNNER_POD_TOLERATIONS` passthrough (JSON or `key=value` list, consistent with how other `RUNNER_POD_*` values are already sourced from env),
- a `RUNNER_SANDBOX_CLASS` env var threaded into the `CreateRunner` request body (the API already accepts `sandboxClass` as of daytona-ai#[Gap A, 2026-09-14] -- runner-manager was built against the prior two-field shape and has not been updated since).

**Update, 2026-09-14 (later same day):** re-verified with a second, more exhaustive search -- every repo (93 in `daytona`, 22 in `daytonaio`, archived included) checked by exact name, plus a code search across both orgs for `createRunnerPod`, `RUNNER_POD_ANTI_AFFINITY_TOPOLOGY_KEY`, and `registerRunner` (zero matches), plus the published `daytonaio/daytona-runner-manager` Docker Hub image itself: `"source": null` on the Hub API, `is_automated: false`, no OCI labels, no linked build. This is not a repo that's merely hard to find -- there is no discoverable link from the published artifact back to any source, anywhere either org controls.

Given that, ownership of `runner-manager` is being claimed rather than left unowned pending a search that has now been run twice. Until a rebuild or a recovered original is scoped, `daytona-region`'s `runner-vm-*` chart templates (Track 2, a standalone DaemonSet independent of `runnermanager`, PR #48) remain the actual path to VM/Windows sandboxes -- not a stopgap waiting on this, since `daytona-runner` (the container/sysbox runner `runnermanager` currently spawns) is itself slated for deprecation and is not the right thing to keep extending. Whoever picks up rebuilding or recovering `runner-manager` should treat the three gaps above as the spec for VM/Windows support if that capability is still wanted in whatever eventually replaces it, and should evaluate whether the effort is worth it at all given `daytona-runner`'s own trajectory, rather than assuming replacement-in-kind is the goal.
