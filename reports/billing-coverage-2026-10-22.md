# Missing billing periods and amounts

Audit now has **Result → Missing amounts**. Existing category, sector, status and
search filters still apply. The view starts sorted by missing amount, descending.
It shows expected water fees, actual recorded fees, missing issue count and
estimated missing amount in cards and per consumer in the table. Each row lists
the missing periods and individual amounts, or the bill number and fee shortfall
when the bill is present. The History button opens the original source records.
CSV includes coverage fields; PDF opens with the missing-detail columns selected.

Missing amounts include estimated fees for uncovered periods plus identified fee
shortfalls. They do not change recorded demand, receipts, fines or water balance.
Unconfirmed rates are excluded from amount totals. Provisional records, including
undated bills and absent history, are identified rather than treated as proven
unissued bills.

## Confirmed calendar

The user selected July 2023 as the baseline for every connection, including later
connection dates. All sessions are six-monthly except July–December 2025, issued
as July, August and September monthly bills plus one October–December bill.
At the usual domestic rate this is 400 + 400 + 400 + 1,200 = Rs. 2,400.
Combined annual and six-month bills cover their constituent months once.
Expired rows establish that a period was generated; arrears and fines do not
create extra periods. The existing newer-overlap selection remains in effect.

Amounts use a consistent recorded monthly water rate. Where no rate is recorded,
standard domestic/private estimates are labelled accordingly. Varying rates and
undated or invalid periods require source confirmation. No source record is
inserted, changed, or assigned to another connection by the coverage check.

## Example: 36011016, MUDASSAR ARSHAD

| Field | Amount / count |
|---|---:|
| Expected water fee through December 2026 | Rs. 16,800 |
| Recorded generated water fee | Rs. 13,200 |
| Missing issues | 2 |
| January–June 2025 missing fee | Rs. 2,400 |
| October–December 2025 missing fee | Rs. 1,200 |
| Total estimated missing amount | Rs. 3,600 |

## Full-source check

The scan used a disposable copy of 27,883 master consumers and 95,102 bill rows,
producing 27,887 account keys including four history-only keys:

- 7,916 accounts with stored history have uncovered periods.
- 15,228 accounts have no stored history; issuance cannot be established.
- 902 gap accounts have undated bills that might cover some candidate periods.
- 481 accounts have present bills with short water fees.
- 552 gap accounts need rate confirmation; their missing amounts are not summed.
- 139 accounts contain varying observed rates.

These groups can overlap and must not be added together. Coverage gaps are not
proof that a bill was never issued or paid. The red History note and Audit detail
preserve this distinction.

Standalone full-data audit loading was about 5.2 seconds in Flutter debug tests
(6.1 seconds while the full suite ran concurrently). The History warning and a
sample PDF were rendered and inspected. The full suite passed 137 tests, with
five opt-in tests skipped; static analysis found no issues. No Windows build or
installer was created.
