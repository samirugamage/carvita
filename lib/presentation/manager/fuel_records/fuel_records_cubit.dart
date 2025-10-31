import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:csv/csv.dart';

import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';

import 'fuel_records_state.dart';

class FuelRecordsCubit extends Cubit<FuelRecordsState> {
  final FuelRepository repo;
  final int vehicleId;

  FuelRecordsCubit({required this.repo, required this.vehicleId})
      : super(FuelRecordsState.initial());

  Future<void> load() async {
    emit(state.copyWith(loading: true, error: null));
    try {
      final list = await repo.getFuelRecordsForVehicle(vehicleId);
      emit(state.copyWith(loading: false, records: list));
    } catch (e) {
      emit(state.copyWith(loading: false, error: e.toString()));
    }
  }

  Future<void> add(FuelRecord r) async {
    try {
      await repo.insertFuelRecord(r);
      await load();
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> update(FuelRecord r) async {
    try {
      await repo.updateFuelRecord(r);
      await load();
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> remove(int id) async {
    try {
      await repo.deleteFuelRecord(id);
      await load();
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  /// Import CSV file at [filePath]. Returns number of imported rows.
  /// Expects headers similar to: "Odometer (km)", "Date", "Price / L", "Total cost", "Volume", "Filled tank completely", "Notes".
  Future<int> importCsv(String filePath) async {
    emit(state.copyWith(loading: true, error: null));
    int imported = 0;
    try {
      final file = File(filePath);
      final content = await file.readAsString();
      final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(content);
      if (rows.isEmpty) {
        emit(state.copyWith(loading: false));
        return 0;
      }
      final header = rows.first.map((e) => (e?.toString() ?? '').trim()).toList();

      int colIndex(String test) {
        final t = test.toLowerCase();
        for (int i = 0; i < header.length; i++) {
          final h = header[i].toString().toLowerCase();
          if (h.contains(t)) return i;
        }
        return -1;
      }

      final idxOdo = colIndex('odometer');
      final idxDate = header.indexWhere((h) => h.toString().toLowerCase().startsWith('date'));
      int idxPpl = header.indexWhere((h) => h.toString().replaceAll(' ', '').toLowerCase() == 'price/l');
      final idxTotal = colIndex('total');
      final idxVol = colIndex('volume');
      int idxFull = colIndex('filled');
      final idxNotes = colIndex('notes');

      if (idxPpl == -1) idxPpl = colIndex('price');
      if (idxFull == -1) idxFull = colIndex('tank');

      double toDouble(dynamic v) {
        if (v == null) return 0.0;
        final s = v.toString().replaceAll(',', '').trim();
        return double.tryParse(s) ?? 0.0;
      }

      bool toBool(dynamic v) {
        final s = (v ?? '').toString().trim().toLowerCase();
        return s == 'yes' || s == 'true' || s == '1';
      }

      DateTime? toDate(dynamic v) {
        if (v == null) return null;
        final s = v.toString().trim();
        try {
          return DateTime.parse(s);
        } catch (_) {
          return null;
        }
      }

      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;

        final odometer = idxOdo >= 0 ? toDouble(row[idxOdo]) : 0.0;
        final date = idxDate >= 0 ? toDate(row[idxDate]) : null;
        final volume = idxVol >= 0 ? toDouble(row[idxVol]) : 0.0;
        final pricePerL = idxPpl >= 0 ? toDouble(row[idxPpl]) : null;
        final totalCost = idxTotal >= 0 ? toDouble(row[idxTotal]) : null;
        final isFull = idxFull >= 0 ? toBool(row[idxFull]) : false;
        final notes = idxNotes >= 0 ? row[idxNotes]?.toString() : null;

        if (date == null || volume <= 0) continue;

        final rec = FuelRecord(
          vehicleId: vehicleId,
          date: date,
          odometer: odometer,
          volume: volume,
          pricePerL: pricePerL,
          totalCost: totalCost,
          isFullTank: isFull,
          notes: notes,
        );
        await repo.insertFuelRecord(rec);
        imported++;
      }
      await load();
      emit(state.copyWith(loading: false));
      return imported;
    } catch (e) {
      emit(state.copyWith(loading: false, error: e.toString()));
      return imported;
    }
  }
}
