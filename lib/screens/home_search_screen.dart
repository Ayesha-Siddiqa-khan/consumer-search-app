import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/consumer_model.dart';
import '../services/csv_import_service.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';
import '../widgets/consumer_detail_dialog.dart';
import '../widgets/bill_history_dialog.dart';
import '../widgets/pdf_export_dialog.dart';
import '../widgets/searchable_select_field.dart';
import '../services/export_service.dart';
import '../services/audio_recorder_service.dart';
import '../services/whisper_service.dart';
import '../services/voice_vocabulary.dart';
import '../services/smart_search_parser.dart';
import 'settings_screen.dart';
import 'billing_audit_screen.dart';
import 'pdf_bills_screen.dart';

class HomeSearchScreen extends StatefulWidget {
  const HomeSearchScreen({super.key});

  @override
  State<HomeSearchScreen> createState() => _HomeSearchScreenState();
}

class _HomeSearchScreenState extends State<HomeSearchScreen>
    with SingleTickerProviderStateMixin {
  // Search & Filter State
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _horizontalScrollCtrl = ScrollController();
  final ScrollController _verticalPageScrollCtrl = ScrollController();
  Timer? _debounceTimer;

  // Auto-suggestions & Voice Search State
  List<String> _suggestions = [];
  bool _isVoiceListening = false;
  bool _isVoiceProcessing = false;
  String _voiceListeningStatus = '';
  String? _lastVoiceTranscript;
  int _voiceSession = 0;
  bool _voiceStarting = false;
  bool _voiceNameSearch = false;
  late AnimationController _micPulseController;
  late Animation<double> _micPulseAnimation;

  String _searchBy = 'all';
  String _selectedSector = 'All Sectors';
  String _selectedLocality = 'All Localities';
  String _selectedConsumerStatus = 'All Statuses';
  String _selectedConnectionStatus = 'Regular Connection';
  String _selectedBillStatus = 'All Bills';
  String _selectedRateType = 'All Rate Types';

  // Dropdown lists
  List<String> _sectors = ['All Sectors'];
  List<String> _localities = ['All Localities'];
  final List<String> _consumerStatuses = ['All Statuses', 'Active', 'In-Active'];
  List<String> _connectionStatuses = ['All Connection Statuses'];
  final List<String> _billStatuses = ['All Bills', 'Paid', 'Un-Paid', 'Expired'];
  List<String> _rateTypes = ['All Rate Types'];

  // Pagination & Results State
  bool _isLoading = false;
  bool _isSeeding = false;
  String _seedStatus = '';
  double _seedProgress = 0.0;

  List<Consumer> _consumers = [];
  int _totalCount = 0;
  int _currentPage = 1;
  int _pageSize = 10;
  final List<int> _pageSizeOptions = [10, 20, 25, 30, 50, 100, 500];

  // Column visibility & Custom Order on Dashboard Table (all selected by default)
  late List<String> _columnOrder;
  late Set<String> _visibleColumnIds;
  static const List<String> _defaultColumnOrder = [
    'sr_no',
    'consumer_name',
    'father_husband_name',
    'total_bill',
    'mobile',
    'connection_no',
    'old_connection_no',
    'sector',
    'locality',
    'address',
    'fine',
    'after_due_date',
    'due_date',
    'bill_status',
    'amount_received',
    'rate_type',
    'order_no',
    'connection_date',
    'connection_status',
    'consumer_status',
    'actions',
  ];
  static const Set<String> _lockedColumns = {'consumer_name', 'connection_no'};
  static const String _prefsKeyVisibleColumns = 'visible_columns_v1';
  static const String _prefsKeyColumnOrder = 'column_order_v1';

  // CONN NO sort state
  String _connSortOrder = 'none'; // 'none' | 'asc' | 'desc'

  List<Consumer> get _sortedConsumers {
    if (_connSortOrder == 'none') return _consumers;
    final sorted = List<Consumer>.from(_consumers);
    sorted.sort((a, b) {
      final valA = a.connectionNo.trim();
      final valB = b.connectionNo.trim();
      final cmp = valA.compareTo(valB);
      return _connSortOrder == 'asc' ? cmp : -cmp;
    });
    return sorted;
  }

  void _toggleConnSort() {
    setState(() {
      _connSortOrder = _connSortOrder == 'none' || _connSortOrder == 'desc'
          ? 'asc'
          : 'desc';
    });
  }

  @override
  void initState() {
    super.initState();
    _micPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    )..repeat(reverse: true);
    _micPulseAnimation = Tween<double>(begin: 0.94, end: 1.18).animate(
      CurvedAnimation(parent: _micPulseController, curve: Curves.easeInOut),
    );

    _columnOrder = List<String>.from(_defaultColumnOrder);
    _visibleColumnIds = Set<String>.from(_defaultColumnOrder);
    _loadColumnPreferences();
    _checkAndInitDatabase();
  }

  @override
  void dispose() {
    _micPulseController.dispose();
    ++_voiceSession;
    AudioRecorderService.instance.cancelRecording();
    _searchController.dispose();
    _horizontalScrollCtrl.dispose();
    _verticalPageScrollCtrl.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadColumnPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final savedOrder = prefs.getStringList(_prefsKeyColumnOrder);
    final savedVisible = prefs.getStringList(_prefsKeyVisibleColumns);
    if (savedOrder != null && mounted) {
      final validOrder = savedOrder.where((id) => _defaultColumnOrder.contains(id)).toList();
      final missing = _defaultColumnOrder.where((id) => !validOrder.contains(id)).toList();
      setState(() {
        _columnOrder = [...validOrder, ...missing];
        _visibleColumnIds = savedVisible != null
            ? savedVisible.where((id) => _defaultColumnOrder.contains(id)).toSet()
            : Set<String>.from(_defaultColumnOrder);
      });
    }
  }

  Future<void> _saveColumnPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKeyColumnOrder, _columnOrder);
    await prefs.setStringList(_prefsKeyVisibleColumns, _visibleColumnIds.toList());
  }

  void _copyText(String text, String label) {
    if (text.trim().isEmpty || text == '-') return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied: $text'),
        duration: const Duration(seconds: 2),
        backgroundColor: AppTheme.primaryGreen,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _openPdfExport() {
    if (_consumers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No consumer records found to export.')),
      );
      return;
    }

    final filters = <String>[];
    if (_selectedSector != 'All Sectors') filters.add('Sector: $_selectedSector');
    if (_selectedLocality != 'All Localities') filters.add('Locality: $_selectedLocality');
    if (_selectedConsumerStatus != 'All Statuses') filters.add('Consumer Status: $_selectedConsumerStatus');
    if (_selectedConnectionStatus != 'All Connection Statuses') filters.add('Conn Status: $_selectedConnectionStatus');
    if (_selectedBillStatus != 'All Bills') filters.add('Bill: $_selectedBillStatus');
    if (_selectedRateType != 'All Rate Types') filters.add('Rate: $_selectedRateType');
    if (_searchController.text.trim().isNotEmpty) filters.add('Search: "${_searchController.text.trim()}"');

    PdfExportDialog.show(
      context: context,
      currentConsumers: _consumers,
      totalFilteredCount: _totalCount,
      filterSummary: filters.isNotEmpty ? filters.join(' • ') : 'All Records',
      searchQuery: _searchController.text,
      searchBy: _searchBy,
      sector: _selectedSector,
      locality: _selectedLocality,
      consumerStatus: _selectedConsumerStatus,
      connectionStatus: _selectedConnectionStatus,
      rateType: _selectedRateType,
      billStatus: _selectedBillStatus,
      initialSelectedColumnKeys: ExportService.defaultPdfColumnKeys,
    );
  }

  Future<void> _exportCsv() async {
    final savedPath = await ExportService.instance.exportCsvBackup(
      consumers: _consumers,
    );
    if (savedPath != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('CSV Backup saved successfully! ($savedPath)'),
          backgroundColor: AppTheme.primaryGreen,
        ),
      );
    }
  }

  Future<List<String>> _fetchAllMatchingConnectionNumbers() async {
    if (_totalCount <= _consumers.length) {
      final list = _consumers
          .map((c) => c.connectionNo.trim())
          .where((s) => s.isNotEmpty && s != '-')
          .toList();
      _applyConnSortToList(list);
      return list;
    }

    final res = await DatabaseService.instance.searchConsumers(
      query: _searchController.text,
      voiceNameSearch: _voiceNameSearch,
      searchBy: _searchBy,
      sector: _selectedSector,
      locality: _selectedLocality,
      consumerStatus: _selectedConsumerStatus,
      connectionStatus: _selectedConnectionStatus,
      rateType: _selectedRateType,
      page: 1,
      pageSize: _totalCount > 0 ? _totalCount : 100000,
    );

    final list = res.items
        .map((c) => c.connectionNo.trim())
        .where((s) => s.isNotEmpty && s != '-')
        .toList();
    _applyConnSortToList(list);
    return list;
  }

  void _applyConnSortToList(List<String> list) {
    if (_connSortOrder == 'asc') {
      list.sort((a, b) => a.compareTo(b));
    } else if (_connSortOrder == 'desc') {
      list.sort((a, b) => b.compareTo(a));
    }
  }

  Future<void> _exportConnectionNumbers({required bool onlyCurrentPage}) async {
    if (_consumers.isEmpty && _totalCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No connection numbers found to export.')),
      );
      return;
    }

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Preparing Connection Numbers CSV...'),
            duration: Duration(seconds: 1),
          ),
        );
      }

      final List<String> list;
      if (onlyCurrentPage) {
        list = _sortedConsumers
            .map((c) => c.connectionNo.trim())
            .where((s) => s.isNotEmpty && s != '-')
            .toList();
      } else {
        list = await _fetchAllMatchingConnectionNumbers();
      }

      if (list.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No valid connection numbers found.')),
          );
        }
        return;
      }

      final savedPath = await ExportService.instance.exportConnectionNumbersCsv(
        connectionNumbers: list,
      );

      if (savedPath != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved ${list.length} Connection Numbers to CSV!\n$savedPath'),
            backgroundColor: AppTheme.primaryGreen,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export error: $e')),
        );
      }
    }
  }

  Future<void> _copyConnectionNumbers({required bool onlyCurrentPage}) async {
    if (_consumers.isEmpty && _totalCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No connection numbers found to copy.')),
      );
      return;
    }

    try {
      final List<String> list;
      if (onlyCurrentPage) {
        list = _sortedConsumers
            .map((c) => c.connectionNo.trim())
            .where((s) => s.isNotEmpty && s != '-')
            .toList();
      } else {
        list = await _fetchAllMatchingConnectionNumbers();
      }

      if (list.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No valid connection numbers found.')),
          );
        }
        return;
      }

      final textToCopy = list.join('\n');
      await Clipboard.setData(ClipboardData(text: textToCopy));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${list.length} Connection Numbers copied to clipboard!'),
            backgroundColor: AppTheme.primaryGreen,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Copy error: $e')),
        );
      }
    }
  }

  Future<void> _checkAndInitDatabase() async {
    setState(() => _isLoading = true);
    try {
      final stats = await DatabaseService.instance.getStats();
      final total = stats['total'] as int? ?? 0;

      final prefs = await SharedPreferences.getInstance();
      if (total == 0 && (stats['billHistoryCount'] as int? ?? 0) == 0 && !(prefs.getBool('database_manually_cleared') ?? false)) {
        // Seed first launch only; an intentional clear must survive app restarts.
        setState(() {
          _isLoading = false;
          _isSeeding = true;
          _seedStatus = 'Seeding initial 27,870 consumer records...';
          _seedProgress = 0.05;
        });

        try {
          await CsvImportService.instance.importFromAsset(
            onProgress: (status, progress) {
              if (mounted) {
                setState(() {
                  _seedStatus = status;
                  _seedProgress = progress;
                });
              }
            },
          );
        } catch (e) {
          debugPrint('Auto seed error: $e');
        }

        if (mounted) {
          setState(() => _isSeeding = false);
        }
      }

      await _loadFilterOptions();
      await _performSearch(resetPage: true);
    } catch (e, stack) {
      debugPrint('Database init error: $e\n$stack');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadFilterOptions() async {
    final sectors = await DatabaseService.instance.getSectors();
    final sector = sectors.contains(_selectedSector) ? _selectedSector : 'All Sectors';
    final localities = await DatabaseService.instance.getLocalities(
      sector: sector != 'All Sectors' ? sector : null,
    );
    final connStatuses = await DatabaseService.instance.getConnectionStatuses();
    final rates = await DatabaseService.instance.getRateTypes();

    if (mounted) {
      setState(() {
        _sectors = ['All Sectors', ...sectors];
        _localities = ['All Localities', ...localities];
        _connectionStatuses = ['All Connection Statuses', ...connStatuses];
        _rateTypes = ['All Rate Types', ...rates];
        _selectedSector = sector;
        if (!_localities.contains(_selectedLocality)) _selectedLocality = 'All Localities';
        if (!_connectionStatuses.contains(_selectedConnectionStatus)) _selectedConnectionStatus = 'All Connection Statuses';
        if (!_rateTypes.contains(_selectedRateType)) _selectedRateType = 'All Rate Types';
      });
    }
  }

  Future<void> _onSectorChanged(String sector) async {
    setState(() {
      _selectedSector = sector;
      _selectedLocality = 'All Localities';
    });
    final localities = await DatabaseService.instance.getLocalities(
      sector: sector != 'All Sectors' ? sector : null,
    );
    if (mounted) {
      setState(() {
        _localities = ['All Localities', ...localities];
      });
    }
    _performSearch(resetPage: true);
  }

  void _onSearchChanged(String text) {
    _debounceTimer?.cancel();

    final query = text.trim();
    // Fetch dynamic live autocomplete suggestions from SQLite
    if (query.isNotEmpty) {
      DatabaseService.instance.getSuggestions(query).then((suggs) {
        if (mounted && _searchController.text.trim() == query) {
          setState(() => _suggestions = suggs);
        }
      });
    } else {
      if (mounted) {
        setState(() => _suggestions = []);
      }
    }

    // Instant incremental search with fast 180ms debounce
    _debounceTimer = Timer(const Duration(milliseconds: 180), () {
      _performSearch(resetPage: true);
    });
  }

  Future<void> _performSearch({bool resetPage = false}) async {
    if (resetPage) {
      _currentPage = 1;
    }
    setState(() => _isLoading = true);

    try {
      final res = await DatabaseService.instance.searchConsumers(
        query: _searchController.text,
        voiceNameSearch: _voiceNameSearch,
        searchBy: _searchBy,
        sector: _selectedSector,
        locality: _selectedLocality,
        consumerStatus: _selectedConsumerStatus,
        connectionStatus: _selectedConnectionStatus,
        rateType: _selectedRateType,
        billStatus: _selectedBillStatus,
        page: _currentPage,
        pageSize: _pageSize,
      );

      if (mounted) {
        setState(() {
          _consumers = res.items;
          _totalCount = res.totalCount;
        });
      }
    } catch (e, stack) {
      debugPrint('Search error: $e\n$stack');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _resetFilters() {
    _voiceNameSearch = false;
    _lastVoiceTranscript = null;
    _searchController.clear();
    setState(() {
      _searchBy = 'all';
      _selectedSector = 'All Sectors';
      _selectedLocality = 'All Localities';
      _selectedConsumerStatus = 'All Statuses';
      _selectedConnectionStatus = 'Regular Connection';
      _selectedBillStatus = 'All Bills';
      _selectedRateType = 'All Rate Types';
    });
    _loadFilterOptions();
    _performSearch(resetPage: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    return SelectionArea(
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Container(
            decoration: const BoxDecoration(
              color: AppTheme.primaryGreen,
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.asset(
                        'assets/images/logo.jpg',
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Consumer Search Engine',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),
                          Text(
                            'Municipal Committee Chishtian',
                            style: TextStyle(
                              color: Colors.white.withAlpha(210),
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(50),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.people_alt, color: Colors.white, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            '$_totalCount Consumers',
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Water Fee Audit',
                      icon: const Icon(Icons.fact_check_outlined, color: Colors.white),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const BillingAuditScreen()),
                      ),
                    ),
                    IconButton(
                      tooltip: 'PDF Bills — Search, Print & Manage',
                      icon: const Icon(Icons.picture_as_pdf_outlined, color: Colors.white),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const PdfBillsScreen()),
                      ),
                    ),
                    IconButton(
                      tooltip: 'System Settings & Data Management',
                      icon: const Icon(Icons.settings, color: Colors.white),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (ctx) => SettingsScreen(
                              onDataChanged: () async {
                                await _loadFilterOptions();
                                await _performSearch(resetPage: true);
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: _isSeeding
            ? _buildSeedingView()
            : Column(
                children: [
                  Expanded(
                    child: Scrollbar(
                      controller: _verticalPageScrollCtrl,
                      thumbVisibility: true,
                      trackVisibility: true,
                      child: SingleChildScrollView(
                        controller: _verticalPageScrollCtrl,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildFilterCard(isDesktop),
                            const SizedBox(height: 16),
                            _buildSearchCard(isDesktop),
                            const SizedBox(height: 16),
                            _buildResultsTable(isDesktop),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _buildPaginationFooter(),
                ],
              ),
      ),
    );
  }

  Widget _buildSeedingView() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 450),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_download, color: AppTheme.primaryGreen, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Initializing Consumer Database',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  _seedStatus,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  value: _seedProgress > 0 ? _seedProgress : null,
                  backgroundColor: Colors.grey.shade200,
                  color: AppTheme.primaryGreen,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 8),
                Text(
                  '${(_seedProgress * 100).toInt()}% completed',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterCard(bool isDesktop) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.tune_rounded, color: AppTheme.primaryGreen, size: 18),
                SizedBox(width: 8),
                Text(
                  'Consumer List Filters',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.darkGreen,
                  ),
                ),
                Spacer(),
                Text(
                  'Tip: Click Sector/Locality to type and search by letters (e.g. "B")',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            const Divider(height: 20),
            // First Row of Filters: Searchable Sector, Searchable Locality, Consumer Status, Connection Status
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SearchableSelectField(
                  label: 'Sector',
                  value: _selectedSector,
                  items: _sectors,
                  allItemLabel: 'All Sectors',
                  width: isDesktop ? 220 : double.infinity,
                  onChanged: _onSectorChanged,
                ),
                SearchableSelectField(
                  label: 'Locality',
                  value: _selectedLocality,
                  items: _localities,
                  allItemLabel: 'All Localities',
                  width: isDesktop ? 220 : double.infinity,
                  onChanged: (val) {
                    setState(() => _selectedLocality = val);
                    _performSearch(resetPage: true);
                  },
                ),
                _buildDropdownItem(
                  label: 'Consumer Status',
                  value: _selectedConsumerStatus,
                  items: _consumerStatuses,
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedConsumerStatus = val);
                      _performSearch(resetPage: true);
                    }
                  },
                  width: isDesktop ? 180 : double.infinity,
                ),
                _buildDropdownItem(
                  label: 'Connection Status',
                  value: _selectedConnectionStatus,
                  items: _connectionStatuses,
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedConnectionStatus = val);
                      _performSearch(resetPage: true);
                    }
                  },
                  width: isDesktop ? 200 : double.infinity,
                ),
                _buildDropdownItem(
                  label: 'Bill Status',
                  value: _selectedBillStatus,
                  items: _billStatuses,
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedBillStatus = val);
                      _performSearch(resetPage: true);
                    }
                  },
                  width: isDesktop ? 160 : double.infinity,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Second Row: Searchable Rate Type and Action Buttons
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SearchableSelectField(
                  label: 'Connection Rate / Type',
                  value: _selectedRateType,
                  items: _rateTypes,
                  allItemLabel: 'All Rate Types',
                  width: isDesktop ? 280 : double.infinity,
                  onChanged: (val) {
                    setState(() => _selectedRateType = val);
                    _performSearch(resetPage: true);
                  },
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('List Consumer'),
                  onPressed: () => _performSearch(resetPage: true),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text('Reset Filters'),
                  onPressed: _resetFilters,
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB71C1C),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.picture_as_pdf, size: 16),
                  label: const Text('Export PDF'),
                  onPressed: _openPdfExport,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Export CSV Backup'),
                  onPressed: _exportCsv,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.pin, size: 16),
                  label: const Text('Conn No CSV'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primaryGreen,
                    side: const BorderSide(color: AppTheme.primaryGreen),
                  ),
                  onPressed: () => _exportConnectionNumbers(onlyCurrentPage: false),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.history, size: 16),
                  label: const Text('Bill History'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF26522),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => BillHistoryDialog.show(
                    context: context,
                    connectionNo: _searchController.text.trim(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchCard(bool isDesktop) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                // Search By dropdown
                SizedBox(
                  width: isDesktop ? 180 : 130,
                  child: DropdownButtonFormField<String>(
                    initialValue: _searchBy,
                    decoration: const InputDecoration(
                      labelText: 'Search By',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('All Fields')),
                      DropdownMenuItem(value: 'consumer_name', child: Text('Consumer Name')),
                      DropdownMenuItem(value: 'father_husband_name', child: Text('F/H Name')),
                      DropdownMenuItem(value: 'mobile', child: Text('Mobile No')),
                      DropdownMenuItem(value: 'connection_no', child: Text('Connection No')),
                      DropdownMenuItem(value: 'old_connection_no', child: Text('Old Conn No')),
                      DropdownMenuItem(value: 'locality', child: Text('Locality')),
                      DropdownMenuItem(value: 'address', child: Text('Address')),
                      DropdownMenuItem(value: 'order_no', child: Text('Order / Reg No')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _searchBy = val);
                        _performSearch(resetPage: true);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                // Search Text Field with Auto-Capitalization and Voice Search (Mic)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: (_isVoiceListening || _isVoiceProcessing)
                              ? [
                                  BoxShadow(
                                    color: _isVoiceProcessing
                                        ? AppTheme.primaryGreen.withValues(alpha: 0.35)
                                        : Colors.red.withValues(alpha: 0.35),
                                    blurRadius: 10,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : null,
                        ),
                        child: TextField(
                          controller: _searchController,
                          textCapitalization: TextCapitalization.characters,
                          inputFormatters: [UpperCaseTextFormatter()],
                          decoration: InputDecoration(
                            hintText: _isVoiceProcessing
                                ? 'Recognizing speech offline...'
                                : (_isVoiceListening
                                    ? _voiceListeningStatus
                                    : 'Type letters e.g. G, GH, FAH, ASLAM, 0401... (Auto-Capitalized)'),
                            hintStyle: TextStyle(
                              color: _isVoiceProcessing
                                  ? AppTheme.primaryGreen
                                  : (_isVoiceListening ? Colors.red.shade700 : Colors.grey.shade600),
                              fontWeight: (_isVoiceListening || _isVoiceProcessing)
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                            prefixIcon: _isVoiceProcessing
                                ? Container(
                                    padding: const EdgeInsets.all(12),
                                    child: const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: AppTheme.primaryGreen,
                                      ),
                                    ),
                                  )
                                : (_isVoiceListening
                                    ? ScaleTransition(
                                        scale: _micPulseAnimation,
                                        child: const Icon(Icons.record_voice_over, size: 20, color: Colors.red),
                                      )
                                    : const Icon(Icons.search, size: 20, color: AppTheme.primaryGreen)),
                            suffixIcon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_searchController.text.isNotEmpty && !_isVoiceListening && !_isVoiceProcessing)
                                  IconButton(
                                    icon: const Icon(Icons.clear, size: 18),
                                    tooltip: 'Clear',
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _suggestions = []);
                                      _performSearch(resetPage: true);
                                    },
                                  ),
                                IconButton(
                                  icon: _isVoiceProcessing
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppTheme.primaryGreen,
                                          ),
                                        )
                                      : (_isVoiceListening
                                          ? ScaleTransition(
                                              scale: _micPulseAnimation,
                                              child: Container(
                                                padding: const EdgeInsets.all(4),
                                                decoration: const BoxDecoration(
                                                  color: Colors.red,
                                                  shape: BoxShape.circle,
                                                ),
                                                child: const Icon(Icons.stop, color: Colors.white, size: 16),
                                              ),
                                            )
                                          : const Icon(Icons.mic_none, color: AppTheme.primaryGreen, size: 20)),
                                  tooltip: _isVoiceListening
                                      ? 'Stop & Search'
                                      : 'Offline Voice Search',
                                  onPressed: _toggleVoiceSearch,
                                ),
                                const SizedBox(width: 4),
                              ],
                            ),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            enabledBorder: (_isVoiceListening || _isVoiceProcessing)
                                ? OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                      color: _isVoiceProcessing ? AppTheme.primaryGreen : Colors.red,
                                      width: 2,
                                    ),
                                  )
                                : null,
                            focusedBorder: (_isVoiceListening || _isVoiceProcessing)
                                ? OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                      color: _isVoiceProcessing ? AppTheme.primaryGreen : Colors.red,
                                      width: 2,
                                    ),
                                  )
                                : null,
                          ),
                          readOnly: _isVoiceListening || _isVoiceProcessing,
                          onChanged: _onSearchChanged,
                          onSubmitted: (_) {
                            if (_isVoiceListening) {
                              _stopVoiceSearch(triggerSearch: true);
                            } else {
                              setState(() => _suggestions = []);
                              _performSearch(resetPage: true);
                            }
                          },
                        ),
                      ),

                      if (_lastVoiceTranscript != null && !_isVoiceListening && !_isVoiceProcessing)
                        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                          Text('Heard: $_lastVoiceTranscript'),
                          TextButton.icon(
                            onPressed: _rememberVoiceCorrection,
                            icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                            label: const Text('Remember corrected name / filters'),
                          ),
                        ]),
                      // Recording and recognition status
                      if (_isVoiceListening || _isVoiceProcessing) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: _isVoiceProcessing
                                  ? [Colors.green.shade50, Colors.teal.shade50]
                                  : [Colors.red.shade50, Colors.green.shade50],
                            ),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: _isVoiceProcessing ? Colors.green.shade300 : Colors.red.shade200,
                            ),
                          ),
                          child: Row(
                            children: [
                              if (_isVoiceProcessing)
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.primaryGreen,
                                  ),
                                )
                              else
                                ScaleTransition(
                                  scale: _micPulseAnimation,
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _voiceListeningStatus,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: _isVoiceProcessing ? AppTheme.primaryGreen : Colors.red,
                                  ),
                                ),
                              ),
                              if (!_isVoiceProcessing) ...[
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryGreen,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  icon: const Icon(Icons.check, size: 14),
                                  label: const Text('Search', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                  onPressed: _voiceStarting ? null : () => _stopVoiceSearch(triggerSearch: true),
                                ),
                                const SizedBox(width: 6),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.grey.shade700,
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: _voiceStarting ? null : _cancelVoiceSearch,
                                  child: const Text('Cancel', style: TextStyle(fontSize: 11)),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),

            // Live Autocomplete Suggestions Box with Yellow Highlighting
            if (_suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(15),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.auto_awesome, size: 14, color: AppTheme.primaryGreen),
                          const SizedBox(width: 6),
                          Text(
                            'Suggestions for "${_searchController.text}" — click to search',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                          ),
                          const Spacer(),
                          InkWell(
                            onTap: () => setState(() => _suggestions = []),
                            child: const Icon(Icons.close, size: 14, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _suggestions.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (ctx, idx) {
                          final suggestion = _suggestions[idx];
                          return InkWell(
                            hoverColor: AppTheme.primaryGreen.withAlpha(20),
                            onTap: () {
                              _searchController.text = suggestion;
                              _searchController.selection = TextSelection.fromPosition(
                                TextPosition(offset: suggestion.length),
                              );
                              setState(() => _suggestions = []);
                              _performSearch(resetPage: true);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  const Icon(Icons.search, size: 16, color: Colors.grey),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _buildHighlightedText(
                                      text: suggestion,
                                      query: _searchController.text,
                                      baseStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primaryGreen.withAlpha(25),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Select ↵',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: AppTheme.primaryGreen,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownItem({
    required String label,
    required String value,
    required List<String> items,
    required void Function(String?) onChanged,
    required double width,
  }) {
    final safeValue = items.contains(value) ? value : items.first;

    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        initialValue: safeValue,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        items: items.map((item) {
          return DropdownMenuItem<String>(
            value: item,
            child: Text(
              item,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          );
        }).toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildSortIndicator(String columnId) {
    final isActive = _connSortOrder != 'none';
    final isAsc = _connSortOrder == 'asc';
    return Icon(
      isActive ? (isAsc ? Icons.arrow_upward : Icons.arrow_downward) : Icons.unfold_more,
      size: 14,
      color: isActive ? Colors.white : Colors.white.withValues(alpha: 0.4),
    );
  }

  Widget _buildConnNoHeaderActions() {
    return Theme(
      data: Theme.of(context).copyWith(
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: PopupMenuButton<String>(
        tooltip: 'Export / Copy Connection Numbers',
        icon: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(
            Icons.file_download_outlined,
            size: 15,
            color: Colors.white,
          ),
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        splashRadius: 14,
        onSelected: (value) {
          if (value == 'csv_all') {
            _exportConnectionNumbers(onlyCurrentPage: false);
          } else if (value == 'csv_page') {
            _exportConnectionNumbers(onlyCurrentPage: true);
          } else if (value == 'copy_all') {
            _copyConnectionNumbers(onlyCurrentPage: false);
          } else if (value == 'copy_page') {
            _copyConnectionNumbers(onlyCurrentPage: true);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'csv_all',
            child: Row(
              children: [
                const Icon(Icons.file_download, size: 18, color: AppTheme.primaryGreen),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Download CSV (All ${_totalCount > 0 ? _totalCount : _consumers.length})',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'csv_page',
            child: Row(
              children: [
                const Icon(Icons.download, size: 18, color: Colors.blueGrey),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Download CSV (Current Page: ${_consumers.length})',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'copy_all',
            child: Row(
              children: [
                const Icon(Icons.copy_all, size: 18, color: AppTheme.primaryGreen),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Copy All to Clipboard (${_totalCount > 0 ? _totalCount : _consumers.length})',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'copy_page',
            child: Row(
              children: [
                const Icon(Icons.copy, size: 18, color: Colors.blueGrey),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Copy Current Page (${_consumers.length})',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsTable(bool isDesktop) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen)),
      );
    }

    final displayConsumers = _sortedConsumers;

    if (displayConsumers.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Center(
            child: Column(
              children: [
                Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                const Text(
                  'No Records Found',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Try modifying your filters or search keywords.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!isDesktop) {
      // Mobile / Compact Card View
      return ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: displayConsumers.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (ctx, idx) {
          final c = displayConsumers[idx];
          final s = c.billStatus.toLowerCase().trim();
          final isPaid = s.contains('paid') && !s.contains('un');

          return Card(
            color: isPaid ? AppTheme.tableRowPaid : null,
            child: ListTile(
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      c.consumerName.isNotEmpty ? c.consumerName : 'N/A',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  _buildStatusChip(c.consumerStatus, isConsumer: true),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text('F/H: ${c.fatherHusbandName.isNotEmpty ? c.fatherHusbandName : "N/A"} • Mobile: ${c.mobile}'),
                  Text('Conn #${c.connectionNo} (Old: ${c.oldConnectionNo}) • Date: ${c.connectionDate}'),
                  Text('Locality: ${c.locality}'),
                ],
              ),
              trailing: IconButton(
                icon: const Icon(Icons.remove_red_eye, color: AppTheme.primaryGreen),
                onPressed: () => ConsumerDetailDialog.show(context, c),
              ),
            ),
          );
        },
      );
    }

    final colMap = {for (var c in _getTableColumns()) c.id: c};
    final orderedCols = _columnOrder
        .where((id) => colMap.containsKey(id))
        .map((id) => colMap[id]!)
        .toList();
    final activeColumns = orderedCols
        .where((col) => _visibleColumnIds.contains(col.id))
        .toList();

    // Desktop Full Responsive Table with Dedicated Horizontal & Vertical Scroll Controls
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Table Top Bar with Quick Scroll Buttons & Column Customization
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              border: const Border(bottom: BorderSide(color: Color(0xFFE0E0E0))),
            ),
            child: Row(
              children: [
                const Icon(Icons.table_chart, size: 16, color: AppTheme.primaryGreen),
                const SizedBox(width: 8),
                Text(
                  'Consumer Records (${activeColumns.length}/${_defaultColumnOrder.length} Columns)',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.darkGreen),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.tune_rounded, size: 15, color: AppTheme.primaryGreen),
                  label: Text(
                    'Reorder & Columns (${activeColumns.length})',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.darkGreen),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                  ),
                  onPressed: _showColumnReorderAndVisibilityDialog,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Tip: Scroll horizontally to view all columns • Click icon to copy',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                // Scroll navigation buttons
                OutlinedButton.icon(
                  icon: const Icon(Icons.arrow_back, size: 14),
                  label: const Text('Start', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () {
                    _horizontalScrollCtrl.animateTo(
                      0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  },
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.arrow_forward, size: 14),
                  label: const Text('End ▶', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () {
                    _horizontalScrollCtrl.animateTo(
                      _horizontalScrollCtrl.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  },
                ),
              ],
            ),
          ),

          if (activeColumns.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.view_column_outlined, size: 48, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    const Text(
                      'All Columns Hidden',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'You have deselected all columns. Click below to restore table columns.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _visibleColumnIds = Set<String>.from(_defaultColumnOrder);
                        });
                        _saveColumnPreferences();
                      },
                      icon: const Icon(Icons.restore, size: 16),
                      label: const Text('Show All Columns'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryGreen,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            // Responsive DataTable with flexible column widths
            LayoutBuilder(
              builder: (context, constraints) {
                DataColumn buildDataColumn(_TableColumnConfig col) {
                  final isConnNo = col.id == 'connection_no';
                  return DataColumn(
                    label: SizedBox(
                      width: col.width,
                      child: Row(
                        children: [
                          if (isConnNo) ...[
                            Flexible(child: col.column.label),
                            const SizedBox(width: 4),
                            _buildSortIndicator(col.id),
                            const Spacer(),
                            _buildConnNoHeaderActions(),
                          ] else
                            col.column.label,
                        ],
                      ),
                    ),
                    tooltip: col.column.tooltip,
                    onSort: isConnNo ? (_, _) => _toggleConnSort() : null,
                  );
                }

                DataCell buildDataCell(_TableColumnConfig col, Consumer c) {
                  final cell = col.cellBuilder(c);
                  return DataCell(
                    Container(
                      width: col.width,
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: AppTheme.tableBorder, width: 1)),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                      child: cell.child,
                    ),
                  );
                }

                return Scrollbar(
                  controller: _horizontalScrollCtrl,
                  thumbVisibility: true,
                  trackVisibility: true,
                  thickness: 10,
                  radius: const Radius.circular(5),
                  child: SingleChildScrollView(
                    controller: _horizontalScrollCtrl,
                    scrollDirection: Axis.horizontal,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 2100,
                      ),
                      child: DataTable(
                        columnSpacing: 8,
                        horizontalMargin: 10,
                        headingRowHeight: 40,
                        dataRowMinHeight: 48,
                        dataRowMaxHeight: 56,
                        headingRowColor: WidgetStateProperty.all(AppTheme.tableHeaderGreen),
                        headingTextStyle: const TextStyle(
                          color: AppTheme.tableHeaderText,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          letterSpacing: 0.3,
                        ),
                        border: TableBorder(
                          bottom: const BorderSide(color: AppTheme.tableBorder, width: 1),
                        ),
                        columns: activeColumns.map(buildDataColumn).toList(),
                        rows: displayConsumers.asMap().entries.map((entry) {
                          final idx = entry.key;
                          final c = entry.value;
                          final s = c.billStatus.toLowerCase().trim();
                          final isPaid = s.contains('paid') && !s.contains('un');

                          return DataRow(
                            color: WidgetStateProperty.resolveWith((states) {
                              if (states.contains(WidgetState.hovered)) {
                                return isPaid ? AppTheme.tableRowPaidHover : AppTheme.tableRowHover;
                              }
                              if (isPaid) {
                                return AppTheme.tableRowPaid;
                              }
                              return idx.isEven ? AppTheme.tableRowEven : AppTheme.tableRowOdd;
                            }),
                            cells: activeColumns.map((col) => buildDataCell(col, c)).toList(),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  List<_TableColumnConfig> _getTableColumns() {
    return [
      _TableColumnConfig(
        id: 'sr_no',
        label: 'Sr #',
        width: 40,
        column: const DataColumn(
          label: SizedBox(
            width: 40,
            child: Text('Sr #', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 40,
            child: Text(
              c.srNo.toString(),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.tableText),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'consumer_name',
        label: 'Consumer Name',
        width: 190,
        column: const DataColumn(
          label: SizedBox(
            width: 190,
            child: Text(
              'CONSUMER NAME',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 190,
            child: Tooltip(
              message: c.consumerName,
              child: Row(
                children: [
                  Expanded(
                    child: _buildHighlightedText(
                      text: c.consumerName.toUpperCase(),
                      query: _searchController.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      baseStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.tableText),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Tooltip(
                    message: 'Copy Name',
                    child: InkWell(
                      onTap: () => _copyText(c.consumerName, 'Consumer Name'),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.copy, size: 14, color: Colors.grey.shade400),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'father_husband_name',
        label: 'F/H Name',
        width: 170,
        column: const DataColumn(
          label: SizedBox(
            width: 170,
            child: Text(
              'F/H NAME',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 170,
            child: Tooltip(
              message: c.fatherHusbandName.isNotEmpty ? c.fatherHusbandName : '-',
              child: _buildHighlightedText(
                text: c.fatherHusbandName.isNotEmpty ? c.fatherHusbandName.toUpperCase() : '-',
                query: _searchController.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                baseStyle: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'total_bill',
        label: 'Total Bill',
        width: 105,
        column: const DataColumn(
          label: SizedBox(
            width: 105,
            child: Text('TOTAL BILL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
          tooltip: 'Total Bill & Water Sanitation History',
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 105,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      c.totalBill.isNotEmpty
                          ? (c.totalBill.contains('.')
                              ? c.totalBill.split('.')[0].replaceAll(RegExp(r'[^0-9-]'), '')
                              : c.totalBill.replaceAll(RegExp(r'[^0-9-]'), ''))
                          : '-',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.billAmountTeal,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'View Water Sanitation Bill History',
                  child: InkWell(
                    onTap: () => BillHistoryDialog.show(
                      context: context,
                      connectionNo: c.connectionNo,
                    ),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF26522).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(
                        Icons.history,
                        size: 15,
                        color: Color(0xFFF26522),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'mobile',
        label: 'Mobile',
        width: 140,
        column: const DataColumn(
          label: SizedBox(
            width: 140,
            child: Text('MOBILE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 140,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    c.mobile.isNotEmpty ? c.mobile : '-',
                    style: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.visible,
                    softWrap: false,
                  ),
                ),
                if (c.mobile.isNotEmpty && c.mobile != '00000000000') ...[
                  const SizedBox(width: 6),
                  Tooltip(
                    message: 'Copy Mobile',
                    child: InkWell(
                      onTap: () => _copyText(c.mobile, 'Mobile'),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.copy, size: 14, color: Colors.grey.shade400),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'sector',
        label: 'Sector',
        width: 180,
        column: const DataColumn(
          label: SizedBox(
            width: 180,
            child: Text(
              'SECTOR',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 180,
            child: Tooltip(
              message: c.sector,
              child: _buildHighlightedText(
                text: c.sector,
                query: _searchController.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                baseStyle: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'locality',
        label: 'Locality',
        width: 160,
        column: const DataColumn(
          label: SizedBox(
            width: 160,
            child: Text(
              'LOCALITY',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 160,
            child: Tooltip(
              message: c.locality,
              child: _buildHighlightedText(
                text: c.locality,
                query: _searchController.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                baseStyle: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'address',
        label: 'Address',
        width: 220,
        column: const DataColumn(
          label: SizedBox(
            width: 220,
            child: Text(
              'ADDRESS',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 220,
            child: Tooltip(
              message: c.address,
              child: _buildHighlightedText(
                text: c.address,
                query: _searchController.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                baseStyle: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'fine',
        label: 'Fine',
        width: 70,
        column: const DataColumn(
          label: SizedBox(
            width: 70,
            child: Text('FINE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 70,
            child: Text(
              c.fine.isNotEmpty ? c.fine : '-',
              style: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'after_due_date',
        label: 'After Due Date',
        width: 100,
        column: const DataColumn(
          label: SizedBox(
            width: 100,
            child: Text('AFT. DUE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
          tooltip: 'After Due Date Amount',
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 100,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                c.afterDueDate.isNotEmpty ? c.afterDueDate : '-',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.afterDueOrange,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'due_date',
        label: 'Due Date',
        width: 120,
        column: const DataColumn(
          label: SizedBox(
            width: 120,
            child: Text('DUE DATE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 120,
            child: Text(
              c.dueDate.isNotEmpty ? c.dueDate : '-',
              style: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'bill_status',
        label: 'Bill Status',
        width: 110,
        column: const DataColumn(
          label: SizedBox(
            width: 110,
            child: Text('BILL STATUS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 110,
            child: Center(child: _buildBillStatusText(c.billStatus)),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'amount_received',
        label: 'Amount Received',
        width: 90,
        column: const DataColumn(
          label: SizedBox(
            width: 90,
            child: Text('AMT. RECEIVED', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
          tooltip: 'Amount Received',
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 90,
            child: Text(
              c.amountReceived.isNotEmpty ? c.amountReceived : '-',
              style: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'connection_no',
        label: 'Connection No',
        width: 145,
        column: const DataColumn(
          label: Text(
            'CONN NO',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          tooltip: 'Connection Number',
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 145,
            child: Row(
              children: [
                Expanded(
                  child: _buildHighlightedText(
                    text: c.connectionNo,
                    query: _searchController.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    baseStyle: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: AppTheme.connNoBlue,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Copy Connection No',
                  child: InkWell(
                    onTap: () => _copyText(c.connectionNo, 'Connection No'),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.copy, size: 14, color: Colors.grey.shade400),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'old_connection_no',
        label: 'Old Conn No',
        width: 110,
        column: const DataColumn(
          label: SizedBox(
            width: 110,
            child: Text(
              'OLD CONN',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          tooltip: 'Old Connection Number',
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 110,
            child: Row(
              children: [
                Expanded(
                  child: _buildHighlightedText(
                    text: c.oldConnectionNo.isNotEmpty ? c.oldConnectionNo : '-',
                    query: _searchController.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    baseStyle: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
                  ),
                ),
                if (c.oldConnectionNo.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Tooltip(
                    message: 'Copy Old Connection No',
                    child: InkWell(
                      onTap: () => _copyText(c.oldConnectionNo, 'Old Connection No'),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.copy, size: 14, color: Colors.grey.shade400),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'rate_type',
        label: 'Rate Type',
        width: 140,
        column: const DataColumn(
          label: SizedBox(
            width: 140,
            child: Text(
              'RATE TYPE',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 140,
            child: Tooltip(
              message: c.rateType,
              child: Text(
                c.rateType,
                style: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'order_no',
        label: 'Order / Reg No',
        width: 65,
        column: const DataColumn(
          label: SizedBox(
            width: 65,
            child: Text(
              'ORDER NO',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          tooltip: 'Order / Registration Number',
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 65,
            child: Tooltip(
              message: c.orderNo.isNotEmpty ? c.orderNo : '-',
              child: _buildHighlightedText(
                text: c.orderNo.isNotEmpty ? c.orderNo : '-',
                query: _searchController.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                baseStyle: const TextStyle(fontSize: 12, color: AppTheme.tableText, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'connection_date',
        label: 'Date (DD-MM-YYYY)',
        width: 120,
        column: const DataColumn(
          label: SizedBox(
            width: 120,
            child: Text('DATE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
          tooltip: 'Connection Date (DD-MM-YYYY)',
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 120,
            child: Tooltip(
              message: c.connectionDate,
              child: Text(
                c.connectionDate,
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12, color: AppTheme.tableText),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'connection_status',
        label: 'Status',
        width: 110,
        column: const DataColumn(
          label: SizedBox(
            width: 110,
            child: Text('STATUS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
          tooltip: 'Connection Status',
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 110,
            child: Center(child: _buildStatusText(c.connectionStatus)),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'consumer_status',
        label: 'Consumer Status',
        width: 110,
        column: const DataColumn(
          label: SizedBox(
            width: 110,
            child: Text('CONSUMER', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
          tooltip: 'Consumer Status',
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 110,
            child: Center(child: _buildStatusText(c.consumerStatus, isConsumer: true)),
          ),
        ),
      ),
      _TableColumnConfig(
        id: 'actions',
        label: 'Actions',
        width: 48,
        column: const DataColumn(
          label: SizedBox(
            width: 48,
            child: Center(child: Text('ACTION', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3))),
          ),
        ),
        cellBuilder: (c) => DataCell(
          SizedBox(
            width: 48,
            child: Center(
              child: InkWell(
                onTap: () => ConsumerDetailDialog.show(context, c),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.more_horiz, size: 18, color: Colors.grey.shade600),
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  void _showColumnReorderAndVisibilityDialog() {
    final colMap = {for (var c in _getTableColumns()) c.id: c};
    final tempOrder = List<String>.from(_columnOrder);
    final tempSelected = Set<String>.from(_visibleColumnIds);

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final allSelected = tempSelected.length == tempOrder.length;

          void moveItem(int fromIndex, int toIndex) {
            if (toIndex < 0 || toIndex >= tempOrder.length) return;
            setDialogState(() {
              final item = tempOrder.removeAt(fromIndex);
              tempOrder.insert(toIndex, item);
            });
          }

          return AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.tune_rounded, color: AppTheme.primaryGreen),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Customize & Reorder Columns',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Drag or click ▲ ▼ to set column order. Uncheck to hide columns.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.lightGreen,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${tempSelected.length} / ${tempOrder.length} Visible',
                    style: const TextStyle(
                      color: AppTheme.darkGreen,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 580,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        icon: Icon(
                          allSelected ? Icons.deselect : Icons.select_all,
                          size: 16,
                          color: AppTheme.primaryGreen,
                        ),
                        label: Text(
                          allSelected ? 'Deselect All' : 'Select All',
                          style: const TextStyle(fontSize: 12, color: AppTheme.primaryGreen),
                        ),
                        onPressed: () {
                          setDialogState(() {
                            if (allSelected) {
                              tempSelected.removeWhere((id) => !_lockedColumns.contains(id));
                              if (tempSelected.length < 3) {
                                for (final id in _defaultColumnOrder) {
                                  tempSelected.add(id);
                                  if (tempSelected.length >= 3) break;
                                }
                              }
                            } else {
                              tempSelected.addAll(tempOrder);
                            }
                          });
                        },
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.restart_alt, size: 16, color: Colors.grey),
                        label: const Text(
                          'Reset Default Order & All',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        onPressed: () {
                          setDialogState(() {
                            tempOrder.clear();
                            tempOrder.addAll(_defaultColumnOrder);
                            tempSelected.clear();
                            tempSelected.addAll(_defaultColumnOrder);
                          });
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 6),
                  Container(
                    height: 390,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: tempOrder.length,
                        // ignore: deprecated_member_use
                        onReorder: (oldIndex, newIndex) {
                          setDialogState(() {
                            if (newIndex > oldIndex) {
                              newIndex -= 1;
                            }
                            final item = tempOrder.removeAt(oldIndex);
                            tempOrder.insert(newIndex, item);
                          });
                        },
                        itemBuilder: (ctx, index) {
                          final colId = tempOrder[index];
                          final col = colMap[colId];
                          final label = col?.label ?? colId;
                          final isSelected = tempSelected.contains(colId);

                          return Container(
                            key: ValueKey(colId),
                            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.white : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected ? Colors.grey.shade300 : Colors.grey.shade200,
                              ),
                              boxShadow: isSelected
                                  ? [
                                      BoxShadow(
                                        color: Colors.black.withAlpha(8),
                                        blurRadius: 3,
                                        offset: const Offset(0, 1),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Row(
                                children: [
                                  // Position indicator #1, #2, etc.
                                  Container(
                                    width: 28,
                                    height: 28,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isSelected ? AppTheme.primaryGreen : Colors.grey.shade400,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Text(
                                      '${index + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),

                                  // Visibility Checkbox
                                  Checkbox(
                                    value: isSelected,
                                    activeColor: AppTheme.primaryGreen,
                                    onChanged: (checked) {
                                      setDialogState(() {
                                        if (checked == true) {
                                          tempSelected.add(colId);
                                        } else {
                                          if (tempSelected.length <= 3 && _lockedColumns.contains(colId)) return;
                                          if (tempSelected.length <= 3) return;
                                          tempSelected.remove(colId);
                                        }
                                      });
                                    },
                                  ),

                                  // Column Name / Label
                                  Expanded(
                                    child: InkWell(
                                      onTap: () {
                                        setDialogState(() {
                                          if (isSelected) {
                                            if (tempSelected.length <= 3 && _lockedColumns.contains(colId)) return;
                                            if (tempSelected.length <= 3) return;
                                            tempSelected.remove(colId);
                                          } else {
                                            tempSelected.add(colId);
                                          }
                                        });
                                      },
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              label,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                                color: isSelected ? Colors.black87 : Colors.grey.shade500,
                                                decoration: isSelected ? null : TextDecoration.lineThrough,
                                              ),
                                            ),
                                          ),
                                          if (_lockedColumns.contains(colId))
                                            const Padding(
                                              padding: EdgeInsets.only(left: 4),
                                              child: Icon(Icons.lock, size: 12, color: Colors.grey),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // Move Up Button (▲)
                                  IconButton(
                                    icon: const Icon(Icons.arrow_upward, size: 16),
                                    tooltip: 'Move Up',
                                    color: index > 0 ? AppTheme.primaryGreen : Colors.grey.shade300,
                                    splashRadius: 18,
                                    onPressed: index > 0 ? () => moveItem(index, index - 1) : null,
                                  ),

                                  // Move Down Button (▼)
                                  IconButton(
                                    icon: const Icon(Icons.arrow_downward, size: 16),
                                    tooltip: 'Move Down',
                                    color: index < tempOrder.length - 1 ? AppTheme.primaryGreen : Colors.grey.shade300,
                                    splashRadius: 18,
                                    onPressed: index < tempOrder.length - 1 ? () => moveItem(index, index + 1) : null,
                                  ),

                                  // Drag Handle for mouse drag
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.grab,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        child: Icon(Icons.drag_indicator, size: 20, color: Colors.grey.shade500),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Apply Order & Visibility'),
                onPressed: () {
                  setState(() {
                    _columnOrder = List<String>.from(tempOrder);
                    _visibleColumnIds = Set<String>.from(tempSelected);
                  });
                  _saveColumnPreferences();
                  Navigator.pop(ctx);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusChip(String status, {bool isConsumer = false}) {
    final clean = status.trim().toLowerCase();
    Color bg = Colors.grey.shade200;
    Color fg = Colors.grey.shade800;

    if (isConsumer) {
      if (clean == 'active') {
        bg = AppTheme.statusActiveBg;
        fg = AppTheme.statusActiveText;
      } else {
        bg = AppTheme.statusInactiveBg;
        fg = AppTheme.statusInactiveText;
      }
    } else {
      if (clean.contains('regular')) {
        bg = AppTheme.statusActiveBg;
        fg = AppTheme.statusActiveText;
      } else if (clean.contains('closed') || clean.contains('dead')) {
        bg = AppTheme.statusInactiveBg;
        fg = AppTheme.statusInactiveText;
      } else if (clean.contains('suspend')) {
        bg = AppTheme.statusSuspendedBg;
        fg = AppTheme.statusSuspendedText;
      } else if (clean.contains('demand')) {
        bg = AppTheme.statusNewDemandBg;
        fg = AppTheme.statusNewDemandText;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        status.isNotEmpty ? status : 'N/A',
        style: TextStyle(color: fg, fontSize: 9.5, fontWeight: FontWeight.bold),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildStatusText(String status, {bool isConsumer = false}) {
    final clean = status.trim().toLowerCase();
    Color fg = AppTheme.tableText;

    if (isConsumer) {
      if (clean == 'active') {
        fg = AppTheme.statusActive;
      } else if (clean == 'inactive' || clean == 'in-active' || clean.contains('closed')) {
        fg = AppTheme.statusInactive;
      }
    } else {
      if (clean.contains('regular')) {
        fg = AppTheme.statusActive;
      } else if (clean.contains('closed') || clean.contains('dead') || clean.contains('inactive') || clean.contains('in-active')) {
        fg = AppTheme.statusInactive;
      } else if (clean.contains('demand')) {
        fg = AppTheme.statusNewDemand;
      } else if (clean.contains('suspend')) {
        fg = AppTheme.statusSuspendedText;
      }
    }

    return Text(
      status.isNotEmpty ? status.toUpperCase() : 'N/A',
      style: TextStyle(
        color: fg,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildBillStatusText(String status) {
    final clean = status.trim().toLowerCase();
    Color fg = AppTheme.tableText;

    if (clean == 'paid') {
      fg = AppTheme.statusActive;
    } else if (clean.contains('un-paid') || clean.contains('unpaid') || clean.contains('expired')) {
      fg = AppTheme.statusInactive;
    } else if (clean.contains('partial')) {
      fg = AppTheme.statusSuspendedText;
    }

    return Text(
      status.isNotEmpty ? status.toUpperCase() : '-',
      style: TextStyle(
        color: fg,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildPaginationFooter() {
    final totalPages = (_totalCount / _pageSize).ceil();
    final startIdx = _totalCount == 0 ? 0 : (_currentPage - 1) * _pageSize + 1;
    final endIdx = (_currentPage * _pageSize > _totalCount) ? _totalCount : _currentPage * _pageSize;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE0E0E0))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Items per page selector
          Row(
            children: [
              const Text('Items per page: ', style: TextStyle(fontSize: 12, color: Colors.grey)),
              DropdownButton<int>(
                value: _pageSize,
                underline: const SizedBox(),
                isDense: true,
                items: _pageSizeOptions.map((sz) {
                  return DropdownMenuItem<int>(
                    value: sz,
                    child: Text('$sz', style: const TextStyle(fontSize: 12)),
                  );
                }).toList(),
                onChanged: (newSize) {
                  if (newSize != null) {
                    setState(() {
                      _pageSize = newSize;
                      _currentPage = 1;
                    });
                    _performSearch(resetPage: true);
                  }
                },
              ),
              const SizedBox(width: 16),
              Text(
                '$startIdx - $endIdx of $_totalCount',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87),
              ),
            ],
          ),

          // Pagination buttons
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.first_page, size: 20),
                tooltip: 'First Page',
                onPressed: _currentPage > 1
                    ? () {
                        setState(() => _currentPage = 1);
                        _performSearch();
                      }
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                tooltip: 'Previous Page',
                onPressed: _currentPage > 1
                    ? () {
                        setState(() => _currentPage--);
                        _performSearch();
                      }
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Page $_currentPage of ${totalPages > 0 ? totalPages : 1} (${_totalCount.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')} consumers)',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                tooltip: 'Next Page',
                onPressed: _currentPage < totalPages
                    ? () {
                        setState(() => _currentPage++);
                        _performSearch();
                      }
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.last_page, size: 20),
                tooltip: 'Last Page',
                onPressed: _currentPage < totalPages
                    ? () {
                        setState(() => _currentPage = totalPages);
                        _performSearch();
                      }
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
  Widget _buildHighlightedText({
    required String text,
    required String query,
    TextStyle? baseStyle,
    int? maxLines,
    TextOverflow? overflow,
  }) {
    if (text.isEmpty) return const Text('-');
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return Text(
        text,
        style: baseStyle,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    final tokens = trimmed
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => RegExp.escape(t))
        .toList();

    if (tokens.isEmpty) {
      return Text(text, style: baseStyle, maxLines: maxLines, overflow: overflow);
    }

    final pattern = RegExp('(${tokens.join('|')})', caseSensitive: false);
    final spans = <TextSpan>[];
    int start = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > start) {
        spans.add(TextSpan(
          text: text.substring(start, match.start),
          style: baseStyle,
        ));
      }
      spans.add(TextSpan(
        text: text.substring(match.start, match.end),
        style: (baseStyle ?? const TextStyle()).copyWith(
          backgroundColor: const Color(0xFFFFEB3B), // Bright Yellow Highlight
          color: Colors.black,
          fontWeight: FontWeight.bold,
        ),
      ));
      start = match.end;
    }

    if (start < text.length) {
      spans.add(TextSpan(
        text: text.substring(start),
        style: baseStyle,
      ));
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  void _toggleVoiceSearch() {
    if (_voiceStarting || _isVoiceProcessing) return;
    if (_isVoiceListening) {
      _stopVoiceSearch();
    } else {
      _startVoiceSearch();
    }
  }

  void _voiceMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message), behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _startVoiceSearch() async {
    final session = ++_voiceSession;
    _debounceTimer?.cancel();
    setState(() {
      _voiceStarting = true;
      _isVoiceListening = true;
      _lastVoiceTranscript = null;
      _voiceListeningStatus = 'Preparing microphone...';
      _suggestions = [];
    });
    try {
      final exe = await WhisperService.instance.getWhisperExePath();
      final model = await WhisperService.instance.getModelPath();
      if (!mounted || session != _voiceSession) return;
      if (exe == null || model == null) {
        _voiceMessage('Offline speech files are missing. Restore Whisper and an English-capable model in assets/bin.');
        setState(() => _isVoiceListening = false);
        return;
      }
      final ok = await AudioRecorderService.instance.startRecording(
        onSpeechActive: () {
          if (mounted && session == _voiceSession && !_isVoiceProcessing) {
            setState(() => _voiceListeningStatus = 'Listening... Say the name and sector. Pause to search, or press Search.');
          }
        },
        onAutoStop: () {
          if (mounted && session == _voiceSession) _stopVoiceSearch();
        },
      );
      if (!mounted || session != _voiceSession) return;
      if (!ok) {
        setState(() => _isVoiceListening = false);
        _voiceMessage('Could not access microphone. Check Windows microphone permissions and input device.');
      } else {
        setState(() => _voiceListeningStatus = 'Speak in English: name, then sector. Press Search when finished (30-second limit).');
      }
    } catch (e) {
      if (mounted && session == _voiceSession) {
        setState(() => _isVoiceListening = false);
        _voiceMessage('Could not start voice search: $e');
      }
    } finally {
      if (mounted && session == _voiceSession) setState(() => _voiceStarting = false);
    }
  }

  Future<void> _stopVoiceSearch({bool triggerSearch = true}) async {
    if (!_isVoiceListening || _isVoiceProcessing || _voiceStarting) return;
    final session = _voiceSession;
    setState(() {
      _isVoiceProcessing = true;
      _voiceListeningStatus = 'Recognizing English offline...';
    });
    try {
      final wavPath = await AudioRecorderService.instance.stopRecording();
      if (!mounted || session != _voiceSession) return;
      if (wavPath == null || !await File(wavPath).exists()) {
        _voiceMessage('No recording was saved. Please check the microphone and try again.');
        return;
      }
      final result = await WhisperService.instance.transcribe(
        wavPath: wavPath, availableSectors: _sectors,
      );
      if (!mounted || session != _voiceSession) return;
      if (result == null || result.normalizedText.isEmpty) {
        _voiceMessage(WhisperService.instance.lastError ?? 'No clear name was recognized. Please try again.');
        return;
      }
      final db = DatabaseService.instance;
      final correction = await db.getVoiceCorrection(result.rawText);
      final allLocalities = await db.getLocalities();
      final placeVocabulary = VoiceVocabulary([..._sectors, ...allLocalities]);
      final phrase = correction ?? placeVocabulary.resolve(result.rawText);
      final parsed = SmartSearchParser.parse(phrase,
        availableSectors: _sectors, availableLocalities: allLocalities);
      final names = VoiceVocabulary(await db.getVoiceVocabulary(sector: parsed.detectedSector));
      final keyword = names.resolve(parsed.cleanKeywords);
      final localities = await db.getLocalities(sector: parsed.detectedSector);
      if (!mounted || session != _voiceSession) return;
      setState(() {
        _lastVoiceTranscript = result.rawText;
        _searchController.text = keyword;
        _searchController.selection = TextSelection.collapsed(offset: keyword.length);
        _searchBy = 'consumer_name';
        _voiceNameSearch = true;
        _selectedSector = parsed.detectedSector ?? 'All Sectors';
        _selectedLocality = parsed.detectedLocality ?? 'All Localities';
        _localities = ['All Localities', ...localities];
        _selectedConnectionStatus = parsed.detectedStatus ?? 'Regular Connection';
        _selectedConsumerStatus = 'All Statuses';
        _selectedRateType = 'All Rate Types';
        _suggestions = [];
      });
      if (triggerSearch) await _performSearch(resetPage: true);

    } catch (e) {
      _voiceMessage('Voice search failed: $e');
    } finally {
      if (mounted && session == _voiceSession) {
        setState(() { _isVoiceListening = false; _isVoiceProcessing = false; });
      }
    }
  }

  Future<void> _rememberVoiceCorrection() async {
    final spoken = _lastVoiceTranscript;
    if (spoken == null) return;
    final corrected = [
      _searchController.text.trim(),
      if (_selectedSector != 'All Sectors') _selectedSector,
      if (_selectedLocality != 'All Localities') _selectedLocality,
    ].where((s) => s.isNotEmpty).join(' ');
    if (corrected.isEmpty) {
      _voiceMessage('Enter the correct name or select its sector first.');
      return;
    }
    try {
      await DatabaseService.instance.rememberVoiceCorrection(spoken, corrected);
      _voiceMessage('Correction saved on this computer for this spoken phrase.');
    } catch (e) { _voiceMessage('Could not save the correction: $e'); }
  }

  void _cancelVoiceSearch() {
    ++_voiceSession;
    AudioRecorderService.instance.cancelRecording();
    setState(() {
      _voiceStarting = false;
      _isVoiceListening = false;
      _isVoiceProcessing = false;
    });
  }

}

class _TableColumnConfig {
  final String id;
  final String label;
  final double width;
  final DataColumn column;
  final DataCell Function(Consumer c) cellBuilder;

  const _TableColumnConfig({
    required this.id,
    required this.label,
    required this.width,
    required this.column,
    required this.cellBuilder,
  });
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

class _VoiceSearchDialog extends StatefulWidget {
  final List<String> availableSectors;
  final ValueChanged<WhisperTranscribeResult> onResult;
  final VoidCallback onCancel;

  const _VoiceSearchDialog({
    required this.availableSectors,
    required this.onResult,
    required this.onCancel,
  });

  @override
  State<_VoiceSearchDialog> createState() => _VoiceSearchDialogState();
}

class _VoiceSearchDialogState extends State<_VoiceSearchDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  bool _isRecording = false;
  bool _isTranscribing = false;
  bool _hasError = false;
  String _status = 'Initializing microphone...';
  int _elapsedSeconds = 0;
  Timer? _tickerTimer;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );

    _startRecording();
  }

  @override
  void dispose() {
    _animController.dispose();
    _tickerTimer?.cancel();
    AudioRecorderService.instance.stopRecording();
    super.dispose();
  }

  Future<void> _startRecording() async {
    _tickerTimer?.cancel();
    setState(() {
      _isRecording = true;
      _isTranscribing = false;
      _hasError = false;
      _elapsedSeconds = 0;
      _status = 'Listening... Say a name and sector, for example "Muhammad Aslam Ali Town".';
    });

    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _elapsedSeconds++);
    });

    final ok = await AudioRecorderService.instance.startRecording(
      onAutoStop: () {
        if (mounted && _isRecording) {
          _stopAndTranscribe();
        }
      },
    );

    if (!ok && mounted) {
      _tickerTimer?.cancel();
      setState(() {
        _isRecording = false;
        _hasError = true;
        _status = 'Microphone not accessible. Please check audio settings.';
      });
    }
  }

  Future<void> _stopAndTranscribe() async {
    _tickerTimer?.cancel();
    if (!_isRecording) return;

    setState(() {
      _isRecording = false;
      _isTranscribing = true;
      _status = 'Transcribing English with Offline Whisper...';
    });

    final wavPath = await AudioRecorderService.instance.stopRecording();
    if (wavPath == null || !File(wavPath).existsSync()) {
      if (mounted) {
        setState(() {
          _isTranscribing = false;
          _hasError = true;
          _status = 'No audio captured. Please try speaking again.';
        });
      }
      return;
    }

    try {
      final result = await WhisperService.instance.transcribe(
        wavPath: wavPath,
        availableSectors: widget.availableSectors,
      );

      if (!mounted) return;

      if (result != null && result.normalizedText.isNotEmpty) {
        widget.onResult(result);
      } else {
        setState(() {
          _isTranscribing = false;
          _hasError = true;
          _status = 'No speech detected in recording.\nPlease speak closer to the microphone and try again.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTranscribing = false;
          _hasError = true;
          _status = 'Error in offline speech recognition: $e';
        });
      }
    }
  }

  String _formatTime(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.mic, color: AppTheme.primaryGreen, size: 22),
                      SizedBox(width: 8),
                      Text(
                        'Offline Whisper Voice Search',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: widget.onCancel,
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Animated Recording / Transcribing Indicator
              if (_isTranscribing)
                Container(
                  width: 84,
                  height: 84,
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 54,
                    height: 54,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryGreen),
                    ),
                  ),
                )
              else
                ScaleTransition(
                  scale: _hasError || !_isRecording
                      ? const AlwaysStoppedAnimation(1.0)
                      : _scaleAnimation,
                  child: InkWell(
                    onTap: _isRecording ? _stopAndTranscribe : _startRecording,
                    borderRadius: BorderRadius.circular(45),
                    child: Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        color: _hasError
                            ? Colors.grey.shade300
                            : (_isRecording ? Colors.red.shade50 : AppTheme.primaryGreen.withAlpha(25)),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _hasError
                              ? Colors.grey
                              : (_isRecording ? Colors.red : AppTheme.primaryGreen),
                          width: 3,
                        ),
                      ),
                      child: Icon(
                        _hasError
                            ? Icons.mic_off
                            : (_isRecording ? Icons.mic : Icons.play_arrow),
                        color: _hasError
                            ? Colors.grey.shade700
                            : (_isRecording ? Colors.red : AppTheme.primaryGreen),
                        size: 40,
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              if (_isRecording)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Recording ${_formatTime(_elapsedSeconds)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 12),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _hasError ? Colors.red.shade700 : Colors.black87,
                ),
              ),

              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.offline_bolt, color: AppTheme.primaryGreen, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '100% Offline Whisper AI • No internet required • Pakistani Name Normalization',
                        style: TextStyle(fontSize: 11, color: Colors.black87, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: widget.onCancel,
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  if (_isRecording)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _stopAndTranscribe,
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('Stop & Search'),
                    )
                  else if (_hasError)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryGreen,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _startRecording,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Try Again'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
