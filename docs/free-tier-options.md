# Free and near-free options, compared

Every provider advertises a free tier. For a VPN, the number that matters is not CPU or RAM —
WireGuard needs almost none of either — it is **egress**. Most free tiers are generous with
compute and stingy with bandwidth, which is exactly backwards for this workload.

*Figures current as of September 2026. Cloud pricing changes; verify before relying on it.*

---

## Summary

| Provider | Sign up | Cost | Egress/month | Verdict |
| --- | --- | --- | --- | --- |
| **Oracle Cloud Always Free** | [oracle.com/cloud/free](https://www.oracle.com/cloud/free/) | $0 forever | **10 TB** | Best free option by a distance — if you can get capacity |
| **Azure free account** | [azure.microsoft.com/free](https://azure.microsoft.com/free/) | $0 for 12 months | 100 GB | One region, one always-on VM, then it expires |
| **AWS Lightsail** | [aws.amazon.com/lightsail/pricing](https://aws.amazon.com/lightsail/pricing/) | $3.50-$5/mo | 0.5-1 TB | Not free, but the cheapest thing that always works |
| **AWS Free Tier** | [aws.amazon.com/free](https://aws.amazon.com/free/) | $100-200 credits | — | Credit-based since July 2025; no 12-month EC2 tier |
| **Google Cloud Always Free** | [cloud.google.com/free](https://cloud.google.com/free) | $0 forever | **1 GB** | Unusable for a VPN |

---

## Oracle Cloud Always Free

The only genuinely free-forever option with enough bandwidth to matter: **10 TB of egress per
month**, roughly twenty times a $5 Lightsail bundle, on an Ampere A1 ARM instance.

The catches are real:

- Oracle **halved** the Always Free A1 allowance from 4 OCPU/24 GB to **2 OCPU/12 GB** effective
  15 June 2026, with no blog post or customer notification, and began terminating instances
  above the new limit from 18 August 2026.
- A1 capacity is frequently unavailable. `Out of host capacity` errors are common in US regions
  and can persist for hours or days. European and Asian regions provision more reliably.
- Free-tier instances can be reclaimed if idle.

Still 2 OCPU and 12 GB of RAM — vastly more than a VPN needs — for nothing. If you can
provision one, take it. Just do not make it the only way you can reach the internet.

Regions covering the common cases: `us-sanjose-1`, `us-phoenix-1`, `ap-mumbai-1`,
`ap-singapore-1`, `eu-frankfurt-1`.

---

## Azure free account

A new Azure account includes **750 hours/month of a B1s VM for 12 months**, which is exactly one
always-on server, plus $200 in credits valid for the first 30 days. Egress is free for the first
100 GB per month.

Good for a full year of one always-on region. Not useful for multi-region, since 750 hours is a
single VM's worth of uptime.

---

## AWS

**The 12-month free tier is gone for new accounts.** Since 15 July 2025, accounts created after
that date get a credit-based model instead: $100 on signup, growing to $200 by completing
onboarding tasks, on either a Free plan (closes after six months or when credits run out) or a
Paid plan. Accounts created *before* that date keep the old 12-month allowances.

So on a new AWS account, Lightsail is not free — but at $5/month flat with 1 TB of transfer, and
billed hourly so you can delete it when idle, it is the cheapest option that provisions reliably
every single time. That predictability is why this repository defaults to it.

Note that AWS's 100 GB/month free egress allowance is **account-wide**, not per region, and
applies to EC2 rather than to Lightsail bundles, which have their own included transfer.

---

## Google Cloud

The Always Free `e2-micro` in `us-west1`, `us-central1`, or `us-east1` includes **1 GB of
outbound transfer per month**. A single video call will exhaust it.

GCP is a paid option for this use case. The $300/90-day trial credit will cover a VPN
comfortably while it lasts.

---

## Recommendation

- **Want free and will tolerate flakiness** → Oracle Cloud Always Free.
- **Want it to work every time** → AWS Lightsail, `down` when idle, ~$0.42-1.67/month.
- **Have a new Azure account** → take the 12 free months for your home region, and use
  Lightsail on-demand for everywhere else.
