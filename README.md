# Asset Volatility & Correlation Dashboard

Tracking how risky and how related a basket of stocks and crypto
assets are over time.

## Business question

Which assets in a mixed stock/crypto portfolio carry the most risk,
and does that risk move together or independently across asset
classes?

This is a real starting point for portfolio risk management, not
just a reason to make charts - the goal is to actually answer it,
not just visualise price data.

## Data

- **Source:** [yfinance](https://pypi.org/project/yfinance/) (no API
  key required)
- **Assets:** AAPL, NVDA, TSLA (tech), XOM (energy), JPM (banking),
  BTC-USD, ETH-USD (crypto)
- **Range:** January 2020 - present, deliberately covering two
  distinct market shocks (the COVID crash and the 2022 crypto crash)
  rather than just one - see `DECISIONS.md`

## Pipeline architecture

```
Python (extract) -> Snowflake (load + transform, SQL) -> Power BI (visualise)
```

1. **Extract** (`extract.py`) - pulls daily OHLC price data via
   `yfinance`, tags each row with its asset class, drops rows with
   missing close prices, saves to `data/raw_prices.csv`.
2. **Load** - raw prices land untouched in
   `stocks_crypto_db.raw.prices`.
3. **Transform** (`transform.sql`) - all analysis logic lives here,
   built with SQL window functions:
   - `clean.daily_returns` - % change per asset per day
     (`LAG()`)
   - `clean.volatility` - rolling 30-day standard deviation of
     returns per asset (`STDDEV() OVER (... ROWS BETWEEN 29
     PRECEDING AND CURRENT ROW)`)
   - `clean.correlation` - rolling 30-day correlation between
     average stock returns and average crypto returns (self-join
     workaround, since Snowflake's `CORR()` doesn't support a
     sliding window - see `DECISIONS.md`)
4. **Visualise** - Power BI, connected directly to the `clean`
   schema. *(in progress)*

## Findings so far

- **AAPL's rolling 30-day volatility roughly tripled** during the
  COVID crash, climbing from ~0.017 (mid-February 2020) to ~0.058
  (early April 2020) - the metric correctly detects a real market
  panic, not just noise.
- **Stock/crypto correlation was already high (~0.80) going into
  the Terra/Luna collapse** (May 2022), peaked around 0.86-0.87
  mid-crash, then declined to ~0.62-0.66 by mid-June. Reading: by
  2022, crypto had already lost much of its "independent asset"
  behaviour relative to tech stocks well before this particular
  crash - the crash briefly intensified the correlation before it
  faded again.

## Why these decisions were made

Full reasoning behind the date range, schema design, weekend-NULL
handling, and the `CORR()` workaround is in
[`DECISIONS.md`](./DECISIONS.md).

## Status

- [x] Extract pipeline
- [x] Snowflake raw + clean layers
- [x] Daily returns
- [x] Rolling volatility
- [x] Rolling correlation
- [ ] Power BI dashboard

## Tools

Python, `yfinance`, Pandas, Snowflake (SQL, window functions),
Power BI
