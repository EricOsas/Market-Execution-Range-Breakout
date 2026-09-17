# ORB Market Exec — NinjaTrader 8

`ORBMarketExecNT8.cs` is the NinjaTrader 8 port of the Market Exec ORB strategy.

## Default behavior

- Range clock: **New York wall clock (DST-aware)**
- Range start: **21:00**
- Range length: **15 minutes** (`21:00-21:15`)
- Confirmation candle: **15 minutes**
- Trigger: market order only after a completed confirmation candle closes beyond the range high/low
- Long side and short side are independent and each may be consumed once per daily range
- Untriggered side expiry: **09:00** on the following clock day
- Stop: opposite opening-range extreme, plus optional stop buffer
- Target: configurable through **1:5**
- Time exit: configurable
- Drawings: blue / grey

## Clock modes

### `NewYorkWallClock`

Use this when the number entered should always mean the displayed New York clock time.

Example: `21:00` always means **9:00 PM New York**. The UTC/platform mapping automatically changes when New York changes between EST and EDT.

### `FixedEST`

Use this when the number entered is a permanently non-shifting UTC-5 reference.

Example: `21:00` always means **21:00 UTC-5**, even while New York is observing daylight saving time.

This makes the user-facing setting explicit instead of hiding whether DST has already been applied.

## Side expiry

`Side Expiry Hour` / `Side Expiry Minute` define when an untriggered side is no longer eligible.

With the defaults:

- Range: 21:00-21:15
- Confirmation starts after the range closes
- If the high side has not qualified before the 09:00 cutoff, no later long may be taken from that range
- Same independently for the low/short side
- Both sides reset when the next daily range starts

## Blackout flatten

`Blackout Flatten Enabled` is intentionally stronger than the normal strategy time exit.

In realtime it calls the NinjaTrader account flatten API for all instruments that currently have an open account position or an active order. This is account-level behavior, not only this strategy's position.

In Strategy Analyzer, there is no live account to flatten, so the historical fallback can only exit the strategy position.

## News filter

NinjaTrader does not expose the same MQL5 Economic Calendar calls used by the MT5 version. The NT8 port therefore uses a deterministic CSV event feed so the same events can be reproduced in Strategy Analyzer and live execution.

Default relative path:

`Documents\NinjaTrader 8\orb_news.csv`

CSV format:

```text
UTC_ISO,impact,currencies,title
2026-09-17T12:30:00Z,3,USD,US CPI
2026-09-17T18:00:00Z,3,USD,FOMC Rate Decision
2026-09-18T08:00:00Z,2,EUR,ECB Speaker
```

Impact values:

- `1` = low
- `2` = medium
- `3` = high

Multiple currencies can be separated with `|`, `;`, or spaces. Use `ALL` to block every instrument.

The strategy reloads the file when its modified timestamp changes.

## Installation

1. Open NinjaTrader 8.
2. Open **New > NinjaScript Editor**.
3. Create or import a Strategy named `ORBMarketExecNT8`.
4. Replace its source with `ORBMarketExecNT8.cs`.
5. Compile.
6. If the News filter is enabled, copy your event file to `Documents\NinjaTrader 8\orb_news.csv` or set an absolute `News CSV Path`.

## Port notes

- The trend/SMA20 filter and RMS range-size filter were intentionally removed.
- The strategy internally uses a 1-minute secondary series to construct the opening range and confirmation windows independently of the chart timeframe.
- Historical risk sizing uses `Starting Account Value`; realtime sizing uses connected-account cash value when available.
- Commission and assumed round-trip slippage are included in risk-based contract sizing.
- The source in this repository still needs to be compiled inside NinjaTrader 8 because this repository environment does not contain NinjaTrader assemblies.
