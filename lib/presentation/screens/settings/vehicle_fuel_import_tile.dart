import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'package:collection/collection.dart';
import 'package:intl/intl.dart';

import 'package:carvita/data/models/vehicle.dart';
import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/models/service_log_entry.dart';
import 'package:carvita/data/models/service_log_performed_item_link.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/data/repositories/maintenance_repository.dart';
import 'package:carvita/data/repositories/vehicle_repository.dart';
import 'package:carvita/data/sources/local/database_helper.dart';

/// A settings-tile style widget that:
/// - lets the user pick a VEHICLE
/// - pick a CSV exported from your other app
/// - imports '##Refuelling' as Fuel records
/// - imports '##Service' as grouped Service Logs (items grouped by same date+odometer)
/// - optionally updates vehicle mileage if an imported odometer is higher
class VehicleDataImportTile extends StatefulWidget {
  const VehicleDataImportTile({super.key});

  @override
  State<VehicleDataImportTile> createState() => _VehicleDataImportTileState();
}

class _VehicleDataImportTileState extends State<VehicleDataImportTile> {
  final _vehRepo = VehicleRepository();
  final _fuelRepo = FuelRepository(dbHelper: DatabaseHelper());
  final _maintRepo = MaintenanceRepository(dbHelper: DatabaseHelper());

  int? _vehicleId;
  String _vehicleName = 'Not set';
  bool _busy = false;

  Future<void> _pickVehicle(BuildContext context) async {
    final vehicles = await _vehRepo.getAllVehicles();
    if (!mounted) return;

    final selected = await showDialog<Vehicle?>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: const Text('Choose vehicle'),
          children: [
            if (vehicles.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No vehicles found. Add a vehicle first.'),
              ),
            ...vehicles.map((v) {
              return SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, v),
                child: Text(v.name),
              );
            }),
          ],
        );
      },
    );

    if (selected != null) {
      setState(() {
        _vehicleId = selected.id;
        _vehicleName = selected.name;
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
      final file = File(path);
      final text = await file.readAsString();

      // Sections are introduced by lines like: ##Refuelling, ##Expense, ##Service
      final sections = _splitIntoSections(text);

      final vehicleId = _vehicleId!;
      double maxOdo = 0;

      // 1) Fuel
      if (sections.containsKey('Refuelling')) {
        final results = _parseCsvTable(sections['Refuelling']!);
        int importedFuel = 0;
        for (final row in results) {
          final odometer = _tryDouble(row['Odometer (km)']);
          final dateStr = (row['Date'] ?? '').toString().trim();
          final pricePerL = _tryDouble(row['Price / L']);
          final totalCost = _tryDouble(row['Total cost']) ?? _tryDouble(row['Total co...ost']) ?? _tryDouble(row['Total']);
          final volume = _tryDouble(row['Volume']) ?? _deriveVolume(pricePerL, totalCost);

          if (odometer == null || dateStr.isEmpty || volume == null) continue;

          final date = DateTime.tryParse(dateStr) ?? _lenientParseDate(dateStr);
          if (date == null) continue;

          final isFullTank = _parseBool(row['Filled tank completely']);
          final notes = _safeString(row['Notes']);

          final rec = FuelRecord(
            id: null,
            vehicleId: vehicleId,
            date: date,
            odometer: odometer,
            volume: volume,
            pricePerL: pricePerL,
            totalCost: totalCost,
            isFullTank: isFullTank ? 1 : 0,
            notes: notes?.isEmpty == true ? null : notes,
          );
          await _fuelRepo.addFuelRecord(rec);

          if (odometer > maxOdo) maxOdo = odometer;
          importedFuel++;
        }
        if (importedFuel > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported $importedFuel fuel record(s) for $_vehicleName')),
          );
        }
      }

      // 2) Service
      if (sections.containsKey('Service')) {
        final results = _parseCsvTable(sections['Service']!);
        // Group by Date + Odometer into a single ServiceLog with multiple items
        final grouped = groupBy<Map<String, dynamic>, String>(results, (r) {
          final d = (r['Date'] ?? '').toString().trim();
          final o = (r['Odometer (km)'] ?? '').toString().trim();
          return '$d|$o';
        });

        int importedServices = 0;
        for (final key in grouped.keys) {
          final rows = grouped[key]!;
          final any = rows.first;

          final odometer = _tryDouble(any['Odometer (km)']);
          final dateStr = (any['Date'] ?? '').toString().trim();
          if (odometer == null || dateStr.isEmpty) continue;

          final date = DateTime.tryParse(dateStr) ?? _lenientParseDate(dateStr);
          if (date == null) continue;

          // items and line costs
          final items = <PerformedItemInput>[];
          double totalCost = 0;

          for (final row in rows) {
            final name = _safeString(row['Type of service']) ?? _safeString(row['Local service']) ?? 'Service';
            final lineCost = _tryDouble(row['Total cost']);
            if (name != null && name.trim().isNotEmpty) {
              items.add(PerformedItemInput(customItemName: name.trim()));
            }
            if (lineCost != null) totalCost += lineCost;
          }

          final entry = ServiceLogEntry(
            id: null,
            vehicleId: vehicleId,
            serviceDate: date,
            mileageAtService: odometer,
            cost: totalCost == 0 ? null : totalCost,
            notes: null,
          );

          await _maintRepo.addServiceLog(entry, items);
          if (odometer > maxOdo) maxOdo = odometer;
          importedServices++;
        }

        if (importedServices > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported $importedServices maintenance log(s) for $_vehicleName')),
          );
        }
      }

      // 3) You also have an ##Expense section in your CSV.
      // If you want these as generic service logs labeled "Expense: <Type>",
      // flip this flag to true. Otherwise leave them untouched.
      const importExpensesAsService = true;
      if (importExpensesAsService && sections.containsKey('Expense')) {
        final results = _parseCsvTable(sections['Expense']!);

        // Group expenses with same date + odometer into one log
        final grouped = groupBy<Map<String, dynamic>, String>(results, (r) {
          final d = (r['Date'] ?? '').toString().trim();
          final o = (r['Odometer (km)'] ?? '').toString().trim();
          return '$d|$o';
        });

        int importedExp = 0;
        for (final key in grouped.keys) {
          final rows = grouped[key]!;
          final any = rows.first;

          final odometer = _tryDouble(any['Odometer (km)']);
          final dateStr = (any['Date'] ?? '').toString().trim();
          if (odometer == null || dateStr.isEmpty) continue;

          final date = DateTime.tryParse(dateStr) ?? _lenientParseDate(dateStr);
          if (date == null) continue;

          final items = <PerformedItemInput>[];
          double total = 0;
          for (final r in rows) {
            final t = _safeString(r['Type of expense']) ?? _safeString(r['Local expense']) ?? 'Expense';
            final c = _tryDouble(r['Total cost']);
            if (t != null && t.trim().isNotEmpty) {
              items.add(PerformedItemInput(customItemName: 'Expense: ${t.trim()}'));
            }
            if (c != null) total += c;
          }

          final entry = ServiceLogEntry(
            id: null,
            vehicleId: vehicleId,
            serviceDate: date,
            mileageAtService: odometer,
            cost: total == 0 ? null : total,
            notes: null,
          );
          await _maintRepo.addServiceLog(entry, items);
          if (odometer > maxOdo) maxOdo = odometer;
          importedExp++;
        }

        if (importedExp > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported $importedExp expense log(s) as maintenance for $_vehicleName')),
          );
        }
      }

      // Update vehicle mileage if any higher odometer seen
      if (maxOdo > 0) {
        await _vehRepo.updateMileageIfHigher(_vehicleId!, maxOdo);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Import finished')),
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
                  onPressed: () => _pickVehicle(context),
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

  // ---------- Helpers ----------

  Map<String, String> _splitIntoSections(String fullText) {
    // Find lines starting with ##<Name>
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
    // Use a forgiving parser. Lines may contain commas in headers and extra unknown columns.
    // We keep a header row and split by commas respecting quotes.
    final rows = const LineSplitter().convert(table).where((l) => l.trim().isNotEmpty).toList();
    if (rows.isEmpty) return [];

    // header
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
    // very small CSV parser for quoted fields
    final out = <String>[];
    final sb = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        out.add(sb.toString());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }
    out.add(sb.toString());
    return out.map((s) => s.trim()).toList();
  }

  double? _tryDouble(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return double.tryParse(s.replaceAll(',', ''));
  }

  bool _parseBool(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes' || s == 'y';
  }

  String? _safeString(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return s;
  }

  DateTime? _lenientParseDate(String s) {
    // Try few common formats if plain DateTime.parse fails
    final cand = [
      DateFormat('yyyy-MM-dd HH:mm:ss'),
      DateFormat('yyyy-MM-dd'),
      DateFormat('dd/MM/yyyy HH:mm:ss'),
      DateFormat('dd/MM/yyyy'),
      DateFormat('MM/dd/yyyy HH:mm:ss'),
      DateFormat('MM/dd/yyyy'),
    ];
    for (final f in cand) {
      try {
        return f.parseStrict(s);
      } catch (_) {}
    }
    return null;
  }

  double? _deriveVolume(double? pricePerL, double? totalCost) {
    if (pricePerL == null || pricePerL <= 0 || totalCost == null) return null;
    return totalCost / pricePerL;
  }
}
