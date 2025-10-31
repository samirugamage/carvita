import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:collection/collection.dart';
import 'package:intl/intl.dart';

import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/models/service_log_entry.dart';
import 'package:carvita/data/models/service_log_performed_item_link.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/data/repositories/maintenance_repository.dart';
import 'package:carvita/data/sources/local/database_helper.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_cubit.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_state.dart';

class VehicleDataImportTile extends StatefulWidget {
  const VehicleDataImportTile({super.key});

  @override
  State<VehicleDataImportTile> createState() => _VehicleDataImportTileState();
}

class _VehicleDataImportTileState extends State<VehicleDataImportTile> {
  final _fuelRepo = FuelRepository(dbHelper: DatabaseHelper());
  final _maintRepo = MaintenanceRepository(dbHelper: DatabaseHelper());

  int? _vehicleId;
  String _vehicleName = 'Not set';
  bool _busy = false;

  Future<void> _chooseVehicle(BuildContext context) async {
    final state = context.read<VehicleCubit>().state;
    List<VehicleListItem> items = [];
    if (state is VehicleLoaded) {
      items = state.vehicles
          .map((v) => VehicleListItem(id: v.id!, name: v.name))
          .toList();
    }
    if (items.isEmpty) {
      // trigger fetch and show a note
      context.read<VehicleCubit>().fetchVehicles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Loading vehicles... try again shortly')),
      );
      return;
    }
    final picked = await showDialog<VehicleListItem?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose vehicle'),
        children: [
          ...items.map(
            (it) => SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, it),
              child: Text(it.name),
            ),
          ),
        ],
      ),
    );
    if (picked != null) {
      setState(() {
        _vehicleId = picked.id;
        _vehicleName = picked.name;
      });
    }
  }

  Future<void> _importCsv(BuildContext context) async {
    if (_vehicleId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a vehicle first')),
      );
      return;
    }

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null) return;

    setState(() => _busy = true);

    try {
      final text = await File(path).readAsString();
      final sections = _splitIntoSections(text);
      double maxOdo = 0;
      final vehicleId = _vehicleId!;

      // Fuel
      if (sections.containsKey('Refuelling')) {
        final rows = _parseCsvTable(sections['Refuelling']!);
        int importedFuel = 0;
        for (final row in rows) {
          final dateStr = (row['Date'] ?? '').toString().trim();
          final date = DateTime.tryParse(dateStr) ?? _lenientParseDate(dateStr);
          final odo = _d(row['Odometer (km)']);
          final pricePerL = _d(row['Price / L']);
          final totalCost = _d(row['Total cost']) ?? _d(row['Total']);
          final volume = _d(row['Volume']) ?? _deriveVolume(pricePerL, totalCost);
          final notes = _s(row['Notes']);
          final full = _b(row['Filled tank completely']);

          if (date == null || odo == null || volume == null) continue;

          final rec = FuelRecord(
            id: null,
            vehicleId: vehicleId,
            date: date,
            odometer: odo,
            volume: volume,
            pricePerL: pricePerL,
            totalCost: totalCost,
            isFullTank: full,
            notes: notes?.isEmpty == true ? null : notes,
          );
          await _fuelRepo.addFuelRecord(rec);
          if (odo > maxOdo) maxOdo = odo;
          importedFuel++;
        }
        if (importedFuel > 0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported $importedFuel fuel record(s) for $_vehicleName')),
          );
        }
      }

      // Service
      if (sections.containsKey('Service')) {
        final rows = _parseCsvTable(sections['Service']!);
        // group rows by same date + odometer into one ServiceLog with multiple items
        final grouped = groupBy<Map<String, dynamic>, String>(rows, (r) {
          final d = (r['Date'] ?? '').toString().trim();
          final o = (r['Odometer (km)'] ?? '').toString().trim();
          return '$d|$o';
        });
        int importedService = 0;
        for (final key in grouped.keys) {
          final group = grouped[key]!;
          final any = group.first;
          final dateStr = (any['Date'] ?? '').toString().trim();
          final date = DateTime.tryParse(dateStr) ?? _lenientParseDate(dateStr);
          final odo = _d(any['Odometer (km)']);
          if (date == null || odo == null) continue;

          // items + total cost
          final items = <PerformedItemInput>[];
          double total = 0;
          for (final r in group) {
            final name = _s(r['Type of service']) ?? _s(r['Local service']) ?? 'Service';
            final cost = _d(r['Total cost']);
            if (name != null && name.trim().isNotEmpty) {
              items.add(PerformedItemInput(customItemName: name.trim()));
            }
            if (cost != null) total += cost;
          }

          final entry = ServiceLogEntry(
            id: null,
            vehicleId: vehicleId,
            serviceDate: date,
            mileageAtService: odo,
            cost: total == 0 ? null : total,
            notes: null,
          );

          await _maintRepo.addServiceLog(entry, items);
          if (odo > maxOdo) maxOdo = odo;
          importedService++;
        }
        if (importedService > 0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported $importedService maintenance log(s) for $_vehicleName')),
          );
        }
      }

      // optionally import ##Expense as service logs too
      if (sections.containsKey('Expense')) {
        final rows = _parseCsvTable(sections['Expense']!);
        final grouped = groupBy<Map<String, dynamic>, String>(rows, (r) {
          final d = (r['Date'] ?? '').toString().trim();
          final o = (r['Odometer (km)'] ?? '').toString().trim();
          return '$d|$o';
        });
        int importedExp = 0;
        for (final key in grouped.keys) {
          final group = grouped[key]!;
          final any = group.first;
          final dateStr = (any['Date'] ?? '').toString().trim();
          final date = DateTime.tryParse(dateStr) ?? _lenientParseDate(dateStr);
          final odo = _d(any['Odometer (km)']);
          if (date == null || odo == null) continue;

          final items = <PerformedItemInput>[];
          double total = 0;
          for (final r in group) {
            final t = _s(r['Type of expense']) ?? _s(r['Local expense']) ?? 'Expense';
            final c = _d(r['Total cost']);
            if (t != null && t.trim().isNotEmpty) {
              items.add(PerformedItemInput(customItemName: 'Expense: ${t.trim()}'));
            }
            if (c != null) total += c;
          }

          final entry = ServiceLogEntry(
            id: null,
            vehicleId: vehicleId,
            serviceDate: date,
            mileageAtService: odo,
            cost: total == 0 ? null : total,
            notes: null,
          );
          await _maintRepo.addServiceLog(entry, items);
          if (odo > maxOdo) maxOdo = odo;
          importedExp++;
        }
        if (importedExp > 0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported $importedExp expense log(s) as maintenance for $_vehicleName')),
          );
        }
      }

      if (maxOdo > 0) {
        await _updateVehicleMileageIfHigher(vehicleId, maxOdo);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Import finished')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(Icons.system_update_alt_outlined,
          color: Theme.of(context).colorScheme.primary),
      title: const Text('Import vehicle data (Fuel + Maintenance)'),
      subtitle: Text(_vehicleId == null ? 'Vehicle: $_vehicleName' : 'Vehicle: $_vehicleName (#$_vehicleId)'),
      trailing: _busy
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            )
          : Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => _chooseVehicle(context),
                  child: const Text('Choose vehicle'),
                ),
                FilledButton.icon(
                  onPressed: () => _importCsv(context),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import CSV'),
                ),
              ],
            ),
    );
  }

  // helpers

  Future<void> _updateVehicleMileageIfHigher(int vehicleId, double newMileage) async {
    final db = await DatabaseHelper().database;
    final rows = await db.query(
      'vehicles',
      columns: ['mileage'],
      where: 'id = ?',
      whereArgs: [vehicleId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final current = (rows.first['mileage'] as num?)?.toDouble() ?? 0.0;
    if (newMileage > current) {
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

  Map<String, String> _splitIntoSections(String fullText) {
    final lines = const LineSplitter().convert(fullText);
    final map = <String, StringBuffer>{};
    String? current;
    for (final raw in lines) {
      final line = raw.trimRight();
      final m = RegExp(r'^##\s*(\w+)\s*$').firstMatch(line);
      if (m != null) {
        current = m.group(1);
        map[current!] = StringBuffer();
      } else if (current != null) {
        map[current]!.writeln(line);
      }
    }
    return map.map((k, v) => MapEntry(k, v.toString().trim()));
  }

  List<Map<String, dynamic>> _parseCsvTable(String table) {
    final rows = const LineSplitter().convert(table).where((l) => l.trim().isNotEmpty).toList();
    if (rows.isEmpty) return [];
    final header = _splitCsvRow(rows.first);
    final data = <Map<String, dynamic>>[];
    for (int i = 1; i < rows.length; i++) {
      final parts = _splitCsvRow(rows[i]);
      final map = <String, dynamic>{};
      for (int c = 0; c < parts.length && c < header.length; c++) {
        map[header[c]] = parts[c];
      }
      data.add(map);
    }
    return data;
  }

  List<String> _splitCsvRow(String line) {
    final out = <String>[];
    final sb = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"'); i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        out.add(sb.toString()); sb.clear();
      } else {
        sb.write(ch);
      }
    }
    out.add(sb.toString());
    return out.map((s) => s.trim()).toList();
  }

  double? _d(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return double.tryParse(s.replaceAll(',', ''));
  }

  String? _s(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  bool _b(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes' || s == 'y';
  }

  DateTime? _lenientParseDate(String s) {
    final cand = [
      DateFormat('yyyy-MM-dd HH:mm:ss'),
      DateFormat('yyyy-MM-dd'),
      DateFormat('dd/MM/yyyy HH:mm:ss'),
      DateFormat('dd/MM/yyyy'),
      DateFormat('MM/dd/yyyy HH:mm:ss'),
      DateFormat('MM/dd/yyyy'),
    ];
    for (final f in cand) {
      try { return f.parseStrict(s); } catch (_) {}
    }
    return null;
  }

  double? _deriveVolume(double? pricePerL, double? totalCost) {
    if (pricePerL == null || pricePerL <= 0 || totalCost == null) return null;
    return totalCost / pricePerL;
  }
}

class VehicleListItem {
  final int id;
  final String name;
  VehicleListItem({required this.id, required this.name});
}
