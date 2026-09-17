# ORB Market Exec — NinjaTrader 8

`ORBMarketExecNT8.cs` is the NinjaTrader 8 port of the Market Exec ORB strategy.

## Default behavior

- Range clock: **New York wall clock (DST-aware)**
- Range start: **21:00**
- Range length: **15 minutes** (`21:00-21:15`)
- Confirmation candle: **15 minutes**
- Trigger: market order only after a completed confirmation candle closes beyond the range high/low
- Long and short sides are independent and may each trigger once per daily range
- Untriggered side expiry: **09:00** on the following clock day
- A confirmation candle closing at **09:00 or later cannot trigger**
- Stop: opposite opening-range extreme, plus optional stop buffer
- Target: configurable through **1:5**
- Time exit: configurable
- Drawings: blue / grey

## Clock modes

### `NewYorkWallClock`

`21:00` always means **9:00 PM New York**. The platform/UTC mapping automatically follows New York DST.

### `FixedEST`

`21:00` always means **21:00 UTC-5** and never shifts for daylight saving time.

The setting therefore tells you exactly whether the configured time is a shifting New York wall clock or a fixed non-shifting EST reference.

## Side expiry

`Side Expiry Hour` / `Side Expiry Minute` define when an untriggered side dies.

With the defaults:

- Range: 21:00-21:15
- Confirmation starts after 21:15
- If the high side has not triggered before 09:00, no later long may be taken from that range
- Same independently for the low/short side
- Both sides reset at the next daily ORB

## Blackout flatten

`Blackout Flatten Enabled` is stronger than the normal strategy time exit.

In realtime the strategy gathers every non-flat position on the connected account and calls NinjaTrader's account `Flatten()` API for those instruments. In Strategy Analyzer there is no live account, so the historical fallback only exits the strategy position.

## Forex Factory news filter

The NT8 strategy is self-sufficient. There is **no news CSV, URL setting, API key, or manual event entry**.

Provider:

`https://nfs.faireconomy.media/ff_calendar_thisweek.json`

This is the Forex Factory weekly JSON export hosted through FairEconomy.

Behavior:

- Default news mode: **High impact**
- Default block window: **30 minutes before / 15 minutes after**
- Optional High+Medium or all economic events
- Optional whole-day bank-holiday blocking
- MNQ, MES, MGC, MCL and other USD-sensitive futures automatically watch USD events
- FX futures automatically watch both the contract currency and USD, e.g. 6E/M6E watches EUR + USD
- Fetch occurs automatically when the strategy reaches realtime
- Successful data is refreshed no more frequently than every **65 minutes**
- Failed downloads retry after **10 minutes** while retaining the last good cache
- HTML/rate-limit responses are rejected rather than parsed as calendar data
- If realtime trading has no valid Forex Factory data for the current week, the news guard **fails closed** and blocks new entries rather than trading blind

### Local cache

Every successful weekly response is stored automatically under:

`Documents\NinjaTrader 8\cache\MarketExecORB\ForexFactory\`

The strategy reloads cached weeks at startup. This means weeks accumulated during live use can later be reused by Strategy Analyzer without manual files.

### Historical limitation

Forex Factory's public export is fundamentally a current-week feed. It does not provide this strategy with an official arbitrary-history JSON endpoint.

Therefore:

- Live/current-week filtering is automatic.
- Historical Strategy Analyzer runs can use any weeks already present in the strategy's automatic cache.
- Old backtest weeks that were never cached cannot be truthfully reconstructed from the current-week feed, so the strategy does not pretend current news data represents those old dates.

## Installation

1. Open NinjaTrader 8.
2. Open **New > NinjaScript Editor**.
3. Create or import a Strategy named `ORBMarketExecNT8`.
4. Replace its source with `ORBMarketExecNT8.cs`.
5. Compile.
6. No separate news file or provider configuration is required.

## Port notes

- The SMA20 / `CHECK THE TREND` filter is removed.
- The RMS `Skip day if opening range > N x` filter is removed.
- The strategy internally uses a 1-minute secondary series to construct the range and arbitrary confirmation windows independently of the chart timeframe.
- Market entries are submitted on that 1-minute execution series immediately after the confirmation window closes.
- Historical risk sizing uses `Starting Account Value`; realtime sizing uses connected-account cash value when available.
- Commission and assumed round-trip slippage are included in risk-based contract sizing.
- This repository environment does not contain NinjaTrader assemblies, so the source still needs a real NinjaTrader 8 compile before live use.
