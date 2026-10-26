# Audit loading and settled-account review

Validated against a disposable snapshot of 27,883 consumers and 95,102 bill rows.
The live consumer and bill tables still match that snapshot exactly, row for row.
No Windows executable or installer was built.

## Loading

The original regular audit took 36.541 seconds, including approximately 1.533
seconds reading SQLite and 35 seconds blocking the main event loop during
reconciliation. The full dataset was parsed again whenever History closed.

The final regular audit took 4.877 seconds; All generated bills took 4.580
seconds. These are Flutter debug-test measurements on the same machine and
database snapshot, not release-build timings. Maximum measured event-loop gaps
fell from 35.019 seconds to 0.187 seconds for the regular audit.

- Reuse parsed money values in a bounded cache and period dates within one audit.
- Reject unrelated carried-fine candidates before parsing their charges.
- Run full reconciliation and source-flag preparation in a background isolate,
  outside the database transaction. Fetch only needed import-state columns.
- Reuse filtered/sorted rows when paging or exporting without filter changes.
- Refresh only the viewed connection after History closes; a History import,
  explicit refresh, bill-group change, or hot reload still refreshes the full audit.
  Filters, sorting, page, and scroll position remain preserved on History return.

Every exported field except the intentionally corrected result/review text was
compared with the original output for all 27,853 regular and 27,887 all-type
connection entries. Fees, receipts, advances, fines, balances, excluded bill
numbers, bill counts, and consumer details are unchanged.

## The supplied 478-connection PDF

The PDF was filtered to Domestic, Regular Connection, Review allocation. All
478 rows show zero water balance. The allocation warnings came from earlier
short receipts against printed totals containing arrears, even after later
payments covered all generated water fees.

For example, connection 10010121 has Rs. 16,800 generated, Rs. 16,800 water
received, and Rs. 320 collected fines. An old bill printed Rs. 2,640 with
Rs. 2,400 received. That old short-receipt warning should not require allocation
review after water recovery reconciles.

The shared rule now clears historical water-only short/arrears warnings when
all valid generated water fees are covered after advance and fine separation.
It preserves warnings for invalid money, duplicate identities, missing or invalid
periods, inconsistent charge arithmetic, and short payments involving other
charges. Source rows and the historical short-receipt count remain intact.

Of the PDF's 478 records, 474 now show **No water balance**. Four show **Needs
review** because their source bills lack billing periods (and receipt dates):

| Connection | Bill needing source-period confirmation |
|---|---|
| 16020128 | 6983266 |
| 31010264 | 6905090 |
| 33010170 | 7061220 |
| 37010371 | 7117311 |

Across the entire dataset, 535 settled accounts change from Review allocation
to No water balance, and those four retain source-quality review. One account
with inconsistent arrears arithmetic still retains Review allocation. No fines
are added to the water balance and no source values were invented.
