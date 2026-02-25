# VibroSense — Decentralized Seismic Activity Monitoring Network

VibroSense is a Clarity smart contract that implements a decentralized, stake-backed network for detecting and correlating ground motion, tremors, and seismic events across geographic regions. Participants register as seismometers by committing STX tokens, then submit amplitude readings that are validated and aggregated into correlated seismic patterns.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Constants & Configuration](#constants--configuration)
- [Data Structures](#data-structures)
- [Functions](#functions)
  - [Read-Only](#read-only-functions)
  - [Public](#public-functions)
  - [Admin](#admin-functions)
- [Error Codes](#error-codes)
- [Getting Started](#getting-started)
- [Security Considerations](#security-considerations)

---

## Overview

VibroSense enables a decentralized group of participants to monitor seismic activity by:

1. **Staking** a minimum commitment of 1 STX to register as a seismometer node.
2. **Submitting** amplitude and sensitivity readings tagged by geographic region.
3. **Correlating** readings across multiple seismometers into aggregated pattern data.
4. **Validating** data quality through surge detection, record age checks, and input bounds.

The contract is governed by a designated `SEISMIC-COORDINATOR` (the deployer) who manages the whitelist of tracked regions and can pause or manage the grid.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  SEISMIC-COORDINATOR                │
│         (Region management, grid control)           │
└────────────────────────┬────────────────────────────┘
                         │
          ┌──────────────▼──────────────┐
          │        Grid (on/off)        │
          └──────────────┬──────────────┘
                         │
     ┌───────────────────┼───────────────────┐
     ▼                   ▼                   ▼
Seismometer A      Seismometer B      Seismometer C
(registered)       (registered)       (registered)
     │                   │                   │
     └──────────── submit-detection ─────────┘
                         │
              ┌──────────▼──────────┐
              │  seismic-detections │  (per region, last reading)
              │  detection-logs     │  (per region+seismometer)
              │  correlated-patterns│  (aggregated stats)
              └─────────────────────┘
```

---

## Constants & Configuration

| Constant | Value | Description |
|---|---|---|
| `MIN-SEISMOMETER-COMMITMENT` | `1,000,000 µSTX` (1 STX) | Minimum stake to register |
| `MAX-RECORD-AGE` | `144 blocks` (~24 hours) | Maximum age before a record is considered stale |
| `MAX-SURGE` | `2000 basis points` (20%) | Maximum allowed amplitude change between readings |
| `MAX-SENSITIVITY` | `18` | Maximum sensitivity parameter value |
| `MAX-AMPLITUDE-VALUE` | `uint max` | Upper bound for amplitude to prevent overflow |

---

## Data Structures

### `seismometers` map
Keyed by `principal`. Tracks each registered node.

| Field | Type | Description |
|---|---|---|
| `is-recording` | `bool` | Whether the node is actively recording |
| `commitment-amount` | `uint` | STX staked by this node |
| `fidelity-score` | `uint` | Quality score (starts at 100) |
| `total-detections` | `uint` | Lifetime detection count |
| `last-detection-height` | `uint` | Block height of last submission |

### `seismic-detections` map
Keyed by `region (string-ascii 32)`. Stores the most recent reading per region.

| Field | Type | Description |
|---|---|---|
| `amplitude` | `uint` | Latest amplitude reading |
| `sensitivity` | `uint` | Sensitivity setting used |
| `last-detected` | `uint` | Block height of detection |
| `detection-frequency` | `uint` | Total number of detections in this region |
| `seismometer` | `principal` | Node that submitted the latest reading |

### `correlated-patterns` map
Keyed by `region`. Stores aggregated statistical data across seismometers.

| Field | Type | Description |
|---|---|---|
| `median-amplitude` | `uint` | Median amplitude across readings |
| `average-amplitude` | `uint` | Average amplitude |
| `min-amplitude` | `uint` | Minimum recorded amplitude |
| `max-amplitude` | `uint` | Maximum recorded amplitude |
| `sensitivity` | `uint` | Sensitivity level |
| `last-correlation` | `uint` | Block height of last correlation |
| `detection-cluster` | `uint` | Cluster identifier |
| `validity-index` | `uint` | Data confidence score |

### `detection-logs` map
Keyed by `{region, seismometer}`. Individual raw readings before correlation.

| Field | Type | Description |
|---|---|---|
| `amplitude` | `uint` | Raw amplitude value |
| `timestamp` | `uint` | Block height at submission |
| `processed` | `bool` | Whether this log has been correlated |

---

## Functions

### Read-Only Functions

#### `get-seismometer-info (seismometer principal)`
Returns the full registry entry for a given seismometer principal, or `none` if not registered.

#### `get-seismic-detection (region string-ascii 32)`
Returns the most recent seismic detection for a region. Returns `none` if the region is invalid or has no data.

#### `get-correlated-patterns (region string-ascii 32)`
Returns the aggregated correlation data for a region.

#### `get-latest-correlation (region string-ascii 32)`
Returns a simplified view of the latest correlation, but errors if the data is older than `MAX-RECORD-AGE` (~24 hours). Returns `ERR-RECORD-AGED` if stale, `ERR-SEISMOMETER-ABSENT` if no data, or `ERR-REGION-UNRECOGNIZED` if the region is invalid.

#### `is-grid-operational`
Returns `true` if the grid is active and accepting registrations/detections.

#### `get-total-seismometers`
Returns the current count of registered seismometers.

#### `is-valid-seismometer (seismometer principal)`
Returns `true` if the given principal is registered, actively recording, and meets the minimum commitment threshold.

#### `calculate-surge (amplitude1 uint) (amplitude2 uint)`
Returns the amplitude surge in basis points between two readings. Used internally to detect anomalous spikes.

---

### Public Functions

#### `register-seismometer`
Registers `tx-sender` as a seismometer node.

- **Requires:** Grid is operational, caller is not already registered, caller has ≥ 1 STX balance.
- **Effect:** Transfers 1 STX commitment to the contract, creates registry entry with `fidelity-score: 100`, increments total seismometer count.

```clarity
(contract-call? .vibro-sense register-seismometer)
```

#### `deregister-seismometer`
Deregisters `tx-sender` and returns their staked STX.

- **Requires:** Grid is operational, caller is registered and currently recording.
- **Effect:** Marks node as not recording, returns committed STX, decrements total count.

```clarity
(contract-call? .vibro-sense deregister-seismometer)
```

#### `submit-detection (region string-ascii 32) (amplitude uint) (sensitivity uint)`
Submits a seismic reading for a given region.

- **Requires:** Grid operational, caller is a recording seismometer, valid region, amplitude > 0 and ≤ max, sensitivity ≤ 18, amplitude surge ≤ 20% vs. previous reading (if one exists).
- **Effect:** Updates `seismic-detections`, appends to `detection-logs`, increments caller's `total-detections`.

```clarity
(contract-call? .vibro-sense submit-detection "us-west-1" u500 u10)
```

---

### Admin Functions

Only callable by the `SEISMIC-COORDINATOR` (contract deployer).

#### `add-tracked-region (region string-ascii 32)`
Adds a region to the whitelist of valid tracking zones.

```clarity
(contract-call? .vibro-sense add-tracked-region "eu-central-2")
```

#### `remove-tracked-region (region string-ascii 32)`
Removes a region from the whitelist.

```clarity
(contract-call? .vibro-sense remove-tracked-region "eu-central-2")
```

---

## Error Codes

| Code | Constant | Description |
|---|---|---|
| `u700` | `ERR-ACCESS-RESTRICTED` | Caller lacks permission (not coordinator, or grid is off) |
| `u701` | `ERR-SEISMOMETER-PRESENT` | Seismometer already registered |
| `u702` | `ERR-SEISMOMETER-ABSENT` | Seismometer not found |
| `u703` | `ERR-AMPLITUDE-INVALID` | Amplitude is zero or exceeds max |
| `u704` | `ERR-RECORD-AGED` | Correlation data is older than 144 blocks |
| `u705` | `ERR-COMMITMENT-LOW` | Insufficient STX to register |
| `u706` | `ERR-SEISMOMETER-PAUSED` | Seismometer is not in recording state |
| `u707` | `ERR-SURGE-ABNORMAL` | Amplitude change exceeds 20% vs. last reading |
| `u708` | `ERR-REGION-UNRECOGNIZED` | Region string is empty or not whitelisted |
| `u709` | `ERR-SENSITIVITY-INVALID` | Sensitivity value exceeds maximum of 18 |

---

## Getting Started

**1. Deploy the contract**

Deploy `vibro-sense.clar` to the Stacks blockchain using Clarinet or the Hiro web wallet. The deploying wallet becomes the `SEISMIC-COORDINATOR`.

**2. Add regions**

As the coordinator, whitelist the regions you want to monitor:

```clarity
(contract-call? .vibro-sense add-tracked-region "na-west")
(contract-call? .vibro-sense add-tracked-region "asia-pacific")
```

**3. Register seismometers**

Any wallet with ≥ 1 STX can register as a seismometer node:

```clarity
(contract-call? .vibro-sense register-seismometer)
```

**4. Submit readings**

Registered nodes submit amplitude readings by region:

```clarity
(contract-call? .vibro-sense submit-detection "na-west" u1200 u8)
```

**5. Query data**

Read the latest detection or correlation for a region:

```clarity
(contract-call? .vibro-sense get-seismic-detection "na-west")
(contract-call? .vibro-sense get-latest-correlation "na-west")
```

---

## Security Considerations

- **Surge limiting** — The 20% amplitude surge cap (`MAX-SURGE`) prevents malicious nodes from injecting wildly anomalous readings that could distort aggregated data.
- **Commitment staking** — Requiring 1 STX to register creates an economic barrier against Sybil attacks (many fake nodes). The stake is returned on deregistration.
- **Record staleness** — `get-latest-correlation` enforces a 24-hour freshness window, preventing stale data from being consumed as current.
- **Input bounds** — All public inputs (amplitude, sensitivity, region) are validated before any state changes occur.
- **Region whitelisting** — Only the `SEISMIC-COORDINATOR` can add or remove valid regions, preventing nodes from submitting to arbitrary or spoofed region codes.
- **No fidelity slashing** — The current implementation initializes `fidelity-score` at 100 but does not implement automated slashing for bad data. This is a potential area for future improvement.