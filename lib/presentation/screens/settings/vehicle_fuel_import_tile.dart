import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:carvita/data/sources/local/database_helper.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/presentation/manager/fuel_records/fuel_records_cubit.dart';

/// Drop-in Settings tile that imports a Fuel CSV into a chosen vehicle.
/// It lets you pick an existing vehicle or create a new one with a starting mileage.
class VehicleFuelImportTile extends StatelessWidget {
  const VehicleFuelImportTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.local_gas_station),
      title: const Text('Import fuel CSV to a vehicle'),
      subtitle: const Text('Pick or create a vehicle then import CSV rows'),
      onTap: () async {
        final picked = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['csv'],
        );
        if (picked == null || picked.files.isEmpty) return;
        final path = picked.files.first.path;
        if (path == null || !File(path).existsSync()) return;

        final dbh = DatabaseHelper();
        final pick = await showDialog<_VehiclePickResult>(
          context: context,
          builder: (_) => _VehiclePickOrCreateDialog(dbHelper: dbh),
        );
        if (pick == null) return;

        // Use the same importer logic by creating a temporary cubit
        final repo = FuelRepository(dbHelper: dbh);
        final cubit = FuelRecordsCubit(repo: repo, vehicleId: pick.vehicleId);

        final imported = await cubit.importCsv(path);

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                imported > 0
                    ? 'Imported $imported fuel record(s) into ${pick.vehicleName}'
                    : 'No records imported',
              ),
            ),
          );
        }
      },
    );
  }
}

class _VehiclePickResult {
  final int vehicleId;
  final String vehicleName;
  _VehiclePickResult(this.vehicleId, this.vehicleName);
}

class _VehiclePickOrCreateDialog extends StatefulWidget {
  final DatabaseHelper dbHelper;
  const _VehiclePickOrCreateDialog({super.key, required this.dbHelper});

  @override
  State<_VehiclePickOrCreateDialog> createState() => _VehiclePickOrCreateDialogState();
}

class _VehiclePickOrCreateDialogState extends State<_VehiclePickOrCreateDialog> {
  List<_VehicleLite> _vehicles = [];
  int? _selectedId;

  final _newName = TextEditingController();
  final _newMileage = TextEditingController();

  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVehicles();
  }

  @override
  void dispose() {
    _newName.dispose();
    _newMileage.dispose();
    super.dispose();
  }

  Future<void> _loadVehicles() async {
    try {
      final db = await widget.dbHelper.database;

      // Try common schemas to read vehicles
      List<Map<String, Object?>> rows = [];
      final candidates = <String>[
        'SELECT id, name FROM vehicles ORDER BY name ASC',
        'SELECT id, vehicle_name AS name FROM vehicles ORDER BY vehicle_name ASC',
        'SELECT vehicle_id AS id, name FROM vehicles ORDER BY name ASC',
      ];

      for (final sql in candidates) {
        try {
          rows = await db.rawQuery(sql);
          if (rows.isNotEmpty || rows.isEmpty) {
            // If the query runs, accept the shape even if empty
            break;
          }
        } catch (_) {
          // try next
        }
      }

      setState(() {
        _vehicles = rows
            .map((m) => _VehicleLite(
                  id: (m['id'] as num?)?.toInt(),
                  name: (m['name'] ?? '').toString(),
                ))
            .where((v) => v.id != null && v.name.isNotEmpty)
            .cast<_VehicleLite>()
            .toList();
      });
    } catch (e) {
      setState(() => _error = 'Failed to load vehicles: $e');
    }
  }

  Future<_VehiclePickResult?> _createVehicle() async {
    final name = _newName.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Vehicle name is required');
      return null;
    }
    final startOdo = double.tryParse(_newMileage.text.trim()) ?? 0.0;

    try {
      final db = await widget.dbHelper.database;

      // Try to insert with different common schemas. First that succeeds wins.
      final attempts = <Map<String, Object?>>[
        {'table': 'vehicles', 'row': {'name': name, 'current_mileage': startOdo}},
        {'table': 'vehicles', 'row': {'name': name, 'mileage': startOdo}},
        {'table': 'vehicles', 'row': {'vehicle_name': name, 'mileage': startOdo}},
        {'table': 'vehicles', 'row': {'name': name}},
      ];

      int? id;
      for (final a in attempts) {
        try {
          final newId = await db.insert(a['table'] as String, a['row'] as Map<String, Object?>);
          id = newId;
          break;
        } catch (_) {
          // try next shape
        }
      }

      if (id == null) {
        setState(() => _error = 'Could not create vehicle. Create it in Vehicles page, then retry import.');
        return null;
      }

      return _VehiclePickResult(id, name);
    } catch (e) {
      setState(() => _error = 'Create failed: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose target vehicle'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_vehicles.isNotEmpty)
              DropdownButtonFormField<int>(
                decoration: const InputDecoration(labelText: 'Existing vehicle'),
                items: _vehicles
                    .map((v) => DropdownMenuItem<int>(
                          value: v.id,
                          child: Text(v.name),
                        ))
                    .toList(),
                value: _selectedId,
                onChanged: (v) => setState(() => _selectedId = v),
              ),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Or create new vehicle'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _newName,
              decoration: const InputDecoration(labelText: 'Vehicle name'),
            ),
            TextField(
              controller: _newMileage,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Starting mileage'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            if (_selectedId != null) {
              final v = _vehicles.firstWhere((e) => e.id == _selectedId);
              // Return existing
              if (context.mounted) {
                Navigator.pop(context, _VehiclePickResult(v.id!, v.name));
              }
              return;
            }
            // Create new
            final created = await _createVehicle();
            if (created != null && context.mounted) {
              Navigator.pop(context, created);
            }
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class _VehicleLite {
  final int? id;
  final String name;
  _VehicleLite({required this.id, required this.name});
}
