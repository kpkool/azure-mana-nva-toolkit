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

VMs:

```
VM         Size              AN        Tag      Verdict
---------  ----------------  --------  -------  ---------------------------------------------------------
<vm-a>     Standard_D4s_v5   Enabled   Not set  Candidate - verify on host (detect-mana.sh)
<vm-v6>    Standard_D4ds_v6  Enabled   Not set  Candidate - verify on host (detect-mana.sh)
<vm-win>   Standard_B4ms     Disabled  Not set  No action - AN disabled
<vm-tag>   Standard_D4s_v5   Enabled   True     Opt-out tag present - confirm reapply, then plan migration
```

VMSS (AKS-aware):

```
VMSS         Size               AN       Tag      Verdict
-----------  -----------------  -------  -------  ---------------------------------------------
<aks-pool>   Standard_D16ds_v5  Enabled  Not set  AKS-managed - not impacted by MANA (per docs)
<nva-vmss>   Standard_D2ads_v5  Enabled  Not set  Candidate - verify on host (detect-mana.sh)
```

**Note:** ARG reports the control-plane signals (AN, tag, size). It does **not** confirm MANA hardware — always finish with the in-guest check (#1–#4).

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
