import 'package:consumer_search_engine/models/bill_history_model.dart';
import 'package:consumer_search_engine/screens/billing_audit_screen.dart';
import 'package:consumer_search_engine/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_backup_test.dart' show fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'connection menu copies all or current page, preserving zeros and serial numbering',
    (tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      late Database db;
      await tester.runAsync(() async {
        db = await fixture(inMemoryDatabasePath);
        for (var i = 1; i <= 24; i++) {
          final id = i.toString().padLeft(6, '0');
          await db.insert('consumers', {
            'connection_no': id,
            'consumer_name': 'Consumer $i',
            'rate_type': 'DOMESTIC',
            'connection_status': 'Regular Connection',
          });
          await db.insert(
            'bill_history',
            BillHistory(
              connectionNo: id,
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
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.binding.setSurfaceSize(const Size(1800, 1300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: BillingAuditScreen(database: DatabaseService.forTesting(db)),
        ),
      );
      for (
        var i = 0;
        i < 40 && find.byType(DataTable).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      DataTable table() => tester.widget<DataTable>(find.byType(DataTable));
      expect((table().rows.first.cells.first.child as Text).data, '1');
      expect((table().rows.last.cells.first.child as Text).data, '20');
      final next = find.widgetWithIcon(IconButton, Icons.chevron_right);
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect((table().rows.first.cells.first.child as Text).data, '21');
      expect((table().rows.last.cells.first.child as Text).data, '24');
      Future<void> openMenu() async {
        final menu = find.byTooltip('Export / Copy Audit Connection Numbers');
        await tester.ensureVisible(menu);
        await tester.pumpAndSettle();
        await tester.tap(menu);
        await tester.pumpAndSettle();
      }

      await openMenu();
      expect(find.text('Download CSV (All 24)'), findsOneWidget);
      expect(find.text('Download CSV (Current Page: 4)'), findsOneWidget);
      await tester.tap(find.text('Copy Current Page (4)'));
      await tester.pumpAndSettle();
      expect(copied, ['000021', '000022', '000023', '000024'].join('\n'));
      await openMenu();
      await tester.tap(find.text('Copy All to Clipboard (24)'));
      await tester.pumpAndSettle();
      expect(
        copied,
        [for (var i = 1; i <= 24; i++) i.toString().padLeft(6, '0')].join('\n'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
