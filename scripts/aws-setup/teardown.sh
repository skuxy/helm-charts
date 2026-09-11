#!/usr/bin/env bash
# scripts/aws-setup/teardown.sh — K8s-native Daytona BYOC teardown on AWS EKS.
# Pairs with up.sh. Idempotent. Continues on error to keep cleaning.
#
# Reverse-create order:
#   1.  helm uninstall daytona-region + delete ns daytona
#   1b. release Service type=LoadBalancer ELBs so the VPC delete doesn't hang
#   2.  eksctl delete cluster (VPC, nodegroup, cluster IAM roles)
#   3.  aws s3 rb --force on the bucket
#   4.  detach + delete IAM policy; delete IAM user/keys (static) or IRSA role
#   5.  delete the IAM OIDC provider (eksctl leaves it behind)
#   6.  cleanup local .state/ + kubeconfig
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"
IAM_KEYS_FILE="$STATE_DIR/iam-keys.env"

if [[ ! -f "$PROMPTS_FILE" ]]; then
  omc::log WARN "$PROMPTS_FILE missing — cannot determine cluster identity"
  omc::log WARN "Set CLUSTER_NAME, AWS_REGION, S3_BUCKET env vars manually OR re-run up.sh first"
fi

if [[ -f "$PROMPTS_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
fi
if [[ -f "$IAM_KEYS_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$IAM_KEYS_FILE"
  set +a
fi

: "${CLUSTER_NAME:?CLUSTER_NAME is required (set in $PROMPTS_FILE or env)}"
: "${AWS_REGION:?AWS_REGION is required}"

omc::log INFO "=== Daytona BYOC: AWS teardown for cluster '$CLUSTER_NAME' ==="
omc::confirm "This will DELETE the EKS cluster + S3 bucket + IAM resources for '$CLUSTER_NAME'. Proceed?" \
  || { omc::log INFO "Aborted by operator."; exit 0; }

omc::need_cmd aws eksctl kubectl helm jq

# === 0. Deregister runners + region from Daytona Cloud =======================
# Despite this script's own docs (and the aws-setup README) claiming teardown
# "also deregisters the region from Daytona Cloud", it never actually did —
# helm uninstall only removes K8s resources; the region and its runners stay
# registered in Daytona Cloud forever, orphaned, with their backing infra
# gone. Must run FIRST, before any K8s/AWS teardown below, since it needs the
# org API key + region id from secrets that step 1 is about to delete.
#
# The API refuses to delete a runner that's still schedulable, and refuses to
# delete a region that still has any runner attached — same two-step
# unschedulable-then-draining sequence the runner-reaper CronJob uses
# (see runner-reaper-cronjob.yaml) is required here too.
if kubectl get ns daytona >/dev/null 2>&1 && kubectl get secret daytona-region-daytona-api-key -n daytona >/dev/null 2>&1; then
  omc::log INFO "=== Deregistering region from Daytona Cloud ==="
  _dtn_key="$(kubectl get secret daytona-region-daytona-api-key -n daytona -o jsonpath='{.data.daytona-api-key}' 2>/dev/null | base64 -d)"
  _region_id="$(kubectl get secret daytona-region-region-config -n daytona -o jsonpath='{.data.id}' 2>/dev/null | base64 -d)"
  _api_url="${DAYTONA_API_URL:-https://app.daytona.io/api}"
  if [[ -n "$_dtn_key" && -n "$_region_id" ]]; then
    _runner_ids="$(curl -sS -H "Authorization: Bearer ${_dtn_key}" "${_api_url}/runners?regionId=${_region_id}" 2>/dev/null | jq -r '.[].id' 2>/dev/null)"
    for _rid in $_runner_ids; do
      curl -sS -o /dev/null -X PATCH -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${_dtn_key}" -d '{"unschedulable":true}' \
        "${_api_url}/runners/${_rid}/scheduling" 2>/dev/null
      curl -sS -o /dev/null -X PATCH -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${_dtn_key}" -d '{"draining":true}' \
        "${_api_url}/runners/${_rid}/draining" 2>/dev/null
      _code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer ${_dtn_key}" "${_api_url}/runners/${_rid}" 2>/dev/null)"
      if [[ "$_code" == "204" ]]; then
        omc::log INFO "  deleted runner ${_rid}"
      else
        omc::log WARN "  runner ${_rid} delete returned HTTP ${_code} (continuing)"
      fi
    done
    _rcode="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer ${_dtn_key}" "${_api_url}/regions/${_region_id}" 2>/dev/null)"
    if [[ "$_rcode" == "204" ]]; then
      omc::log INFO "region ${_region_id} deregistered from Daytona Cloud"
    else
      omc::log WARN "region deregistration returned HTTP ${_rcode} — may need manual cleanup: DELETE ${_api_url}/regions/${_region_id}"
    fi
  else
    omc::log WARN "Could not read API key/region id from secrets — skipping Daytona Cloud deregistration. Manual cleanup may be needed."
  fi
else
  omc::log WARN "daytona namespace or API key secret not found — skipping Daytona Cloud deregistration (already torn down, or install never completed)."
fi

# === 1. helm uninstall + delete namespace ====================================
if kubectl get ns daytona >/dev/null 2>&1; then
  helm uninstall daytona-region -n daytona --wait --timeout 5m 2>/dev/null \
    && omc::log INFO "helm uninstalled daytona-region" \
    || omc::log WARN "helm uninstall failed or release not found"
  kubectl delete namespace daytona --wait=false 2>/dev/null \
    && omc::log INFO "namespace daytona deletion initiated" \
    || omc::log WARN "namespace daytona delete failed or absent"
fi

# === 1b. Release cloud load balancers BEFORE deleting the VPC ================
# Service type=LoadBalancer (ingress-nginx-controller, ssh-gateway) provisions
# ELBs whose ENIs + security groups pin the VPC. If they outlive the helm
# uninstall, eksctl's VPC delete hangs. Delete them explicitly and wait so AWS
# releases the ELBs first. Also capture the IAM OIDC provider id while the
# cluster still exists (eksctl delete does NOT remove it -> leak otherwise).
OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)"
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
if kubectl cluster-info >/dev/null 2>&1; then
  while IFS= read -r lb_line; do
    [[ -z "$lb_line" ]] && continue
    lb_ns="${lb_line%%/*}"; lb_name="${lb_line##*/}"
    kubectl delete svc "$lb_name" -n "$lb_ns" --wait=true --timeout=3m 2>/dev/null \
      && omc::log INFO "released LoadBalancer svc $lb_line" || true
  done < <(kubectl get svc -A \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
fi

# === 1c. Release account-wide GuardDuty EKS Protection resources =============
# If GuardDuty's EKS Runtime Monitoring / Protection is enabled account- or
# org-wide, AWS auto-injects a `guardduty-data` VPC interface endpoint (with
# one ENI per subnet) AND a GuardDutyManagedSecurityGroup-<vpc-id> security
# group into EVERY new VPC — completely outside eksctl's knowledge, since
# eksctl's own CloudFormation stack didn't create them. eksctl's VPC delete
# then fails ~30s into a LONG (10-15+ min) teardown with "has dependencies
# and cannot be deleted", on the ENIs first (blocking subnets), then on the
# security group (blocking the VPC itself) once the endpoint is gone.
# Confirmed live: this VPC-endpoint-then-security-group sequence is exactly
# what blocked a real dogfood teardown, requiring two separate manual
# `eksctl delete cluster` retries to work through both blockers in order.
# Harmless no-op if GuardDuty EKS Protection isn't enabled for this account.
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  GD_VPCE_IDS="$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.guardduty-data" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)"
  if [[ -n "$GD_VPCE_IDS" ]]; then
    aws ec2 delete-vpc-endpoints --region "$AWS_REGION" --vpc-endpoint-ids $GD_VPCE_IDS >/dev/null 2>&1 \
      && omc::log INFO "released GuardDuty VPC endpoint(s): $GD_VPCE_IDS" \
      || omc::log WARN "failed to delete GuardDuty VPC endpoint(s): $GD_VPCE_IDS (continuing)"
    # ENI detachment lags the endpoint delete call by a few seconds.
    sleep 15
  fi
  GD_SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=GuardDutyManagedSecurityGroup-*" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [[ -n "$GD_SG_ID" && "$GD_SG_ID" != "None" ]]; then
    aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$GD_SG_ID" >/dev/null 2>&1 \
      && omc::log INFO "released GuardDuty security group: $GD_SG_ID" \
      || omc::log WARN "failed to delete GuardDuty security group $GD_SG_ID (continuing)"
  fi
fi

# === 2. eksctl delete cluster ================================================
if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  omc::log INFO "Deleting EKS cluster (this takes 10-15 min)..."
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait \
    && omc::log INFO "EKS cluster deleted" \
    || omc::log WARN "eksctl delete cluster reported errors (check AWS console)"
else
  omc::log INFO "EKS cluster $CLUSTER_NAME not found in $AWS_REGION (already gone)"
fi

# === 3. S3 bucket ============================================================
if [[ -n "${S3_BUCKET:-}" ]]; then
  if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    aws s3 rb "s3://$S3_BUCKET" --force --region "$AWS_REGION" \
      && omc::log INFO "S3 bucket $S3_BUCKET deleted" \
      || omc::log WARN "S3 bucket delete failed (versioned bucket? check console)"
  else
    omc::log INFO "S3 bucket $S3_BUCKET not found"
  fi
fi

# === 4. IAM cleanup ==========================================================
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
S3_POLICY_NAME="${CLUSTER_NAME}-s3"

if [[ -n "$ACCOUNT_ID" ]]; then
  S3_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${S3_POLICY_NAME}"

  # Static mode: IAM user + keys
  IAM_USER="${CLUSTER_NAME}-daytona"
  if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    aws iam list-access-keys --user-name "$IAM_USER" \
      --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null \
      | tr '\t' '\n' \
      | while IFS= read -r key; do
          [[ -z "$key" ]] && continue
          aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$key" \
            && omc::log INFO "deleted access key $key" \
            || true
        done
    aws iam detach-user-policy --user-name "$IAM_USER" --policy-arn "$S3_POLICY_ARN" 2>/dev/null || true
    aws iam delete-user --user-name "$IAM_USER" \
      && omc::log INFO "IAM user $IAM_USER deleted" \
      || omc::log WARN "IAM user delete failed"
  fi

  # IRSA mode: role
  IRSA_ROLE_NAME="${CLUSTER_NAME}-runner-irsa"
  if aws iam get-role --role-name "$IRSA_ROLE_NAME" >/dev/null 2>&1; then
    aws iam detach-role-policy --role-name "$IRSA_ROLE_NAME" --policy-arn "$S3_POLICY_ARN" 2>/dev/null || true
    aws iam delete-role --role-name "$IRSA_ROLE_NAME" \
      && omc::log INFO "IRSA role $IRSA_ROLE_NAME deleted" \
      || omc::log WARN "IRSA role delete failed"
  fi

  # The shared policy
  if aws iam get-policy --policy-arn "$S3_POLICY_ARN" >/dev/null 2>&1; then
    aws iam delete-policy --policy-arn "$S3_POLICY_ARN" \
      && omc::log INFO "IAM policy $S3_POLICY_NAME deleted" \
      || omc::log WARN "IAM policy delete failed (still attached somewhere?)"
  fi

  # IAM OIDC provider (created by eksctl `withOIDC`; NOT removed by cluster delete)
  if [[ -n "${OIDC_ISSUER:-}" && "$OIDC_ISSUER" != "None" ]]; then
    OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER#https://}"
    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
      aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" \
        && omc::log INFO "IAM OIDC provider deleted" \
        || omc::log WARN "OIDC provider delete failed"
    else
      omc::log INFO "IAM OIDC provider already gone"
    fi
  fi
fi

# === 5. Local state ==========================================================
if [[ -d "$STATE_DIR" ]]; then
  rm -rf "$STATE_DIR"
  omc::log INFO "removed $STATE_DIR"
fi
kubectl config delete-context "$CLUSTER_NAME" 2>/dev/null || true
kubectl config delete-cluster "$CLUSTER_NAME" 2>/dev/null || true

cat >&2 <<EOF

==================== TEARDOWN COMPLETE ====================
Verify with:
  aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION
    (expect ResourceNotFoundException)
  aws s3api head-bucket --bucket ${S3_BUCKET:-<none>} 2>&1
    (expect 404)
  aws iam get-user --user-name ${CLUSTER_NAME}-daytona 2>&1
    (expect NoSuchEntity)
===========================================================
EOF
