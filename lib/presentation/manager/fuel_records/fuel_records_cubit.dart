import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:csv/csv.dart';
import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';

import 'fuel_records_state.dart';

class FuelRecordsCubit extends Cubit<FuelRecordsState> {
  final FuelRepository repo;
  final int vehicleId;

  FuelRecordsCubit({
    required this.repo,
    required this.vehicleId,
  }) : super(FuelRecordsState.initial());

  Future<void> load() async {
    emit(state.copyWith(loading: true, error: null));
    try {
      final list = await repo.getFuelRecords(vehicleId);
      emit(state.copyWith(loading: false, records: list));
    } catch (e) {
      emit(state.copyWith(loading: false, error: e.toString()));
    }
  }

  Future<void> add(FuelRecord r) async {
    try {
      await repo.addFuelRecord(r);
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

  /// Import CSV at [filePath]. Returns count imported.
  /// Handles banner lines like "##Refuelling" before the real header.
  /// Required columns: Date, Volume.
  /// Optional columns: Odometer (km), Price / L, Total cost, Filled tank completely, Notes.
  Future<int> importCsv(String filePath) async {
    emit(state.copyWith(loading: true, error: null));
    int imported = 0;

    try {
      final raw = await File(filePath).readAsString();

      // 1) Find the real header line. Skip banner lines like "##Refuelling".
      final lines = raw
          .split(RegExp(r'\r?\n'))
          .where((l) => l.trim().isNotEmpty)
          .toList();

      int headerLineIndex = -1;
      bool _looksLikeHeader(String l) {
        final s = l.toLowerCase();
        return s.contains('date') && (s.contains('volume') || s.contains('fuel'));
      }

      for (int i = 0; i < lines.length; i++) {
        if (_looksLikeHeader(lines[i])) {
          headerLineIndex = i;
          break;
        }
      }
      if (headerLineIndex == -1) headerLineIndex = 0;

      // 2) Parse from the header to end.
      final normalized = lines.sublist(headerLineIndex).join('\n');
      final rows = const CsvToListConverter(
        eol: '\n',
        shouldParseNumbers: false,
      ).convert(normalized);

      if (rows.isEmpty) {
        emit(state.copyWith(loading: false));
        return 0;
      }

      final header = rows.first.map((e) => (e?.toString() ?? '').trim()).toList();

      int _idx(List<String> opts) {
        for (int i = 0; i < header.length; i++) {
          final h = header[i].toLowerCase().replaceAll(' ', '');
          for (final o in opts) {
            if (h.contains(o)) return i;
          }
        }
        return -1;
      }

      final idxOdo   = _idx(['odometer']);
      final idxDate  = _idx(['date']);
      int idxVol     = _idx(['volume','litre','liter']);
      int idxPpl     = _idx(['price/l','priceperl','price']);
      final idxTotal = _idx(['total']);
      int idxFull    = _idx(['filled','tank']);
      final idxNotes = _idx(['notes']);

      if (idxVol == -1) idxVol = _idx(['litre','liter']);
      if (idxFull == -1) idxFull = _idx(['tank']);

      if (idxDate == -1 || idxVol == -1) {
        emit(state.copyWith(
          loading: false,
          error: 'CSV needs Date and Volume columns',
        ));
        return 0;
      }

      double _toDouble(dynamic v) {
        if (v == null) return 0.0;
        final s = v.toString().replaceAll(',', '').trim();
        return double.tryParse(s) ?? 0.0;
      }

      bool _toBool(dynamic v) {
        final s = (v ?? '').toString().trim().toLowerCase();
        return s == 'yes' || s == 'true' || s == '1' || s == 'y';
      }

      DateTime? _toDate(dynamic v) {
        if (v == null) return null;
        final s = v.toString().trim();
        try {
          // Handles "2025-08-07 12:24:19"
          return DateTime.parse(s);
        } catch (_) {
          return null;
        }
      }

      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;

        final date      = idxDate  >= 0 && idxDate  < row.length ? _toDate(row[idxDate])    : null;
        final volume    = idxVol   >= 0 && idxVol   < row.length ? _toDouble(row[idxVol])   : 0.0;
        final odometer  = idxOdo   >= 0 && idxOdo   < row.length ? _toDouble(row[idxOdo])   : 0.0;
        final pricePerL = idxPpl   >= 0 && idxPpl   < row.length ? _toDouble(row[idxPpl])   : null;
        final totalCost = idxTotal >= 0 && idxTotal < row.length ? _toDouble(row[idxTotal]) : null;
        final isFull    = idxFull  >= 0 && idxFull  < row.length ? _toBool(row[idxFull])    : false;
        final notes     = idxNotes >= 0 && idxNotes < row.length ? row[idxNotes]?.toString() : null;

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

        await repo.addFuelRecord(rec);
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
