# MANA Explained + Evidence Walkthrough

A single place to **explain what MANA is** (with a plain-English analogy), then **prove it** with exact,
real script/query outputs for every case: on MANA, not on MANA, driver missing, hardware missing, traffic
attribution, AN disabled, and NVA tagging. Use it to teach the change, the scripts, and the lifecycle.

> Everything here is grounded in official Microsoft Learn ([references.md](./references.md)). Verified 2026-08-24.
> Real outputs are reused from [sample-outputs.md](./sample-outputs.md); the reproducible lab is [evidence-lab.md](./evidence-lab.md).

---

## 1. The analogy — MANA is a new highway, not a faster car

The most common misconception is _"MANA makes my network faster."_ It doesn't raise your speed limit.

- **Your VM is a car**, and your network traffic is the cars on the road.
- **The speed limit is your VM size** — Azure ties network bandwidth caps to the **VM size, not the hardware**.
  Moving to MANA does **not** raise that limit. A bigger car (bigger VM) still has the higher limit on either road.
- **Mellanox / ConnectX is the old highway.** It works fine today.
- **MANA is a newly engineered highway** (new **hardware**) with a smoother **express lane** and better on-ramps,
  built by Microsoft, shipped with **forward-compatible drivers** (new **software**).
- **The express lane is Accelerated Networking (the SR-IOV Virtual Function / VF).** To drive it, your car needs a
  **driver who knows the express lane — the MANA OS driver** (a supported Linux kernel or the Windows MANA driver).
- If your driver **doesn't** know the new express lane (OS lacks MANA support), you fall back to the **regular lane
  (NetVSC / the hypervisor virtual switch)**. Fine when traffic is light; it **jams at rush hour** (many concurrent
  connections).
- **The payoff isn't top speed — it's rush hour.** The new highway handles **high connection counts** better and is
  more **reliable and resilient**, with drivers that won't need replacing every year.
- **NVAs are special heavy vehicles** (armored trucks / inspection booths = firewalls, routers, SD-WAN). They're
  **bolted tightly to the road hardware and drivers**, so if their driver isn't certified for the new express lane
  they can **stall or slow the whole lane** — which is why they need validation before MANA.
- **The `LegacyVMNVA` tag is a "stay on the old highway" permit** for those special vehicles — it keeps them on the
  familiar Mellanox road **until May 31, 2027** while you retrofit them (update the driver / move to a MANA-ready vehicle).
- **AKS is a fleet with its own dispatcher** — Azure manages the node image and driver, so the dispatcher moves the
  fleet onto the new highway **automatically**. You don't drive those.

```mermaid
flowchart LR
  Car["Your VM = a car (your traffic)"] --> Limit["Speed limit = VM size (same on BOTH roads)"]
  Limit --> Fork{"Which highway did Azure place you on?"}
  Fork -->|"Mellanox / ConnectX"| Old["Old highway - works fine today (mlx5_core)"]
  Fork -->|"MANA (new, Microsoft-built)"| Drv{"Does your driver know the express lane? (MANA OS driver)"}
  Drv -->|"Yes: MANA driver + AN"| Exp["Express lane = VF active - smooth even at rush hour"]
  Drv -->|"No: OS lacks MANA driver"| Reg["Regular lane = NetVSC fallback - fine light, jams at rush hour"]
  Special["Special heavy vehicle = NVA (firewall / router)"] --> Cert{"Certified for the express lane? (vendor MANA support)"}
  Cert -->|"Not yet"| Permit["LegacyVMNVA permit: stay on old highway until May 31 2027, then retrofit"]
  Cert -->|"Yes"| Exp
```

### Analogy → Azure reality → what to check

| Analogy                       | Azure reality                                             | How you see it (this toolkit)                                   |
| ----------------------------- | --------------------------------------------------------- | --------------------------------------------------------------- |
| The car                       | Your VM / workload                                        | ARG inventory (`inventory-nva-*.kql`)                           |
| Speed limit                   | Bandwidth cap **tied to VM size**, not the road           | Docs fact; unchanged by MANA placement                          |
| Old highway                   | Mellanox / ConnectX host + `mlx5_core` VF driver          | `lspci` = ConnectX; VF driver `mlx5_core`                       |
| New highway (hardware)        | MANA-capable host                                         | `lspci` = `Device 00ba` (Linux) / `VEN_1414&DEV_00BA` (Windows) |
| Express lane                  | Accelerated Networking = SR-IOV **Virtual Function (VF)** | A NIC with the `SLAVE` flag bonded to `eth0`                    |
| Driver who knows the lane     | **MANA OS driver** (Linux kernel / Windows driver)        | VF driver `mana` / adapter "Microsoft Azure Network Adapter"    |
| Regular lane (fallback)       | **NetVSC** (hypervisor vSwitch) when OS lacks MANA        | On MANA hw but VF driver ≠ `mana` → NetVSC fallback             |
| Rush hour                     | **High concurrent connection counts**                     | Where MANA's reliability/scale benefit shows                    |
| Special heavy vehicle         | **NVA** (firewall / router / SD-WAN)                      | `NVAClass` in ARG; validate on host or via vendor               |
| "Stay on old highway" permit  | **`LegacyVMNVA`** opt-out tag (honored to May 31, 2027)   | Tag + `reapply`; ARG `LegacyVMNVATag` column                    |
| Fleet with its own dispatcher | **AKS** (Azure manages the node image/driver)             | Auto-excluded → "AKS-managed - not impacted"                    |

---

## 2. What MANA actually is (grounded)

- **MANA = Microsoft Azure Network Adapter**, a **component of Azure Boost**. A **next-generation network interface**
  with **stable, forward-compatible drivers** for Windows and Linux; **hardware and software both engineered by
  Microsoft**. ([overview](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-overview))
- **It's not a bandwidth upgrade.** _"Networking limits in Azure are tied to the VM size, not the underlying hardware.
  No change in performance is expected when moving to MANA-capable hardware if your VM's OS supports all network
  devices."_ ([existing-sizes](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-existing-sizes))
- **The value:** performance **at scale** (high connection counts), **reliability**, **resiliency**, and
  **forward-compatible drivers** that reduce future churn.
- **Feature parity is maintained.** MANA-eligible VMs run on hosts with **both** Mellanox and MANA NICs, so existing
  `mlx4` / `mlx5` support must still be present.
- **If the OS doesn't support MANA**, networking **falls back to NetVSC** (the hypervisor virtual switch). The VF may
  be visible but exposes no interfaces; performance is comparable to `ConnectX-3/4 Lx/5`, and **workloads with many
  concurrent connections may see reduced performance**.
- **If Accelerated Networking is disabled**, MANA placement is a **non-event** — no VF, no MANA driver dependency,
  **no action required**.

### The three things that must line up

MANA acceleration needs **all three**. Miss one and you land in the fallback lane (or MANA is simply irrelevant):

```mermaid
flowchart LR
  H["1 MANA hardware (host places you there)"] --> R{"All three present?"}
  O["2 MANA OS driver (supported kernel / Windows driver)"] --> R
  A["3 Accelerated Networking enabled (the VF)"] --> R
  R -->|"Yes"| Y["Express lane active - VF driver = mana"]
  R -->|"Missing #2 on MANA hw"| N["NetVSC fallback - follow up: update kernel/driver"]
  R -->|"AN off (missing #3)"| Z["No risk - MANA irrelevant; opt-in candidate later"]
```

---

## 3. Lifecycle + tagging — what / when / why / when-not

The end-to-end loop (inventory → verify → safeguard-if-needed → migrate → govern) and the two tracks (risk vs
MANA-optimization opt-in) are drawn in the [README](../README.md#how-it-works) and detailed in
[governance.md](./governance.md). The tag mechanics:

| Question            | Answer                                                                                                                                                                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **What** is the tag | `LegacyVMNVA` — applied by a **built-in Azure Policy** (`e87a87f5-e6dd-4919-be21-abb0a4ea4630`, v1.3.0)                                                                                                                              |
| **What** it does    | Keeps tagged NVA VMs / VMSS **off** MANA-capable hardware while you migrate                                                                                                                                                          |
| **When** to apply   | **Proactively**, for an **AN-based NVA not yet confirmed MANA-compatible** — before a placement change, not after degradation                                                                                                        |
| **When NOT** to     | General workloads, AN-disabled VMs, AKS, or NVAs already MANA-ready — tagging these adds risk/limits (e.g. ODCR SLA)                                                                                                                 |
| **How** (existing)  | Assign policy → **remediation** adds tag → **`az vm reapply`** enables it (VMSS Uniform: `reapply` REST) → verify                                                                                                                    |
| **How** (new)       | New in-scope deployments are tagged automatically                                                                                                                                                                                    |
| **How long**        | Honored **until May 31, 2027**; per Microsoft, after that the tag is no longer honored and MANA-eligible series may be placed on MANA hardware. Migrate NVAs to MANA-compatible before then; remove the policy assignment afterward. |
| **Gotcha**          | Applying the tag **alone is not enough** for existing resources — the **reapply** step enables it                                                                                                                                    |
| **BYO / non-Mktpl** | Built-in policy only tags **listed Marketplace publishers**; for BYO images, tag via your own tooling + reapply                                                                                                                      |

---

## 4. The scripts — what, when, why

Run the `.kql` in **Azure Resource Graph Explorer** (portal) or `az graph query`. Run the host scripts via
`az vm run-command` — **no SSH/RDP, no public IP**. **Pick `.sh` for Linux, `.ps1` for Windows** (they call OS-native tools).

| Script                                                                                                 | What it answers                                                      | When to run                                         | Why / key signal                                                    |
| ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------- |
| [`inventory-nva-vms.kql`](../scripts/inventory-nva-vms.kql)                                            | Which VMs are candidates? vendor, OS, AN, `NVAClass`, tag, verdict   | **First** — fleet-wide triage                       | Control-plane inventory; 6-state `NVAClass` so no vendor is skipped |
| [`inventory-nva-vmss.kql`](../scripts/inventory-nva-vmss.kql)                                          | Same, for **scale sets** (AKS-aware)                                 | With the VM query                                   | AKS auto-excluded; catches NVAs deployed as VMSS                    |
| [`discover-vendors.kql`](../scripts/discover-vendors.kql)                                              | **Every** distinct vendor/plan/OS with `PolicyScoped`/`FirstPartyOS` | Safety net alongside inventory                      | Eyeball unknown/third-party vendors so nothing is missed            |
| [`detect-mana.sh`](../scripts/detect-mana.sh) / [`.ps1`](../scripts/detect-mana.ps1)                   | Is **this** VM on MANA? (quick)                                      | Per candidate, after inventory                      | `lspci` `00ba` + VF driver `mana` = on MANA                         |
| [`validate-nva-mana.sh`](../scripts/validate-nva-mana.sh) / [`.ps1`](../scripts/validate-nva-mana.ps1) | Full per-VM verdict (tag+hw+driver+datapath+VF)                      | When you need a single PASS/FAIL verdict + evidence | Adds the **authoritative** netvsc `dmesg` datapath line             |
| [`distinguish-vf-mana.sh`](../scripts/distinguish-vf-mana.sh)                                          | **Which** NIC carried live traffic under load                        | To attribute traffic MANA vs ConnectX               | Driver-specific IRQ families + `dmesg` (counters alone can't tell)  |
| [`traffic-capture.sh`](../scripts/traffic-capture.sh)                                                  | Is traffic actually riding the VF?                                   | Quick before/after proof                            | `vf_*` counters jump by the packets you sent                        |

> **Important nuance:** `vf_*` counters prove the path is **accelerated**, but they are **driver-agnostic** (identical
> on MANA and Mellanox). To prove **which** NIC family, use the **VF driver name**, the netvsc **`dmesg`** datapath line,
> or the **IRQ family** (`mana_*` vs `mlx5_*`) — that's what `distinguish-vf-mana.sh` does.

---

## 5. Evidence walkthrough — exact outputs, what they mean, follow-up

Each scenario: **what you run → what you see (real capture) → what it means → follow-up.**

### A. SUCCESS — on MANA, driver working (`detect-mana.sh` / `validate-nva-mana.sh`)

```
=== lspci ethernet ===
7870:00:00.0 Ethernet controller: Microsoft Corporation Device 00ba
=== bound NIC driver (definitive: mana vs mlx5) ===
primary interface: eth0
VF interface: ens1
  ens1 driver = mana
  => VF driver 'mana' -> ON MANA
== 4. MANA driver ==   (validator)
netvsc datapath (dmesg): hv_netvsc <guid> eth0: Data path switched to VF: ens1
[PASS] netvsc reports datapath ON the VF (accelerated path active)
VERDICT: ON MANA, driver working.
```

- **Means:** hardware present (`00ba`), express-lane driver bound (`mana`), and netvsc confirms the datapath is **on the VF**.
- **Follow-up:** none for general workloads. If it's an NVA, validate appliance behavior and plan a MANA-optimized series.

### B. NOT on MANA — ConnectX / old highway (`detect-mana.sh`)

```
=== lspci ethernet ===
29c9:00:02.0 Ethernet controller: Mellanox Technologies MT27800 Family [ConnectX-5 Virtual Function] (rev 80)
=== MANA verdict (lspci 00ba) ===
NOT on MANA (no 00ba)
  enP10697s1 driver = mlx5_core
  => VF driver 'mlx5_core' -> NOT MANA (Mellanox/ConnectX)
```

- **Means:** you're on the old highway (Mellanox). Same OS/kernel as **A** — **only the host hardware differs**.
- **Follow-up:** none today. It's a **MANA opt-in candidate** later (newer/MANA-optimized series raise the odds).

### C. FOLLOW-UP — on MANA hardware but **driver missing** → NetVSC fallback (`validate-nva-mana.sh`)

> Expected output from the validator's **failure branch**. Reproduce by placing a MANA-eligible VM on an OS/kernel
> **without** MANA support (we could not force this in-lab — our MANA hosts had the driver). This is the case the
> analogy's "regular lane" warns about.

```
== 3. MANA hardware (PCI Device 00ba) ==
[PASS] MANA NIC present: Microsoft Corporation Device 00ba
== 4. MANA driver ==
VF 'ens1' bound driver: (none / hv_netvsc)
[FAIL] On MANA hardware but MANA driver NOT bound -> NetVSC fallback risk (update kernel/driver)
VERDICT: ON MANA hardware but driver MISSING -> NetVSC fallback. Update OS/kernel or install MANA driver.
```

- **Means:** you're on the new highway but your driver doesn't know the express lane → you're in the **regular lane
  (NetVSC)**. Fine at light load; **degrades at high connection counts**.
- **Follow-up:** **update the Linux kernel** (MANA Ethernet upstream in 5.15+, DPDK needs 6.14+) **or install the
  Windows MANA driver** (<https://aka.ms/manawindowsdrivers>). If it's an NVA that degrades, **keep `LegacyVMNVA`** until fixed.

### D. HARDWARE MISSING vs AN DISABLED — no MANA involvement

- **Hardware missing** = scenario **B** (no `00ba` → you're simply on Mellanox; nothing to do).
- **AN disabled** (ARG, real):

```
VM      Vendor     NVAClass               AN        Tag      Verdict
web-01  canonical  General (platform OS)  Disabled  Not set  No action - AN disabled
```

- **Means:** no VF, no MANA driver dependency — MANA placement is a **non-event**.
- **Follow-up:** none for risk. Keep it in the re-scan as a **MANA opt-in** candidate (enable AN + MANA-ready OS later).

### E. TRAFFIC ATTRIBUTION — MANA vs ConnectX under load (`traffic-capture.sh` / `distinguish-vf-mana.sh`)

```
=== VF counters BEFORE ===   vf_rx_packets: 1231   vf_tx_packets: 1449
=== generating traffic (flood ping x5000) ===   ping exit=0
=== VF counters AFTER  ===   vf_rx_packets: 6232   vf_tx_packets: 6454      # +~5000 each way

# distinguish-vf-mana.sh attributes the SAME load to the right family:
# MANA VM     -> dmesg "Data path switched to VF: ens1"    IRQs mana_q0..q3 / mana_hwc
# ConnectX VM -> dmesg "Data path switched to VF: enP..s1" IRQs mlx5_comp0..3 / mlx5_async0
```

- **Means:** traffic rides the accelerated **VF**; the **driver/`dmesg`/IRQ family** proves it's MANA (not just "accelerated").
- **Follow-up:** none — this is your proof artifact that the express lane is actually carrying the cars.

### F. NVA CLASSIFICATION + TAGGING (`inventory-nva-vms.kql`, policy remediation)

```
VM         Vendor            NVAClass                          AN       Tag      Verdict
nva-fw-01  paloaltonetworks  Policy-scoped NVA (auto-tag)      Enabled  Not set  NVA (policy-scoped) - validate on host; policy auto-tags in scope
nva-el-01  elisityinc123     Marketplace - not in policy list  Enabled  Not set  Marketplace NVA NOT in policy list - tag MANUALLY if not MANA-ready
nva-ac-01  acme-appliances   Third-party publisher (review)    Enabled  Not set  Third-party publisher - verify on host; tag manually if it is an NVA
```

```
# az policy remediation create ...  -> state: Succeeded, totalDeployments: 0
# (built-in policy only tags listed Marketplace NVA publishers; plain OS VMs match nothing = expected)
# Manual (BYO): az vm update --set tags.LegacyVMNVA=true  ->  az vm reapply  ->  tag enabled
```

- **Means:** the 6-state `NVAClass` routes **every** non-first-party publisher to an explicit review bucket — no vendor
  is silently skipped. Policy auto-tags only in-scope Marketplace publishers; everything else is a **manual** decision.
- **Follow-up:** for each flagged NVA, confirm MANA support with the vendor; if not ready, **tag + reapply**, then migrate.

---

## 6. Suggested run order (talk track)

1. **Set the mental model** — the highway analogy (§1). Land the "speed limit = VM size; MANA is a better road, not a
   faster car" point first.
2. **Inventory** — run `inventory-nva-*.kql` + `discover-vendors.kql`; show the 6-state `NVAClass` and that nothing is skipped (§5F).
3. **Prove placement** — `detect-mana.sh` on a MANA VM (**A**) and a ConnectX VM (**B**); same OS, different road.
4. **Prove the datapath** — `validate-nva-mana.sh` (netvsc `dmesg` line) and `distinguish-vf-mana.sh` under load (**E**).
5. **Show the failure mode** — the driver-missing / NetVSC fallback verdict (**C**) and how to fix it.
6. **Lifecycle + tag** — when to apply `LegacyVMNVA`, the reapply gotcha, May 31 2027, and the two tracks (risk vs opt-in).
7. **Close** — "no action" is never "ignore forever"; AN-off/general stay in the loop as MANA-optimization candidates.

---

## 7. Troubleshooting (quick)

| Symptom                                               | Fix                                                                           |
| ----------------------------------------------------- | ----------------------------------------------------------------------------- |
| `az: 'graph' is not in the 'az' command group`        | `az extension add -n resource-graph`                                          |
| ARG `InvalidQuery` / `ParserFailure` on an operator   | ARG lacks some KQL operators (e.g. `mv-apply`); use `mv-expand` + `summarize` |
| `run-command ... execution is in progress` (Conflict) | One `run-command` per VM at a time — retry after the prior one finishes       |
| VF interface name changed after redeploy              | Derive the VF from the `SLAVE` flag; never hardcode (`enP..s1` changes)       |
| `dmesg` datapath line empty                           | May need `sudo`, or the ring rotated — re-check after generating traffic      |

---

## References

- MANA overview: <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-overview>
- MANA for existing VM series (dates, "tied to VM size"): <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-existing-sizes>
- MANA NVA opt-out (`LegacyVMNVA`): <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-network-virtual-appliance-opt-out>
- Linux VMs with MANA: <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-linux>
- Windows VMs with MANA: <https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-windows>
- Full list + verified key values: [references.md](./references.md)
  </content>
  </invoke>
