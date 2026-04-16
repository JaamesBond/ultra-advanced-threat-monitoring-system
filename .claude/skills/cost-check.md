---
name: cost-check
description: Estimate monthly AWS cost impact of proposed changes against the current ~$565/month baseline for the XDR system
---

# Cost Check — Big Chemistry XDR

Estimate the cost impact of proposed or recent changes. This project is budget-constrained — every new resource needs justification.

## Procedure

### Step 1: Identify New/Changed Resources

Read the diff or proposed changes. For each resource, classify:
- **NEW**: Resource being added
- **MODIFIED**: Existing resource changing size/config
- **REMOVED**: Resource being deleted

### Step 2: Calculate Cost Delta

Use this reference pricing (eu-central-1, on-demand):

**EC2 Instances:**
| Type | $/hour | $/month (730h) |
|------|--------|----------------|
| t3.nano | $0.0052 | $3.80 |
| t3.micro | $0.0104 | $7.59 |
| t3.small | $0.0208 | $15.18 |
| t3.medium | $0.0416 | $30.37 |
| t3.large | $0.0832 | $60.74 |
| t3.xlarge | $0.1664 | $121.47 |
| t4g.nano | $0.0042 | $3.07 |
| t4g.micro | $0.0084 | $6.13 |
| t4g.small | $0.0168 | $12.26 |

**EKS:** $0.10/hour = $73/month per cluster

**NAT Gateway (managed):** $0.045/hour + $0.045/GB = ~$32.85/month base

**Transit Gateway:** $0.05/hour + $0.02/GB = ~$36.50/month base

**VPC Interface Endpoint:** ~$0.01/hour/AZ + $0.01/GB = ~$7.30/month/AZ (1 AZ) to ~$21.90 (3 AZ)

**VPC Gateway Endpoint (S3/DynamoDB):** FREE

**EBS (gp3):** $0.0880/GB/month

**Data Transfer:**
- VPC Peering: $0.01/GB (same region)
- NAT to internet: $0.09/GB
- Within AZ: free
- Cross-AZ: $0.01/GB each direction

**Public IPv4:** $0.005/hour = $3.65/month (since Feb 2024)

### Step 3: Compare Against Budget

Current baseline: ~$565-585/month.

Flag:
- Any single resource adding > $10/month → needs justification
- Any change pushing total > $650/month → needs approval
- Any managed service replacing a self-managed one → calculate savings vs cost

### Step 4: Suggest Alternatives

For each flagged cost:
- Can we use ARM (t4g)? — ~20% cheaper
- Can we use Spot? — ~60-70% cheaper (if tolerant)
- Can we use Gateway endpoint instead of Interface? — free vs $7+/month
- Can we schedule stop/start? — 50% savings for 12h/day
- Can we use a smaller instance? — show pod resource math
- Can we share an existing resource?

### Step 5: Report

```
## Cost Check

### Current Baseline: ~$X/month

### Changes:
| Resource | Action | Cost Impact |
|----------|--------|-------------|
| ... | NEW/MODIFY/REMOVE | +/- $X/month |

### Net Monthly Change: +/- $X/month
### New Estimated Total: ~$X/month

### Flags:
[Any cost concerns]

### Alternatives:
[Cheaper options if applicable]

### Verdict: [APPROVE / NEEDS JUSTIFICATION]
```
