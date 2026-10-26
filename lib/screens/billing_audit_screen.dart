import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/billing_audit_model.dart';
import '../services/database_service.dart';
import '../services/export_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bill_history_dialog.dart';
import '../widgets/billing_audit_pdf_dialog.dart';
import '../widgets/copyable_text.dart';

class BillingAuditScreen extends StatefulWidget {
  const BillingAuditScreen({super.key, this.database});

  final DatabaseService? database;

  @override
  State<BillingAuditScreen> createState() => _BillingAuditScreenState();
}

class _BillingAuditScreenState extends State<BillingAuditScreen> {
  final _search = TextEditingController();
  final _generatedFeeThreshold = TextEditingController();
  final _number = NumberFormat('#,##0.##');
  List<BillingAuditEntry> _entries = [];
  bool _loading = true;
  bool _exporting = false;
  String? _error;
  int _page = 0;
  int _pageSize = 20;
  int _sortColumn = 10;
  bool _ascending = false;
  String _category = 'Domestic';
  String _sector = 'All sectors';
  String _result = 'All results';
  String _billGroup = 'regular';
  String _connectionStatus = 'Regular Connection';
  String _consumerStatus = 'All consumer statuses';
  String _billStatus = 'All bills';
  String _missingBalance = 'All water balances';
  Object? _filteredKey;
  List<BillingAuditEntry> _filteredRows = [];
  final _nonLetters = RegExp(r'[^a-z]');
  int _loadRequest = 0;
  bool get _missingAmountsView => _result == 'Missing amounts';
  int? get _minimumGeneratedFee =>
      auditAmountInPaisa(_generatedFeeThreshold.text);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void reassemble() {
    super.reassemble();
    _load(preservePosition: true);
  }

  @override
  void dispose() {
    _search.dispose();
    _generatedFeeThreshold.dispose();
    super.dispose();
  }

  Future<void> _load({
    bool preservePosition = false,
    String? connectionNo,
  }) async {
    final request = ++_loadRequest;
    setState(() {
      if (_result == 'Missing / short bills') _result = 'Missing amounts';
      if (!preservePosition) _loading = true;
      _error = null;
    });
    try {
      final entries = await (widget.database ?? DatabaseService.instance)
          .getBillingAudit(billGroup: _billGroup, connectionNo: connectionNo);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _entries = connectionNo == null
            ? entries
            : [
                ..._entries.where((e) => e.connectionNo != connectionNo),
                ...entries,
              ];
        _loading = false;
        if (!_entries.any((e) => e.sector == _sector)) _sector = 'All sectors';
        _page = preservePosition
            ? _page.clamp(
                0,
                (_filtered.length - 1).clamp(0, _entries.length) ~/ _pageSize,
              )
            : 0;
      });
    } catch (e) {
      if (mounted && request == _loadRequest) {
        setState(() {
          _loading = false;
          _error = 'Could not load audit: $e';
        });
      }
    }
  }

  String _money(int? paisa) =>
      paisa == null ? '—' : 'Rs. ${_number.format(paisa / 100)}';

  List<BillingAuditEntry> get _filtered {
    final key = (
      _entries,
      _search.text,
      _category,
      _connectionStatus,
      _consumerStatus,
      _billStatus,
      _sector,
      _result,
      _missingBalance,
      _generatedFeeThreshold.text,
      _sortColumn,
      _ascending,
    );
    if (_filteredKey == key) return _filteredRows;
    String normalized(String value) =>
        value.toLowerCase().replaceAll(_nonLetters, '');
    final connectionStatus = normalized(_connectionStatus);
    final consumerStatus = normalized(_consumerStatus);
    final billStatus = normalized(_billStatus);
    final query = _search.text.trim().toLowerCase();
    final minimumGeneratedFee = _minimumGeneratedFee;
    final rows = _entries
        .where(
          (e) =>
              (_category == 'All categories' || e.categoryLabel == _category) &&
              (_connectionStatus == 'All connection statuses' ||
                  normalized(e.connectionStatus) == connectionStatus) &&
              (_consumerStatus == 'All consumer statuses' ||
                  normalized(e.consumerStatus) == consumerStatus) &&
              (_billStatus == 'All bills' ||
                  normalized(e.currentBillStatus) == billStatus ||
                  (_billStatus == 'Un-Paid' &&
                      normalized(e.currentBillStatus) == 'expired')) &&
              (_sector == 'All sectors' || e.sector == _sector) &&
              (_result == 'All results' ||
                  (_result == 'Needs review'
                      ? e.needsReview
                      : _missingAmountsView
                      ? (e.coverage?.hasShortBills ?? false)
                      : _result == 'Unapplied receipts / advance'
                      ? e.advanceBalance > 0
                      : e.result == _result)) &&
              (!_missingAmountsView ||
                  _missingBalance == 'All water balances' ||
                  (_missingBalance == 'Water balance outstanding' &&
                      e.payableBalance != null &&
                      e.payableBalance! > 0) ||
                  (_missingBalance == 'Water balance zero' &&
                      e.payableBalance == 0)) &&
              (!_missingAmountsView ||
                  _generatedFeeThreshold.text.trim().isEmpty ||
                  (minimumGeneratedFee != null &&
                      e.waterFee != null &&
                      e.waterFee! > minimumGeneratedFee)) &&
              (query.isEmpty ||
                  '${e.connectionNo} ${e.consumerName} ${e.fatherHusbandName} ${e.locality}'
                      .toLowerCase()
                      .contains(query)),
        )
        .toList();
    rows.sort((a, b) {
      int compareMoney(int? x, int? y) {
        if (x == null) return y == null ? 0 : 1;
        if (y == null) return -1;
        return _ascending ? x.compareTo(y) : y.compareTo(x);
      }

      final comparison = switch (_sortColumn) {
        0 => a.connectionNo.compareTo(b.connectionNo) * (_ascending ? 1 : -1),
        1 => a.consumerName.compareTo(b.consumerName) * (_ascending ? 1 : -1),
        4 => compareMoney(a.billCount, b.billCount),
        5 => compareMoney(
          _missingAmountsView ? a.coverage?.expectedWaterFee : a.paidBillCount,
          _missingAmountsView ? b.coverage?.expectedWaterFee : b.paidBillCount,
        ),
        6 => compareMoney(
          _missingAmountsView
              ? a.coverage?.missingBillCount
              : a.unpaidBillCount,
          _missingAmountsView
              ? b.coverage?.missingBillCount
              : b.unpaidBillCount,
        ),
        7 => compareMoney(a.waterFee, b.waterFee),
        8 => compareMoney(a.waterReceived, b.waterReceived),
        9 => compareMoney(
          _missingAmountsView
              ? a.coverage?.estimatedMissingFee
              : a.fineCollected,
          _missingAmountsView
              ? b.coverage?.estimatedMissingFee
              : b.fineCollected,
        ),
        11 => compareMoney(
          _missingAmountsView ? a.coverage?.shortFeeAmount : a.paidShortCount,
          _missingAmountsView ? b.coverage?.shortFeeAmount : b.paidShortCount,
        ),
        13 => compareMoney(
          a.coverage?.estimatedMissingAmount,
          b.coverage?.estimatedMissingAmount,
        ),
        _ => compareMoney(a.payableBalance, b.payableBalance),
      };
      return comparison != 0
          ? comparison
          : a.connectionNo.compareTo(b.connectionNo);
    });
    _filteredKey = key;
    return _filteredRows = rows;
  }

  void _filter(VoidCallback change) => setState(() {
    change();
    _page = 0;
  });

  String _missingDetails(BillingAuditEntry entry) {
    final coverage = entry.coverage!;
    return [
      for (final gap in coverage.missingPeriods)
        '${gap.label}: ${gap.estimatedFee == null ? 'Rate unconfirmed' : _money(gap.estimatedFee)}',
      for (final bill in coverage.shortFees)
        'Bill ${bill.billNo}, ${bill.period}: ${_money(bill.amount)} short',
      if (!coverage.hasRecordedHistory)
        'No regular history imported; issuance unconfirmed.',
      if (coverage.undatedBills.isNotEmpty)
        'Possible gaps: bills ${coverage.undatedBills.join(', ')} have no usable period.',
      if (coverage.variableRates) 'Water rate varies; amount unconfirmed.',
    ].join('\n');
  }

  Future<void> _export(
    List<BillingAuditEntry> rows, {
    bool connectionsOnly = false,
  }) async {
    if (_exporting || rows.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final path = connectionsOnly
          ? await ExportService.instance.exportConnectionNumbersCsv(
              connectionNumbers: rows.map((e) => e.connectionNo).toList(),
              fileNamePrefix: _missingAmountsView
                  ? 'Missing_Amounts_Connections'
                  : 'Unpaid_Water_Connections',
            )
          : await ExportService.instance.exportBillingAudit(rows);
      if (path != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved: $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _dropdown(
    String label,
    String value,
    List<String> values,
    ValueChanged<String> onChanged,
  ) => SizedBox(
    width: 210,
    child: DropdownButtonFormField<String>(
      initialValue: value,
      key: ValueKey('$label$value'),
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: values
          .map(
            (v) => DropdownMenuItem(
              value: v,
              child: Text(v, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) _filter(() => onChanged(v));
      },
    ),
  );

  Widget _metric(String label, String value, Color color, {String? note}) =>
      SizedBox(
        width: 245,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                const SizedBox(height: 8),
                CopyableText(
                  value,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                if (note != null) ...[
                  const SizedBox(height: 4),
                  Text(note, style: const TextStyle(fontSize: 11)),
                ],
              ],
            ),
          ),
        ),
      );

  void _sort(int column, bool ascending) => setState(() {
    _sortColumn = column;
    _ascending = ascending;
    _page = 0;
  });

  DataColumn _column(
    String label,
    double width, {
    String? heading,
    bool numeric = false,
    bool sortable = false,
    bool centered = false,
  }) => DataColumn(
    columnWidth: FlexColumnWidth(width),
    label: Expanded(
      child: Text(
        heading ?? label,
        softWrap: true,
        textAlign: centered ? TextAlign.center : null,
      ),
    ),
    tooltip: label,
    numeric: numeric,
    onSort: sortable ? _sort : null,
    headingRowAlignment: centered ? MainAxisAlignment.center : null,
  );

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final short = rows.where((e) => (e.payableBalance ?? 0) > 0).toList();
    int? sumAmount(int? Function(BillingAuditEntry) amount) {
      var total = 0;
      var known = false;
      for (final row in rows) {
        final value = amount(row);
        if (value == null) continue;
        known = true;
        total += value;
      }
      return known || rows.isEmpty ? total : null;
    }

    final totalWater = sumAmount((e) => e.waterFee);
    final grossReceived = sumAmount((e) => e.cashReceived);
    final appliedAdvance = rows.fold<int>(
      0,
      (sum, e) => sum + e.advanceApplied,
    );
    final remainingAdvance = rows.fold<int>(
      0,
      (sum, e) => sum + e.advanceBalance,
    );
    final totalReceived = sumAmount((e) => e.waterReceived);
    final pendingFine = sumAmount((e) => e.outstandingFine);
    final totalFine = rows.fold<int>(0, (sum, e) => sum + e.fineCollected);
    final totalDifference = sumAmount((e) => e.payableBalance);
    final unknownWater = rows.where((e) => e.waterReceived == null).length;
    final unknownBalance = rows.where((e) => e.payableBalance == null).length;
    final unknownFine = rows.where((e) => e.outstandingFine == null).length;
    final unknownDemand = rows.where((e) => e.waterFee == null).length;
    final expectedFees = sumAmount((e) => e.coverage?.expectedWaterFee);
    final missingAmount = sumAmount((e) => e.coverage?.estimatedMissingAmount);
    final missingCount = rows.fold<int>(
      0,
      (sum, e) => sum + (e.coverage?.missingBillCount ?? 0),
    );
    final shortFeeCount = rows.fold<int>(
      0,
      (sum, e) => sum + (e.coverage?.shortFees.length ?? 0),
    );
    final unknownMissing = rows
        .where((e) => e.coverage?.estimatedMissingAmount == null)
        .length;
    final provisionalMissing = rows
        .where(
          (e) =>
              e.coverage != null &&
              (!e.coverage!.hasRecordedHistory ||
                  e.coverage!.undatedBills.isNotEmpty),
        )
        .length;
    final sectors =
        _entries
            .map((e) => e.sector)
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final start = (_page * _pageSize).clamp(0, rows.length);
    final end = (start + _pageSize).clamp(0, rows.length);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Water Fee Audit / واٹر فیس آڈٹ'),
        actions: [
          IconButton(
            tooltip: 'Refresh audit',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : SelectionArea(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Generated bills & water fee recovery',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 24,
                            runSpacing: 12,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                'Generated bills: ${_number.format(rows.fold<int>(0, (sum, e) => sum + e.billCount))}',
                              ),
                              Text(
                                'Marked paid: ${_number.format(rows.fold<int>(0, (sum, e) => sum + e.paidBillCount))}',
                              ),
                              Text(
                                'Expired (carried): ${_number.format(rows.fold<int>(0, (sum, e) => sum + e.expiredBillCount))}',
                              ),
                              Text(
                                'Unpaid: ${_number.format(rows.fold<int>(0, (sum, e) => sum + e.unpaidBillCount))}',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Filtered connections: ${_number.format(rows.length)} | '
                            'Connections with payable balance: ${_number.format(short.length)} | '
                            'Needs data review: ${_number.format(rows.where((e) => e.needsReview).length)}',
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Only bills present in history are counted. Monthly, quarterly and six-month bills contribute their actual Water Fee. '
                            'Periods with no generated bill add no demand. Carried arrears and expired bills are not added again as separate demands.',
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Water balance = Generated Water Fee - Amount Received (water only). '
                            'Collected fines are separated from receipts and are not counted as water recovery. '
                            'Water balance excludes fines. Advances are counted once; credit applications are excluded from cash receipts. '
                            'Older expired bills are not added again; data conflicts remain flagged for review.',
                          ),
                          const SizedBox(height: 8),
                          if (rows.any(
                            (row) => row.confirmedPaymentCount > 0,
                          )) ...[
                            Text(
                              'Confirmed sector payment exception (Ali Town / Muslim Town, July-December 2023): '
                              '${rows.fold<int>(0, (sum, row) => sum + row.confirmedPaymentCount)} bill(s); '
                              'Rs. ${_number.format(rows.fold<int>(0, (sum, row) => sum + row.confirmedPaymentAdjustment) / 100)} included in receipts. '
                              'Already-Paid bills and imported source records are unchanged.',
                            ),
                            const SizedBox(height: 8),
                          ],
                          const Text(
                            'Click a value to copy it. New Connection bills have a separate view; use All generated bills to reconcile payments across bill types.',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _dropdown(
                        'Bill type',
                        billingAuditGroups[_billGroup]!,
                        billingAuditGroups.values.toList(),
                        (v) {
                          _billGroup = billingAuditGroups.entries
                              .firstWhere((e) => e.value == v)
                              .key;
                          _load();
                        },
                      ),
                      SizedBox(
                        width: 300,
                        child: TextField(
                          controller: _search,
                          decoration: const InputDecoration(
                            labelText: 'Connection / name / locality',
                            prefixIcon: Icon(Icons.search),
                          ),
                          onChanged: (_) => _filter(() {}),
                        ),
                      ),
                      _dropdown('Category', _category, [
                        'All categories',
                        'Domestic',
                        'Private Societies',
                        'Commercial',
                        'Unclassified',
                      ], (v) => _category = v),
                      _dropdown('Sector', _sector, [
                        'All sectors',
                        ...sectors,
                      ], (v) => _sector = v),
                      _dropdown(
                        'Result',
                        _result,
                        [
                          'All results',
                          'Water balance due',
                          'No water balance',
                          'Unapplied receipts / advance',
                          'Missing amounts',
                          'Review allocation',
                          'No generated bills',
                          'Needs review',
                        ],
                        (v) {
                          final wasMissing = _missingAmountsView;
                          _result = v;
                          if (wasMissing != _missingAmountsView) {
                            _sortColumn = _missingAmountsView ? 13 : 10;
                            _ascending = false;
                          }
                        },
                      ),
                      if (_missingAmountsView)
                        _dropdown(
                          'Missing: water balance',
                          _missingBalance,
                          [
                            'All water balances',
                            'Water balance outstanding',
                            'Water balance zero',
                          ],
                          (v) => _missingBalance = v,
                        ),
                      if (_missingAmountsView)
                        SizedBox(
                          width: 300,
                          child: TextField(
                            key: const ValueKey(
                              'generated-water-fee-threshold',
                            ),
                            controller: _generatedFeeThreshold,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: 'Generated water fee above (Rs.)',
                              hintText: 'e.g. 9600',
                              helperText: 'Strictly greater than this amount',
                              errorText:
                                  _generatedFeeThreshold.text
                                          .trim()
                                          .isNotEmpty &&
                                      _minimumGeneratedFee == null
                                  ? 'Enter a valid non-negative rupee amount'
                                  : null,
                              suffixIcon: _generatedFeeThreshold.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip:
                                          'Clear generated water fee filter',
                                      icon: const Icon(Icons.clear),
                                      onPressed: () =>
                                          _filter(_generatedFeeThreshold.clear),
                                    ),
                            ),
                            onChanged: (_) => _filter(() {}),
                          ),
                        ),
                      _dropdown('Current bill status', _billStatus, [
                        'All bills',
                        'Paid',
                        'Un-Paid',
                        'Expired',
                      ], (v) => _billStatus = v),
                      _dropdown(
                        'Connection status',
                        _connectionStatus,
                        {
                          'All connection statuses',
                          'Regular Connection',
                          'Closed',
                          'Dead',
                          'New Demand',
                          'Suspended',
                          ..._entries
                              .map((e) => e.connectionStatus)
                              .where((s) => s.isNotEmpty),
                        }.toList(),
                        (v) => _connectionStatus = v,
                      ),
                      _dropdown(
                        'Consumer status',
                        _consumerStatus,
                        ['All consumer statuses', 'Active', 'In-Active'],
                        (v) => _consumerStatus = v,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (_missingAmountsView) ...[
                        _metric(
                          'Expected Water Fee',
                          _money(expectedFees),
                          AppTheme.darkGreen,
                          note:
                              'July 2023 through the current issue cycle; estimated at the applicable rate.',
                        ),
                        _metric(
                          'Recorded Water Fee',
                          _money(totalWater),
                          AppTheme.darkGreen,
                          note: 'Actual Water Fee column total.',
                        ),
                        _metric(
                          'Missing Bills',
                          _number.format(missingCount),
                          AppTheme.statusInactive,
                          note: shortFeeCount == 0
                              ? 'Missing billing periods in history.'
                              : '$shortFeeCount additional bill(s) have short water fees.',
                        ),
                        _metric(
                          'Estimated Missing Amount',
                          _money(missingAmount),
                          AppTheme.statusInactive,
                          note:
                              'Missing periods and short water fees.'
                              '${unknownMissing == 0 ? '' : ' $unknownMissing rate-unconfirmed account(s) excluded.'}'
                              '${provisionalMissing == 0 ? '' : ' $provisionalMissing provisional account(s).'}',
                        ),
                      ] else ...[
                        _metric(
                          'Generated Water Fee',
                          _money(totalWater),
                          AppTheme.darkGreen,
                          note: unknownDemand == 0
                              ? null
                              : 'Confirmed subtotal; $unknownDemand unresolved connection(s) excluded.',
                        ),
                        _metric(
                          'Amount Received (water)',
                          _money(totalReceived),
                          AppTheme.statusActive,
                          note:
                              '${unknownWater == 0 ? '' : 'Confirmed subtotal; $unknownWater unresolved excluded. '}Cash receipts: ${_money(grossReceived)} | Advance applied: ${_money(appliedAdvance)} | Unapplied receipts: ${_money(remainingAdvance)}',
                        ),
                        _metric(
                          'Fine Collected',
                          _money(totalFine),
                          AppTheme.afterDueOrange,
                          note:
                              'Unpaid fine confirmed: ${_money(pendingFine)}${unknownFine == 0 ? '' : '; $unknownFine unconfirmed (separate from water)'}',
                        ),
                        _metric(
                          'Water Balance',
                          _money(totalDifference),
                          (totalDifference ?? 0) > 0
                              ? AppTheme.statusInactive
                              : AppTheme.darkGreen,
                          note:
                              '${unknownBalance == 0 ? '' : 'Confirmed subtotal; $unknownBalance unresolved excluded. '}Generated water fee minus water received. Fines separate.',
                        ),
                      ],
                    ],
                  ),
                  if (_missingAmountsView)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Missing amounts identify gaps or short water fees in the imported history. '
                        'They are estimates and are not added to the recorded water balance. Fines are excluded.',
                      ),
                    ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: rows.isEmpty || _exporting
                            ? null
                            : () => _export(rows),
                        icon: const Icon(Icons.download),
                        label: Text(
                          _missingAmountsView
                              ? 'Export missing amounts CSV'
                              : 'Export filtered audit CSV',
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: rows.isEmpty || _exporting
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) => BillingAuditPdfDialog(
                                  entries: rows,
                                  initialColumnKeys: _missingAmountsView
                                      ? ExportService
                                            .defaultMissingAmountsPdfColumns
                                      : null,
                                  filterSummary:
                                      '${billingAuditGroups[_billGroup]} | $_category | $_sector | $_result${_missingAmountsView ? ' | $_missingBalance' : ''}${_missingAmountsView && _generatedFeeThreshold.text.trim().isNotEmpty ? ' | Generated water fee > ${_money(_minimumGeneratedFee)}' : ''} | $_billStatus | $_connectionStatus | $_consumerStatus${_search.text.trim().isEmpty ? '' : ' | Search: ${_search.text.trim()}'}',
                                ),
                              ),
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text('Export PDF / choose columns'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            (_missingAmountsView
                                    ? rows.isEmpty
                                    : short.isEmpty) ||
                                _exporting
                            ? null
                            : () => _export(
                                _missingAmountsView ? rows : short,
                                connectionsOnly: true,
                              ),
                        icon: const Icon(Icons.list_alt),
                        label: Text(
                          _missingAmountsView
                              ? 'Export connections with missing amounts'
                              : 'Export connections with balance',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_entries.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No connections found. Import the consumer master and full bill history from Settings.',
                        ),
                      ),
                    )
                  else if (rows.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No connections match these filters.'),
                      ),
                    )
                  else
                    Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LayoutBuilder(
                            builder: (context, constraints) => FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.topLeft,
                              child: SizedBox(
                                // Keep narrow windows usable without horizontal scrolling.
                                width: constraints.maxWidth < 1200
                                    ? 1200
                                    : constraints.maxWidth,
                                child: DataTable(
                                  sortColumnIndex: _sortColumn,
                                  sortAscending: _ascending,
                                  horizontalMargin: 8,
                                  columnSpacing: 8,
                                  dataRowMinHeight: 52,
                                  dataRowMaxHeight: double.infinity,
                                  headingRowHeight: constraints.maxWidth >= 1500
                                      ? 72
                                      : 88,
                                  dataTextStyle: TextStyle(
                                    fontSize: constraints.maxWidth >= 1500
                                        ? 13
                                        : 12,
                                    height: 1.35,
                                  ),
                                  headingRowColor: const WidgetStatePropertyAll(
                                    AppTheme.tableHeaderGreen,
                                  ),
                                  headingTextStyle: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: constraints.maxWidth >= 1700
                                        ? 13
                                        : constraints.maxWidth >= 1400
                                        ? 12
                                        : 11,
                                  ),
                                  columns: [
                                    _column(
                                      'Connection No.',
                                      .95,
                                      heading: 'Conn. No.',
                                      sortable: true,
                                    ),
                                    _column('Consumer', 1.7, sortable: true),
                                    _column('Sector / Locality', 1.5),
                                    _column('Category', .9),
                                    _column(
                                      'Generated bills',
                                      .65,
                                      numeric: true,
                                    ),
                                    _column(
                                      _missingAmountsView
                                          ? 'Expected water fee'
                                          : 'Marked paid',
                                      _missingAmountsView ? 1.2 : .8,
                                      numeric: true,
                                      sortable: true,
                                    ),
                                    _column(
                                      _missingAmountsView
                                          ? 'Missing bills'
                                          : 'Unpaid',
                                      .85,
                                      numeric: true,
                                      sortable: true,
                                    ),
                                    _column(
                                      'Generated water fee',
                                      1.15,
                                      numeric: true,
                                      sortable: true,
                                    ),
                                    _column(
                                      'Amount Received (water)',
                                      1.15,
                                      numeric: true,
                                      sortable: true,
                                    ),
                                    _column(
                                      _missingAmountsView
                                          ? 'Missing bill fees'
                                          : 'Fine Collected',
                                      1.15,
                                      numeric: true,
                                      sortable: true,
                                    ),
                                    _column(
                                      'Water balance',
                                      1.2,
                                      numeric: true,
                                      sortable: true,
                                    ),
                                    _column(
                                      _missingAmountsView
                                          ? 'Short water fee'
                                          : 'Paid bills with short receipt',
                                      1.35,
                                      numeric: true,
                                      sortable: true,
                                      centered: true,
                                    ),
                                    _column(
                                      _missingAmountsView
                                          ? 'Missing periods / details'
                                          : 'Result / review',
                                      _missingAmountsView ? 3.2 : 1.15,
                                    ),
                                    if (_missingAmountsView)
                                      _column(
                                        'Total missing amount',
                                        1.3,
                                        numeric: true,
                                        sortable: true,
                                      ),
                                    _column(
                                      'History',
                                      _missingAmountsView ? .75 : .6,
                                    ),
                                  ],
                                  rows: [
                                    for (final entry in rows.sublist(
                                      start,
                                      end,
                                    ))
                                      DataRow(
                                        color: WidgetStatePropertyAll(
                                          (entry.payableBalance ?? 0) > 0
                                              ? Colors.red.shade50
                                              : null,
                                        ),
                                        cells: [
                                          DataCell(
                                            CopyableText(entry.connectionNo),
                                          ),
                                          DataCell(
                                            Tooltip(
                                              message:
                                                  'F/H: ${entry.fatherHusbandName}\nConnected: ${entry.connectionDate}\nStatus: ${entry.connectionStatus}\n${entry.address}',
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 8,
                                                    ),
                                                child: CopyableText(
                                                  entry.consumerName,
                                                ),
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 8,
                                                  ),
                                              child: CopyableText(
                                                '${entry.sector}\n${entry.locality}',
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            CopyableText(entry.categoryLabel),
                                          ),
                                          DataCell(
                                            CopyableText('${entry.billCount}'),
                                          ),
                                          DataCell(
                                            CopyableText(
                                              _missingAmountsView
                                                  ? _money(
                                                      entry
                                                          .coverage
                                                          ?.expectedWaterFee,
                                                    )
                                                  : '${entry.paidBillCount}',
                                            ),
                                          ),
                                          DataCell(
                                            CopyableText(
                                              _missingAmountsView
                                                  ? '${entry.coverage?.missingBillCount ?? 0}'
                                                  : '${entry.unpaidBillCount}',
                                            ),
                                          ),
                                          DataCell(
                                            CopyableText(
                                              _money(entry.waterFee),
                                            ),
                                          ),
                                          DataCell(
                                            CopyableText(
                                              _money(entry.waterReceived),
                                            ),
                                          ),
                                          DataCell(
                                            CopyableText(
                                              _money(
                                                _missingAmountsView
                                                    ? entry
                                                          .coverage
                                                          ?.estimatedMissingFee
                                                    : entry.fineCollected,
                                              ),
                                              style: _missingAmountsView
                                                  ? const TextStyle(
                                                      color: AppTheme
                                                          .statusInactive,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    )
                                                  : null,
                                            ),
                                          ),
                                          DataCell(
                                            CopyableText(
                                              _money(entry.payableBalance),
                                              style: TextStyle(
                                                color:
                                                    (entry.payableBalance ??
                                                            0) >
                                                        0
                                                    ? AppTheme.statusInactive
                                                    : AppTheme.darkGreen,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Center(
                                              child: CopyableText(
                                                _missingAmountsView
                                                    ? _money(
                                                        entry
                                                            .coverage
                                                            ?.shortFeeAmount,
                                                      )
                                                    : '${entry.paidShortCount}',
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            _missingAmountsView
                                                ? Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          vertical: 8,
                                                        ),
                                                    child: CopyableText(
                                                      _missingDetails(entry),
                                                      style: const TextStyle(
                                                        color: AppTheme
                                                            .statusInactive,
                                                      ),
                                                    ),
                                                  )
                                                : Tooltip(
                                                    message: entry.reviewReasons
                                                        .join('\n'),
                                                    child: CopyableText(
                                                      entry.result,
                                                      style: TextStyle(
                                                        color: entry.needsReview
                                                            ? AppTheme
                                                                  .afterDueOrange
                                                            : null,
                                                      ),
                                                    ),
                                                  ),
                                          ),
                                          if (_missingAmountsView)
                                            DataCell(
                                              CopyableText(
                                                _money(
                                                  entry
                                                      .coverage
                                                      ?.estimatedMissingAmount,
                                                ),
                                                style: const TextStyle(
                                                  color:
                                                      AppTheme.statusInactive,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          DataCell(
                                            IconButton(
                                              tooltip: 'Open bill history',
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(
                                                minWidth: 32,
                                                minHeight: 36,
                                              ),
                                              icon: const Icon(
                                                Icons.history,
                                                size: 20,
                                              ),
                                              onPressed: () async {
                                                var historyChanged = false;
                                                await BillHistoryDialog.show(
                                                  context: context,
                                                  connectionNo:
                                                      entry.connectionNo,
                                                  database: widget.database,
                                                  onHistoryChanged: () =>
                                                      historyChanged = true,
                                                );
                                                if (mounted) {
                                                  await _load(
                                                    preservePosition: true,
                                                    connectionNo: historyChanged
                                                        ? null
                                                        : entry.connectionNo,
                                                  );
                                                }
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 12,
                              children: [
                                const Text('Rows per page:'),
                                DropdownButton<int>(
                                  value: _pageSize,
                                  items: [
                                    for (final n in [10, 20, 50, 100])
                                      DropdownMenuItem(
                                        value: n,
                                        child: Text('$n'),
                                      ),
                                  ],
                                  onChanged: (n) {
                                    if (n != null) _filter(() => _pageSize = n);
                                  },
                                ),
                                Text('${start + 1}–$end of ${rows.length}'),
                                IconButton(
                                  tooltip: 'First page',
                                  onPressed: _page > 0
                                      ? () => setState(() => _page = 0)
                                      : null,
                                  icon: const Icon(Icons.first_page),
                                ),
                                IconButton(
                                  tooltip: 'Previous page',
                                  onPressed: _page > 0
                                      ? () => setState(() => _page--)
                                      : null,
                                  icon: const Icon(Icons.chevron_left),
                                ),
                                IconButton(
                                  tooltip: 'Next page',
                                  onPressed: end < rows.length
                                      ? () => setState(() => _page++)
                                      : null,
                                  icon: const Icon(Icons.chevron_right),
                                ),
                                IconButton(
                                  tooltip: 'Last page',
                                  onPressed: end < rows.length
                                      ? () => setState(
                                          () => _page =
                                              (rows.length - 1) ~/ _pageSize,
                                        )
                                      : null,
                                  icon: const Icon(Icons.last_page),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
