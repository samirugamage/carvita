import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:intl/intl.dart';

import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/models/service_log_entry.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/data/repositories/vehicle_repository.dart';
import 'package:carvita/data/sources/local/database_helper.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Neat, single ListTile that lets you choose a vehicle and import one CSV.
/// It imports fuel rows and maintenance rows.
/// Fuel rows are recognized if they have any of: volume, price_per_l, total_cost.
/// Maintenance rows are recognized if they have any of: mileage, cost, items, notes.
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
      final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(text);
      if (rows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV is empty')));
        return;
      }

      final header = rows.first.map((e) => e.toString().trim().toLowerCase()).toList();
      final idx = Map<String, int>.fromEntries(
        header.asMap().entries.map((e) => MapEntry(header[e.key], e.key)),
      );

      bool hasFuelHints = header.contains('volume') || header.contains('price_per_l') || header.contains('total_cost');
      bool hasMaintHints = header.contains('mileage') || header.contains('mileage_km') || header.contains('items') || header.contains('notes') || header.contains('cost');

      final fuelRepo = FuelRepository(dbHelper: DatabaseHelper());

      // Optional: If you have a dedicated ServiceLog repository, import it here.
      // If your repository has a different name, update the import above and variable here.
      // Example name used in your codebase:
      // import 'package:carvita/data/repositories/service_log_repository.dart';
      // final serviceRepo = ServiceLogRepository();
      //
      // To keep compilation safe if you have a different file name,
      // we will insert via a minimal helper at the bottom using DatabaseHelper.

      for (int r = 1; r < rows.length; r++) {
        final cells = rows[r].map((e) => e?.toString().trim() ?? '').toList();
        if (cells.every((c) => c.isEmpty)) continue;

        DateTime? when = _parseDate(_get(cells, idx, ['date', 'datetime']));
        String? items = _get(cells, idx, ['items', 'item', 'services']);
        String? notes = _get(cells, idx, ['notes', 'note', 'remark', 'remarks']);

        final mileageStr = _get(cells, idx, ['mileage', 'mileage_km', 'odometer', 'odo']);
        final mileage = _toDouble(mileageStr);

        // Fuel fields
        final volume = _toDouble(_get(cells, idx, ['volume', 'liters', 'litres', 'qty']));
        final pricePerL = _toDouble(_get(cells, idx, ['price_per_l', 'price/l', 'price']));
        final totalCost = _toDouble(_get(cells, idx, ['total_cost', 'amount', 'cost']));
        final fullTank = _truthy(_get(cells, idx, ['is_full_tank', 'full', 'full_tank']));

        // Decide row type
        final isFuelRow = hasFuelHints && (volume != null || pricePerL != null || totalCost != null);
        final isMaintRow = hasMaintHints && (mileage != null || items != null || notes != null);

        if (isFuelRow) {
          // Fuel: date, odometer, volume/price/total, full tank
          // Default date fallback
          when ??= DateTime.now();

          // If user supplied only price and total, compute volume
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
        } else if (isMaintRow) {
          // Maintenance: date, mileage, items, cost, notes
          when ??= DateTime.now();
          final cost = totalCost; // reuse parsed totalCost

          // Store item names inside notes so they show up in history
          final mergedNotes = [
            if (items != null && items.isNotEmpty) 'Items: $items',
            if (notes != null && notes.isNotEmpty) notes,
          ].join(' | ');

          final entry = ServiceLogEntry(
            id: null,
            vehicleId: _vehicleId!,
            serviceDate: when,
            mileageAtService: (mileage ?? 0).toDouble(),
            cost: cost,
            notes: mergedNotes.isEmpty ? null : mergedNotes,
          );

          // Insert via helper method at bottom using DatabaseHelper
          await _insertServiceLogEntry(entry);
          maintCount++;
        } else {
          // Skip unknown line
        }
      }

      // Optional: recompute vehicle mileage from all records
      try {
        await VehicleRepository().recomputeMileageFromRecords(_vehicleId!);
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
      title: const Text('Import vehicle data (Fuel + Maintenance)'),
      subtitle: Text(label),
      contentPadding: EdgeInsets.zero,
      trailing: _busy
          ? SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            )
          : Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => _pickVehicle(context),
                  child: const Text('Choose vehicle'),
                ),
                FilledButton(
                  onPressed: () => _importCsv(context),
                  child: const Text('Import CSV'),
                ),
              ],
            ),
      onTap: () => _pickVehicle(context),
    );
  }

  // ---------------- helpers ----------------

  String? _get(List<String> row, Map<String, int> idx, List<String> keys) {
    for (final k in keys) {
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
      try { return DateFormat(fmt).parseStrict(s); } catch (_) {}
    }
    // Try timestamp
    try { final ms = int.parse(s); return DateTime.fromMillisecondsSinceEpoch(ms); } catch (_) {}
    // Fallback: now
    return DateTime.now();
  }

  double? _toDouble(String? s) {
    if (s == null || s.isEmpty) return null;
    final t = s.replaceAll(',', '').replaceAll('LKR', '').trim();
    return double.tryParse(t);
  }

  bool _truthy(String? s) {
    if (s == null) return false;
    final t = s.trim().toLowerCase();
    return t == '1' || t == 'true' || t == 'yes' || t == 'y';
  }

  /// Minimal direct insert for ServiceLogEntry using DatabaseHelper.
  /// This avoids guessing your repository class name.
  Future<void> _insertServiceLogEntry(ServiceLogEntry e) async {
    final db = await DatabaseHelper().database;
    // Table and columns match your models used in history tab.
    // Adjust only if your table uses different names.
    await db.insert('service_log_entries', {
      'vehicle_id': e.vehicleId,
      'service_date': e.serviceDate.millisecondsSinceEpoch,
      'mileage_at_service': e.mileageAtService,
      'cost': e.cost,
      'notes': e.notes,
    });
  }
}
