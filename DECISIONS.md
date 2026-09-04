# Project Decisions Log

Why this file exists: the SQL comments explain *what* each query does.
This file explains *why* I made the calls I made — the tradeoffs I
considered and what I chose, so I can actually talk through the
reasoning in an interview rather than just describing finished code.

---

## Date range: Jan 2020 - present (not just the last 2-3 years)

Started with a shorter window in mind, but extended it back to
January 2020 specifically so the dataset would capture two distinct
market stress events - the COVID crash (2020) and the crypto crash
(2022) - rather than just one. Having two very different shocks in
the data makes the volatility story stronger: I can show risk
spiking under different conditions, not just once, which is a more
convincing signal than a single event.

## Raw / clean schema separation in Snowflake

Split the database into a `raw` schema (untouched source data,
exactly as loaded from the CSV) and a `clean` schema (calculated
tables: daily_returns, volatility, correlation). Kept these
physically separate rather than transforming in place so the
original data is always recoverable and auditable - if a transform
turns out to be wrong, I can always see exactly what it started
from and rebuild, rather than the raw data having been overwritten
or lost.

## Filtering out weekend NULLs before calculating correlation

Crypto trades 7 days a week; stocks trade 5. When I grouped returns
by date to compare "average stock return" vs "average crypto
return," weekends showed a real crypto number but a blank stock
number - correlation can't be calculated against a missing value,
so those rows had to be excluded.

Tradeoff I'm accepting here: this means correlation is really
"stocks vs. crypto on weekdays only." I'm not capturing whether a
big weekend move in crypto predicts what stocks do the following
Monday. That's a reasonable scope decision for this project, not an
oversight - and a good answer if asked "what would you improve
next."

## Self-join instead of a window function for rolling correlation

Rolling volatility used a clean window function
(`STDDEV() OVER (... ROWS BETWEEN 29 PRECEDING AND CURRENT ROW)`),
and I expected `CORR()` to work the same way. Snowflake doesn't
support a sliding row frame for `CORR()` - it's a more complex
calculation than STDDEV under the hood, and the engine just doesn't
implement it that way.

Worked around it with a self-join: each date joins back to itself
across the prior 30 rows (using a row number rather than raw dates,
so holiday gaps don't throw off the window), then `CORR()` runs as
a normal aggregate over that joined set. Slower than a window
function, but the only way to get a genuinely rolling correlation
in Snowflake SQL. Worth mentioning in an interview as a real
example of hitting a database limitation and finding a working
alternative, not just writing the "textbook" version of a query.

## Trimming the first 29 rows of correlation (unstable early window)

Noticed the correlation chart in Power BI had a sharp spike straight
up to 1.0 right at the very start of the timeline (Jan 2020). This
wasn't a real signal - the first ~29 rows of the rolling window
don't have a full 30 days of history yet (the same edge case noted
for volatility), so correlation was being calculated on a tiny
number of points early on, which is statistically unstable and can
swing to extreme values that don't mean anything.

Fixed this in SQL rather than filtering it out in Power BI, so the
`clean.correlation` table itself is trustworthy on its own, not just
the dashboard view of it. Added `WHERE row_num >= 30` to the final
query, using the row_num already generated for the self-join
workaround - this keeps only dates where the full 30-day window is
genuinely present. Row count dropped from 1,673 to 1,644 (~29 rows
removed), exactly as expected.

---

 (not decisions, but good to have on hand)

- **AAPL rolling volatility roughly tripled** during the COVID
  crash, from ~0.017 (mid-Feb 2020) to ~0.058 (early Apr 2020) -
  the metric correctly detects a real market panic.
- **Stock/crypto correlation was already high (~0.80) going into
  the Terra/Luna collapse** (May 2022), peaked around 0.86-0.87
  mid-crash, then declined to ~0.62-0.66 by mid-June. Reading: by
  2022, crypto had already lost a lot of its "independent asset"
  behaviour relative to tech stocks well before the widely-known
  crash - the crash briefly intensified the correlation before it
  faded again. More nuanced than a flat "correlation spiked during
  the crash."
