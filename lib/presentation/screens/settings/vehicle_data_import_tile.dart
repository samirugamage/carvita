import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:intl/intl.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/models/service_log_entry.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/data/repositories/vehicle_repository.dart';
import 'package:carvita/data/sources/local/database_helper.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_cubit.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_state.dart';

/// A compact import tile that lets the user:
/// 1) Pick a target vehicle
/// 2) Import a CSV that can contain both Fuel and Maintenance rows.
///
/// Fuel hints: any of [volume, price_per_l, total_cost]
/// Maintenance hints: any of [mileage / odometer, cost, items, notes]
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
    final state = context.read<VehicleCubit>().state;
    if (state is! VehicleLoaded || state.vehicles.isEmpty) {
      // Ensure vehicles are loaded
      context.read<VehicleCubit>().fetchVehicles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No vehicles. Please add a vehicle first.')),
        );
      }
      return;
    }
    final vehicles = state.vehicles;

    final selected = await showDialog<(int, String)?>(context: context, builder: (ctx) {
      int? tempId = _vehicleId ?? vehicles.first.id;
      return AlertDialog(
        title: const Text('Choose vehicle'),
        content: StatefulBuilder(
          builder: (ctx, setSt) => DropdownButton<int>(
            isExpanded: true,
            value: tempId,
            items: [
              for (final v in vehicles) DropdownMenuItem(value: v.id, child: Text(v.name)),
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
    });

    if (!mounted) return;
    if (selected != null) {
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

    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (picked == null || picked.files.isEmpty) return;
    final p = picked.files.first.path;
    if (p == null) return;

    setState(() => _busy = true);
    int fuelCount = 0, maintCount = 0;

    try {
      final text = await File(p).readAsString();
      final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(text);
      if (rows.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV is empty')));
        }
        return;
      }

      // Header
      final header = rows.first.map((e) => e.toString().trim().toLowerCase()).toList();
      final idx = Map<String, int>.fromEntries(header.asMap().entries.map((e) => MapEntry(header[e.key], e.key)));

      final hasFuelHints = header.contains('volume') || header.contains('price_per_l') || header.contains('total_cost');
      final hasMaintHints = header.contains('mileage') ||
          header.contains('mileage_km') ||
          header.contains('odometer') ||
          header.contains('items') ||
          header.contains('notes') ||
          header.contains('cost');

      // detect decimal comma once from first non-empty numeric field
      final decComma = _detectDecimalComma(rows.skip(1).map((r) => r.map((e) => e?.toString() ?? '').toList()));

      final fuelRepo = FuelRepository(dbHelper: DatabaseHelper());

      for (int r = 1; r < rows.length; r++) {
        final raw = rows[r];
        final cells = raw.map((e) => e?.toString().trim() ?? '').toList();
        if (cells.every((c) => c.isEmpty)) continue;

        DateTime? when = _parseDate(_val(cells, idx, ['date', 'datetime']));

        final mileage = _toNum(_val(cells, idx, ['mileage', 'mileage_km', 'odometer', 'odo']), decComma: decComma);
        final volume = _toNum(_val(cells, idx, ['volume', 'liters', 'litres', 'qty']), decComma: decComma);
        final pricePerL = _toNum(_val(cells, idx, ['price_per_l', 'price/l', 'price']), decComma: decComma);
        final totalCost = _toNum(_val(cells, idx, ['total_cost', 'amount', 'cost']), decComma: decComma);
        final items = _val(cells, idx, ['items', 'item', 'services']);
        final notes = _val(cells, idx, ['notes', 'note', 'remark', 'remarks']);
        final fullTank = _truthy(_val(cells, idx, ['is_full_tank', 'full', 'full_tank']));

        final isFuelRow = hasFuelHints && (volume != null || pricePerL != null || totalCost != null);
        final isMaintRow = hasMaintHints && (mileage != null || items != null || notes != null);

        if (isFuelRow) {
          when ??= DateTime.now();
          double? vol = volume;
          if ((vol == null || vol == 0) && pricePerL != null && totalCost != null && pricePerL > 0) {
            vol = totalCost / pricePerL;
          }

          final rec = FuelRecord(
            id: null,
            vehicleId: _vehicleId!,
            date: when,
            odometer: (mileage ?? 0).toDouble(),
            volume: (vol ?? 0).toDouble(),
            pricePerL: pricePerL,
            totalCost: totalCost,
            isFullTank: fullTank,
          );
          await fuelRepo.addFuelRecord(rec);
          fuelCount++;
        } else if (isMaintRow) {
          when ??= DateTime.now();
          final mergedNotes = [
            if (items != null && items.isNotEmpty) 'Items: $items',
            if (notes != null && notes.isNotEmpty) notes,
          ].join(' | ');

          final entry = ServiceLogEntry(
            id: null,
            vehicleId: _vehicleId!,
            serviceDate: when,
            mileageAtService: (mileage ?? 0).toDouble(),
            cost: totalCost,
            notes: mergedNotes.isEmpty ? null : mergedNotes,
          );
          await _insertServiceLogEntry(entry);
          maintCount++;
        }
      }

      // Optional: ask VehicleCubit to refresh UI after import
      try {
        context.read<VehicleCubit>().fetchVehicles();
      } catch (_) {}

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported: $fuelCount fuel, $maintCount maintenance')),
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
    return ListTile(
      leading: Icon(Icons.upload_file, color: Theme.of(context).colorScheme.primary),
      title: const Text(
        'Import vehicle data (Fuel + Maintenance)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      contentPadding: EdgeInsets.zero,
      trailing: _busy
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.primary),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(onPressed: () => _pickVehicle(context), child: const Text('Choose vehicle')),
                const SizedBox(width: 8),
                FilledButton(onPressed: () => _importCsv(context), child: const Text('Import CSV')),
              ],
            ),
      onTap: () => _pickVehicle(context),
    );
  }

  // ---------------- helpers ----------------

  String? _val(List<String> row, Map<String, int> idx, List<String> keys) {
    for (final k in keys) {
      final i = idx[k];
      if (i != null && i < row.length) {
        final v = row[i].trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  bool _detectDecimalComma(Iterable<List<String>> rows) {
    for (final r in rows) {
      for (final c in r) {
        // look for number-like with comma
        if (c.contains(',') && RegExp(r'^\d{1,3}([.,]\d{3})*([,]\d+)?$').hasMatch(c)) {
          return true;
        }
      }
    }
    return false;
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
    // timestamp
    try {
      final ms = int.parse(s);
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {}
    return null;
  }

  double? _toNum(String? s, {required bool decComma}) {
    if (s == null || s.trim().isEmpty) return null;
    var t = s.trim();
    t = t.replaceAll('LKR', '').replaceAll('Rs', '').replaceAll('\$', '').trim();
    if (decComma) {
      // 1.234,56 -> 1234.56
      t = t.replaceAll('.', '').replaceAll(',', '.');
    } else {
      // 1,234.56 -> 1234.56
      t = t.replaceAll(',', '');
    }
    return double.tryParse(t);
    }

  bool _truthy(String? s) {
    if (s == null) return false;
    final t = s.trim().toLowerCase();
    return t == '1' || t == 'true' || t == 'yes' || t == 'y';
  }

  /// Direct insert for ServiceLogEntry using DatabaseHelper with camelCase column names.
  Future<void> _insertServiceLogEntry(ServiceLogEntry e) async {
    final db = await DatabaseHelper().database;
    await db.insert('service_log_entries', {
      'vehicleId': e.vehicleId,
      'service_date': e.serviceDate.millisecondsSinceEpoch,
      'mileage_at_service': e.mileageAtService,
      'cost': e.cost,
      'notes': e.notes,
    });
  }
}
