# Safe data import plan

1. **Consumer master first.** Read column headers, not file names. Validate the entire CSV before a single transaction updates or inserts consumers by exact connection number. Preserve leading zeroes, suffixes and all existing billing fields. Conflicting duplicate connection records stop the import.
2. **Full history second.** Read the selected folder, including nested CSVs. Match only exact connection number plus bill number. Collapse repeated copies across sector and combined files. Use October 21 snapshots over September 25 where both contain the same bill; keep older-only bills. Equal-date conflicts are held for review rather than guessed. Missing fields never erase known values.
3. **Daily bills afterwards.** Select any appropriately structured CSV and its snapshot date. Update the existing bill, or add a genuinely new bill identity. Preserve billing periods and receipt dates absent from the daily file. Record Paid and Amount Received even when the source has no receipt date, and flag the missing date. Never invent a payment date or silently change a Paid bill back to unpaid.
4. **Reconciliation and accountability.** Use one transaction for each selected bill upload group, including current consumer bill summaries. Keep source date/file and review reasons beside each bill, and provide inserted/updated/unchanged/held counts plus a downloadable review report. Do not change source files. A newer import must not be overwritten by an older snapshot.
5. **Test before live use.** Use the supplied files on a separate empty database; reconcile master and bill identity counts, inspect changed receipts, and repeat imports to prove no new duplicates or erased dates. Validate SQLite integrity. Save a standalone live backup before populating the empty app database.

## Source findings (21 October 2026)

- Consumer master: 27,883 rows and unique connection numbers.
- History folder: 154 CSVs, 337,066 data rows, 99,809 distinct connection/bill pairs. Sector and combined copies repeat data. There are 697 pairs with differing snapshot values.
- Daily file: 9,740 unique bill identities, all matched to the consumer master; 8,797 exact history matches and 943 identities absent from that history.
- Daily data does not include Billing Period or Receive Date. User confirmed: retain existing dates, accept Paid/amount, flag missing dates.
- User confirmed: October 21 takes precedence for matching bills; retain older-only history.
- Several history Due Date fields contain amounts rather than dates. They must not overwrite valid dates.
- Connection 90010045: user previously confirmed the authoritative name is ZULFIQAR ALI / MUHAMMAD UMAR. History names may be corrected to match this register entry without altering money or bill identity.

## Limits requiring review

A different bill number is not automatically a duplicate merely because its amount or period looks similar. Missing receipt dates, conflicting equal-date snapshots, unknown consumers and overlapping bill periods remain visible for review. Import accuracy and final audit liability are separate checks; carried arrears and reissued bills must not be counted twice when computing liability.

## Additional trial findings

- The daily file contains 9,740 bills for 9,537 connections; 184 connections have multiple bills (up to four). Retain all distinct bills and select the highest bill number for the current consumer summary within that snapshot. Older daily snapshots cannot overwrite a newer summary.
- Negative arrears, Total Bill and After Due Date exist in the source. Preserve these signed credits / adjustments exactly and flag them; never turn them into zero or a positive demand. Negative current water fees, fines or receipts are rejected.
- A dated daily source takes precedence over a history snapshot on the same day. Re-imported history cannot undo the current daily values.
- Reports and per-bill source dates / review flags are included in SQLite backups and cleared with Delete All Data.

User clarification: missing connections are acceptable and do not block saving. All available unmatched history remains saved under its original connection number. No connection mapping was guessed.

## Current reconciliation rule (supersedes bill-number-only retention)

The user confirmed that merged CSV connection numbers are authoritative, and selected the newer snapshot for overlapping billing periods. See `output/import/History_Duplication_Repair.md` for the implemented policy, verified active counts, recovery backup, and review files. Different numbers for the same period must not be blindly appended from older snapshots.
