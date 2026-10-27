import 'dart:convert';
import 'dart:io';
import 'package:consumer_search_engine/models/employee_sector_assignments.dart';
import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/screens/billing_audit_screen.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:consumer_search_engine/widgets/billing_audit_pdf_dialog.dart';
import 'package:consumer_search_engine/widgets/searchable_select_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_backup_test.dart' show fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final data =
      jsonDecode(
            File(
              'assets/data/employee_sector_assignments.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final assignments = EmployeeSectorAssignments.fromJson(data);
  EmployeeResponsibility? owner(
    String sector, {
    String locality = '',
    String id = '1',
  }) => assignments.resolveConnection(
    connectionNo: id,
    sector: sector,
    locality: locality,
  );

  test(
    'individuals and shared pairs use source aliases without duplicate responsibility',
    () {
      expect(
        assignments.options,
        containsAll([
          'MUHAMMAD IRFAN',
          'ZULFIQAR',
          'MUHAMMAD IRFAN / ZULFIQAR',
          'MUHAMMAD TAHIR',
        ]),
      );
      final pair = owner('  MUHAMMAD CITY   (PRIVATE SOCIETY) ');
      expect(pair!.employees, ['MUHAMMAD IRFAN', 'ZULFIQAR']);
      expect(pair.includes('ZULFIQAR'), isTrue);
      expect(pair.includes('MUHAMMAD IRFAN / ZULFIQAR'), isTrue);
      expect(owner('Lala Zaar Colony')!.employees, [
        'MUHAMMAD KHALID',
        'MUHAMMAD NAZAR',
      ]);
      expect(owner('Gulbarg', locality: 'Zone A')!.label, 'MUHAMMAD TAHIR');
      expect(owner('Lalazar Colony', locality: 'Zone B')!.employees, [
        'MUHAMMAD KHALID',
        'MUHAMMAD NAZAR',
      ]);
      expect(owner('Unknown place'), isNull);
    },
  );

  test(
    'same sector in two zones is disambiguated; missing zone is unassigned',
    () {
      expect(
        owner('ALHARAM CITY', locality: 'Alharam City Zone A')!.label,
        'TAUSEEF / GOSHI IBRAHIM',
      );
      expect(
        owner('ALHARAM CITY', locality: 'Alharam City Zone B')!.label,
        'MUHAMMAD KHALID / MUHAMMAD NAZAR',
      );
      expect(owner('ALHARAM CITY'), isNull);
      expect(owner('ALHARAM CITY', locality: 'Zone C'), isNull);
    },
  );

  test(
    'connection ranges take precedence, preserve zero prefixes and apply only to their area',
    () {
      expect(
        owner('Mahboob Colony (SHARQI)', id: '12020560')!.label,
        'MUHAMMAD KASHIF / MUHAMMAD SHAHID',
      );
      expect(
        owner('29 - Mahboob Colony (SHARQI)', id: '12020561')!.label,
        'MUHAMMAD ILYAS / MUHAMMAD NAEEM',
      );
      expect(owner('NoorPura', id: '04010428')!.label, 'MUHAMMAD MURTAZA');
      expect(owner('51 - NoorPura', id: '04010429')!.label, 'ABDUL LATIF');
      expect(owner('NoorPura', id: '0004010428')!.label, 'MUHAMMAD MURTAZA');
      expect(owner('NoorPura', id: '04010428-A'), isNull);
      expect(
        owner('Islam Pura', id: '12020560')!.label,
        'MUHAMMAD KASHIF / MUHAMMAD SHAHID',
      );
      expect(owner('Unknown', id: '04010428'), isNull);
    },
  );

  testWidgets(
    'select employee or pair exports all assigned sectors and respects connection splits',
    (tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      late Database db;
      await tester.runAsync(() async {
        db = await fixture(inMemoryDatabasePath);
        for (final row in [
          (
            '12020560',
            'Mahboob Colony (SHARQI)',
            'Mehboob Colony SHARQI Zone B',
          ),
          (
            '12020561',
            'Mahboob Colony (SHARQI)',
            'Mehboob Colony SHARQI Zone B',
          ),
          ('16020001', 'Islam Pura', 'Islam Pura Zone B'),
          ('37010001', 'Hussain Colony', 'Hussain Colony Zone A'),
        ]) {
          await db.insert('consumers', {
            'connection_no': row.$1,
            'consumer_name': 'Consumer ${row.$1}',
            'sector': row.$2,
            'locality': row.$3,
            'rate_type': 'DOMESTIC',
            'connection_status': 'Regular Connection',
          });
          await db.insert(
            'bill_history',
            BillHistory(
              connectionNo: row.$1,
              billNo: '1',
              billType: 'Regular',
              billingPeriod: '01/07/2026 - 31/12/2026',
              waterFee: '2400',
              totalBill: '2400',
              status: 'Un-Paid',
            ).toMap(),
          );
        }
      });
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(1900, 1700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: BillingAuditScreen(database: DatabaseService.forTesting(db)),
        ),
      );
      for (
        var i = 0;
        i < 40 && find.byType(SearchableSelectField).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final field = find.widgetWithText(
        SearchableSelectField,
        'Employee / pair',
      );
      Future<void> select(String label) async {
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.byType(TextField),
          ),
          label,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.widgetWithText(ListTile, label),
          ),
        );
        await tester.pumpAndSettle();
      }

      await select('MUHAMMAD SHAHID');
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 2);
      expect(find.text('Consumer 12020560'), findsOneWidget);
      expect(find.text('Consumer 12020561'), findsNothing);
      expect(find.text('Responsibility: MUHAMMAD SHAHID'), findsOneWidget);
      expect(
        find.textContaining('MUHAMMAD KASHIF / MUHAMMAD SHAHID'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Export PDF / choose columns'));
      await tester.tap(find.text('Export PDF / choose columns'));
      await tester.pumpAndSettle();
      final report = tester.widget<BillingAuditPdfDialog>(
        find.byType(BillingAuditPdfDialog),
      );
      expect(report.employeeName, 'MUHAMMAD SHAHID');
      expect(
        report.entries.map((e) => e.connectionNo),
        unorderedEquals(['12020560', '16020001']),
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await select('MUHAMMAD KASHIF / MUHAMMAD SHAHID');
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 2);
      await select('All employees');
      expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
