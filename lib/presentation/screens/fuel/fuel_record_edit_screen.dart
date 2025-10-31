import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:carvita/data/models/fuel_record.dart';

class FuelRecordEditScreen extends StatefulWidget {
  final FuelRecord? initial;
  final int vehicleId;
  final ValueChanged<FuelRecord> onSave;

  const FuelRecordEditScreen({
    super.key,
    required this.vehicleId,
    this.initial,
    required this.onSave,
  });

  @override
  State<FuelRecordEditScreen> createState() => _FuelRecordEditScreenState();
}

class _FuelRecordEditScreenState extends State<FuelRecordEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _dateCtrl;
  late final TextEditingController _odoCtrl;
  late final TextEditingController _volCtrl;
  late final TextEditingController _pplCtrl;
  late final TextEditingController _totalCtrl;
  late final TextEditingController _notesCtrl;
  bool _isFull = false;
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _date = r?.date ?? DateTime.now();
    _isFull = r?.isFullTank ?? false;

    _dateCtrl = TextEditingController(text: DateFormat('yyyy-MM-dd HH:mm').format(_date));
    _odoCtrl = TextEditingController(text: r?.odometer.toString() ?? '');
    _volCtrl = TextEditingController(text: r?.volume.toString() ?? '');
    _pplCtrl = TextEditingController(text: r?.pricePerL?.toString() ?? '');
    _totalCtrl = TextEditingController(text: r?.totalCost?.toString() ?? '');
    _notesCtrl = TextEditingController(text: r?.notes ?? '');
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    _odoCtrl.dispose();
    _volCtrl.dispose();
    _pplCtrl.dispose();
    _totalCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    final combined = DateTime(
      d.year, d.month, d.day,
      (t?.hour ?? _date.hour), (t?.minute ?? _date.minute),
    );
    setState(() {
      _date = combined;
      _dateCtrl.text = DateFormat('yyyy-MM-dd HH:mm').format(_date);
    });
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final rec = FuelRecord(
      id: widget.initial?.id,
      vehicleId: widget.vehicleId,
      date: _date,
      odometer: double.tryParse(_odoCtrl.text.trim()) ?? 0,
      volume: double.tryParse(_volCtrl.text.trim()) ?? 0,
      pricePerL: _pplCtrl.text.trim().isEmpty ? null : double.tryParse(_pplCtrl.text.trim()),
      totalCost: _totalCtrl.text.trim().isEmpty ? null : double.tryParse(_totalCtrl.text.trim()),
      isFullTank: _isFull,
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );
    widget.onSave(rec);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.initial == null ? 'Add Fuel Record' : 'Edit Fuel Record')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _dateCtrl,
              readOnly: true,
              decoration: const InputDecoration(labelText: 'Date'),
              onTap: _pickDateTime,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _odoCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Odometer (km)'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _volCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Volume (L)'),
              validator: (v) {
                final x = double.tryParse(v?.trim() ?? '');
                if (x == null || x <= 0) return 'Enter volume in litres';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pplCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Price / L (optional)'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _totalCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Total cost (optional)'),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Filled tank completely'),
              value: _isFull,
              onChanged: (v) => setState(() => _isFull = v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notesCtrl,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _save,
              child: const Text('Save'),
            )
          ],
        ),
      ),
    );
  }
}
