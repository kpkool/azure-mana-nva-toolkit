# Sample Outputs (real, anonymized)

Actual outputs from running this toolkit's scripts and queries. Private IPs/identifiers replaced with placeholders. Your PCI addresses, MACs, and counters will differ.

---

## 1. Linux — ON MANA (`scripts/detect-mana.sh`)

```
=== kernel ===
6.17.0-1021-azure
=== lspci ethernet ===
7870:00:00.0 Ethernet controller: Microsoft Corporation Device 00ba
=== MANA verdict (lspci 00ba) ===
ON MANA: Microsoft Device 00ba present
=== mana driver present ===
kernel/drivers/net/ethernet/microsoft/mana/mana.ko
=== ip link (brief) ===
eth0             UP   <mac>  <BROADCAST,MULTICAST,UP,LOWER_UP>
ens1             UP   <mac>  <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP>
=== bound NIC driver (definitive: mana vs mlx5) ===
primary interface: eth0
VF interface: ens1
  eth0 driver = hv_netvsc
  ens1 driver = mana
  => VF driver 'mana' -> ON MANA
=== VF counters (primary NIC) ===
     vf_rx_packets: 817
     vf_tx_packets: 949
```

**Verdict:** `lspci` shows `00ba`, VF `ens1` driver is **`mana`** → **ON MANA**.

---

## 2. Linux — NOT on MANA / ConnectX (`scripts/detect-mana.sh`)

```
=== lspci ethernet ===
29c9:00:02.0 Ethernet controller: Mellanox Technologies MT27800 Family [ConnectX-5 Virtual Function] (rev 80)
=== MANA verdict (lspci 00ba) ===
NOT on MANA (no 00ba)
=== bound NIC driver (definitive: mana vs mlx5) ===
primary interface: eth0
VF interface: enP10697s1
  eth0 driver = hv_netvsc
  enP10697s1 driver = mlx5_core
  => VF driver 'mlx5_core' -> NOT MANA (Mellanox/ConnectX)
```

**Verdict:** ConnectX-5, VF driver **`mlx5_core`** → **NOT MANA**. (Same OS/kernel as #1 — only the host hardware differs.)

---

## 3. Linux — MANA traffic before/after (`scripts/traffic-capture.sh`)

```
primary interface: eth0   target: <target-private-ip>
=== VF counters BEFORE ===
     vf_rx_packets: 1231
     vf_tx_packets: 1449
=== generating traffic (flood ping x5000) ===
ping exit=0
=== VF counters AFTER ===
     vf_rx_packets: 6232
     vf_tx_packets: 6454
```

**Verdict:** VF counters jumped ~5,000 packets each way → traffic is flowing through the **MANA VF** data path.

---

## 3b. Linux — full validator + traffic attribution (`scripts/validate-nva-mana.sh`, `scripts/distinguish-vf-mana.sh`)

`validate-nva-mana.sh` — one-pass verdict (ON MANA), key lines:

```
== 4. MANA driver ==
VF 'ens1' bound driver: mana
[PASS] VF driver = mana -> MANA driver loaded and bound
netvsc datapath (dmesg): hv_netvsc <guid> eth0: Data path switched to VF: ens1
[PASS] netvsc reports datapath ON the VF (accelerated path active)
== SUMMARY ==
VERDICT: ON MANA, driver working. No action for general workloads. If this is an NVA, validate appliance behavior and consider migrating to a MANA-optimized series.
```

On a ConnectX host the same script prints `VF driver = mlx5_core -> Mellanox/ConnectX (not MANA)` and `VERDICT: NOT on MANA`. The Windows `validate-nva-mana.ps1` prints the equivalent PASS/VERDICT via `Get-PnpDevice` + `Get-NetAdapter`.

`distinguish-vf-mana.sh` — attributes the **same** flood-ping load to the correct NIC family under load:

```
# MANA VM  (VF ens1, driver mana)
Signal 0 dmesg: eth0: Data path switched to VF: ens1
Signal 2 IRQs:  mana_q0..q3 + mana_hwc@pci   (incrementing)
delta rx_bytes on ens1        = 7,210,042

# ConnectX VM  (VF enP..s1, driver mlx5_core)
Signal 0 dmesg: eth0: Data path switched to VF: enP..s1
Signal 2 IRQs:  mlx5_comp0..3 + mlx5_async0@pci   (incrementing)
delta rx_bytes on enP..s1     = 7,210,631
```

**Verdict:** the netvsc `dmesg` line plus the driver-specific IRQ family attribute traffic to MANA vs ConnectX. The `vf_*` counters alone prove the path is _accelerated_, not _which_ NIC — the driver / `dmesg` / IRQ names are the discriminator.

---

## 4. Windows — ON MANA (`scripts/detect-mana.ps1`)

```
=== Get-NetAdapter ===
Name       InterfaceDescription              Status LinkSpeed
----       --------------------              ------ ---------
Ethernet 2 Microsoft Azure Network Adapter   Up     200 Gbps
Ethernet   Microsoft Hyper-V Network Adapter Up     200 Gbps

=== MANA PCI device (VEN_1414 & DEV_00BA) ===
Status Class         FriendlyName
------ -----         ------------
OK     MultiFunction Microsoft Azure Network Adapter Virtual Bus

=== MANA verdict ===
ON MANA: Microsoft Azure Network Adapter present
=== MANA adapter statistics ===
Name          : Ethernet 2
ReceivedBytes : 1425310
SentBytes     : 1001831
```

**Verdict:** `Get-NetAdapter` lists **Microsoft Azure Network Adapter** and `Get-PnpDevice` shows the MANA Virtual Bus (`VEN_1414&DEV_00BA`) → **ON MANA**. A ConnectX host would instead show a Mellanox adapter / `VEN_15B3` and no `00ba`.

---

## 5. ARG inventory — success (`scripts/inventory-nva-vms.kql` + `inventory-nva-vmss.kql`)

VMs — enriched with **Vendor (plan-publisher aware), NVAClass (6-state), ImageSource, OS + OSVersion**. `NVAClass` routes every non-first-party-OS VM to an explicit review bucket so no vendor is skipped; `OS` tells you `.sh` vs `.ps1`:

```
VM        Vendor            NVAClass                          ImageSource     OS       OSVersion                           AN       Tag      Verdict
--------  ----------------  --------------------------------  --------------  -------  ----------------------------------  -------  -------  ------------------------------------------------------------
web-01    canonical         General (platform OS)             Platform        Linux    ubuntu-24_04-lts / server           Disabled Not set  No action - AN disabled
nva-fw-01 paloaltonetworks  Policy-scoped NVA (auto-tag)      Marketplace     Linux    vmseries-flex / byol                Enabled  Not set  NVA (policy-scoped) - validate on host; policy auto-tags in scope
nva-el-01 elisityinc123     Marketplace - not in policy list  Marketplace     Linux    elisity-edge / edge                 Enabled  Not set  Marketplace NVA NOT in policy list - verify on host; tag MANUALLY if not MANA-ready
nva-ac-01 acme-appliances   Third-party publisher (review)    Platform        Linux    acme-secure-gw / 2024               Enabled  Not set  Third-party publisher - verify on host; tag manually if it is an NVA
nva-gw-01 unknown/custom    Custom/unknown image (review)     Gallery/Custom  Linux    custom image (no publisher/sku)     Enabled  Not set  Unknown/custom image - verify on host; tag manually if it is an NVA
app-01    canonical         General (platform OS)             Platform        Linux    ubuntu-24_04-lts / server           Enabled  Not set  AN general VM - verify on host (likely no action)
win-01    microsoftwindows… General (platform OS)             Platform        Windows  WindowsServer / 2022-datacenter-g2  Enabled  True     Opt-out tag present - confirm reapply, then plan migration
```

VMSS (AKS-aware) — **real captured output** (anonymized): AKS auto-excluded, a general Ubuntu VMSS classified `General`:

```
VMSS                     Vendor          NVAClass                       ImageSource     OS     OSVersion                        AN       Verdict
-----------------------  --------------  -----------------------------  --------------  -----  -------------------------------  -------  ---------------------------------------------------
aks-systempool-...-vmss  unknown/custom  Custom/unknown image (review)  Gallery/Custom  Linux  custom image (no publisher/sku)  Enabled  AKS-managed - not impacted by MANA (per docs)
aks-userpool-...-vmss    unknown/custom  Custom/unknown image (review)  Gallery/Custom  Linux  custom image (no publisher/sku)  Enabled  AKS-managed - not impacted by MANA (per docs)
devops-vmss              canonical       General (platform OS)          Platform        Linux  ubuntu-24_04-lts / server        Enabled  AN general VMSS - verify on host (likely no action)
```

**Discovery (safety net)** — `scripts/discover-vendors.kql` lists every distinct vendor/plan/OS with a `PolicyScoped` and `FirstPartyOS` flag so nothing is skipped; **`FirstPartyOS=No` rows are the third parties to review** (real capture):

```
Vendor                  OSType   OSVersion                           ImageSource     PolicyScoped  FirstPartyOS  VMCount
----------------------  -------  ----------------------------------  --------------  ------------  ------------  -------
unknown/custom          Linux    custom image (no publisher/sku)     Gallery/Custom  No            No            2
unknown/custom          Windows  custom image (no publisher/sku)     Gallery/Custom  No            No            1
Canonical               Linux    ubuntu-24_04-lts / server           Platform        No            Yes           3
MicrosoftWindowsServer  Windows  WindowsServer / 2022-datacenter-g2  Platform        No            Yes           1
```

**Note:** the KQL always selects `subscriptionId`/`resourceGroup` (plus PlanPublisher, PlanProduct, Offer, Sku, location); the CLI `--query "data[].{...}"` is a client-side projection. `Vendor` prefers the **Marketplace plan publisher** (what the policy matches). ARG reports control-plane signals only — always finish with the in-guest check (#1–#3b).

---

## 6. Policy assignment + remediation (documented process)

Assigning the built-in policy and running remediation (see [implementation-legacyvmnva.md](./implementation-legacyvmnva.md)):

```
# az policy assignment create ... --policy e87a87f5-...
{ "enforcement": "Default", "identity": "SystemAssigned", "name": "LegacyVMNVA-optout" }

# az policy remediation create ...
{ "deploymentStatus": { "failedDeployments": 0, "successfulDeployments": 0, "totalDeployments": 0 },
  "name": "LegacyVMNVA-remediate", "state": "Succeeded" }
```

**Verdict:** remediation **Succeeded with 0 deployments** — confirming the built-in policy only tags **Marketplace NVA** publisher/product images. Plain Ubuntu/Windows VMs match nothing, so nothing is tagged (expected). For non-Marketplace/BYO images, use the manual tag + reapply path below.

**Manual tag + reapply (BYO / test images):**

```
# az vm update ... --set tags.LegacyVMNVA=true   ->  { "LegacyVMNVA": "True" }
# az vm reapply ...                              ->  exit 0
# az vm show ... --query tags.LegacyVMNVA        ->  True
```

---

## Failure / troubleshooting outputs

**Resource Graph extension missing (CLI):**

```
az: 'graph' is not in the 'az' command group.
```

Fix: `az extension add -n resource-graph`.

**Invalid ARG query (e.g., unsupported operator):**

```
{ "code": "BadRequest", "details": [ { "code": "InvalidQuery" },
  { "code": "ParserFailure", "additionalProperties": { "token": "mv-apply" } } ] }
```

Fix: ARG doesn't support every KQL operator (e.g., `mv-apply`); use `mv-expand` + `summarize` (already applied in `inventory-nva-vmss.kql`).

**`run-command` busy on a VM:**

```
(Conflict) Run command extension execution is in progress. Please wait for completion before invoking a run command.
```

Fix: only one `run-command` runs per VM at a time — retry after the previous one finishes.
