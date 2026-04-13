"""
auto_mirror.py — Dynamic VPC Traffic Mirror Session manager

Triggered by EventBridge on Auto Scaling lifecycle events:
  EC2 Instance Launch Successful  → create mirror session for new EKS node ENI
  EC2 Instance Terminate Successful → delete mirror session for terminated node ENI

Environment variables (set by Terraform):
  MIRROR_FILTER_ID  — aws_ec2_traffic_mirror_filter ID
  MIRROR_TARGET_ID  — aws_ec2_traffic_mirror_target ID (NLB)
  EKS_CLUSTER_NAME  — only mirror nodes belonging to this cluster
  VXLAN_VNI         — VXLAN virtual network ID (default: 100)
  SESSION_NUMBER    — session number to assign (default: 1, unique per ENI so 1 is safe)

Session numbers are unique per SOURCE ENI, not globally. Each ENI gets exactly
one session (session_number=1), so there is no conflict between nodes.

Terraform-managed sessions (for nodes that existed at apply time) and Lambda-managed
sessions (for auto-scaled nodes) both use session_number=1 per ENI.
"""

import boto3
import json
import logging
import os
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client("ec2", region_name=os.environ.get("AWS_REGION", "eu-central-1"))

MIRROR_FILTER_ID = os.environ["MIRROR_FILTER_ID"]
MIRROR_TARGET_ID = os.environ["MIRROR_TARGET_ID"]
EKS_CLUSTER_NAME = os.environ["EKS_CLUSTER_NAME"]
VXLAN_VNI        = int(os.environ.get("VXLAN_VNI", "100"))
SESSION_NUMBER   = int(os.environ.get("SESSION_NUMBER", "1"))

COMMON_TAGS = [
    {"Key": "Component",  "Value": "suricata-mirror"},
    {"Key": "ManagedBy",  "Value": "lambda-auto-mirror"},
    {"Key": "Environment","Value": os.environ.get("ENV", "prd")},
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def is_eks_node(instance_id: str) -> bool:
    """Return True if the instance belongs to EKS_CLUSTER_NAME."""
    try:
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        for reservation in resp["Reservations"]:
            for inst in reservation["Instances"]:
                tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                if tags.get("eks:cluster-name") == EKS_CLUSTER_NAME:
                    return True
    except Exception as exc:
        logger.warning("describe_instances(%s) failed: %s", instance_id, exc)
    return False


def get_primary_eni(instance_id: str, retries: int = 6, delay: int = 5) -> str | None:
    """
    Return the primary ENI ID (device-index 0) for the instance.
    Retries because at launch the ENI attachment may not be visible immediately.
    """
    for attempt in range(retries):
        try:
            resp = ec2.describe_network_interfaces(
                Filters=[
                    {"Name": "attachment.instance-id",   "Values": [instance_id]},
                    {"Name": "attachment.device-index",  "Values": ["0"]},
                    {"Name": "status",                   "Values": ["in-use"]},
                ]
            )
            enis = resp["NetworkInterfaces"]
            if enis:
                return enis[0]["NetworkInterfaceId"]
        except Exception as exc:
            logger.warning("describe_network_interfaces attempt %d failed: %s", attempt + 1, exc)

        if attempt < retries - 1:
            logger.info("Primary ENI not found yet for %s, retrying in %ds...", instance_id, delay)
            time.sleep(delay)

    logger.error("Primary ENI not found for %s after %d attempts", instance_id, retries)
    return None


def find_session_for_eni(eni_id: str) -> str | None:
    """Return the TrafficMirrorSessionId for the given ENI, if any."""
    try:
        resp = ec2.describe_traffic_mirror_sessions(
            Filters=[
                {"Name": "network-interface-id", "Values": [eni_id]},
                {"Name": "traffic-mirror-target-id", "Values": [MIRROR_TARGET_ID]},
            ]
        )
        sessions = resp["TrafficMirrorSessions"]
        if sessions:
            return sessions[0]["TrafficMirrorSessionId"]
    except Exception as exc:
        logger.warning("describe_traffic_mirror_sessions(%s) failed: %s", eni_id, exc)
    return None


# ---------------------------------------------------------------------------
# Core actions
# ---------------------------------------------------------------------------

def create_session(instance_id: str) -> None:
    if not is_eks_node(instance_id):
        logger.info("Instance %s is not an EKS node in cluster %s — skipping", instance_id, EKS_CLUSTER_NAME)
        return

    eni_id = get_primary_eni(instance_id)
    if not eni_id:
        return

    # Idempotency: don't create a second session if one already exists
    existing = find_session_for_eni(eni_id)
    if existing:
        logger.info("Mirror session %s already exists for ENI %s — nothing to do", existing, eni_id)
        return

    try:
        resp = ec2.create_traffic_mirror_session(
            NetworkInterfaceId=eni_id,
            TrafficMirrorTargetId=MIRROR_TARGET_ID,
            TrafficMirrorFilterId=MIRROR_FILTER_ID,
            SessionNumber=SESSION_NUMBER,
            VirtualNetworkId=VXLAN_VNI,
            Description=f"bc-prd ENI {eni_id} → Suricata (auto-scaled)",
            TagSpecifications=[
                {
                    "ResourceType": "traffic-mirror-session",
                    "Tags": COMMON_TAGS + [{"Key": "InstanceId", "Value": instance_id}],
                }
            ],
        )
        sid = resp["TrafficMirrorSession"]["TrafficMirrorSessionId"]
        logger.info("Created mirror session %s for ENI %s (instance %s)", sid, eni_id, instance_id)
    except ec2.exceptions.ClientError as exc:
        if "already exists" in str(exc):
            logger.info("Session already exists for ENI %s — idempotent", eni_id)
        else:
            raise


def delete_session(instance_id: str) -> None:
    """
    Delete the mirror session for the terminating instance.
    The ENI may already be detached, so we look up sessions by InstanceId tag as a fallback.
    """
    # Try by ENI first (instance still has ENI during termination)
    eni_id = get_primary_eni(instance_id, retries=2, delay=2)
    if eni_id:
        session_id = find_session_for_eni(eni_id)
        if session_id:
            _delete(session_id, eni_id)
            return

    # Fallback: find session by InstanceId tag
    try:
        resp = ec2.describe_traffic_mirror_sessions(
            Filters=[
                {"Name": "traffic-mirror-target-id", "Values": [MIRROR_TARGET_ID]},
                {"Name": "tag:InstanceId",           "Values": [instance_id]},
            ]
        )
        sessions = resp["TrafficMirrorSessions"]
        for s in sessions:
            _delete(s["TrafficMirrorSessionId"], s.get("NetworkInterfaceId", "unknown"))
        if not sessions:
            logger.info("No mirror session found for instance %s — nothing to delete", instance_id)
    except Exception as exc:
        logger.warning("Fallback session lookup failed for %s: %s", instance_id, exc)


def _delete(session_id: str, eni_id: str) -> None:
    try:
        ec2.delete_traffic_mirror_session(TrafficMirrorSessionId=session_id)
        logger.info("Deleted mirror session %s (ENI %s)", session_id, eni_id)
    except ec2.exceptions.ClientError as exc:
        if "InvalidTrafficMirrorSessionId" in str(exc):
            logger.info("Session %s already gone — idempotent", session_id)
        else:
            raise


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def handler(event: dict, context) -> dict:
    logger.info("Event: %s", json.dumps(event))

    detail_type = event.get("detail-type", "")
    detail      = event.get("detail", {})
    instance_id = detail.get("EC2InstanceId")

    if not instance_id:
        logger.warning("No EC2InstanceId in event detail — ignoring")
        return {"statusCode": 200, "body": "no-op"}

    if detail_type == "EC2 Instance Launch Successful":
        logger.info("Launch event for %s", instance_id)
        create_session(instance_id)

    elif detail_type == "EC2 Instance Terminate Successful":
        logger.info("Terminate event for %s", instance_id)
        delete_session(instance_id)

    else:
        logger.info("Unhandled detail-type '%s' — ignoring", detail_type)

    return {"statusCode": 200, "body": "ok"}
