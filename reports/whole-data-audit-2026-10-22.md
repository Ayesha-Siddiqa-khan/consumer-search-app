# Whole-data water-fee audit validation — 22 October 2026

Validated a read-only snapshot of all **27,883 consumer records** and **95,102 bill-history records**. The complete-account calculation includes 27,887 connection keys because four histories have no consumer-master record; these remain identified. The regular/other-bill view contains 27,853 connection keys.

Every consumer and bill-history row was compared with the live source after verification: all source values are unchanged. No database replacement, financial-record edits, or Windows build was performed.

## Rules applied to the entire dataset

- Audit water balance is generated water fees minus water recovered. Fines remain separate; an unknown fine date cannot hide water recovery or the water balance.
- Advance applications repeated in Amount Received are excluded from new cash receipts. The original advance is counted once. Partial-credit cash payments and separately collected fines remain distinguishable.
- Water recovery is limited to generated demand. Additional receipts are visible separately as unapplied receipts / advance credit. An unidentified excess is not automatically labelled as a collected fine.
- Following the confirmed newer-entry-wins policy, older overlapping bill entries are excluded from audit demand and receipt totals. Their original rows are preserved, and their bill numbers are included in exports/history notes. The existing one-payment first-period exception for Ali Town/Muslim Town remains in force.
- The connection number identifies the account. Name differences do not change financial totals. Rejected old-number daily receipts do not block authoritative merged-history calculations.
- Confirmed summary subtotals show how many unresolved accounts were excluded instead of blanking every total.

## Coverage and results

- Connections with repeated advance applications separated: **616**.
- Older overlapping bill entries excluded from complete-account totals: **692**.
- Connections with unapplied receipts / credit remaining: **850**.

| Regular/other-bill result | Before | After |
|---|---:|---:|
| Water balance due | 9,383 | 10,015 |
| No water balance | 1,014 | 1,736 |
| Needs review | 1,068 | 334 |
| Review allocation | 272 | 540 |
| Receipts exceed water fee | 888 | 0 |
| No generated bills | 15,228 | 15,228 |

The former excess-water result is replaced by a separate **Unapplied receipts / advance** filter. Excess money is retained outside water recovery; it has not been deleted.

## Examples from the reported screens

Amounts are rupees. Fees and receipts exclude older bill entries replaced by newer period bills.

| Connection | Generated water fee | Water recovered | Repeated credit application excluded | Water balance | Result |
|---|---:|---:|---:|---:|---|
| 31010015 | 16,800.00 | 16,800.00 | 2,400.00 | 0.00 | No water balance |
| 31010125 | 16,800.00 | 16,800.00 | 2,400.00 | 0.00 | No water balance |
| 31010109 | 16,800.00 | 16,800.00 | 0.00 | 0.00 | No water balance |
| 31010048 | 16,800.00 | 0.00 | 0.00 | 16,800.00 | Water balance due |
| 31010084 | 16,800.00 | 14,403.00 | 0.00 | 2,397.00 | Water balance due |
| 31010181 | 16,800.00 | 14,400.00 | 2,400.00 | 2,400.00 | Water balance due |
| 31010056 | 14,800.00 | 14,400.00 | 2,400.00 | 400.00 | Water balance due |
| 31010026 | 16,800.00 | 14,400.00 | 2,400.00 | 2,400.00 | Water balance due |

Applying a previously recorded advance is not fresh collection. Removing that repetition can reveal a real difference between generated fees and actual cash recovery, even if the latest individual bill is Paid. History retains its separate latest-bill remaining balance.

## Remaining source issues

In the complete-account view, **335** connections have the result Needs review, and **542** have Review allocation. These were not forced to zero or silently rewritten. Remaining reasons include competing first-period bills under the confirmed one-payment exception, missing receipt dates/billing periods, conflicting or short receipts, and histories without a consumer-master record. A Review allocation result may have zero water balance while a mixed receipt still needs classification.

Use the app’s Review Reasons export column to inspect the exact reason on each account. CSV and optional PDF columns now also include cash receipts, recorded receipts, advance applications, unapplied receipts, and excluded older bill numbers.

## Verification

- Complete-dataset runs for both regular/other bills and all bill types.
- For every calculated account: cash receipts = water recovery + identified non-water receipts + unapplied receipts.
- Audit water balance = generated water fees minus recovered water fees.
- Source row values unchanged across the whole consumer and bill-history tables.
- Focused financial, import, export, filtering, layout, and history-return tests; static analysis.
