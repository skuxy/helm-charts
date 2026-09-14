# Daytona BYOC — Troubleshooting

Cross-cloud failure modes, plus the DNS-01 wildcard TLS upgrade path. Most issues are operational (DNS, LB, certs) rather than chart bugs; the chart's own behavior is validated by `helm-unittest` and `helm lint`.

## Ubuntu version mismatch — `omc::verify_node_ubuntu` aborts

If `up.sh` fails with `Refusing to continue. Ubuntu 24.04 is REQUIRED with NO EXCEPTIONS.`:

```bash
# See what your nodes actually report
kubectl get nodes -l daytona-sandbox-c=true \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\n"}{end}'
```

Common causes:

- **Your cloud CLI is too old.** eksctl pre-0.200 doesn't know `Ubuntu2404`. Update with `brew upgrade eksctl` or download a fresh release.
- **Your cloud region hasn't rolled out Ubuntu 24.04 yet.** AKS rolled out per-region; GKE rolls with K8s version. Try `us-east-1` / `eastus` / `us-central1` first.
- **You re-attached an existing node pool that was originally Ubuntu 22.04.** Delete + recreate the sandbox node pool with the explicit Ubuntu 24.04 flag.
- **GKE cluster is on an older K8s version.** Stable channel currently gives 1.32+, which uses Ubuntu 24.04 by default. If you pinned an older version, upgrade the cluster.

To recover: `bash teardown.sh` then re-run `up.sh`. Both are idempotent.

## LoadBalancer stuck pending > 5 min

```bash
kubectl -n ingress-nginx describe svc ingress-nginx-controller
```

**Per-cloud causes:**

- **AWS (EKS):** the IAM principal lacks `elasticloadbalancing:CreateLoadBalancer`. Check `eksctl` cluster IAM. Or: NLB quota hit; check Service Quotas console.
- **Azure (AKS):** sometimes the public IP allocation lags; wait 2 more minutes. If still pending, `az network public-ip list -g <node-rg>` shows nothing — confirm `--load-balancer-sku standard` was used at cluster create.
- **GCP (GKE):** project quota for in-use external IPs. `gcloud compute project-info describe --project <project>` and look for `IN_USE_ADDRESSES`. Region-level quota: `gcloud compute regions describe <region>`.

The `up.sh` scripts wait 300s by default. If the LB never allocates, the script aborts and you can fix the quota then re-run (it's idempotent).

## cert-manager Certificate stuck in `False`

```bash
kubectl -n daytona get certificate
kubectl -n daytona describe certificate <name>
kubectl -n daytona get challenges
kubectl -n cert-manager logs deployment/cert-manager
```

Common causes:

1. **DNS not propagated yet.** ACME HTTP-01 needs `proxy.<base-domain>` to resolve to the LB hostname. Test with `dig proxy.<base-domain> @1.1.1.1` and `curl http://proxy.<base-domain>/.well-known/acme-challenge/test`.
2. **Wildcard cert under HTTP-01 — impossible.** HTTP-01 cannot validate `*.proxy.<base>`. By default the setup issues two non-wildcard certs (`proxy.<base>` and `snapshots.<base>`); per-sandbox subdomains either reuse the proxy cert or need DNS-01 (see below).
3. **Let's Encrypt rate limit hit.** Production endpoint has tight limits. Switch the `ClusterIssuer` to staging temporarily: change `spec.acme.server` to `https://acme-staging-v02.api.letsencrypt.org/directory` and re-apply.

## Runner DaemonSet pod CrashLoopBackOff

```bash
kubectl -n daytona get pods -l app.kubernetes.io/component=runner
kubectl -n daytona describe pod <runner-pod>
kubectl -n daytona logs <runner-pod> -c runner --previous
kubectl -n daytona logs <runner-pod> -c docker-installer --tail=200
kubectl -n daytona logs <runner-pod> -c daytona-binary-installer --tail=200
```

**The host-side bootstrap (docker + sysbox) happens in the `docker-installer` sidecar via `nsenter -t 1 -m -u -n -i`. If `docker-installer` fails, the runner never starts.**

Per-cloud:

- **AKS:** check for the tarball-fallback log line: `dockerd not installed by deb (managed-runtime conflict?) - using static tarball`. If it's NOT there and `docker version` in the docker-installer logs reports an apt conflict, the d1892ef fallback didn't fire. The up.sh script enforces `--os-sku Ubuntu2404` and the post-create `omc::verify_node_ubuntu` gate refuses to continue if nodes aren't on Ubuntu 24.04 — if the gate passed, your nodes are correct.
- **GKE:** PSA enforce=privileged label must be on the namespace. Without it: `Pod ... is forbidden: violates PodSecurity "restricted:latest": privileged ...`. Apply: `kubectl label namespace daytona pod-security.kubernetes.io/enforce=privileged --overwrite`.
- **EKS:** look for `containerd not found` or `sysbox not found` in `docker-installer` logs. Ubuntu **24.04** family AMI is required (eksctl `amiFamily: Ubuntu2404`); the up.sh post-create `omc::verify_node_ubuntu` gate enforces this — if the gate passed, your nodes are correct.

## Sandbox build returns 403 from snapshot manager

This means the runner cannot read/write your S3-compatible bucket.

```bash
# What does the runner think its AWS env is?
kubectl -n daytona exec daemonset/daytona-region-runner -c runner -- env | grep AWS_

# Does the snapshot-manager think it can reach the bucket?
kubectl -n daytona logs deployment/daytona-region-snapshot-manager --tail=50 | grep -iE 'error|403|denied'
```

Per-cloud:

- **AWS:** IAM policy on the user/role missing one of `s3:{GetObject,PutObject,DeleteObject,ListBucket,AbortMultipartUpload,ListMultipartUploadParts}`. Confirm with `aws iam list-attached-user-policies --user-name <cluster>-daytona` or `aws iam list-attached-role-policies --role-name <cluster>-runner-irsa`.
- **Azure:** rclone-s3-gateway is down. `kubectl -n daytona get deploy rclone-s3-gateway` and `kubectl -n daytona logs deploy/rclone-s3-gateway`.
- **GCP:** HMAC keys revoked or the GSA lost its `storage.objectAdmin` binding. `gcloud storage hmac list --service-account=<gsa>@<project>.iam.gserviceaccount.com`.

## `credentialMode: irsa` works at chart level but runner exits at startup

This is the **known upstream gap** documented in [`issues-summary.md`](issues-summary.md). The upstream daytona-runner currently hard-requires non-empty `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` at startup, even when the runner's AWS SDK would otherwise pick up IRSA-projected web-identity tokens.

**Workaround:** use `credentialMode: static`. The chart's `allowEmptyStaticKeyShim` knob is a placeholder for the partial workaround but is not production-functional today.

## DNS-01 wildcard upgrade path

By default `up.sh` installs an **HTTP-01** ClusterIssuer and renders the proxy
cert **non-wildcard** (apex `proxy.<base>` only, `services.proxy.ingress.wildcardTls=false`),
so it issues with no DNS plumbing. Per-sandbox preview subdomains then reuse the
apex cert (browser hostname mismatch) until you move to DNS-01.

**Automated path (Cloudflare):** re-run `up.sh` with `CLOUDFLARE_API_TOKEN` set
(zone-scoped: `Zone:Read` + `Zone DNS:Edit`). up.sh applies a DNS-01 ClusterIssuer
via `omc::cluster_issuer_apply_cf_dns01` and renders the proxy ingress with
`wildcardTls=true`, so cert-manager issues a real `*.proxy.<base>` SAN — nothing
else to do.

**Manual path (any other DNS provider):** set `services.proxy.ingress.wildcardTls=true`
in your values and apply a DNS-01 ClusterIssuer named `letsencrypt-prod` for your
provider (so the proxy ingress annotation finds it). Example for the long-hand
route (separate issuer + Certificate):

```yaml
# cluster-issuer-dns01.yaml — apply AFTER up.sh
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns01
spec:
  acme:
    email: you@example.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-dns01-account-key
    solvers:
      - dns01:
          # AWS Route53
          route53:
            region: us-east-1
            # IAM credentials via IRSA (set serviceAccountRef) or AccessKey secretRef
            # See: https://cert-manager.io/docs/configuration/acme/dns01/route53/
          # Azure DNS:
          # azureDNS:
          #   clientID: ...
          #   tenantID: ...
          #   subscriptionID: ...
          #   resourceGroupName: ...
          # GCP Cloud DNS:
          # cloudDNS:
          #   project: <project>
          #   serviceAccountSecretRef:
          #     name: clouddns-dns01-solver-svc-acct
          #     key: key.json
```

Then issue a wildcard cert:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: proxy-wildcard-tls
  namespace: daytona
spec:
  secretName: proxy-wildcard-tls
  issuerRef:
    name: letsencrypt-prod-dns01
    kind: ClusterIssuer
  dnsNames:
    - "*.proxy.byoc.example.com"
```

Reference the certificate from the proxy ingress's `tls.secretName`.

cert-manager DNS-01 docs:

- Route53: <https://cert-manager.io/docs/configuration/acme/dns01/route53/>
- Azure DNS: <https://cert-manager.io/docs/configuration/acme/dns01/azuredns/>
- Cloud DNS: <https://cert-manager.io/docs/configuration/acme/dns01/google/>

## Helm install times out at the wait step

```bash
helm upgrade --install daytona-region ... --wait --timeout 10m
```

If 10 min isn't enough (e.g. very slow AKS node group provisioning), re-run `up.sh` — the helm step is idempotent and will continue waiting from where it left off. Or run the install yourself without `--wait` and poll `kubectl -n daytona get pods` manually.

## State files left over after teardown

The teardown scripts wipe `scripts/<cloud>-setup/.state/` at the end. If something interrupts teardown mid-way:

```bash
rm -rf scripts/aws-setup/.state/   # or azure / gcs
```

Then re-run `teardown.sh` — it's idempotent and will skip resources that no longer exist.

## Sandbox DNS stopped working after enabling networkPolicy

Symptom: `nslookup`/`curl` inside sandboxes time out, while the runner and snapshot pulls are fine.

Cause: the egress policy (`services.runner.networkPolicy`) blocks RFC1918 and link-local destinations — including whatever resolver the node's `/etc/resolv.conf` pointed at (the GCE metadata resolver `169.254.169.254` on GKE, a VPC resolver elsewhere). Sandboxes inherit that resolver unless you pin one.

Fix: set both DNS knobs (the enforcer auto-exempts them from the block list) and bounce the runner DaemonSet:

```yaml
services:
  runner:
    dockerInstaller:
      dns: ["8.8.8.8", "1.1.1.1"]
    buildkit:
      dns:
        nameservers: ["8.8.8.8", "1.1.1.1"]
```

Existing sandboxes keep their old resolv.conf until recreated. Details: [`operations.md`](operations.md#sandbox-network-security-and-dns).

## Egress policy seems inactive (probe still reaches metadata/cluster IPs)

```bash
# on the sandbox node — both chains must exist and be hooked
iptables -L SBX_EGRESS -n | head
iptables -L DOCKER-USER -n | grep SBX_EGRESS
kubectl logs -n daytona ds/daytona-runner -c egress-enforcer --tail=20
```

If the chains are missing: confirm `networkPolicy.enabled: true` actually reached the release (`helm get values`), and check the enforcer log for nsenter/iptables errors. The chains attach to `docker0`/`br-+` — if your sandboxes run on a custom `CONTAINER_NETWORK` bridge whose interface name has a different prefix, they won't match it; use a `br-`-prefixed bridge or extend the enforcer interface list.

## helm install/upgrade fails at "volume-preflight"

That is the gate doing its job: `services.runner.volumes.backend` is set but the runner image lacks a working mount binary (`mount-s3` is glibc-only and absent from the stock Alpine image). Read the Job log —

```bash
kubectl logs -n daytona job/daytona-volume-preflight
```

— then either bake the binary into a custom runner image (see [`operations.md`](operations.md#sandbox-volumes) for a Dockerfile example), switch to `backend: rclone` (musl-friendly), or set `volumes.backend: ""` to disable volume support. To validate an image before touching the release: `scripts/preflight/check-volume-backend.sh <backend> <image>`.

## SSH connects, then the session closes immediately

`ssh -p 2222 <token>@<gateway-lb>` completes the handshake (the gateway host key is offered) and then drops. Gateway logs show:

```
Failed to validate SSH access: 403 Forbidden
```

The gateway is validating sessions with an org `dtn_` key (or the chart's placeholder) — only the **region-scoped** ssh-gateway key passes `ValidateSshAccess`. The setup scripts swap it in automatically post-install (`omc::region_sshgateway_finalize`); manually:

```bash
REGION_ID=$(kubectl -n daytona get secret <release>-region-config -o jsonpath='{.data.id}' | base64 -d)
curl -sf -X POST -H "Authorization: Bearer $ORG_KEY" \
  "https://app.daytona.io/api/regions/$REGION_ID/regenerate-ssh-gateway-api-key"
# roll the returned apiKey into services.sshGateway.apiKey (helm upgrade), then
kubectl -n daytona delete pod -l app.kubernetes.io/component=ssh-gateway
```

If SSH instead hangs with no gateway log line at all, the runners are missing `SSH_PUBLIC_KEY` (base64 of the gateway's client public key) in `services.runner.env` — runners work normally otherwise, which makes this failure silent.

## Snapshots stuck in `error`; docker push gets 502

Snapshot-manager logs show:

```
panic ... nil pointer dereference
  .../registry/storage/driver/s3-aws.(*driver).Writer
```

The registry's s3 driver (distribution v3) resumes blob uploads via `ListMultipartUploads`, which S3 *shims* (rclone `serve s3`, GCS XML interop, most "S3-compatible" gateways) stub out — the driver nil-panics mid-push and nginx returns 502. Fix: `services.snapshotManager.storage.driver: filesystem` (PVC-backed; the chart creates the claim). `driver: s3` is safe only against real AWS S3. Delete any snapshots stuck in `error` and re-create them after the switch.

## runnermanager ImagePullBackOff

Not every chart `appVersion` has a published `daytonaio/daytona-runner-manager` tag (the tag lines are sparse: plain, `-k8s-oss`, `-byoc` flavors). Keep the chart's pinned default tag unless you have verified the override exists on Docker Hub.

## Runner DaemonSet pod stuck `Pending` — `didn't have free ports`

`services.runner.mainContainer.enabled: true` makes the DaemonSet bind hostPorts 3000/2220 on every sandbox node — the same ports the runner-manager's spawned pods need (hostNetwork). The manager's pods are also the only runners registered with Daytona Cloud, so the static ones add no capacity. Set `mainContainer.enabled: false` (sidecar-only host prep) whenever `runnermanager` is enabled.

## runner-vm DaemonSet pod stuck `ContainerCreating` — `/dev/kvm is not a character device`

`services.runnerVm` needs the node it lands on to actually have nested virtualization enabled at EC2 launch — being on a nested-virt-*capable* instance family (AWS: 8th-gen Intel — `c8i`/`m8i`/`r8i` + flex variants; see `up.sh`'s `ENABLE_VM_NODE_POOL` handling) is necessary but not sufficient. `eksctl`'s managed-nodegroup schema has no field for the underlying EC2 `CpuOptions.NestedVirtualization` launch parameter, so a node pool provisioned without an explicit launch template carrying it comes up on the right family with `/dev/kvm` simply absent — confirmed live 2026-09-14 via `kubectl describe pod`: `MountVolume.SetUp failed for volume "dev-kvm" : hostPath type check failed: /dev/kvm is not a character device`.

`up.sh` (from this fix onward) creates and attaches the needed launch template automatically for a **fresh** cluster/node-pool creation — nothing to do there. There is currently no equivalent automated path for repairing an **already-provisioned** node pool that's missing it (e.g. one created before this fix landed, or hand-rolled outside `up.sh`). If you hit this on an existing cluster, the manual remediation is:

1. Create (or reuse) an EC2 launch template carrying just `CpuOptions.NestedVirtualization=enabled` — the *only* field it should own if you want `eksctl` to still auto-manage everything else on a **fresh** managed nodegroup. `aws ec2 create-launch-template --launch-template-data '{"CpuOptions":{"NestedVirtualization":"enabled"}}'`.
2. `eksctl create nodegroup -f <yaml>` referencing it via `launchTemplate.id` alongside `instanceType`/`amiFamily`/`labels`/`taints`/`volumeSize` at the nodegroup level, as `up.sh` itself does — **this only works for a brand-new nodegroup**. Repairing an existing one is more involved: `eksctl` flatly rejects `instanceType`/`volumeSize` set at the nodegroup level once *any* custom `launchTemplate.id` is attached ("cannot set instanceType, ami, ... volumeSize ... in managedNodeGroup when a launch template is supplied") — those must move into the launch template itself. Worse, the moment the launch template also carries an explicit `ImageId` (required, because EKS's `CreateNodegroup` API rejects `amiType: CUSTOM` — which `eksctl` silently selects the instant *any* custom launch template is attached — without one), `eksctl` then *also* requires you to supply the full node-bootstrap `UserData` yourself and to drop `amiFamily` entirely ("node bootstrapping script (UserData) must be set when using a custom AMI" / "cannot set managedNodeGroup.ami when launchTemplate.ImageId is set"). In practice this meant extracting and adapting the real bootstrap `UserData` (a gzip+base64 `#cloud-config` blob invoking `/etc/eks/bootstrap.sh` and eksctl's own kubelet-label/taint injection scripts) from an already-working nodegroup's own auto-generated launch template — `aws ec2 describe-launch-template-versions --launch-template-id <existing-working-nodegroup's-LT-id> --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData'`, base64-decode, gunzip, swap the `NODE_LABELS`/`NODE_TAINTS` lines for the target nodegroup, re-gzip+base64, and bake it into the new launch template version along with `ImageId`/`InstanceType`.
3. Create the fixed nodegroup under a new name (don't try to update the broken one in place), confirm `/dev/kvm` on the new node (`kubectl debug node/<node> -it --image=busybox -- ls -la /host/dev/kvm`), confirm the DaemonSet pod reschedules there and reaches `Ready`, then `eksctl delete nodegroup --name <broken-name>`.

If you land here often enough that this is worth automating, the natural shape is an `up.sh --repair-node-pool` mode (or a standalone script) that does the launch-template-version/UserData-extraction dance above automatically — it doesn't exist yet.

## helm upgrade silently drops the runner-vm nodeSelector override — `DESIRED=N/READY=0`, no scheduling error

If your cluster needs `services.runnerVm.nodeSelector.<some-other-key>: null` (nulling out the chart's own default nodeSelector key so the DaemonSet doesn't end up requiring *both* that key and your actual selector on one node — Helm deep-merges maps, so a missing override just inherits the chart default instead of unsetting it), that override **must be passed explicitly on every single `helm upgrade`**, including ones using `--reuse-values`. Confirmed live: `--reuse-values` does not reliably re-apply a previously-set explicit `null` across releases — a plain `helm upgrade --reuse-values` reverted the nodeSelector to require both labels again, and the DaemonSet just silently never matched any node (`DESIRED=2 READY=0`, zero warning events). There is no chart-level fix for this yet — always pass the override values file (e.g. `-f values-runnervm-override.yaml`) by name on every upgrade; don't rely on `--reuse-values` to carry it.

## runner-vm image pulls `docker.io/<your-registry-host>/...` and fails with `insufficient_scope` / "repository does not exist"

`services.runnerVm.image.registry` and `.repository` are separate chart values; `registry` defaults to `docker.io`. Setting only `image.repository` to a fully-qualified private-registry host+path (e.g. an ECR URL) without also overriding `image.registry` produces a broken combined reference — the default `docker.io` gets prepended in front of your already-fully-qualified path. Set both explicitly when pointing at a private registry, e.g.:

```
--set services.runnerVm.image.registry=<account-id>.dkr.ecr.<region>.amazonaws.com \
--set services.runnerVm.image.repository=<path>/runner-vm \
--set services.runnerVm.image.tag=<tag>
```

## Where to escalate

- **Chart bug** (helm template fails, values key wrong, etc.) → file against the helm-charts repo with the rendered YAML + helm version.
- **Runner bug** (CrashLoopBackOff, sandbox build fails, etc.) → file against `daytonaio/daytona` with the runner pod logs + chart commit SHA.
- **Cloud setup bug** (up.sh wedges, teardown leaves orphans) → file against the helm-charts repo with cloud + the prompt set you used.
- **Daytona Cloud / dashboard issue** → email Daytona support.
