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
VERDICT: ON MANA, driver working. Validate NVA behavior; plan migration to MANA-optimized series.
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

VMs (display projection includes **Sub + RG + Vendor + OS** — the `OS` column tells you whether to run the `.sh` or `.ps1` in the host check):

```
Sub    RG    VM        Vendor                  Size              OS       AN       Tag      Verdict
-----  ----  --------  ----------------------  ----------------  -------  -------  -------  ---------------------------------------------------------
<sub>  <rg>  <vm-a>    Canonical               Standard_D4s_v5   Linux    Enabled  Not set  Candidate - verify on host (detect-mana.sh)
<sub>  <rg>  <vm-v6>   Canonical               Standard_D4ds_v6  Linux    Enabled  Not set  Candidate - verify on host (detect-mana.sh)
<sub>  <rg>  <vm-tag>  Canonical               Standard_D4s_v5   Linux    Enabled  True     Opt-out tag present - confirm reapply, then plan migration
<sub>  <rg>  <vm-win>  MicrosoftWindowsServer  Standard_D4ds_v6  Windows  Enabled  True     Opt-out tag present - confirm reapply, then plan migration
```

VMSS (AKS-aware; illustrative):

```
Sub    RG    VMSS         Mode     Size               OS       AN       Tag      Verdict
-----  ----  -----------  -------  -----------------  -------  -------  -------  ---------------------------------------------
<sub>  <rg>  <aks-pool>   Uniform  Standard_D16ds_v5  Linux    Enabled  Not set  AKS-managed - not impacted by MANA (per docs)
<sub>  <rg>  <nva-vmss>   Uniform  Standard_D2ads_v5  Linux    Enabled  Not set  Candidate - verify on host (detect-mana.sh)
```

**Note:** the KQL always selects `subscriptionId` and `resourceGroup` (and OSType, Offer, Sku, location); the CLI `--query "data[].{...}"` is a client-side projection that decides which columns show. ARG reports control-plane signals (AN, tag, size, OS) only — it does **not** confirm MANA hardware; always finish with the in-guest check (#1–#3b).

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
