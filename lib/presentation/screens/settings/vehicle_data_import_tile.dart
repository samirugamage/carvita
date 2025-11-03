import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:intl/intl.dart';

import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/models/service_log_entry.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/data/sources/local/database_helper.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Compact tile to pick a vehicle and import a single CSV.
/// Imports Fuel rows and Maintenance/Expense rows.
/// Assumes camelCase DB columns (vehicleId, serviceDate, mileageAtService, ...).
class VehicleDataImportTile extends StatefulWidget {
  const VehicleDataImportTile({super.key});

  @override
  State<VehicleDataImportTile> createState() => _VehicleDataImportTileState();
}

class _VehicleDataImportTileState extends State<VehicleDataImportTile> {
  int? _vehicleId;
  String? _vehicleName;
  bool _busy = false;

  Future<void> _pickVehicle(BuildContext context) async {
    final vehicleState = context.read<VehicleCubit>().state;
    final vehicles = switch (vehicleState) {
      final VehicleLoaded s => s.vehicles,
      _ => <dynamic>[],
    };

    if (vehicles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No vehicles. Please add a vehicle first.')),
      );
      return;
    }

    final selected = await showDialog<(int, String)?>(
      context: context,
      builder: (ctx) {
        int? tempId = _vehicleId ?? vehicles.first.id;
        return AlertDialog(
          title: const Text('Choose vehicle'),
          content: StatefulBuilder(
            builder: (ctx, setSt) => DropdownButton<int>(
              isExpanded: true,
              value: tempId,
              items: [
                for (final v in vehicles)
                  DropdownMenuItem(value: v.id, child: Text(v.name)),
              ],
              onChanged: (val) => setSt(() => tempId = val),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final v = vehicles.firstWhere((x) => x.id == tempId);
                Navigator.pop(ctx, (v.id as int, v.name as String));
              },
              child: const Text('Select'),
            ),
          ],
        );
      },
    );

    if (selected != null && mounted) {
      setState(() {
        _vehicleId = selected.$1;
        _vehicleName = selected.$2;
      });
    }
  }

  Future<void> _importCsv(BuildContext context) async {
    if (_vehicleId == null) {
      await _pickVehicle(context);
      if (_vehicleId == null) return;
    }

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (picked == null || picked.files.isEmpty) return;

    final path = picked.files.first.path;
    if (path == null) return;

    setState(() => _busy = true);

    int fuelCount = 0;
    int maintCount = 0;

    try {
      final text = await File(path).readAsString();
      final rows = const CsvToListConverter(
        eol: '\n',
        shouldParseNumbers: false,
      ).convert(text);
      if (rows.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV is empty')));
        }
        return;
      }

      // Header normalization
      final header = rows.first.map((e) => _normalizeKey(e.toString())).toList();
      final idx = Map<String, int>.fromEntries(
        header.asMap().entries.map((e) => MapEntry(header[e.key], e.key)),
      );

      // Useful hints
      final hasFuelHints = header.contains('volume') ||
          header.contains('price_per_l') ||
          header.contains('total_cost') ||
          header.contains('liters') ||
          header.contains('litres');

      final hasMaintHints = header.contains('mileage') ||
          header.contains('mileage_km') ||
          header.contains('odometer') ||
          header.contains('items') ||
          header.contains('notes') ||
          header.contains('cost') ||
          header.contains('type_of_expense') ||
          header.contains('expense');

      // Also respect an explicit Type column if present
      final hasTypeCol = header.contains('type');

      final fuelRepo = FuelRepository(dbHelper: DatabaseHelper());

      for (int r = 1; r < rows.length; r++) {
        final rawCells = rows[r];
        final cells = rawCells.map((e) => e?.toString().trim() ?? '').toList();
        if (cells.every((c) => c.isEmpty)) continue;

        final rowType = _get(cells, idx, ['type'])?.toLowerCase();

        DateTime? when = _parseDate(_get(cells, idx, ['date', 'datetime']));
        String? items = _get(cells, idx, ['items', 'item', 'services', 'type_of_expense', 'expense']);
        String? notes = _get(cells, idx, ['notes', 'note', 'remark', 'remarks']);

        final mileageStr = _get(cells, idx, ['mileage', 'mileage_km', 'odometer', 'odo']);
        final mileage = _toDouble(mileageStr);

        // Fuel fields
        final volume = _toDouble(_get(cells, idx, ['volume', 'liters', 'litres', 'qty']));
        final pricePerL = _toDouble(_get(cells, idx, ['price_per_l', 'price/l', 'price']));
        final totalCost = _toDouble(_get(cells, idx, ['total_cost', 'amount', 'cost', 'price_total']));
        final fullTank = _truthy(_get(cells, idx, ['is_full_tank', 'full', 'full_tank']));

        // Decide row type
        bool isFuelRow = false;
        bool isMaintRow = false;

        if (hasTypeCol) {
          if (rowType == 'fuel' || rowType == 'gas' || rowType == 'refuel') isFuelRow = true;
          if (rowType == 'service' || rowType == 'maintenance' || rowType == 'expense') isMaintRow = true;
        } else {
          isFuelRow = hasFuelHints && (volume != null || pricePerL != null || totalCost != null);
          isMaintRow = hasMaintHints && (mileage != null || items != null || notes != null || totalCost != null);
        }

        if (isFuelRow) {
          when ??= DateTime.now();
          double? vol = volume;
          if ((vol == null || vol == 0) && pricePerL != null && totalCost != null && pricePerL > 0) {
            vol = totalCost / pricePerL;
          }

          final record = FuelRecord(
            id: null,
            vehicleId: _vehicleId!,
            date: when,
            odometer: mileage ?? 0,
            volume: vol ?? 0,
            pricePerL: pricePerL,
            totalCost: totalCost,
            isFullTank: fullTank,
          );

          await fuelRepo.addFuelRecord(record);
          fuelCount++;
          continue;
        }

        if (isMaintRow) {
          when ??= DateTime.now();
          final cost = totalCost;

          // Merge item type + notes into a single display field
          final mergedNotes = [
            if (items != null && items.isNotEmpty) 'Type: $items',
            if (notes != null && notes.isNotEmpty) 'Notes: $notes',
          ].join(' | ');

          final entry = ServiceLogEntry(
            id: null,
            vehicleId: _vehicleId!,
            serviceDate: when,
            mileageAtService: (mileage ?? 0).toDouble(),
            cost: cost,
            notes: mergedNotes.isEmpty ? null : mergedNotes,
          );

          await _insertServiceLogEntry(entry); // camelCase columns
          maintCount++;
          continue;
        }

        // Unknown line, skip silently
      }

      // Refresh vehicle mileage from both tables using camelCase columns
      await _refreshVehicleMileage(_vehicleId!);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported: $fuelCount fuel, $maintCount maintenance/expenses')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _vehicleName == null ? 'Vehicle: Not set' : 'Vehicle: $_vehicleName';

    // Layout puts buttons under the title to avoid squeezing title on narrow screens.
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              dense: false,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.upload_file, color: Theme.of(context).colorScheme.primary),
              title: const Text('Import vehicle data (Fuel + Maintenance)'),
              subtitle: Text(label),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _pickVehicle(context),
                  child: const Text('Choose vehicle'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : () => _importCsv(context),
                  child: _busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        )
                      : const Text('Import CSV'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- helpers ----------------

  static String _normalizeKey(String s) {
    final t = s.trim().toLowerCase();
    // unify common variants
    return t
        .replaceAll(' ', '_')
        .replaceAll('-', '_')
        .replaceAll('/', '_');
  }

  String? _get(List<String> row, Map<String, int> idx, List<String> keys) {
    for (final k in keys.map(_normalizeKey)) {
      final i = idx[k];
      if (i != null && i < row.length) {
        final v = row[i].trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    final cands = [
      'yyyy-MM-dd HH:mm',
      'yyyy-MM-dd',
      'dd/MM/yyyy',
      'MM/dd/yyyy',
      'yyyy/MM/dd',
      'dd-MM-yyyy',
      'yyyy.MM.dd',
    ];
    for (final fmt in cands) {
      try {
        return DateFormat(fmt).parseStrict(s);
      } catch (_) {}
    }
    // try epoch ms
    try {
      final ms = int.parse(s);
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {}
    return null;
  }

  double? _toDouble(String? s) {
    if (s == null || s.isEmpty) return null;
    final t = s
        .replaceAll(',', '')
        .replaceAll('LKR', '')
        .replaceAll('Rs', '')
        .replaceAll('usd', '')
        .trim();
    return double.tryParse(t);
  }

  bool _truthy(String? s) {
    if (s == null) return false;
    final t = s.trim().toLowerCase();
    return t == '1' || t == 'true' || t == 'yes' || t == 'y';
  }

  /// Direct insert using camelCase column names to match your DB schema.
  Future<void> _insertServiceLogEntry(ServiceLogEntry e) async {
    final db = await DatabaseHelper().database;
    await db.insert('service_log_entries', {
      'vehicleId': e.vehicleId,
      'serviceDate': e.serviceDate.toIso8601String(),
      'mileageAtService': e.mileageAtService,
      'cost': e.cost,
      'notes': e.notes,
    });
  }

  /// Recompute and persist the vehicle's mileage using MAX across both tables.
  Future<void> _refreshVehicleMileage(int vehicleId) async {
    final db = await DatabaseHelper().database;

    // fuel_records likely uses camelCase 'vehicleId'
    final fr = await db.rawQuery(
      'SELECT MAX(odometer) AS m FROM fuel_records WHERE vehicleId = ?',
      [vehicleId],
    );
    final sr = await db.rawQuery(
      'SELECT MAX(mileageAtService) AS m FROM service_log_entries WHERE vehicleId = ?',
      [vehicleId],
    );

    double maxFuelOdo = 0;
    double maxSvcOdo = 0;

    final mf = fr.isNotEmpty ? fr.first['m'] : null;
    if (mf is int) maxFuelOdo = mf.toDouble();
    if (mf is double) maxFuelOdo = mf;

    final ms = sr.isNotEmpty ? sr.first['m'] : null;
    if (ms is int) maxSvcOdo = ms.toDouble();
    if (ms is double) maxSvcOdo = ms;

    final newMileage = [maxFuelOdo, maxSvcOdo].reduce((a, b) => a > b ? a : b);

    await db.update(
      'vehicles',
      {
        'mileage': newMileage,
        'mileage_last_updated': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [vehicleId],
    );
  }
}
