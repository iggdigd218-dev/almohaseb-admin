import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:license_admin/firebase_usage.dart';
import 'package:license_admin/main.dart';
import 'package:license_admin/rtdb.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  test('USAGE-01 تنسيق الأحجام وحساب المتبقي لباقة Spark و Blaze', () async {
    expect(formatStorageBytes(512), '512 B');
    expect(formatStorageBytes(2048), '2.0 KB');
    expect(formatStorageBytes(5 * kBytesPerMiB), '5.00 MB');
    expect(formatStorageBytes(2 * kBytesPerGiB), '2.000 GB');

    const settingsSpark = FirebaseQuotaSettings(planTier: FirebasePlanTier.spark);
    expect(settingsSpark.effectiveStorageLimitBytes, kSparkStorageLimitBytes);
    expect(
      settingsSpark.effectiveMonthlyTransferLimitBytes,
      kSparkMonthlyTransferLimitBytes,
    );

    final report = FirebaseUsageReport(
      measuredAtMs: 1770000000000,
      workspacesStorageBytes: 100 * kBytesPerMiB,
      registryStorageBytes: 10 * kBytesPerMiB,
      systemStorageBytes: 2 * kBytesPerMiB,
      trialsStorageBytes: 12 * kBytesPerMiB,
      workspaceCount: 3,
      totalOperationsCount: 500,
      exactMeasuredWorkspacesCount: 1,
      scanConsumedBytes: 18432,
      transferStats: TransferStatsSnapshot(
        monthKey: currentMonthKey(),
        sessionDownBytes: 4096,
        sessionUpBytes: 1024,
        sessionRequests: 5,
        monthDownBytes: 50 * kBytesPerMiB,
        monthUpBytes: 10 * kBytesPerMiB,
        monthRequests: 25,
      ),
      settings: FirebaseQuotaSettings(
        planTier: FirebasePlanTier.spark,
        consoleBaselineMonthKey: currentMonthKey(),
        consoleBaselineTransferBytes: 500 * kBytesPerMiB,
        appTransferAtBaselineBytes: 40 * kBytesPerMiB,
      ),
      topWorkspaces: const [],
    );

    expect(report.totalUsedStorageBytes, 124 * kBytesPerMiB);
    expect(
      report.remainingStorageBytes,
      kSparkStorageLimitBytes - (124 * kBytesPerMiB),
    );
    // 500 MB baseline + (50 - 40) MB app delta since baseline = 510 MB
    expect(report.effectiveMonthTransferBytes, 510 * kBytesPerMiB);
    expect(
      report.remainingMonthlyTransferBytes,
      kSparkMonthlyTransferLimitBytes - (510 * kBytesPerMiB),
    );
  });

  test('USAGE-02 الفحص الهجين لا يقرأ /workspaces.json بالكامل ويحسب النقل بدقة', () async {
    SharedPreferences.setMockInitialValues({});
    final rtdb = Rtdb.instance;
    rtdb.resetTransferStatsForTest();
    await rtdb.load();

    final seenUrls = <String>[];
    final client = MockClient((req) async {
      seenUrls.add(req.url.toString());
      if (req.url.host.contains('identitytoolkit') ||
          req.url.host.contains('securetoken')) {
        return _json({
          'idToken': 'IDTOK-USAGE',
          'refreshToken': 'REF-USAGE',
          'expiresIn': '3600',
          'localId': 'UID-USAGE',
        });
      }
      final path = req.url.path;
      final isShallow = req.url.queryParameters['shallow'] == 'true';

      if (path.endsWith('/system.json')) {
        return _json({'maintenance': {'is_active': false}});
      }
      if (path.endsWith('/trials.json')) {
        return _json({'DEV-1': {'status': 'trial'}});
      }
      if (path.endsWith('/workspaces/_registry/subscribers_summary.json')) {
        return _json({
          'WS-ALPHA': {'store_name': 'متجر ألفا'}
        });
      }
      if (path.endsWith('/workspaces/_registry/subscriptions_index.json') ||
          path.endsWith('/workspaces/_registry/device_index.json')) {
        return _json({});
      }
      if (path.endsWith('/workspaces/_registry/license_hub.json') && isShallow) {
        return _json({'WS-ALPHA': true});
      }
      if (path.endsWith('/workspaces.json')) {
        expect(
          isShallow,
          isTrue,
          reason: 'ممنوع منعاً باتاً سحب /workspaces.json بدون shallow=true',
        );
        return _json({'WS-ALPHA': true, '_registry': true, 'default': true});
      }
      if (path.endsWith('/workspaces/WS-ALPHA.json')) {
        if (isShallow) {
          return _json({'meta': true, 'catalog_digest': true, 'operations': true, 'snapshot': true});
        }
        return _json({
          'meta': {'name': 'متجر ألفا'},
          'catalog_digest': {
            'counts': {'items': 307, 'accounts': 45, 'transactions': 120}
          },
          'operations': {
            'op1': {'id': 'op1'},
            'op2': {'id': 'op2'},
            'op3': {'id': 'op3'},
          },
          'snapshot': {'data': {'items': [{'id': 1, 'name': 'صنف'}]}},
        });
      }
      if (path.endsWith('/workspaces/WS-ALPHA/catalog_digest.json')) {
        return _json({
          'counts': {'items': 307, 'accounts': 45, 'transactions': 120}
        });
      }
      if (path.endsWith('/workspaces/WS-ALPHA/operations.json') && isShallow) {
        return _json({'op1': true, 'op2': true, 'op3': true});
      }
      return _json('null');
    });

    rtdb.clientOverride = client;
    final svc = FirebaseUsageService(rtdb);
    final report = await svc.scanHybridUsage();

    expect(report.workspaceCount, 1);
    expect(report.totalOperationsCount, 3);
    expect(report.totalUsedStorageBytes, greaterThan(0));
    expect(report.remainingStorageBytes, lessThan(kSparkStorageLimitBytes));
    expect(report.scanConsumedBytes, greaterThan(0));
    expect(report.transferStats.monthDownBytes, greaterThan(0));
    expect(report.topWorkspaces.first.storeName, 'متجر ألفا');
    expect(report.topWorkspaces.first.itemsCount, 307);
    expect(report.topWorkspaces.first.isExactMeasured, isFalse);

    // الفحص الدقيق لمنشأة واحدة يحدّث الكاش وتستفيد منه القراءة اللاحقة
    final exact = await svc.measureSingleWorkspaceExact('WS-ALPHA');
    expect(exact.isExactMeasured, isTrue);
    expect(exact.estimatedBytes, greaterThan(0));

    final secondReport = await svc.scanHybridUsage();
    expect(secondReport.exactMeasuredWorkspacesCount, 1);
    expect(secondReport.topWorkspaces.first.isExactMeasured, isTrue);
  });

  testWidgets('USAGE-03 عرض بطاقة مساحة فيرباس والنقل بدون أخطاء', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: SingleChildScrollView(child: FirebaseUsageCard()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('مساحة فيرباس وحجم النقل'), findsOneWidget);
    expect(find.text('المساحة المستخدمة'), findsOneWidget);
    expect(find.text('المساحة المتبقية'), findsOneWidget);
    expect(find.text('فحص المساحة الآن'), findsOneWidget);
  });
}
