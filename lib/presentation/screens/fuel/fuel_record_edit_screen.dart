import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/data/sources/local/database_helper.dart';
import 'package:carvita/presentation/manager/fuel_records/fuel_records_cubit.dart';

class FuelRecordEditScreen extends StatefulWidget {
  final int vehicleId;
  final FuelRecord? initial;
  final Future<void> Function(FuelRecord rec)? onSave;

  const FuelRecordEditScreen({
    super.key,
    required this.vehicleId,
    this.initial,
    this.onSave,
  });

  @override
  State<FuelRecordEditScreen> createState() => _FuelRecordEditScreenState();
}

class _FuelRecordEditScreenState extends State<FuelRecordEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late DateTime _date;
  final _odoCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _totalCtrl = TextEditingController();
  final _volCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  bool _fullTank = false;

  final _fuelRepo = FuelRepository(dbHelper: DatabaseHelper());

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _date = i?.date ?? DateTime.now();
    _odoCtrl.text = i?.odometer.toStringAsFixed(0) ?? '';
    _priceCtrl.text = i?.pricePerL?.toStringAsFixed(2) ?? '';
    _totalCtrl.text = i?.totalCost?.toStringAsFixed(2) ?? '';
    _volCtrl.text = i?.volume.toStringAsFixed(2) ?? '';
    _notesCtrl.text = i?.notes ?? '';
    _fullTank = i?.isFullTank ?? false;

    _priceCtrl.addListener(_recalcVolumeForward);
    _totalCtrl.addListener(_recalcVolumeForward);
    _volCtrl.addListener(_recalcCostsBackward);
  }

  @override
  void dispose() {
    _odoCtrl.dispose();
    _priceCtrl.dispose();
    _totalCtrl.dispose();
    _volCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _recalcVolumeForward() {
    final p = double.tryParse(_priceCtrl.text.replaceAll(',', ''));
    final t = double.tryParse(_totalCtrl.text.replaceAll(',', ''));
    if (p != null && p > 0 && t != null && !_isEditing(_volCtrl)) {
      final v = t / p;
      _setText(_volCtrl, v.toStringAsFixed(3));
    }
  }

  void _recalcCostsBackward() {
    final v = double.tryParse(_volCtrl.text.replaceAll(',', ''));
    final p = double.tryParse(_priceCtrl.text.replaceAll(',', ''));
    if (v != null && p != null && p > 0 && !_isEditing(_totalCtrl)) {
      final t = v * p;
      _setText(_totalCtrl, t.toStringAsFixed(2));
    }
  }

  bool _isEditing(TextEditingController c) {
    final sel = c.selection;
    return sel.baseOffset != -1 || sel.extentOffset != -1;
  }

  void _setText(TextEditingController c, String s) {
    if (c.text == s) return;
    final sel = c.selection;
    _priceCtrl.removeListener(_recalcVolumeForward);
    _totalCtrl.removeListener(_recalcVolumeForward);
    _volCtrl.removeListener(_recalcCostsBackward);
    c.text = s;
    if (sel.baseOffset >= 0 && sel.baseOffset <= s.length) {
      c.selection = sel;
    }
    _priceCtrl.addListener(_recalcVolumeForward);
    _totalCtrl.addListener(_recalcVolumeForward);
    _volCtrl.addListener(_recalcCostsBackward);
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDate: _date,
    );
    if (d != null) {
      final t = TimeOfDay.fromDateTime(_date);
      setState(() => _date = DateTime(d.year, d.month, d.day, t.hour, t.minute));
    }
  }

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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final odometer = double.parse(_odoCtrl.text.replaceAll(',', ''));
    final price = double.tryParse(_priceCtrl.text.replaceAll(',', ''));
    final total = double.tryParse(_totalCtrl.text.replaceAll(',', ''));
    final vol = double.parse(_volCtrl.text.replaceAll(',', ''));

    final rec = FuelRecord(
      id: widget.initial?.id,
      vehicleId: widget.vehicleId,
      date: _date,
      odometer: odometer,
      volume: vol,
      pricePerL: price,
      totalCost: total,
      isFullTank: _fullTank,
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );

    if (widget.initial == null) {
      await _fuelRepo.addFuelRecord(rec);
    } else {
      await _fuelRepo.updateFuelRecord(rec);
    }

    await _updateVehicleMileageIfHigher(widget.vehicleId, odometer);

    final cubit = BlocProvider.maybeOf<FuelRecordsCubit>(context);
    if (cubit != null) {
      await cubit.load();
    }

    if (widget.onSave != null) {
      await widget.onSave!(rec);
    }

    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'Add Fuel Record' : 'Edit Fuel Record'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Date'),
              subtitle: Text(DateFormat('yyyy-MM-dd HH:mm').format(_date)),
              trailing: OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.event),
                label: const Text('Pick'),
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _odoCtrl,
              decoration: const InputDecoration(
                labelText: 'Odometer (km)',
                hintText: 'e.g. 13220',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final d = double.tryParse((v ?? '').replaceAll(',', ''));
                if (d == null) return 'Enter a valid number';
                if (d < 0) return 'Cannot be negative';
                return null;
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _priceCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Price / L',
                      hintText: 'e.g. 305.00',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _totalCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Total cost',
                      hintText: 'e.g. 1500.00',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _volCtrl,
              decoration: const InputDecoration(
                labelText: 'Volume (L)',
                hintText: 'e.g. 4.918',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final d = double.tryParse((v ?? '').replaceAll(',', ''));
                if (d == null) return 'Enter a valid number';
                if (d <= 0) return 'Must be > 0';
                return null;
              },
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _fullTank,
              onChanged: (b) => setState(() => _fullTank = b),
              title: const Text('Filled tank completely'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notesCtrl,
              decoration: const InputDecoration(
                labelText: 'Notes',
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
