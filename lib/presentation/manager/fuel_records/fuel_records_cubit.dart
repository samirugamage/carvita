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
  /// Accepts files that start with a banner line like "##Refuelling" before the real header.
  /// Expected header contains at least: "Odometer (km)", "Date", "Volume".
  /// Optional columns: "Price / L", "Total cost", "Filled tank completely", "Notes".
  Future<int> importCsv(String filePath) async {
    emit(state.copyWith(loading: true, error: null));
    int imported = 0;

    try {
      final raw = await File(filePath).readAsString();

      // Split into lines and find the first line that looks like the real header.
      final lines = raw.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();

      int headerLineIndex = -1;
      for (int i = 0; i < lines.length; i++) {
        final l = lines[i].toLowerCase();
        // Heuristic: the header line should contain these keywords
        final looksLikeHeader =
            l.contains('odometer') && l.contains('date') && (l.contains('volume') || l.contains('fuel'));
        if (looksLikeHeader) {
          headerLineIndex = i;
          break;
        }
      }

      if (headerLineIndex == -1) {
        // Fallback: keep old behavior so at least we do not crash
        headerLineIndex = 0;
      }

      // Re-parse only from the detected header to the end
      final normalized = lines.sublist(headerLineIndex).join('\n');

      final rows = const CsvToListConverter(
        eol: '\n',
        shouldParseNumbers: false,
      ).convert(normalized);

      if (rows.isEmpty) {
        emit(state.copyWith(loading: false));
        return 0;
      }

      // Normalize header labels
      final header = rows.first
          .map((e) => (e?.toString() ?? '').trim())
          .toList();

      int idxOdo   = header.indexWhere((h) => h.toLowerCase().contains('odometer'));
      int idxDate  = header.indexWhere((h) => h.toLowerCase().startsWith('date'));
      int idxVol   = header.indexWhere((h) => h.toLowerCase().contains('volume'));

      // Price per L variants
      int idxPpl   = header.indexWhere((h) {
        final s = h.replaceAll(' ', '').toLowerCase();
        return s == 'price/l' || s == 'priceperl' || h.toLowerCase().startsWith('price');
      });

      int idxTotal = header.indexWhere((h) => h.toLowerCase().contains('total'));
      int idxFull  = header.indexWhere((h) => h.toLowerCase().contains('filled'));
      int idxNotes = header.indexWhere((h) => h.toLowerCase().contains('notes'));

      // If we still cannot find some indexes, try a looser match
      if (idxVol == -1) {
        idxVol = header.indexWhere((h) => h.toLowerCase().contains('litre') || h.toLowerCase().contains('liter'));
      }
      if (idxFull == -1) {
        idxFull = header.indexWhere((h) => h.toLowerCase().contains('tank'));
      }

      // If even core fields are missing, bail out gracefully
      if (idxDate == -1 || idxVol == -1) {
        emit(state.copyWith(loading: false, error: 'CSV does not have required columns: Date and Volume'));
        return 0;
      }

      double _toDouble(dynamic v) {
        if (v == null) return 0.0;
        final s = v.toString().replaceAll(',', '').trim();
        return double.tryParse(s) ?? 0.0;
      }

      bool _toBool(dynamic v) {
        final s = (v ?? '').toString().trim().toLowerCase();
        // Accept many forms
        return s == 'yes' || s == 'true' || s == '1' || s == 'y';
      }

      DateTime? _toDate(dynamic v) {
        if (v == null) return null;
        final s = v.toString().trim();
        // Try standard parse
        try {
          return DateTime.parse(s);
        } catch (_) {
          // Common fallback formats
          for (final fmt in const [
            'yyyy/MM/dd HH:mm',
            'yyyy/MM/dd',
            'dd/MM/yyyy HH:mm',
            'dd/MM/yyyy',
            'MM/dd/yyyy HH:mm',
            'MM/dd/yyyy',
            'yyyy-MM-dd',
          ]) {
            try {
              // Very small lightweight parser set
              // For simplicity keep DateTime.parse. If needed, add intl parsing here.
              // If format not parseable by DateTime.parse, skip.
              return DateTime.parse(s);
            } catch (_) {}
          }
        }
        return null;
      }

      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;

        final odometer = idxOdo   >= 0 && idxOdo   < row.length ? _toDouble(row[idxOdo])   : 0.0;
        final date     = idxDate  >= 0 && idxDate  < row.length ? _toDate(row[idxDate])    : null;
        final volume   = idxVol   >= 0 && idxVol   < row.length ? _toDouble(row[idxVol])   : 0.0;
        final pricePerL= idxPpl   >= 0 && idxPpl   < row.length ? _toDouble(row[idxPpl])   : null;
        final totalCost= idxTotal >= 0 && idxTotal < row.length ? _toDouble(row[idxTotal]) : null;
        final isFull   = idxFull  >= 0 && idxFull  < row.length ? _toBool(row[idxFull])    : false;
        final notes    = idxNotes >= 0 && idxNotes < row.length ? row[idxNotes]?.toString() : null;

        if (date == null || volume <= 0) {
          continue;
        }

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
