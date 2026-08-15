# OpenVision telemetry

Optional, **off by default**, and entirely self-hosted: metrics go to an InfluxDB you run, and
Grafana draws them. Nothing is sent anywhere unless you switch it on and give it an endpoint.

## What gets sent

Numbers only — **never transcripts, replies, prompts, or tool arguments.**

| Measurement | Fields | Why it matters |
|---|---|---|
| `turn` | `perceived_latency_s`, `commit_s`, `ttft_s`, `generation_s`, `tts_lead_in_s`, `total_s`, `tokens`, `tokens_per_second`, `abandoned` | Where a voice turn actually spends its time |
| `device` | `memory_footprint_mb`, `memory_available_mb`, `cpu_percent`, `thermal_level`, `battery_level`, `low_power_mode` | Jetsam headroom and thermal throttling |

Tags: `device`, and on turns `backend` + `model`, so you can compare models side by side.

**`perceived_latency_s` is the headline** — silence from when you stop speaking to when the reply
starts. The stage fields say which part to blame: endpointing (`commit_s`), the model (`ttft_s`,
`generation_s`), or speech synthesis (`tts_lead_in_s`).

## What iOS cannot report

Don't go looking for these — there are no public APIs:

- **Temperature in degrees.** Only `thermal_level`: 0 nominal, 1 fair, 2 serious, 3 critical.
- **Per-core CPU frequency / per-cluster load.** `cpu_percent` is this app's threads summed across
  cores, so >100% is normal and expected during inference.
- **GPU utilisation.** Infer MLX load from `tokens_per_second` instead.

(Android dashboards showing "skin 25.3°C, prime 0.56 GHz" read sysfs, which iOS has no equivalent of.)

## Run it

```bash
cd telemetry
docker compose up -d
```

- Grafana: <http://localhost:3000> (anonymous admin; the InfluxDB datasource is pre-wired)
- InfluxDB: <http://localhost:8086> — `openvision` / `openvision123`

## Point the app at it

The phone needs your Mac's **LAN address**, not `localhost` — on the phone that would mean the
phone.

```bash
ipconfig getifaddr en0     # e.g. 192.168.1.20
```

In OpenVision: **Settings → Telemetry**

| Field | Value |
|---|---|
| URL | `http://192.168.1.20:8086` |
| Bucket | `metrics` |
| Org | `openvision` |
| Token | `openvision-dev-token` |

Then enable it. Metrics batch every 10 s (or every 50 points), so allow a few seconds before the
first ones appear.

> iOS App Transport Security blocks plaintext `http://` to bare private IPs. If pushes fail with a
> transport error, use the Mac's `.local` name (`http://my-mac.local:8086`) instead — allowed
> without an ATS exception — or put the stack behind TLS.

## Useful queries

Perceived latency over time, split by model:

```flux
from(bucket: "metrics")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "turn" and r._field == "perceived_latency_s")
  |> group(columns: ["model"])
```

Where the time goes (stage breakdown):

```flux
from(bucket: "metrics")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "turn")
  |> filter(fn: (r) => r._field =~ /commit_s|ttft_s|generation_s|tts_lead_in_s/)
```

Jetsam headroom — watch this while running a local model next to a vision model:

```flux
from(bucket: "metrics")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "device" and r._field == "memory_available_mb")
```

## Credentials

The values here are throwaway defaults for a LAN dev stack — plain HTTP, no TLS, weak passwords.
Change them for anything beyond your own network, and never expose these ports to the internet.
