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
-- 3. Rolling 30-day correlation (stocks vs crypto)
-- -------------------------------------------------------------
-- Answers the second half of the business question: does crypto
-- move independently from stocks, or has it started moving
-- together with them?
--
-- paired_returns collapses all stock tickers into one average
-- daily return, and all crypto tickers into another, so the two
-- asset classes become directly comparable series. Rows where
-- either side is NULL (weekends, when crypto trades but stocks
-- don't) are filtered out - correlation needs a real value on
-- both sides. See DECISIONS.md for the tradeoff this involves.
--
-- CORR() doesn't support a sliding ROWS BETWEEN frame the way
-- STDDEV() does, so this uses a self-join instead: each date is
-- joined to itself across the prior 30 rows (by row number, so
-- holiday gaps don't distort the window), then CORR() runs as a
-- normal aggregate over that joined set. See DECISIONS.md for
-- why this workaround was needed.
--
-- Validated: correlation was already ~0.80 going into the
-- Terra/Luna crypto collapse (May 2022), peaked ~0.86-0.87
-- mid-crash, then declined to ~0.62-0.66 by mid-June - crypto had
-- already lost much of its "independent asset" behaviour relative
-- to stocks before this crash, which briefly intensified the
-- correlation before it faded again.
--
-- WHERE a.row_num >= 30 excludes the first ~29 dates, which don't
-- have a full 30-day window yet and produced an unstable, non-
-- meaningful spike to 1.0 right at the start of the series when
-- first plotted. See DECISIONS.md.
-- -------------------------------------------------------------

CREATE OR REPLACE TABLE stocks_crypto_db.clean.correlation AS
WITH paired_returns AS (
    SELECT
        date,
        AVG(CASE WHEN asset_class = 'stock' THEN daily_return END) AS avg_stock_return,
        AVG(CASE WHEN asset_class = 'crypto' THEN daily_return END) AS avg_crypto_return
    FROM stocks_crypto_db.clean.daily_returns
    GROUP BY date
    HAVING avg_stock_return IS NOT NULL AND avg_crypto_return IS NOT NULL
),
dated AS (
    SELECT
        date,
        avg_stock_return,
        avg_crypto_return,
        ROW_NUMBER() OVER (ORDER BY date) AS row_num
    FROM paired_returns
)
SELECT
    a.date,
    a.avg_stock_return,
    a.avg_crypto_return,
    CORR(b.avg_stock_return, b.avg_crypto_return) AS rolling_correlation_30d
FROM dated a
JOIN dated b
    ON b.row_num BETWEEN a.row_num - 29 AND a.row_num
WHERE a.row_num >= 30
GROUP BY a.date, a.avg_stock_return, a.avg_crypto_return
ORDER BY a.date;


-- -------------------------------------------------------------
-- 4. Portfolio growth ($1000 invested)
-- -------------------------------------------------------------
-- Answers "what would $1000 have actually turned into" - an
-- intuitive companion to the volatility/correlation metrics.
--
-- Daily returns compound rather than add, so this can't just sum
-- daily_return values. Uses the log-sum-exp trick: the sum of logs
-- of daily growth factors equals the log of their product, so
-- summing LN(1 + daily_return) cumulatively and converting back
-- with EXP() gives a genuine compounded running total.
--
-- ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW = "everything
-- from the start of this ticker's history up to today" - an
-- unbounded window, unlike the fixed 30-day windows used above.
-- COALESCE(daily_return, 0) handles each ticker's first day (NULL
-- daily_return) by treating it as "no change yet" so LN() doesn't
-- break on a NULL input.
--
-- Validated: $1000 in AAPL grew to ~$4,384 by 2026-08-31 (~4.4x);
-- $1000 in BTC-USD grew to ~$10,909 (~10.9x) over the same period -
-- both believable, and usefully different multiples for the chart.
-- -------------------------------------------------------------

CREATE OR REPLACE TABLE stocks_crypto_db.clean.portfolio_growth AS
SELECT
    date,
    ticker,
    asset_class,
    daily_return,
    1000 * EXP(SUM(LN(1 + COALESCE(daily_return, 0))) OVER (
        PARTITION BY ticker
        ORDER BY date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )) AS portfolio_value
FROM stocks_crypto_db.clean.daily_returns
ORDER BY ticker, date;


-- -------------------------------------------------------------
-- Sanity checks (run manually, not part of the pipeline)
-- -------------------------------------------------------------
-- SELECT COUNT(*) FROM stocks_crypto_db.clean.daily_returns;    -- expect 13240
-- SELECT COUNT(*) FROM stocks_crypto_db.clean.volatility;       -- expect 13240
-- SELECT COUNT(*) FROM stocks_crypto_db.clean.correlation;      -- expect ~1644
-- SELECT COUNT(*) FROM stocks_crypto_db.clean.portfolio_growth; -- expect 13240


-- -------------------------------------------------------------
-- Dashboard: Power BI, connected to the clean schema (Import mode)
-- -------------------------------------------------------------
