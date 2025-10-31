import 'package:carvita/data/models/vehicle.dart';
import 'package:carvita/data/sources/local/database_helper.dart';

class VehicleRepository {
  final DatabaseHelper _dbHelper;

  VehicleRepository({DatabaseHelper? dbHelper})
    : _dbHelper = dbHelper ?? DatabaseHelper();

  Future<List<Vehicle>> getVehicles() async {
    return await _dbHelper.getAllVehicles();
  }

  Future<Vehicle?> getVehicleById(int id) async {
    return await _dbHelper.getVehicleById(id);
  }

  Future<void> addVehicle(Vehicle vehicle) async {
    await _dbHelper.insertVehicle(vehicle);
  }

  Future<void> updateVehicle(Vehicle vehicle) async {
    await _dbHelper.updateVehicle(vehicle);
  }

  Future<void> deleteVehicle(int id) async {
    await _dbHelper.deleteVehicle(id);
  }

    /// Updates the vehicle mileage only if [newMileage] is higher than the stored mileage.
  Future<void> updateMileageIfHigher(int vehicleId, double newMileage) async {
    final db = await DatabaseHelper().database;
    // fetch current
    final rows = await db.query('vehicles',
        columns: ['mileage'],
        where: 'id = ?',
        whereArgs: [vehicleId],
        limit: 1);
    if (rows.isEmpty) return;
    final current = (rows.first['mileage'] as num).toDouble();
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

}
