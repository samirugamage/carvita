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
import 'package:carvita/presentation/manager/vehicle_list/vehicle_cubit.dart';
import 'package:carvita/presentation/manager/vehicle_list/vehicle_state.dart';

/// A compact ListTile that lets you choose a vehicle and import one CSV.
/// Supports multi-section CSV with headers like:
///   ##Refuelling
///   "Odometer (km)","Date","Fuel","Price / L","Total cost","Volume",...
///   ##Expense
///   "Odometer (km)","Date","Total cost","Type of expense",...
///   ##Service
///   "Odometer (km)","Date","Total cost","Type of service",...
///
/// Fuel rows will be saved to fuel_records.
/// Expense + Service rows will be saved to service_log_entries.
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No vehicles. Please add a vehicle first.')),
      );
      return;
    }

    final selected = await showDialog<(int, String)?>(
      context: context,
      builder: (ctx) {
        int? tempId = _vehicleId ?? vehicles.first.id as int?;
        return AlertDialog(
          title: const Text('Choose vehicle'),
          content: StatefulBuilder(
            builder: (ctx, setSt) => DropdownButton<int>(
              isExpanded: true,
              value: tempId,
              items: [
                for (final v in vehicles)
                  DropdownMenuItem(value: v.id as int, child: Text(v.name as String)),
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

    final p = picked.files.first.path;
    if (p == null) return;

    setState(() => _busy = true);
    int fuelCount = 0;
    int maintCount = 0;

    try {
      final text = await File(p).readAsString();
      final lines = text.split(RegExp(r'\r?\n'));

      final csv = const CsvToListConverter(shouldParseNumbers: false);

      String mode = ''; // 'fuel' 'expense' 'service'
      List<String> header = [];
      Map<String, int> idx = {};

      FuelRepository fuelRepo = FuelRepository(dbHelper: DatabaseHelper());

      String? headerLineBuffer;

      String? nextNonEmptyLine(List<String> ls, int start) {
        for (int i = start; i < ls.length; i++) {
          final t = ls[i].trim();
          if (t.isNotEmpty) return ls[i];
        }
        return null;
      }

      for (int i = 0; i < lines.length; i++) {
        final raw = lines[i];
        final line = raw.trim();
        if (line.isEmpty) {
          continue;
        }

        // Section start
        if (line.startsWith('##')) {
          final tag = line.substring(2).trim().toLowerCase();
          if (tag.startsWith('refuelling')) {
            mode = 'fuel';
          } else if (tag.startsWith('expense')) {
            mode = 'expense';
          } else if (tag.startsWith('service')) {
            mode = 'service';
          } else {
            mode = '';
          }
          // reset header for new section
          header = [];
          idx = {};
          // The next non-empty line should be the header
          headerLineBuffer = nextNonEmptyLine(lines, i + 1);
          if (headerLineBuffer != null) {
            final parsed = csv.convert(headerLineBuffer!);
            if (parsed.isNotEmpty) {
              header = parsed.first.map((e) => e.toString()).toList();
              idx = _buildIndex(header);
            }
          }
          continue;
        }

        // If we do not have a header yet in current mode try to parse this as header
        if (mode.isNotEmpty && header.isEmpty) {
          final parsed = csv.convert(line);
          if (parsed.isNotEmpty) {
            header = parsed.first.map((e) => e.toString()).toList();
            idx = _buildIndex(header);
            continue;
          }
        }

        // If there is no current mode or no header skip
        if (mode.isEmpty || header.isEmpty) {
          continue;
        }

        // Stop if this looks like a new section by mistake
        if (line.startsWith('##')) {
          // loop will pick this up as a new section on next iteration
          continue;
        }

        // Parse this row
        final parsed = csv.convert(raw);
        if (parsed.isEmpty) continue;
        final row = parsed.first.map((e) => (e ?? '').toString()).toList();

        // Skip lines that are blank in all useful columns
        final joined = row.join('').trim();
        if (joined.isEmpty) continue;

        if (mode == 'fuel') {
          final when = _parseDate(_val(row, idx, ['date']));
          final odometer = _toDouble(_val(row, idx, [
                'odometer',
                'odometer_km',
                'odometer_(km)',
                'km',
                'mileage',
              ])) ??
              0.0;

          // Volume and price
          final volume = _toDouble(_val(row, idx, ['volume', 'liters', 'litres', 'qty']));
          final pricePerL = _toDouble(_val(row, idx, [
            'price_per_l',
            'price_l',
            'price__l',
            'price___l',
            'price_liter',
            'price_litre',
            'price',
          ]));
          final totalCost = _toDouble(_val(row, idx, [
            'total_cost',
            'totalcost',
            'total',
            'amount',
            'cost',
          ]));

          // full tank field if present
          final fullTankStr = _val(row, idx, ['full_tank', 'full', 'is_full_tank', 'filled_full']);
          final isFullTank = _truthy(fullTankStr);

          final anyFuelHints = (volume != null) || (pricePerL != null) || (totalCost != null);
          if (!anyFuelHints) {
            // It might be a non-fuel line under refuelling, skip
            continue;
          }

          double volFinal = volume ?? 0.0;
          if ((volFinal == 0.0) && pricePerL != null && totalCost != null && pricePerL > 0) {
            volFinal = totalCost / pricePerL;
          }

          final record = FuelRecord(
            id: null,
            vehicleId: _vehicleId!,
            date: when ?? DateTime.now(),
            odometer: odometer,
            volume: volFinal,
            pricePerL: pricePerL,
            totalCost: totalCost,
            isFullTank: isFullTank,
          );

          await fuelRepo.addFuelRecord(record);
          fuelCount++;
        } else if (mode == 'expense' || mode == 'service') {
          final when = _parseDate(_val(row, idx, ['date'])) ?? DateTime.now();
          final odometer = _toDouble(_val(row, idx, [
            'odometer',
            'odometer_km',
            'odometer_(km)',
            'km',
            'mileage',
          ])) ??
              0.0;

          final cost = _toDouble(_val(row, idx, [
            'total_cost',
            'totalcost',
            'total',
            'amount',
            'cost',
          ]));

          final typ = _val(
            row,
            idx,
            mode == 'expense' ? ['type_of_expense', 'expense_type'] : ['type_of_service', 'service_type'],
          );
          final notes = _val(row, idx, ['notes', 'note', 'remark', 'remarks']);

          final mergedNotes = [
            if (typ != null && typ.trim().isNotEmpty) 'Type: $typ',
            if (notes != null && notes.trim().isNotEmpty) notes!,
          ].join(' | ').trim();

          final entry = ServiceLogEntry(
            id: null,
            vehicleId: _vehicleId!,
            serviceDate: when,
            mileageAtService: odometer,
            cost: cost,
            notes: mergedNotes.isEmpty ? null : mergedNotes,
          );

          await _insertServiceLogEntry(entry);
          maintCount++;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported: $fuelCount fuel, $maintCount maintenance')),
      );

      // Refresh vehicle list in UI
      context.read<VehicleCubit>().fetchVehicles();
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
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.primary),
            )
          : Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.end,
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

  // ------------- helpers -------------

  // Build a case-insensitive, normalized header index
  Map<String, int> _buildIndex(List<String> header) {
    final map = <String, int>{};
    for (int i = 0; i < header.length; i++) {
      final raw = header[i].trim();
      final lower = raw.toLowerCase();
      final norm = _norm(lower);
      map[lower] = i;
      map[norm] = i;
    }
    return map;
  }

  // Normalize header keys: lower case, non-alnum to underscore, collapse underscores
  String _norm(String s) {
    final t = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return t.replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  }

  // Try variants of keys across normalized and raw lower-case
  String? _val(List<String> row, Map<String, int> idx, List<String> keys) {
    for (final k in keys) {
      final n = _norm(k);
      final j = idx[n] ?? idx[k.toLowerCase()];
      if (j != null && j < row.length) {
        final v = row[j].toString().trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    final cands = <String>[
      'yyyy-MM-dd HH:mm:ss',
      'yyyy-MM-dd HH:mm',
      'yyyy-MM-dd',
      'dd/MM/yyyy HH:mm:ss',
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
    // Try unix ms
    try {
      final ms = int.parse(s);
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {}
    return null;
  }

  double? _toDouble(String? s) {
    if (s == null || s.isEmpty) return null;
    // Remove currency and spaces and thousands separators
    final t = s.replaceAll(RegExp(r'[^\d\.\-]'), '');
    // If there are multiple dots because of thousands separator, keep the last one
    if ('.'.allMatches(t).length > 1) {
      final last = t.lastIndexOf('.');
      final cleaned = t.replaceAll('.', '');
      final withDot = cleaned.substring(0, last) + '.' + cleaned.substring(last);
      return double.tryParse(withDot);
    }
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
}
