import 'dart:developer' as dev;
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

/// List-tile that lets you pick a vehicle and import **Fuel + Maintenance** CSV.
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
    final vehicles = state is VehicleLoaded ? state.vehicles : <dynamic>[];

    if (vehicles.isEmpty) {
      context.read<VehicleCubit>().fetchVehicles();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No vehicles. Add one first.')),
      );
      return;
    }

    int? tempId = _vehicleId ?? vehicles.first.id as int?;
    final selected = await showDialog<int?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose vehicle'),
        content: StatefulBuilder(
          builder: (_, setSt) => DropdownButton<int>(
            isExpanded: true,
            value: tempId,
            items: [
              for (final v in vehicles)
                DropdownMenuItem<int>(value: v.id as int, child: Text(v.name)),
            ],
            onChanged: (val) => setSt(() => tempId = val),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, tempId), child: const Text('Select')),
        ],
      ),
    );

    if (selected != null && mounted) {
      final v = vehicles.firstWhere((x) => x.id == selected);
      setState(() {
        _vehicleId  = selected;
        _vehicleName = v.name;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _vehicleName == null ? 'Vehicle: Not set' : 'Vehicle: $_vehicleName';
    return ListTile(
      leading: Icon(Icons.upload_file, color: Theme.of(context).colorScheme.primary),
      title: const Text('Import data'),
      subtitle: Text('$subtitle  •  Fuel + Maintenance'),
      contentPadding: EdgeInsets.zero,
      trailing: _busy
          ? SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.primary),
            )
          : Wrap(
              spacing: 8,
              children: [
                OutlinedButton(onPressed: () => _pickVehicle(context), child: const Text('Choose')),
                FilledButton(onPressed: () => _importCsv(context), child: const Text('CSV')),
              ],
            ),
      onTap: () => _pickVehicle(context),
    );
  }

  // ───────────────────────── CSV IMPORT ─────────────────────────

  Future<void> _importCsv(BuildContext context) async {
    if (_vehicleId == null) {
      await _pickVehicle(context);
      if (_vehicleId == null) return;
    }

    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (picked == null || picked.files.isEmpty) return;

    final path = picked.files.first.path;
    if (path == null) return;

    setState(() => _busy = true);
    int fuelCnt = 0, maintCnt = 0;

    try {
      final raw = await File(path).readAsString();
      final txt  = _stripBom(raw);
      final delim = _sniffDelimiter(txt);
      final decComma = delim != ',';           // Excel “;” CSV → decimal comma
      final rows = CsvToListConverter(
        fieldDelimiter: delim, shouldParseNumbers: false, eol: _sniffEol(txt),
      ).convert(txt);

      if (rows.isEmpty) return _snack('CSV is empty');

      // ── header map
      final header = rows.first.map((e) => _normHeader(e)).toList();
      final idx = { for (var i = 0; i < header.length; i++) header[i] : i };

      final fuelHint = _hasAny(header, ['volume','price_per_l','total_cost','amount']);
      final maintHint= _hasAny(header, ['mileage','odometer','items','notes','cost']);

      final fuelRepo = FuelRepository(dbHelper: DatabaseHelper());

      for (var r = 1; r < rows.length; r++) {
        final cells = rows[r].map((e) => (e ?? '').toString().trim()).toList();
        if (cells.every((c) => c.isEmpty)) continue;

        DateTime? when = _parseDate(_val(cells, idx,['date','datetime']));
        final items = _val(cells, idx,['items','services']);
        final notes = _val(cells, idx,['notes','remark']);
        final mileage = _toNum(_val(cells, idx,['mileage','odometer']), decComma);

        final volume    = _toNum(_val(cells, idx,['volume','liters','qty']), decComma);
        final pricePerL = _toNum(_val(cells, idx,['price_per_l','price/l','price']), decComma);
        final totalCost = _toNum(_val(cells, idx,['total_cost','amount','cost']), decComma);
        final fullTank  = _truthy(_val(cells, idx,['is_full_tank','full']));

        final fuelRow  = fuelHint  && (volume!=null || pricePerL!=null || totalCost!=null);
        final maintRow = maintHint && (mileage!=null||items!=null||notes!=null);

        if (fuelRow) {
          when ??= DateTime.now();
          double? vol = volume;
          if ((vol==null||vol==0) && pricePerL!=null && totalCost!=null && pricePerL>0) {
            vol = totalCost/pricePerL;
          }
          await fuelRepo.addFuelRecord(FuelRecord(
            id:null, vehicleId:_vehicleId!, date:when,
            odometer: mileage??0, volume: vol??0,
            pricePerL: pricePerL, totalCost: totalCost, isFullTank: fullTank,
          ));
          fuelCnt++;
        } else if (maintRow) {
          when ??= DateTime.now();
          final mergedNotes = [
            if(items?.isNotEmpty??false) 'Items: $items',
            if(notes?.isNotEmpty??false) notes,
          ].join(' | ').trim();
          await _insertServiceLog(ServiceLogEntry(
            id:null, vehicleId:_vehicleId!, serviceDate:when,
            mileageAtService:(mileage??0).toDouble(), cost:totalCost,
            notes: mergedNotes.isEmpty?null:mergedNotes,
          ));
          maintCnt++;
        }
      }

      await _recomputeMileage(_vehicleId!);
      if (mounted) context.read<VehicleCubit>().fetchVehicles();

      _snack('Imported: $fuelCnt fuel, $maintCnt maintenance');
    } catch (e,st) {
      dev.log('import failed', name:'import', error:e, stackTrace:st);
      _snack('Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ───────────────────────── LOW-LEVEL HELPERS ─────────────────────────

  void _snack(String m) { if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m))); }

  String _stripBom(String s)=> s.isNotEmpty&&s.codeUnitAt(0)==0xFEFF?s.substring(1):s;
  String _sniffDelimiter(String txt){
    final l=txt.split(RegExp(r'\r\n|\n|\r')).firstOrNull??txt;
    final c=_cnt(l,','), sc=_cnt(l,';'), t=_cnt(l,'\t');
    if(sc>c&&sc>=t) return ';'; if(t>c&&t>=sc) return '\t'; return ',';
  }
  String _sniffEol(String txt)=> txt.contains('\r\n')?'\r\n':txt.contains('\n')?'\n':'\r';
  int _cnt(String s,String k){var c=0,i=0;while((i=s.indexOf(k,i))!=-1){c++;i++;}return c;}

  String _normHeader(dynamic h){
    final s=(h??'').toString().trim().toLowerCase();
    switch(s){
      case 'price/l': case 'price l': return 'price_per_l';
      case 'liters': case 'litres': case 'qty': return 'volume';
      case 'amount': return 'total_cost';
      case 'mileage_km': case 'odo': return 'odometer';
      default: return s;
    }
  }
  bool _hasAny(List<String> h,List<String> k)=> k.any(h.contains);
  String? _val(List<String> row, Map<String,int> idx, List<String> keys){
    for(final k in keys){ final i=idx[k]; if(i!=null&&i<row.length){final v=row[i]; if(v.isNotEmpty) return v;}}
    return null;
  }

  DateTime? _parseDate(String? s){
    if(s==null||s.isEmpty) return null;
    for(final f in ['yyyy-MM-dd HH:mm','yyyy-MM-dd','dd/MM/yyyy','MM/dd/yyyy','yyyy/MM/dd','dd-MM-yyyy']){
      try{ return DateFormat(f).parseStrict(s);}catch(_){}
    }
    try{ return DateTime.fromMillisecondsSinceEpoch(int.parse(s));}catch(_){}
    return null;
  }
  double? _toNum(String? s,{required bool decComma}){
    if(s==null||s.isEmpty) return null;
    var t=s.replaceAll(RegExp(r'[^0-9,.\-]'),'');
    if(decComma){
      if(!t.contains('.')&&t.contains(',')) t=t.replaceAll(',','.');
      else t=t.replaceAll(',','');
    } else { t=t.replaceAll(',',''); }
    return double.tryParse(t);
  }
  bool _truthy(String? s)=> s!=null && ['1','true','yes','y'].contains(s.trim().toLowerCase());

  Future<void> _insertServiceLog(ServiceLogEntry e) async {
    final db=await DatabaseHelper().database;
    await db.insert('service_log_entries', {
      'vehicleId': e.vehicleId,                // ← camelCase
      'service_date': e.serviceDate.millisecondsSinceEpoch,
      'mileage_at_service': e.mileageAtService,
      'cost': e.cost,
      'notes': e.notes,
    });
  }

  Future<void> _recomputeMileage(int vid) async {
    final db=await DatabaseHelper().database;
    double maxFuel=0,maxMaint=0;

    try{
      final fr=await db.rawQuery('SELECT MAX(odometer) AS m FROM fuel_records WHERE vehicleId=?',[vid]);
      if(fr.isNotEmpty&&fr.first['m']!=null) maxFuel = (fr.first['m'] as num).toDouble();
    }catch(_){}
    try{
      final sr=await db.rawQuery('SELECT MAX(mileage_at_service) AS m FROM service_log_entries WHERE vehicleId=?',[vid]);
      if(sr.isNotEmpty&&sr.first['m']!=null) maxMaint = (sr.first['m'] as num).toDouble();
    }catch(_){}

    final newMiles = maxFuel>maxMaint?maxFuel:maxMaint;
    try{
      final cur=await db.rawQuery('SELECT mileage FROM vehicles WHERE id=?',[vid]);
      final current = cur.isNotEmpty && cur.first['mileage']!=null ? (cur.first['mileage'] as num).toDouble():0;
      if(newMiles>0 && newMiles!=current){
        await db.update('vehicles', {'mileage':newMiles}, where:'id=?', whereArgs:[vid]);
      }
    }catch(_){}
  }
}
