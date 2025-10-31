import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:intl/intl.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/models/service_log_entry.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/data/sources/local/database_helper.dart';
import 'package:carvita/data/repositories/vehicle_repository.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_cubit.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_state.dart';

/// Single tile that lets you choose a vehicle and import one CSV.
/// It imports both fuel rows and maintenance rows.
///
/// Fuel rows are recognized if any of: volume, price_per_l, total_cost
/// Maintenance rows are recognized if any of: mileage/odometer, cost, items, notes
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
    List<dynamic> vehicles = [];
    if (vehicleState is VehicleLoaded) {
      vehicles = vehicleState.vehicles;
    }

    if (vehicles.isEmpty) {
      // Ask cubit to fetch if not loaded yet
      context.read<VehicleCubit>().fetchVehicles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No vehicles. Please add a vehicle first.')),
        );
      }
      return;
    }

    int? tempId = _vehicleId ?? vehicles.first.id as int?;
    final selected = await showDialog<int?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Choose vehicle'),
          content: StatefulBuilder(
            builder: (ctx, setSt) => DropdownButton<int>(
              isExpanded: true,
              value: tempId,
              items: [
                for (final v in vehicles)
                  DropdownMenuItem<int>(value: v.id as int, child: Text(v.name as String)),
              ],
              onChanged: (val) => setSt(() => tempId = val),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, tempId),
              child: const Text('Select'),
            ),
          ],
        );
      },
    );

    if (selected != null && mounted) {
      final v = vehicles.firstWhere((x) => x.id == selected);
      setState(() {
        _vehicleId = selected;
        _vehicleName = v.name as String?;
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

      final header = rows.first.map((e) => e.toString().trim().toLowerCase()).toList();
      final idx = Map<String, int>.fromEntries(
        header.asMap().entries.map((e) => MapEntry(header[e.key], e.key)),
      );

      final hasFuelHints = header.contains('volume') || header.contains('price_per_l') || header.contains('total_cost');
      final hasMaintHints = header.contains('mileage') || header.contains('mileage_km') || header.contains('odometer')
          || header.contains('items') || header.contains('notes') || header.contains('cost');

      final fuelRepo = FuelRepository(dbHelper: DatabaseHelper());

      for (int r = 1; r < rows.length; r++) {
        final cells = rows[r].map((e) => (e ?? '').toString().trim()).toList();
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

        final isFuelRow = hasFuelHints && (volume != null || pricePerL != null || totalCost != null);
        final isMaintRow = hasMaintHints && (mileage != null || items != null || notes != null);

        if (isFuelRow) {
          // Default date if missing
          when ??= DateTime.now();

          // compute volume if missing and we have price * total
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
          // Default date if missing
          when ??= DateTime.now();
          final cost = totalCost;

          // merge item names into notes so they display in history
          final mergedNotes = [
            if (items != null && items.isNotEmpty) 'Items: $items',
            if (notes != null && notes.isNotEmpty) notes,
          ].join(' | ').trim();

          final entry = ServiceLogEntry(
            id: null,
            vehicleId: _vehicleId!,
            serviceDate: when,
            mileageAtService: (mileage ?? 0).toDouble(),
            cost: cost,
            notes: mergedNotes.isEmpty ? null : mergedNotes,
          );

          await _insertServiceLogEntry(entry);
          maintCount++;
        } else {
          // Skip line that doesn't look like either
        }
      }

      // Recompute and update vehicle mileage without calling unknown repository methods
      await _recomputeMileageFromRecords(_vehicleId!);

      // Refresh vehicle list on UI
      if (mounted) {
        context.read<VehicleCubit>().fetchVehicles();
      }

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
      title: const Text('Import vehicle data'),
      subtitle: Text('$label  •  Fuel + Maintenance'),
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
    final fmts = <String>[
      'yyyy-MM-dd HH:mm',
      'yyyy-MM-dd',
      'dd/MM/yyyy',
      'MM/dd/yyyy',
      'yyyy/MM/dd',
      'dd-MM-yyyy',
      'yyyy.MM.dd',
    ];
    for (final f in fmts) {
      try {
        return DateFormat(f).parseStrict(s);
      } catch (_) {}
    }
    // maybe epoch ms
    try {
      final ms = int.parse(s);
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {}
    return null;
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
  Future<void> _insertServiceLogEntry(ServiceLogEntry e) async {
    final db = await DatabaseHelper().database;
    await db.insert('service_log_entries', {
      'vehicle_id': e.vehicleId,
      'service_date': e.serviceDate.millisecondsSinceEpoch,
      'mileage_at_service': e.mileageAtService,
      'cost': e.cost,
      'notes': e.notes,
    });
  }

  /// Recompute mileage as the max of fuel.odometer and service_log.mileage_at_service,
  /// then update the vehicle row.
  Future<void> _recomputeMileageFromRecords(int vehicleId) async {
    final db = await DatabaseHelper().database;

    double maxFuel = 0;
    double maxMaint = 0;

    // max from fuel_records
    final fr = await db.rawQuery(
      'SELECT MAX(odometer) AS m FROM fuel_records WHERE vehicle_id = ?',
      [vehicleId],
    );
    if (fr.isNotEmpty && fr.first['m'] != null) {
      final v = fr.first['m'];
      if (v is int) maxFuel = v.toDouble();
      if (v is double) maxFuel = v;
    }

    // max from service_log_entries
    final sr = await db.rawQuery(
      'SELECT MAX(mileage_at_service) AS m FROM service_log_entries WHERE vehicle_id = ?',
      [vehicleId],
    );
    if (sr.isNotEmpty && sr.first['m'] != null) {
      final v = sr.first['m'];
      if (v is int) maxMaint = v.toDouble();
      if (v is double) maxMaint = v;
    }

    final newMileage = maxFuel > maxMaint ? maxFuel : maxMaint;

    // update vehicles.mileage if greater than current
    try {
      final cur = await db.rawQuery(
        'SELECT mileage FROM vehicles WHERE id = ?',
        [vehicleId],
      );
      double currentMileage = 0;
      if (cur.isNotEmpty && cur.first['mileage'] != null) {
        final v = cur.first['mileage'];
        if (v is int) currentMileage = v.toDouble();
        if (v is double) currentMileage = v;
      }

      if (newMileage >= 0 && newMileage != currentMileage) {
        await db.update(
          'vehicles',
          {'mileage': newMileage},
          where: 'id = ?',
          whereArgs: [vehicleId],
        );
      }
    } catch (_) {
      // If vehicles table or mileage column differ, silently ignore
    }
  }
}
