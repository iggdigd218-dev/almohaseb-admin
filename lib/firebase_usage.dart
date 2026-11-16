// 📊 مراقب مساحة وحجم نقل Firebase RTDB (البديل الهجين الخفيف والآمن).
//
// ⚠️ التصميم المعماري:
// • لا يقرأ `/workspaces.json` بالكامل أبداً حتى لا يستنزف حصة النقل الشهرية (10 GB في Spark).
// • يعتمد على مسح خفيف (`?shallow=true` + `catalog_digest` + `meta`) وقياس دقيق لعقد النظام والفهارس.
// • يتتبّع حجم النقل الفعلي للطلبات (Bytes In / Bytes Out) تلقائياً في `SharedPreferences`
//   مع دعم معايرة القراءة الشهرية من لوحة Firebase وتحديد الباقة (Spark 1GB/10GB أو Blaze أو مخصص).

import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'rtdb.dart';

const int kBytesPerKiB = 1024;
const int kBytesPerMiB = 1024 * 1024;
const int kBytesPerGiB = 1024 * 1024 * 1024;

/// حد التخزين الافتراضي في باقة Spark المجانية (1 GiB).
const int kSparkStorageLimitBytes = 1 * kBytesPerGiB;

/// حد النقل/التحميل الشهري الافتراضي في باقة Spark المجانية (10 GiB).
const int kSparkMonthlyTransferLimitBytes = 10 * kBytesPerGiB;

/// السقف العملي الافتراضي لقاعدة واحدة في باقة Blaze (200 GiB).
const int kBlazeStorageLimitBytes = 200 * kBytesPerGiB;

/// سقف تنبيه النقل الشهري الافتراضي في باقة Blaze (100 GiB قابل للتخصيص).
const int kBlazeDefaultMonthlyAlertBytes = 100 * kBytesPerGiB;

enum FirebasePlanTier {
  spark,
  blaze,
  custom;

  String get id => name;

  String get arabicLabel => switch (this) {
        FirebasePlanTier.spark => 'Spark المجانية (1 GB مساحة · 10 GB/شهر نقل)',
        FirebasePlanTier.blaze => 'Blaze المدفوعة (حسب الاستهلاك)',
        FirebasePlanTier.custom => 'سقف مخصص',
      };

  static FirebasePlanTier parse(String? raw) {
    final clean = (raw ?? '').trim().toLowerCase();
    for (final v in FirebasePlanTier.values) {
      if (v.name == clean) return v;
    }
    return FirebasePlanTier.spark;
  }
}

/// تنسيق الحجم بالبايت إلى نص واضح (B / KB / MB / GB).
String formatStorageBytes(int bytes) {
  final safe = bytes < 0 ? 0 : bytes;
  if (safe < kBytesPerKiB) {
    return '$safe B';
  }
  if (safe < kBytesPerMiB) {
    return '${(safe / kBytesPerKiB).toStringAsFixed(1)} KB';
  }
  if (safe < kBytesPerGiB) {
    return '${(safe / kBytesPerMiB).toStringAsFixed(2)} MB';
  }
  return '${(safe / kBytesPerGiB).toStringAsFixed(3)} GB';
}

String currentMonthKey([DateTime? now]) {
  final dt = (now ?? DateTime.now()).toUtc();
  final mm = dt.month.toString().padLeft(2, '0');
  return '${dt.year}-$mm';
}

class TransferStatsSnapshot {
  final String monthKey;
  final int sessionDownBytes;
  final int sessionUpBytes;
  final int sessionRequests;
  final int monthDownBytes;
  final int monthUpBytes;
  final int monthRequests;

  const TransferStatsSnapshot({
    required this.monthKey,
    required this.sessionDownBytes,
    required this.sessionUpBytes,
    required this.sessionRequests,
    required this.monthDownBytes,
    required this.monthUpBytes,
    required this.monthRequests,
  });

  int get sessionTotalBytes => sessionDownBytes + sessionUpBytes;
  int get monthTotalBytes => monthDownBytes + monthUpBytes;
}

class FirebaseQuotaSettings {
  static const String _kPlanTier = 'fb_usage_plan_tier';
  static const String _kCustomStorageMb = 'fb_usage_custom_storage_mb';
  static const String _kCustomTransferMb = 'fb_usage_custom_transfer_mb';
  static const String _kBaselineMonth = 'fb_usage_baseline_month';
  static const String _kBaselineBytes = 'fb_usage_baseline_bytes';
  static const String _kAppAtBaselineBytes = 'fb_usage_app_at_baseline_bytes';
  static const String _kBaselineUpdatedMs = 'fb_usage_baseline_updated_ms';

  final FirebasePlanTier planTier;
  final int customStorageLimitBytes;
  final int customTransferLimitBytes;
  final String consoleBaselineMonthKey;
  final int consoleBaselineTransferBytes;
  final int appTransferAtBaselineBytes;
  final int consoleBaselineUpdatedAtMs;

  const FirebaseQuotaSettings({
    this.planTier = FirebasePlanTier.spark,
    this.customStorageLimitBytes = kSparkStorageLimitBytes,
    this.customTransferLimitBytes = kSparkMonthlyTransferLimitBytes,
    this.consoleBaselineMonthKey = '',
    this.consoleBaselineTransferBytes = 0,
    this.appTransferAtBaselineBytes = 0,
    this.consoleBaselineUpdatedAtMs = 0,
  });

  int get effectiveStorageLimitBytes => switch (planTier) {
        FirebasePlanTier.spark => kSparkStorageLimitBytes,
        FirebasePlanTier.blaze => kBlazeStorageLimitBytes,
        FirebasePlanTier.custom =>
          math.max(10 * kBytesPerMiB, customStorageLimitBytes),
      };

  int get effectiveMonthlyTransferLimitBytes => switch (planTier) {
        FirebasePlanTier.spark => kSparkMonthlyTransferLimitBytes,
        FirebasePlanTier.blaze => customTransferLimitBytes > 0
            ? customTransferLimitBytes
            : kBlazeDefaultMonthlyAlertBytes,
        FirebasePlanTier.custom =>
          math.max(10 * kBytesPerMiB, customTransferLimitBytes),
      };

  static Future<FirebaseQuotaSettings> load() async {
    final sp = await SharedPreferences.getInstance();
    final tier = FirebasePlanTier.parse(sp.getString(_kPlanTier));
    final storageMb = sp.getInt(_kCustomStorageMb) ?? 1024;
    final transferMb = sp.getInt(_kCustomTransferMb) ?? 10240;
    final activeMonth = currentMonthKey();
    final storedMonth = sp.getString(_kBaselineMonth) ?? '';
    final validSameMonth = storedMonth == activeMonth;
    return FirebaseQuotaSettings(
      planTier: tier,
      customStorageLimitBytes: math.max(10, storageMb) * kBytesPerMiB,
      customTransferLimitBytes: math.max(10, transferMb) * kBytesPerMiB,
      consoleBaselineMonthKey: validSameMonth ? storedMonth : activeMonth,
      consoleBaselineTransferBytes:
          validSameMonth ? (sp.getInt(_kBaselineBytes) ?? 0) : 0,
      appTransferAtBaselineBytes:
          validSameMonth ? (sp.getInt(_kAppAtBaselineBytes) ?? 0) : 0,
      consoleBaselineUpdatedAtMs:
          validSameMonth ? (sp.getInt(_kBaselineUpdatedMs) ?? 0) : 0,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPlanTier, planTier.id);
    await sp.setInt(
      _kCustomStorageMb,
      math.max(10, (customStorageLimitBytes / kBytesPerMiB).round()),
    );
    await sp.setInt(
      _kCustomTransferMb,
      math.max(10, (customTransferLimitBytes / kBytesPerMiB).round()),
    );
    await sp.setString(_kBaselineMonth, consoleBaselineMonthKey);
    await sp.setInt(_kBaselineBytes, math.max(0, consoleBaselineTransferBytes));
    await sp.setInt(
      _kAppAtBaselineBytes,
      math.max(0, appTransferAtBaselineBytes),
    );
    await sp.setInt(_kBaselineUpdatedMs, consoleBaselineUpdatedAtMs);
  }

  FirebaseQuotaSettings copyWith({
    FirebasePlanTier? planTier,
    int? customStorageLimitBytes,
    int? customTransferLimitBytes,
    String? consoleBaselineMonthKey,
    int? consoleBaselineTransferBytes,
    int? appTransferAtBaselineBytes,
    int? consoleBaselineUpdatedAtMs,
  }) {
    return FirebaseQuotaSettings(
      planTier: planTier ?? this.planTier,
      customStorageLimitBytes:
          customStorageLimitBytes ?? this.customStorageLimitBytes,
      customTransferLimitBytes:
          customTransferLimitBytes ?? this.customTransferLimitBytes,
      consoleBaselineMonthKey:
          consoleBaselineMonthKey ?? this.consoleBaselineMonthKey,
      consoleBaselineTransferBytes:
          consoleBaselineTransferBytes ?? this.consoleBaselineTransferBytes,
      appTransferAtBaselineBytes:
          appTransferAtBaselineBytes ?? this.appTransferAtBaselineBytes,
      consoleBaselineUpdatedAtMs:
          consoleBaselineUpdatedAtMs ?? this.consoleBaselineUpdatedAtMs,
    );
  }
}

class WorkspaceUsageEntry {
  final String workspaceId;
  final String storeName;
  final int estimatedBytes;
  final bool isExactMeasured;
  final int operationsCount;
  final int itemsCount;
  final int accountsCount;
  final int transactionsCount;
  final bool hasSnapshot;
  final bool hasBackup;
  final int measuredAtMs;

  const WorkspaceUsageEntry({
    required this.workspaceId,
    required this.storeName,
    required this.estimatedBytes,
    required this.isExactMeasured,
    this.operationsCount = 0,
    this.itemsCount = 0,
    this.accountsCount = 0,
    this.transactionsCount = 0,
    this.hasSnapshot = false,
    this.hasBackup = false,
    this.measuredAtMs = 0,
  });

  Map<String, Object?> toJson() => {
        'workspaceId': workspaceId,
        'storeName': storeName,
        'estimatedBytes': estimatedBytes,
        'isExactMeasured': isExactMeasured,
        'operationsCount': operationsCount,
        'itemsCount': itemsCount,
        'accountsCount': accountsCount,
        'transactionsCount': transactionsCount,
        'hasSnapshot': hasSnapshot,
        'hasBackup': hasBackup,
        'measuredAtMs': measuredAtMs,
      };

  factory WorkspaceUsageEntry.fromJson(Map<dynamic, dynamic> map) {
    return WorkspaceUsageEntry(
      workspaceId: asStr(map['workspaceId']),
      storeName: asStr(map['storeName']),
      estimatedBytes: (map['estimatedBytes'] as num?)?.toInt() ?? 0,
      isExactMeasured: map['isExactMeasured'] == true,
      operationsCount: (map['operationsCount'] as num?)?.toInt() ?? 0,
      itemsCount: (map['itemsCount'] as num?)?.toInt() ?? 0,
      accountsCount: (map['accountsCount'] as num?)?.toInt() ?? 0,
      transactionsCount: (map['transactionsCount'] as num?)?.toInt() ?? 0,
      hasSnapshot: map['hasSnapshot'] == true,
      hasBackup: map['hasBackup'] == true,
      measuredAtMs: (map['measuredAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class FirebaseUsageReport {
  final int measuredAtMs;
  final int workspacesStorageBytes;
  final int registryStorageBytes;
  final int systemStorageBytes;
  final int trialsStorageBytes;
  final int workspaceCount;
  final int totalOperationsCount;
  final int exactMeasuredWorkspacesCount;
  final int scanConsumedBytes;
  final TransferStatsSnapshot transferStats;
  final FirebaseQuotaSettings settings;
  final List<WorkspaceUsageEntry> topWorkspaces;

  const FirebaseUsageReport({
    required this.measuredAtMs,
    required this.workspacesStorageBytes,
    required this.registryStorageBytes,
    required this.systemStorageBytes,
    required this.trialsStorageBytes,
    required this.workspaceCount,
    required this.totalOperationsCount,
    required this.exactMeasuredWorkspacesCount,
    required this.scanConsumedBytes,
    required this.transferStats,
    required this.settings,
    required this.topWorkspaces,
  });

  int get totalUsedStorageBytes =>
      workspacesStorageBytes +
      registryStorageBytes +
      systemStorageBytes +
      trialsStorageBytes;

  int get storageLimitBytes => settings.effectiveStorageLimitBytes;

  int get remainingStorageBytes =>
      math.max(0, storageLimitBytes - totalUsedStorageBytes);

  double get storageUsedRatio => storageLimitBytes <= 0
      ? 0.0
      : (totalUsedStorageBytes / storageLimitBytes).clamp(0.0, 1.0);

  bool get hasConsoleBaseline =>
      settings.consoleBaselineMonthKey == transferStats.monthKey &&
      settings.consoleBaselineTransferBytes > 0;

  int get effectiveMonthTransferBytes {
    if (!hasConsoleBaseline) {
      return transferStats.monthTotalBytes;
    }
    final deltaSinceBaseline = math.max(
      0,
      transferStats.monthDownBytes - settings.appTransferAtBaselineBytes,
    );
    return settings.consoleBaselineTransferBytes + deltaSinceBaseline;
  }

  int get monthlyTransferLimitBytes =>
      settings.effectiveMonthlyTransferLimitBytes;

  int get remainingMonthlyTransferBytes =>
      math.max(0, monthlyTransferLimitBytes - effectiveMonthTransferBytes);

  double get transferUsedRatio => monthlyTransferLimitBytes <= 0
      ? 0.0
      : (effectiveMonthTransferBytes / monthlyTransferLimitBytes)
          .clamp(0.0, 1.0);
}

class FirebaseUsageService {
  static const String _kExactCachePref = 'fb_usage_ws_exact_cache_v1';
  static const String _kLastReportPref = 'fb_usage_last_report_v1';

  final Rtdb rtdb;
  FirebaseUsageService(this.rtdb);

  static int utf8JsonBytes(Object? data) {
    if (data == null) return 0;
    try {
      return utf8.encode(jsonEncode(data)).length;
    } catch (_) {
      return 0;
    }
  }

  /// تقدير حجم المنشأة من البيانات الوصفية الخفيفة (`?shallow=true` + `catalog_digest`)
  /// دون سحب عقد `snapshot` أو `operations` الثقيلة.
  static int estimateWorkspaceBytes({
    required int opsCount,
    required int itemsCount,
    required int accountsCount,
    required int transactionsCount,
    required int vouchersCount,
    required int stockMovesCount,
    required bool hasSnapshot,
    required bool hasJoinSnapshot,
    required bool hasBackup,
    required bool hasChat,
    required int nodeCount,
  }) {
    final opsBytes = opsCount * 580;
    var snapshotUnit = (itemsCount * 420) +
        (accountsCount * 280) +
        (transactionsCount * 540) +
        (vouchersCount * 260) +
        (stockMovesCount * 220);
    if (snapshotUnit == 0 && (hasSnapshot || hasJoinSnapshot || hasBackup)) {
      snapshotUnit = 256 * kBytesPerKiB;
    }
    var total = 4096 + (nodeCount * 512) + opsBytes;
    if (hasSnapshot) total += snapshotUnit + 4096;
    if (hasJoinSnapshot) total += snapshotUnit + 4096;
    if (hasBackup) total += (snapshotUnit * 0.85).round() + 4096;
    if (hasChat) total += 8192;
    return total;
  }

  Future<Map<String, WorkspaceUsageEntry>> _loadExactCache() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kExactCachePref);
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, WorkspaceUsageEntry>{};
      for (final e in decoded.entries) {
        if (e.value is Map) {
          final entry = WorkspaceUsageEntry.fromJson(e.value as Map);
          if (entry.workspaceId.isNotEmpty) {
            out[entry.workspaceId] = entry;
          }
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveExactCache(Map<String, WorkspaceUsageEntry> cache) async {
    final sp = await SharedPreferences.getInstance();
    final map = <String, Object?>{
      for (final e in cache.entries) e.key: e.value.toJson(),
    };
    await sp.setString(_kExactCachePref, jsonEncode(map));
  }

  /// قراءة آخر تقرير مخزّن محلياً (صفر استهلاك شبكة عند فتح الشاشة).
  Future<FirebaseUsageReport?> loadCachedReport() async {
    final sp = await SharedPreferences.getInstance();
    final settings = await FirebaseQuotaSettings.load();
    final transfer = await rtdb.transferStatsSnapshot();
    final raw = sp.getString(_kLastReportPref);
    if (raw == null || raw.trim().isEmpty) {
      return FirebaseUsageReport(
        measuredAtMs: 0,
        workspacesStorageBytes: 0,
        registryStorageBytes: 0,
        systemStorageBytes: 0,
        trialsStorageBytes: 0,
        workspaceCount: 0,
        totalOperationsCount: 0,
        exactMeasuredWorkspacesCount: 0,
        scanConsumedBytes: 0,
        transferStats: transfer,
        settings: settings,
        topWorkspaces: const [],
      );
    }
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final topRaw = m['topWorkspaces'];
      final top = <WorkspaceUsageEntry>[
        if (topRaw is List)
          for (final item in topRaw)
            if (item is Map) WorkspaceUsageEntry.fromJson(item),
      ];
      return FirebaseUsageReport(
        measuredAtMs: (m['measuredAtMs'] as num?)?.toInt() ?? 0,
        workspacesStorageBytes:
            (m['workspacesStorageBytes'] as num?)?.toInt() ?? 0,
        registryStorageBytes:
            (m['registryStorageBytes'] as num?)?.toInt() ?? 0,
        systemStorageBytes: (m['systemStorageBytes'] as num?)?.toInt() ?? 0,
        trialsStorageBytes: (m['trialsStorageBytes'] as num?)?.toInt() ?? 0,
        workspaceCount: (m['workspaceCount'] as num?)?.toInt() ?? 0,
        totalOperationsCount:
            (m['totalOperationsCount'] as num?)?.toInt() ?? 0,
        exactMeasuredWorkspacesCount:
            (m['exactMeasuredWorkspacesCount'] as num?)?.toInt() ?? 0,
        scanConsumedBytes: (m['scanConsumedBytes'] as num?)?.toInt() ?? 0,
        transferStats: transfer,
        settings: settings,
        topWorkspaces: top,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCachedReport(FirebaseUsageReport report) async {
    final sp = await SharedPreferences.getInstance();
    final payload = {
      'measuredAtMs': report.measuredAtMs,
      'workspacesStorageBytes': report.workspacesStorageBytes,
      'registryStorageBytes': report.registryStorageBytes,
      'systemStorageBytes': report.systemStorageBytes,
      'trialsStorageBytes': report.trialsStorageBytes,
      'workspaceCount': report.workspaceCount,
      'totalOperationsCount': report.totalOperationsCount,
      'exactMeasuredWorkspacesCount': report.exactMeasuredWorkspacesCount,
      'scanConsumedBytes': report.scanConsumedBytes,
      'topWorkspaces': [for (final w in report.topWorkspaces) w.toJson()],
    };
    await sp.setString(_kLastReportPref, jsonEncode(payload));
  }

  /// فحص هجين خفيف وآمن: لا يقرأ `/workspaces.json` بالكامل أبداً.
  Future<FirebaseUsageReport> scanHybridUsage({int maxWorkspaces = 120}) async {
    final beforeTx = await rtdb.transferStatsSnapshot();
    final settings = await FirebaseQuotaSettings.load();
    final exactCache = await _loadExactCache();

    // 1) قياس عقد النظام والفهارس والتجارب الخفيفة بدقة
    var systemBytes = 0;
    var trialsBytes = 0;
    var registryBytes = 0;

    try {
      final sysData = await rtdb.getJson('system');
      systemBytes = utf8JsonBytes(sysData);
    } catch (_) {}

    try {
      final trialsData = await rtdb.getJson('trials');
      trialsBytes = utf8JsonBytes(trialsData);
    } catch (_) {}

    for (final regPath in const [
      'workspaces/_registry/subscribers_summary',
      'workspaces/_registry/subscriptions_index',
      'workspaces/_registry/device_index',
    ]) {
      try {
        final d = await rtdb.getJson(regPath);
        registryBytes += utf8JsonBytes(d);
      } catch (_) {}
    }

    try {
      final hubShallow = await rtdb.getJsonQuery(
        'workspaces/_registry/license_hub',
        const {'shallow': 'true'},
      );
      if (hubShallow is Map) {
        registryBytes += hubShallow.length * 420;
      }
    } catch (_) {}

    // 2) قائمة مفاتيح المساحات عبر shallow فقط (~بضعة كيلوبايت)
    final wsKeysMap =
        await rtdb.getJsonQuery('workspaces', const {'shallow': 'true'});
    final wsIds = wsKeysMap is Map
        ? wsKeysMap.keys
            .map((k) => '$k')
            .where((k) => !k.startsWith('_') && k != 'default')
            .take(maxWorkspaces)
            .toList()
        : <String>[];

    // قراءة ملخص الأسماء المتاح من subscribers_summary لتجنب طلبات إضافية عند الإمكان
    final storeNames = <String, String>{};
    try {
      final summary = await rtdb.getJson(kSubscribersSummaryPath);
      if (summary is Map) {
        for (final e in summary.entries) {
          if (e.value is Map) {
            final n = asStr((e.value as Map)['store_name'] ??
                (e.value as Map)['storeName'] ??
                (e.value as Map)['name']);
            if (n.isNotEmpty) storeNames['${e.key}'] = n;
          }
        }
      }
    } catch (_) {}

    // 3) مسح خفيف على دفعات متوازية للمنشآت
    final entries = <WorkspaceUsageEntry>[];
    const batchSize = 6;
    for (var i = 0; i < wsIds.length; i += batchSize) {
      final slice = wsIds.sublist(i, math.min(i + batchSize, wsIds.length));
      final batchResults = await Future.wait(
        slice.map(
          (wsId) => _scanSingleWorkspaceLightweight(
            wsId,
            cachedName: storeNames[wsId] ?? '',
            cachedExact: exactCache[wsId],
          ),
        ),
      );
      entries.addAll(batchResults);
    }

    entries.sort((a, b) => b.estimatedBytes.compareTo(a.estimatedBytes));

    var wsBytesTotal = 0;
    var opsTotal = 0;
    var exactCount = 0;
    for (final e in entries) {
      wsBytesTotal += e.estimatedBytes;
      opsTotal += e.operationsCount;
      if (e.isExactMeasured) exactCount++;
    }

    final afterTx = await rtdb.transferStatsSnapshot();
    final scanCost =
        math.max(0, afterTx.sessionTotalBytes - beforeTx.sessionTotalBytes);

    final report = FirebaseUsageReport(
      measuredAtMs: DateTime.now().millisecondsSinceEpoch,
      workspacesStorageBytes: wsBytesTotal,
      registryStorageBytes: registryBytes,
      systemStorageBytes: systemBytes,
      trialsStorageBytes: trialsBytes,
      workspaceCount: wsIds.length,
      totalOperationsCount: opsTotal,
      exactMeasuredWorkspacesCount: exactCount,
      scanConsumedBytes: scanCost,
      transferStats: afterTx,
      settings: settings,
      topWorkspaces: entries,
    );
    await _saveCachedReport(report);
    return report;
  }

  Future<WorkspaceUsageEntry> _scanSingleWorkspaceLightweight(
    String wsId, {
    required String cachedName,
    WorkspaceUsageEntry? cachedExact,
  }) async {
    final enc = Uri.encodeComponent(wsId);
    var storeName = cachedName;
    var hasSnapshot = false;
    var hasJoinSnapshot = false;
    var hasBackup = false;
    var hasOperations = false;
    var hasChat = false;
    var nodeCount = 0;

    try {
      final wsShallow = await rtdb.getJsonQuery(
        'workspaces/$enc',
        const {'shallow': 'true'},
      );
      if (wsShallow is Map) {
        nodeCount = wsShallow.length;
        hasSnapshot = wsShallow.containsKey('snapshot');
        hasJoinSnapshot = wsShallow.containsKey('joinSnapshot');
        hasBackup = wsShallow.containsKey('backup');
        hasOperations = wsShallow.containsKey('operations');
        hasChat = wsShallow.containsKey('chat');
      }
    } catch (_) {}

    if (storeName.isEmpty) {
      try {
        final meta = await rtdb.getJson('workspaces/$enc/meta');
        if (meta is Map) {
          storeName = asStr(meta['name'] ?? meta['store_name']);
        }
      } catch (_) {}
    }

    var itemsCount = 0;
    var accountsCount = 0;
    var transactionsCount = 0;
    var vouchersCount = 0;
    var stockMovesCount = 0;
    try {
      final digest = await rtdb.getJson('workspaces/$enc/catalog_digest');
      if (digest is Map) {
        final counts = digest['counts'] is Map ? digest['counts'] as Map : digest;
        itemsCount = (counts['items'] as num?)?.toInt() ?? 0;
        accountsCount = (counts['accounts'] as num?)?.toInt() ?? 0;
        transactionsCount = (counts['transactions'] as num?)?.toInt() ?? 0;
        vouchersCount = (counts['vouchers'] as num?)?.toInt() ?? 0;
        stockMovesCount = (counts['stock_moves'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}

    var opsCount = 0;
    if (hasOperations) {
      try {
        final opsShallow = await rtdb.getJsonQuery(
          'workspaces/$enc/operations',
          const {'shallow': 'true'},
        );
        if (opsShallow is Map) {
          opsCount = opsShallow.length;
        }
      } catch (_) {}
    }

    final est = estimateWorkspaceBytes(
      opsCount: opsCount,
      itemsCount: itemsCount,
      accountsCount: accountsCount,
      transactionsCount: transactionsCount,
      vouchersCount: vouchersCount,
      stockMovesCount: stockMovesCount,
      hasSnapshot: hasSnapshot,
      hasJoinSnapshot: hasJoinSnapshot,
      hasBackup: hasBackup,
      hasChat: hasChat,
      nodeCount: nodeCount,
    );

    // إذا تم فحص هذه المنشأة بدقة سابقاً ولم يتغير عدد العمليات أو الأصناف تغيراً كبيراً (< 15)،
    // نعرض القياس الدقيق المحفوظ دون إعادة سحب اللقطات.
    if (cachedExact != null &&
        cachedExact.isExactMeasured &&
        (cachedExact.operationsCount - opsCount).abs() <= 15 &&
        (cachedExact.itemsCount - itemsCount).abs() <= 10) {
      return WorkspaceUsageEntry(
        workspaceId: wsId,
        storeName: storeName.isNotEmpty ? storeName : cachedExact.storeName,
        estimatedBytes: cachedExact.estimatedBytes,
        isExactMeasured: true,
        operationsCount: opsCount,
        itemsCount: itemsCount > 0 ? itemsCount : cachedExact.itemsCount,
        accountsCount:
            accountsCount > 0 ? accountsCount : cachedExact.accountsCount,
        transactionsCount: transactionsCount > 0
            ? transactionsCount
            : cachedExact.transactionsCount,
        hasSnapshot: hasSnapshot,
        hasBackup: hasBackup,
        measuredAtMs: cachedExact.measuredAtMs,
      );
    }

    return WorkspaceUsageEntry(
      workspaceId: wsId,
      storeName: storeName,
      estimatedBytes: est,
      isExactMeasured: false,
      operationsCount: opsCount,
      itemsCount: itemsCount,
      accountsCount: accountsCount,
      transactionsCount: transactionsCount,
      hasSnapshot: hasSnapshot,
      hasBackup: hasBackup,
      measuredAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// فحص دقيق بالبايت الفعلي لمنشأة واحدة فقط (عند طلب المشرف صراحةً) مع حفظ النتيجة محلياً.
  Future<WorkspaceUsageEntry> measureSingleWorkspaceExact(String wsId) async {
    final enc = Uri.encodeComponent(wsId.trim());
    final raw = await rtdb.getJson('workspaces/$enc');
    final exactBytes = utf8JsonBytes(raw);
    var storeName = '';
    var opsCount = 0;
    var itemsCount = 0;
    var accountsCount = 0;
    var txCount = 0;
    var hasSnapshot = false;
    var hasBackup = false;

    if (raw is Map) {
      final meta = raw['meta'];
      if (meta is Map) {
        storeName = asStr(meta['name'] ?? meta['store_name']);
      }
      final ops = raw['operations'];
      if (ops is Map) opsCount = ops.length;
      hasSnapshot = raw.containsKey('snapshot');
      hasBackup = raw.containsKey('backup');
      final digest = raw['catalog_digest'];
      if (digest is Map) {
        final counts = digest['counts'] is Map ? digest['counts'] as Map : digest;
        itemsCount = (counts['items'] as num?)?.toInt() ?? 0;
        accountsCount = (counts['accounts'] as num?)?.toInt() ?? 0;
        txCount = (counts['transactions'] as num?)?.toInt() ?? 0;
      }
    }

    final entry = WorkspaceUsageEntry(
      workspaceId: wsId.trim(),
      storeName: storeName,
      estimatedBytes: exactBytes,
      isExactMeasured: true,
      operationsCount: opsCount,
      itemsCount: itemsCount,
      accountsCount: accountsCount,
      transactionsCount: txCount,
      hasSnapshot: hasSnapshot,
      hasBackup: hasBackup,
      measuredAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    final cache = await _loadExactCache();
    cache[entry.workspaceId] = entry;
    await _saveExactCache(cache);
    return entry;
  }
}
