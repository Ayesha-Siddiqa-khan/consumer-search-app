# Consumer search engine

Windows Flutter application for searching the imported consumer register.
The bundled CSV has 27,870 records, 83 sectors, and 110 localities.

## PDF Bills

Open **PDF Bills** using the PDF icon beside Water Fee Audit and Settings.
**Import Folder + CSV** copies the folder's PDFs into a separate local library
and reads `Localities.csv` (Locality, Sector, PDF Filename). When individual PDFs
are present, folder import skips `All Bills.pdf`; exact duplicate file contents
are skipped too. **Upload PDFs** can import a merged PDF by itself. Each page is
indexed separately, including its locality and sector. Textless scanned pages
remain available for preview/print but need OCR before text search can find them.

Filter by sector, locality, source file, or connection rate/type. Consumer,
connection and bill status filters use the **current consumer register**, joined
by connection number; these statuses are not inferred from an old PDF. The All
statuses options include PDFs without a matching register record. Search supports
multiple partial words in any order and the consumer search's name-spelling
normalization, with dedicated name, father/husband, mobile, address, connection,
old connection, bill and reference number fields.

Click a result to preview its original PDF page. Print/save one bill, selected
pages (including selections across result pages), or every filtered result.
Exports preserve original PDF page content rather than recreating the bill.
**Manage Files** edits locality/sector, replaces one PDF, or deletes a library
copy. Uploading a changed PDF with the same filename updates that file. **Replace
All** replaces the library only after the new files finish indexing; failed or
cancelled imports preserve the existing library. Delete actions ask for
confirmation. Original source uploads, consumers and audit history are preserved.

**Backup** creates a timestamped folder containing the PDFs, SQLite search index
and locality mappings. Keep the complete folder together. **Restore Backup**
validates the database, PDF checksums and page counts before replacing the current
PDF library. This backup is separate from Settings' consumer/history SQLite backup;
use both if you need to back up the whole application.

Verification: `flutter test test/pdf_bill_library_test.dart`. To also check a real
bill folder against its CSV page counts, set `PDF_BILLS_DATASET` to the folder path
and run `flutter test test/pdf_bill_dataset_test.dart`.

## SQLite backups

In Settings → Data Management Actions, **Export SQLite Backup (.db)** saves a
consistent database snapshot. **Import SQLite Backup (.db)** replaces existing
consumers, bill history, report selections and saved voice corrections with the
backup’s records; it does not merge them. A confirmation popup explains the
replacement and offers Cancel before anything is imported. Invalid, damaged or
incompatible backups are rejected, and replacement errors roll back the data.
Old CSV upload timestamps are cleared after a successful restore. The search
index and consumer list refresh automatically. Empty backups stay empty on restart.

## Water fee audit

Open **Water Fee Audit** from the checklist icon beside Settings. Demand is the
sum of **Water Fee** on unique generated bills in the imported history. Monthly,
quarterly and combined bills use their actual fees; ungenerated periods add no
demand. There is no fixed Rs. 16,800 / Rs. 33,600 target. A single unpaid bill for
Rs. 4,800 therefore has Rs. 4,800 in water demand. Audit keeps fines separate from its water balance.

The **Bill type** selector separates **New Connection bills** from regular/other
bills; **All generated bills** gives the complete account. New-connection-only
accounts are not listed in the regular view. Cross-type arrears payments need
account-level review in All generated bills before calculating separate balances.

Filters include current bill status (Paid, Un-Paid, Expired), connection status
(Regular Connection by default, Closed, Dead, New Demand, Suspended and imported
values), and consumer status (Active/In-Active). Un-Paid includes expired bills,
as in the main search screen. These filters select connections; their historical
totals still include all bills within the selected bill type.

The audit table fits the window with compact column spacing and wrapped headings
and values. All columns, including History, stay visible without horizontal scrolling;
windows narrower than 1,240 pixels scale the table down to fit.

Click table values to copy their full text. History
details and amounts also support click-to-copy and text selection. Closing history
preserves the audit page, filters, sorting and scroll position. Importing
history triggers a refresh after closing while preserving the current position.

The four audit cards show **Generated Water Fee**, **Amount Received (water)**,
**Fine Collected**, and **Water Balance** for the filtered connections. Water
receipts exclude identifiable collected fines and other non-water charges. A
Rs. 2,640 payment against Rs. 2,400 water fees therefore contributes Rs. 2,400 to
water received and Rs. 240 to Fine Collected.

Water balance = generated water fees minus water received. The fine card shows
collected fines and identifies unpaid fines separately. An unknown fine date does
not hide the confirmed water balance. History retains its latest-bill balance,
including a late fine only when its applicability is known.

Consistent negative arrears represent advance credits. A credit application shown
again in Amount Received is deducted from cash receipts, so the original advance
is counted once. Receipts above generated water demand are shown separately as
unapplied receipts / advance credit, rather than overstating recovered water fees.
Unidentified excess is not automatically called a collected fine.
Newer period bills replace an older overlapping entry; both the older fee and its
receipt are excluded from audit totals. Original
source rows remain intact, and excluded bill numbers appear in history and exports.
This uses the user's newer-entry-wins policy without inventing prorated bills.
The confirmed Ali Town/Muslim Town first-period exception retains one payment per
connection and flags competing entries, as previously specified.

Connections are joined by connection number. Name differences do not change the
financial calculation. Rejected daily updates to superseded bill numbers remain
archived; they do not block totals when authoritative merged history exists.
Confirmed summary subtotals identify any unresolved connections excluded from them.

Arrears are not added again as demand. A carried fine is separated only where a
fully paid adjacent-period bill uniquely carries an expired bill's complete
after-due amount, or the unpaid fine from a predecessor whose principal was paid.
Any fine already received on the predecessor is deducted before carrying the rest.
Waived fines that disappear from carried arrears are never treated as collected.
Each recovered fine is counted once. Fully paid arrears that reconcile do not
trigger allocation warnings; ambiguous or partial arrears never
invent a collected fine. Paid status does not erase a short receipt.

History uses its own latest-bill remaining balance, independent of the audit's
whole-account reconciliation. Both pages show water-only Amount Received and
separate Fine Collected, preserving total payments for reference.

Filter and sort the report, open a connection's history, or export all filtered
connections to CSV/PDF. **Export PDF / choose columns** lets you select or remove
any report column, then save the PDF or preview/print it. Exports preserve the
current filters and sort order, across all pages. A separate CSV lists connections
with a positive payable balance for notice preparation after reviewing flagged data.

History **Export PDF** and **Print History** include every record, across all UI
pages. A4 landscape output wraps full cell values, adds pages automatically and
repeats the table headings and page numbers for longer histories.

Invalid money and duplicate/missing bill identities have no calculated balance
until reviewed. No imported history is shown as **No generated bills**, with zero
demand; ensure required history has been imported. The audit does not alter bills.

## Offline English voice search

1. Click the microphone and wait for the listening message.
2. Say the consumer name followed by the full sector name in English, using your natural Pakistani accent.
   - `Asif Ali Town` → name `ASIF`, sector `Ali Town`.
   - `Ghafoor Farooq Colony` → name `GHAFOOR`, sector `Farooq Colony`.
3. Pause for about 2.8 seconds, or press **Search**. Recording has a 30-second limit.
4. The app displays the heard transcript and searches automatically. If needed,
   edit the search name and sector/locality filters, then click
   **Remember corrected name / filters**. The next matching transcript uses that
   correction. Save again to replace a mistaken correction.

Voice search starts a fresh consumer-name search, clearing unrelated old filters.
Typed search continues to support the existing search fields and filters.
An unsuccessful recording preserves the previous search text.

## Recognition and matching

- A complete 16 kHz mono WAV is finalized before Whisper starts. Repeated stop
  requests return the same path, including the automatic-stop → screen-stop path.
- Silence detection tolerates quiet speech and natural pauses; invalid meter
  readings do not stop a recording. In noisy rooms, press Search manually.
- WAV preparation checks PCM chunks, rejects silence/truncation, and boosts quiet
  audio without overwriting metadata or the original recording.
- Whisper is fixed to English transcription (`--language en`) with English
  context for Pakistani proper names. It does not translate speech into Urdu.
  The bundled base model is used; an English-only base model is supported when
  installed. Recognition has a 90-second timeout.
- English spelling variants of Pakistani names are matched against actual
  imported vocabulary. Consonant matches are accepted only when unambiguous.
  Unknown or ambiguous spellings remain visible for correction.
- Full database sector names win over shorter aliases. Localities are recognized
  when their full phrase is present. Name spelling variants such as Gafoor/Ghafoor
  are searched together. No consumer records are renamed or changed.
- Explicit corrections are stored in `voice_aliases` in the existing local SQLite
  database. This remembers text corrections; it does not train the speech model.
- Speech processing and consumer lookup are local. No cloud transcription is used.

Recognition accuracy depends on the speaker, microphone, and model. A short live trial with the office
microphone and representative names is necessary; synthetic fixtures cannot
establish Pakistani-accent accuracy. Expect a pause plus CPU recognition time,
not live word-by-word transcription. The legacy stream executable is not used by
this screen.

## Build and verify

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

Run `build/windows/x64/runner/Release/consumer_search_engine.exe` with its entire
Release folder intact, including `data/flutter_assets/assets/bin` and its DLLs.
Tests include recorder finalization, quiet speech/pause handling, WAV metadata,
English examples, database spelling variants, and correction persistence. The legacy
microphone test is opt-in (`RUN_MIC_TESTS=1`); normal tests do not record live audio.

Before office rollout, try several real names in each common sector, a quiet
speaker, a short pause between name and sector, silence, manual stop, cancel, and
a saved correction after restarting. Check both the transcript and selected
filters; matching quality depends on recognition quality and vocabulary coverage.

Whisper CLI options are documented by the project:
https://github.com/ggml-org/whisper.cpp/tree/master/examples/cli


## Safe CSV upload sequence

Settings now provides **1. Consumer Master CSV → 2. Full History Folder → 3. Daily Bills CSV**. Use any filenames. Folder import includes nested CSVs, collapses exact bill identities, and uses optional ISO dates in filenames to order history snapshots; select the correct fallback snapshot date for undated filenames. Daily imports use the selected date. Equal-date conflicts are held for review. Master uploads preserve billing fields.

Bills match only on exact connection number plus bill number (including leading zeroes / suffixes). Missing daily columns preserve saved receipt dates and billing periods. Older snapshots and payment regressions cannot undo saved payments. Each selected bill group saves atomically with consumer bill summaries. Review notes, source dates and import reports persist in SQLite backups. **Review Last Import** shows notes and exports the full review CSV. Negative source credits are preserved and flagged; missing or invalid dates are never invented.

See [the import plan](docs/data-import-plan.md). The real-file integration test is opt-in (`RUN_SOURCE_IMPORT=1`); it requires the supplied `data/` files, uses a separate database, and verifies repeat uploads, counts and retained dates. It never replaces a populated database.


### Replaced bill numbers across history snapshots

History now reconciles by exact connection, bill type and normalized billing period as well as bill number. A newer full-history snapshot supersedes older alternative bill numbers for that period; older periods absent from the newer snapshot remain. All entries within the newest snapshot are preserved, including legitimate multiple bills. Superseded source records move to a recovery archive included in SQLite backups; they are excluded from active history, audit sums and PDF exports. Names never move history to another connection.

Daily updates referring to a superseded bill number are held with their original receipt details rather than creating duplicate demand or transferring money to a different bill. Affected positive receipts flag the connection for audit allocation review. Import dates must describe the source snapshot accurately. Equal-date alternate bill numbers are held for review.

### Missing billing periods

History shows a red coverage note with missing periods, issue count and estimated
water fees. The user-selected baseline is July 2023 for every connection, through
the current issue cycle. Sessions are six-monthly except July–December 2025:
July, August and September are monthly issues, followed by October–December as
one quarterly issue. Combined annual or half-year bills also cover their months;
expired bills still count as generated periods.

Audit's **Missing amounts** result filter finds these accounts; CSV and
optional PDF columns include the coverage details. Missing history is not added
to recorded fees or payable balances. Undated bills make gaps provisional. Rates
come from consistent recorded water fees; where unavailable, domestic/private
estimates use the standard category rate and say so. Conflicting rates require
confirmation. Zero-fee period bills are reported separately as fee shortfalls.

Within Missing amounts, **Missing: water balance** separates **Water balance
outstanding** from **Water balance zero**. Unknown balances stay in **All water
balances** and are not treated as zero. Cards, table rows and exports follow the
selection. The **Total missing amount** column beside the period details combines
missing bill fees and short water fees; the component amounts remain separate.

**Generated water fee above (Rs.)** accepts a custom threshold in Missing amounts.
For example, `9600` keeps only actual generated water-fee totals strictly greater
than Rs. 9,600, excluding exactly Rs. 9,600. Commas and up to two decimal places
are accepted. Clear the field for all amounts. The filter combines with the
balance category and applies to cards, table rows and exports; invalid amounts
show a validation message rather than silently broadening the results.
