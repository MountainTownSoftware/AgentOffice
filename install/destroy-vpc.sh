#!/usr/bin/env bash
# Delete the AgentOffice VPC (and everything in it).
#
# Useful when a `tofu apply` failed partway and left orphan AWS resources that
# OpenTofu no longer tracks. If your state file still knows about the VPC,
# prefer `tofu destroy` in the directory you applied from — deleting out of
# band leaves stale entries in state.
#
# Usage:
#   ./destroy-vpc.sh                    # dry run, deletes nothing
#   ./destroy-vpc.sh --yes              # actually delete
#   ./destroy-vpc.sh --yes --all        # delete every VPC tagged for this project
set -euo pipefail

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}"
PROJECT_TAG="${PROJECT_TAG:-opencode-office}"
ASSUME_YES=0
ALL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}➜${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
die()   { echo -e "${RED}✖${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${CYAN}═══ $* ═══${NC}"; }

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --all|-a) ALL=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done

command -v aws >/dev/null || die "aws CLI not found"
aws sts get-caller-identity >/dev/null 2>&1 || die "Not authenticated to AWS. Run 'aws configure' first."

# --- Find candidate VPCs ------------------------------------------------

# Both tags are checked so we never touch a VPC that is not ours. Name alone is
# too weak — it is a common name and the default VPC may share it.
find_vpcs() {
  aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
              "Name=state,Values=available" \
    --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

step "Looking for AgentOffice VPCs in $REGION"
VPCS="$(find_vpcs)"
if [ -z "$VPCS" ]; then
  ok "No VPCs tagged Project=$PROJECT_TAG — nothing to do"
  exit 0
fi

if [ "$ALL" -eq 0 ] && [ "$(echo "$VPCS" | wc -l | tr -d ' ')" -gt 1 ]; then
  warn "Found more than one VPC. Re-run with --all to delete them all, or"
  warn "set VPC_ID=<id> to pick one."
  echo "$VPCS" | while read -r v; do
    echo "  $v  $(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$v" \
      --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null)"
  done
  exit 0
fi

# --- Report contents ----------------------------------------------------

for VPC in $VPCS; do
  step "Inspecting $VPC"
  aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC" \
    --query 'Vpcs[0].{Cidr:CidrBlock,State:State,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table 2>/dev/null || die "Could not describe $VPC"

  # A default VPC cannot be deleted by this script; bail rather than guess.
  IS_DEFAULT="$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC" \
    --query 'Vpcs[0].IsDefault' --output text 2>/dev/null)"
  if [ "$IS_DEFAULT" = "True" ]; then
    die "$VPC is the default VPC — refusing to delete it"
  fi

  INSTANCES="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType}' \
    --output text 2>/dev/null | tr '\t' ' ' || true)"
  if [ -n "$INSTANCES" ]; then
    warn "This VPC still has EC2 instances. They WILL be terminated:"
    echo "    $INSTANCES" | tr ' ' '\n' | sed 's/^/      /'
    echo ""
  fi

  EIPS="$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=domain,Values=vpc" \
    --query "Addresses[?NetworkInterfaceId!=null].[AllocationId,PublicIp]" \
    --output text 2>/dev/null | tr '\t' ' ' || true)"
done

# --- Confirm ------------------------------------------------------------

if [ "$ASSUME_YES" -eq 0 ]; then
  echo ""
  warn "About to delete: $(echo $VPCS)"
  warn "This cannot be undone. Terraform state is NOT updated by this script."
  echo -n "Type 'delete' to confirm: "
  read -r CONFIRM
  [ "$CONFIRM" = "delete" ] || { info "Aborted."; exit 0; }
fi

# --- Delete in dependency order ----------------------------------------

for VPC in $VPCS; do
  step "Deleting resources in $VPC"

  # ENIs and instances first — they block subnet and SG deletion.
  ENIS="$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)"
  for eni in $ENIS; do
    aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" 2>/dev/null \
      && ok "ENI $eni deleted" || warn "ENI $eni: skipped (likely attached)"
  done

  INSTS="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)"
  for inst in $INSTS; do
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$inst" >/dev/null 2>&1 \
      && ok "Instance $inst terminated" || warn "Instance $inst: could not terminate"
  done

  # Release EIPs allocated in this VPC before the VPC goes away.
  for addr in $(aws ec2 describe-addresses --region "$REGION" \
      --query 'Addresses[].[AllocationId,NetworkInterfaceId]' --output text 2>/dev/null \
      | tr '\t' ' '); do
    ALLOC="${addr%% *}"
    ENI_REF="${addr##* }"
    if [ -n "$ENI_REF" ] && [ "$ENI_REF" != "None" ]; then
      aws ec2 release-address --region "$REGION" --allocation-id "$ALLOC" 2>/dev/null \
        && ok "EIP $ALLOC released" || true
    fi
  done

  # Route table associations must be removed before the table or subnet.
  for assoc in $(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" \
      --query 'RouteTables[].Associations[?SubnetId!=null].AssociationId' \
      --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true); do
    aws ec2 disassociate-route-table --region "$REGION" --association-id "$assoc" 2>/dev/null \
      && ok "Route table assoc $assoc removed" || true
  done

  # Detach the IGW before deleting either it or the VPC.
  for igw in $(aws ec2 describe-internet-gateways --region "$REGION" \
      --filters "Name=attachment.vpc-id,Values=$VPC" \
      --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true); do
    aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$igw" --vpc-id "$VPC" 2>/dev/null \
      && ok "IGW $igw detached" || warn "IGW $igw: detach failed"
    aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$igw" 2>/dev/null \
      && ok "IGW $igw deleted" || warn "IGW $igw: delete failed"
  done

  for sg in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true); do
    # Suppress stdout: this API returns a {"Return": true} object.
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 \
      && ok "Security group $sg deleted" || warn "Security group $sg: delete failed (check for dependencies)"
  done

  # Subnets before route tables: a route table can hold a subnet association,
  # and the "main" route table cannot be deleted at all (it goes with the VPC).
  for sn in $(aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" \
      --query 'Subnets[].SubnetId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true); do
    aws ec2 delete-subnet --region "$REGION" --subnet-id "$sn" >/dev/null 2>&1 \
      && ok "Subnet $sn deleted" || warn "Subnet $sn: delete failed"
  done

  for rt in $(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" \
      --query 'RouteTables[?AssociationState==`associated`].RouteTableId' \
      --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true); do
    # The main route table is deleted implicitly with the VPC; skip it.
    aws ec2 delete-route-table --region "$REGION" --route-table-id "$rt" >/dev/null 2>&1 \
      && ok "Route table $rt deleted" || warn "Route table $rt: skipped (main table — removed with VPC)"
  done

  # Dependency teardown is eventually consistent; retry the VPC delete a few
  # times before reporting failure.
  for attempt in 1 2 3; do
    if aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC" >/dev/null 2>&1; then
      ok "VPC $VPC deleted"
      break
    fi
    if [ "$attempt" -lt 3 ]; then
      warn "VPC $VPC delete failed, retrying (attempt $attempt/3)..."
      sleep 5
    else
      warn "VPC $VPC: delete failed — check for leftover resources"
    fi
  done
done

step "Verification"
REMAINING="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)"
if [ -z "$REMAINING" ]; then
  ok "No AgentOffice VPCs remain in $REGION"
else
  warn "Still present: $(echo $REMAINING)"
  warn "Something is still attached. Check for load balancers, VPN gateways,"
  warn "or EIPs you have not released, then re-run this script."
fi

step "Done"
info "Remember: if Terraform state still references these resources, remove"
info "them from state with 'tofu state rm' so a later apply does not try to"
info "manage what no longer exists."
