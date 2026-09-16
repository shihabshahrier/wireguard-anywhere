---
name: New cloud provider
about: Request or propose support for another cloud
title: 'Provider: '
labels: enhancement, provider
assignees: ''
---

**Which provider?**

**Cheapest instance that can run WireGuard, and its price:**

**Included egress per month, and the overage rate:**

**Does it have a scriptable CLI?** (link to docs)

**Does it require anything special for packet forwarding?**
GCP needs `--can-ip-forward`; Azure needs IP forwarding on the NIC resource.

**Are you planning to implement it?**
The interface is documented in [AGENTS.md](../../AGENTS.md) and
[CONTRIBUTING.md](../../CONTRIBUTING.md).
