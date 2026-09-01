"""
Extract step: pull daily OHLC price data for a mixed stock/crypto basket.

Why this file exists:
Everything downstream (Snowflake load, SQL transforms, Power BI dashboard)
depends on this data being clean and consistent. So this script's job is
narrow but important: get the raw prices, handle the quirks (missing days,
crypto trading 7 days/week vs stocks 5), and save a tidy CSV we can trust.
"""

import yfinance as yf
import pandas as pd

# Locking in the basket now so every downstream step (SQL, dashboard)
# refers to the same consistent set of tickers.
TICKERS = [
    "AAPL", "NVDA", "TSLA",  # tech
    "XOM",                    # energy
    "JPM",                    # banks
    "BTC-USD", "ETH-USD",     # crypto
]

# Starting Jan 2020 captures two very different stress events -
# the COVID crash and the 2022 crypto crash - which gives the volatility
# story more to compare than a single event would.
START_DATE = "2020-01-01"
END_DATE = "2026-09-01"


def pull_prices(tickers, start, end):
    """Download daily OHLC data for each ticker and stack into one long
    (tidy) DataFrame: one row per ticker per date, rather than one column
    per ticker. This shape is much easier to load into a SQL table."""
    all_rows = []

    for ticker in tickers:
        print(f"Pulling {ticker}...")
        df = yf.download(ticker, start=start, end=end, progress=False)

        if df.empty:
            print(f"  WARNING: no data returned for {ticker}")
            continue

        # yfinance sometimes returns MultiIndex columns when you pass
        # multiple tickers at once (we're not, here, but this guards
        # against that shape showing up).
        if isinstance(df.columns, pd.MultiIndex):
            df.columns = df.columns.get_level_values(0)

        df = df.reset_index()
        df["ticker"] = ticker
        df["asset_class"] = "crypto" if "-USD" in ticker else "stock"

        all_rows.append(df)

    combined = pd.concat(all_rows, ignore_index=True)

    # Standardise column names to snake_case for SQL later.
    combined = combined.rename(columns={
        "Date": "date",
        "Open": "open",
        "High": "high",
        "Low": "low",
        "Close": "close",
        "Adj Close": "adj_close",
        "Volume": "volume",
    })

    return combined


def clean_prices(df):
    """Handle the quirks: crypto trades every day, stocks don't.
    We're NOT forcing them onto the same calendar here — that's a
    decision for the SQL layer (or later) — but we do drop any rows
    with no close price, since a missing close breaks return calcs."""
    before = len(df)
    df = df.dropna(subset=["close"])
    after = len(df)
    if before != after:
        print(f"Dropped {before - after} rows with missing close price")

    df = df.sort_values(["ticker", "date"]).reset_index(drop=True)
    return df


if __name__ == "__main__":
    raw = pull_prices(TICKERS, START_DATE, END_DATE)
    clean = clean_prices(raw)

    print(clean.groupby(["ticker", "asset_class"]).size())
    print(f"\nTotal rows: {len(clean)}")
    print(f"Date range: {clean['date'].min()} to {clean['date'].max()}")

    clean.to_csv("data/raw_prices.csv", index=False)
    print("\nSaved to data/raw_prices.csv")
