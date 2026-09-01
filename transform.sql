-- =============================================================
-- Asset Volatility & Correlation Dashboard - SQL Transform Layer
-- =============================================================
-- This script builds the "clean" layer on top of the raw price
-- data loaded into Snowflake from extract.py.
--
-- Business question this supports:
-- Which assets in a mixed stock/crypto portfolio carry the most
-- risk, and does that risk move together or independently across
-- asset classes?
--
-- Pipeline stage: raw.prices --> clean.daily_returns --> clean.volatility
-- (rolling correlation is the next table to add here)
-- =============================================================


-- Schema to hold transformed ("clean") tables, kept separate from
-- raw.prices so raw source data and derived logic are never mixed.
CREATE SCHEMA IF NOT EXISTS stocks_crypto_db.clean;


-- -------------------------------------------------------------
-- 1. Daily returns
-- -------------------------------------------------------------
-- Converts raw closing prices into % change day-to-day, per ticker.
-- Returns are what make a $200 stock and a $60,000 Bitcoin
-- comparable - raw price moves aren't, % moves are.
--
-- LAG() looks back one row within the same ticker (PARTITION BY
-- ticker) ordered by date, so each row can see "yesterday's" close
-- without a self-join. The first day for each ticker has no prior
-- day, so prev_close and daily_return are NULL there by design.
-- -------------------------------------------------------------

CREATE OR REPLACE TABLE stocks_crypto_db.clean.daily_returns AS
SELECT
    date,
    ticker,
    asset_class,
    close,
    LAG(close) OVER (PARTITION BY ticker ORDER BY date) AS prev_close,
    (close - LAG(close) OVER (PARTITION BY ticker ORDER BY date))
        / LAG(close) OVER (PARTITION BY ticker ORDER BY date) AS daily_return
FROM stocks_crypto_db.raw.prices
ORDER BY ticker, date;


-- -------------------------------------------------------------
-- 2. Rolling 30-day volatility
-- -------------------------------------------------------------
-- Volatility = how much daily returns bounce around over a
-- trailing window. Higher STDDEV = more erratic/risky, lower =
-- steadier. "Rolling" means it's recalculated for every date using
-- that date's trailing 30 trading days, not one fixed number for
-- the whole series - this is what lets the dashboard show risk
-- changing over time (e.g. spiking during the COVID crash).
--
-- ROWS BETWEEN 29 PRECEDING AND CURRENT ROW = "this row plus the
-- 29 before it" = a 30-row window. For each ticker's first ~29
-- rows there isn't a full 30 days of history yet, so STDDEV is
-- calculated over however many days are available - expected
-- behaviour, not a bug.
--
-- Validated: AAPL's rolling_volatility_30d roughly tripled from
-- ~0.017 (mid-Feb 2020) to ~0.058 (early Apr 2020), correctly
-- tracking the COVID crash.
-- -------------------------------------------------------------

CREATE OR REPLACE TABLE stocks_crypto_db.clean.volatility AS
SELECT
    date,
    ticker,
    asset_class,
    daily_return,
    STDDEV(daily_return) OVER (
        PARTITION BY ticker
        ORDER BY date
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS rolling_volatility_30d
FROM stocks_crypto_db.clean.daily_returns
ORDER BY ticker, date;


-- -------------------------------------------------------------
-- Sanity checks (run manually, not part of the pipeline)
-- -------------------------------------------------------------
-- SELECT COUNT(*) FROM stocks_crypto_db.clean.daily_returns;  -- expect 13240
-- SELECT COUNT(*) FROM stocks_crypto_db.clean.volatility;     -- expect 13240


-- -------------------------------------------------------------
-- Next up: rolling correlation between stocks vs crypto
-- -------------------------------------------------------------
