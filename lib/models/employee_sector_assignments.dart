import 'dart:convert';
import 'package:flutter/services.dart';
import 'billing_audit_model.dart';

class EmployeeResponsibility {
  final List<String> employees;
  final String zone;
  const EmployeeResponsibility(this.employees, this.zone);
  String get label => employees.join(' / ');
  bool includes(String selection) =>
      label == selection || employees.contains(selection);
}

class EmployeeSectorAssignments {
  static const allEmployees = 'All employees';
  static const unassigned = 'Unassigned / review';
  static EmployeeSectorAssignments? _loaded;
  static Future<EmployeeSectorAssignments> load() async {
    if (_loaded != null) return _loaded!;
    final text = await rootBundle.loadString(
      'assets/data/employee_sector_assignments.json',
      cache: false,
    );
    return _loaded = EmployeeSectorAssignments.fromJson(jsonDecode(text));
  }

  final List<Map<String, dynamic>> _rules;
  final List<Map<String, dynamic>> _overrides;
  final List<Map<String, dynamic>> _aliases;
  final _bySector = <String, List<Map<String, dynamic>>>{};
  final _byLocality = <String, List<Map<String, dynamic>>>{};
  EmployeeSectorAssignments.fromJson(Map<String, dynamic> data)
    : _rules = List<Map<String, dynamic>>.from(data['assignments']),
      _overrides = List<Map<String, dynamic>>.from(
        data['connection_number_overrides'],
      ),
      _aliases = List<Map<String, dynamic>>.from(
        data['text_matching_aliases'],
      ) {
    for (final rule in _rules) {
      final sector = _name(rule['sector'] ?? '');
      final locality = _name(rule['locality'] ?? '');
      if (sector.isNotEmpty) (_bySector[sector] ??= []).add(rule);
      if (locality.isNotEmpty) (_byLocality[locality] ??= []).add(rule);
    }
  }

  List<String> get options {
    final values = <String>{};
    for (final rule in [..._rules, ..._overrides]) {
      final people = List<String>.from(rule['employees']);
      values.addAll(people);
      if (people.length > 1) values.add(people.join(' / '));
    }
    return [allEmployees, ...(values.toList()..sort()), unassigned];
  }

  static String _name(String text) => text
      .toLowerCase()
      .replaceFirst(RegExp(r'^\s*\d+\s*-\s*'), '')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  static String _zone(String text) =>
      RegExp(
        r'\bzone[\s\-",]*([abc])\b',
        caseSensitive: false,
      ).firstMatch(text)?.group(1)?.toUpperCase() ??
      '';

  EmployeeResponsibility? resolve(BillingAuditEntry entry) => resolveConnection(
    connectionNo: entry.connectionNo,
    sector: entry.sector,
    locality: entry.locality,
  );

  EmployeeResponsibility? resolveConnection({
    required String connectionNo,
    required String sector,
    required String locality,
  }) {
    final sectorKey = _name(sector), localityKey = _name(locality);
    final zone = _zone('$locality $sector');
    bool sameArea(Map<String, dynamic> rule) =>
        sectorKey.isNotEmpty && _name(rule['sector'] ?? '') == sectorKey ||
        localityKey.isNotEmpty && _name(rule['locality'] ?? '') == localityKey;
    final number = RegExp(r'^\d+$').hasMatch(connectionNo.trim())
        ? BigInt.tryParse(connectionNo.trim())
        : null;
    if (number == null && _overrides.any(sameArea)) return null;
    if (number != null) {
      for (final rule in _overrides) {
        final ruleZone = _zone('${rule['locality']}');
        if (!sameArea(rule) ||
            (zone.isNotEmpty && ruleZone.isNotEmpty && zone != ruleZone)) {
          continue;
        }
        final min = BigInt.parse(rule['connection_min']);
        final max = rule['connection_max'] == null
            ? null
            : BigInt.parse(rule['connection_max']);
        if (number >= min && (max == null || number <= max)) {
          return EmployeeResponsibility(
            List<String>.from(rule['employees']),
            ruleZone,
          );
        }
      }
    }
    var matches = [...?_bySector[sectorKey], ...?_byLocality[localityKey]];
    if (matches.isEmpty) {
      for (final alias in _aliases) {
        final key = _name(alias['match']);
        if ((sectorKey.contains(key) || localityKey.contains(key)) &&
            (zone.isEmpty || zone == alias['zone'])) {
          matches.addAll(
            _rules.where(
              (rule) =>
                  rule['source_staff_name'] == alias['staff_name'] &&
                  rule['zone'] == alias['zone'],
            ),
          );
        }
      }
    }
    // Zone disambiguates shared area names. Unique sector assignments remain
    // authoritative when imported locality labels have a conflicting zone.
    final inZone = matches.where((r) => r['zone'] == zone).toList();
    if (inZone.isNotEmpty) matches = inZone;
    final teams = <String, EmployeeResponsibility>{};
    for (final rule in matches) {
      final responsibility = EmployeeResponsibility(
        List<String>.from(rule['employees']),
        rule['zone'],
      );
      teams[responsibility.label] = responsibility;
    }
    return teams.length == 1 ? teams.values.single : null;
  }
}
