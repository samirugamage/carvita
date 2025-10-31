import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/sources/local/database_helper.dart';

/// Repository that encapsulates all CRUD operations for [FuelRecord]s.
///
/// Keeping database access behind a repository class allows the UI layer to
/// remain agnostic of persistence details.  See [DatabaseHelper] for the
/// underlying implementation.
class FuelRepository {
  final DatabaseHelper dbHelper;

  FuelRepository({required this.dbHelper});

  /// Inserts a new fuel record and returns its generated id.  If [record.id]
  /// is non‐null it will be ignored and an auto‐incremented id assigned.
  Future<int> addFuelRecord(FuelRecord record) async {
    return await dbHelper.insertFuelRecord(record);
  }

  /// Retrieves all fuel records for the specified vehicle id, ordered by
  /// descending date (most recent first).
  Future<List<FuelRecord>> getFuelRecords(int vehicleId) async {
    return await dbHelper.getFuelRecordsForVehicle(vehicleId);
  }

  /// Updates an existing fuel record.  Returns the number of rows affected.
  Future<int> updateFuelRecord(FuelRecord record) async {
    return await dbHelper.updateFuelRecord(record);
  }

  /// Deletes the fuel record with the given id.  Returns the number of rows
  /// deleted (0 if none).
  Future<int> deleteFuelRecord(int id) async {
    return await dbHelper.deleteFuelRecord(id);
  }
}