import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/data/sources/local/database_helper.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_cubit.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_state.dart';

class VehicleFuelImportTile extends StatefulWidget {
  const VehicleFuelImportTile({super.key});

  @override
  State<VehicleFuelImportTile> createState() => _VehicleFuelImportTileState();
}

class _VehicleFuelImportTileState extends State<VehicleFuelImportTile> {
  final _fuelRepo = FuelRepository(dbHelper: DatabaseHelper());

  int? _vehicleId;
  String _vehicleName = 'Not set';
  bool _busy = false;

  Future<void> _chooseVehicle(BuildContext context) async {
    final state = context.read<VehicleCubit>().state;
    if (state is! VehicleLoaded || state.vehicles.isEmpty) {
      context.read<VehicleCubit>().fetchVehicles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Loading vehicles... try again')),
      );
      return;
    }
    final picked = await showDialog<_VItem?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose vehicle'),
        children: [
          ...state.vehicles.map(
            (v) => SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, _VItem(v.id!, v.name)),
              child: Text(v.name),
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

      int imported = 0;
      double maxOdo = 0;

      if (sections.containsKey('Refuelling')) {
        final rows = _parseCsvTable(sections['Refuelling']!);
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
            vehicleId: _vehicleId!,
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
          imported++;
        }
      }

      if (maxOdo > 0) {
        await _updateVehicleMileageIfHigher(_vehicleId!, maxOdo);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported $imported fuel record(s) for $_vehicleName')),
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
      leading: Icon(Icons.local_gas_station_outlined,
          color: Theme.of(context).colorScheme.primary),
      title: const Text('Import fuel records (CSV)'),
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

class _VItem {
  final int id; final String name;
  _VItem(this.id, this.name);
}
