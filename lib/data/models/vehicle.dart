import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// Represents a vehicle in the CarVita application.
///
/// This model mirrors the `vehicles` table in the local SQLite database.  In
/// addition to the existing fields (name, mileage, etc.) a nullable
/// [tankCapacity] was introduced to allow storing the fuel tank capacity for
/// each vehicle.  This value is used when predicting fuel consumption and
/// upcoming fuel stops.
class Vehicle extends Equatable {
  final int? id;
  final String name;
  final double mileage;
  final DateTime mileageLastUpdated;
  final DateTime boughtDate;
  final Uint8List? image;
  final String? model;
  final String? plateNumber;
  final String? vin;
  final String? engineNumber;
  /// Fuel tank capacity in litres.  This field may be null if the user
  /// chooses not to specify it when registering the vehicle.
  final double? tankCapacity;

  const Vehicle({
    this.id,
    required this.name,
    required this.mileage,
    required this.mileageLastUpdated,
    required this.boughtDate,
    this.image,
    this.model,
    this.plateNumber,
    this.vin,
    this.engineNumber,
    this.tankCapacity,
  });

  /// Creates a [Vehicle] instance from a database map.  The keys in the map
  /// correspond to the column names in the `vehicles` table.  Date values are
  /// parsed from ISO‐8601 strings.  The [tankCapacity] field reads the
  /// `tank_capacity` column, which will be absent on databases created prior
  /// to version 2 and therefore remains null in those cases.
  factory Vehicle.fromMap(Map<String, dynamic> map) {
    return Vehicle(
      id: map['id'] as int?,
      name: map['name'] as String,
      mileage: (map['mileage'] as num).toDouble(),
      mileageLastUpdated: DateTime.parse(map['mileage_last_updated'] as String),
      boughtDate: DateTime.parse(map['bought_date'] as String),
      image: map['image'] as Uint8List?,
      model: map['model'] as String?,
      plateNumber: map['plate_number'] as String?,
      vin: map['vin'] as String?,
      engineNumber: map['engine_number'] as String?,
      tankCapacity: map['tank_capacity'] == null
          ? null
          : (map['tank_capacity'] as num).toDouble(),
    );
  }

  /// Converts this [Vehicle] into a map for insertion into the database.
  /// Fields that are null (e.g., [tankCapacity] or [image]) remain null in
  /// the resulting map so that SQLite stores them as NULL.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'mileage': mileage,
      'mileage_last_updated': mileageLastUpdated.toIso8601String(),
      'bought_date': boughtDate.toIso8601String(),
      'image': image,
      'model': model,
      'plate_number': plateNumber,
      'vin': vin,
      'engine_number': engineNumber,
      'tank_capacity': tankCapacity,
    };
  }

  /// Creates a copy of this vehicle with selectively replaced fields.  The
  /// [clearImage] flag can be used to explicitly nullify the image when
  /// updating a vehicle record.  If [tankCapacity] is omitted it retains its
  /// existing value.
  Vehicle copyWith({
    int? id,
    String? name,
    double? mileage,
    DateTime? mileageLastUpdated,
    DateTime? boughtDate,
    Uint8List? image,
    String? model,
    String? plateNumber,
    String? vin,
    String? engineNumber,
    double? tankCapacity,
    bool clearImage = false,
  }) {
    return Vehicle(
      id: id ?? this.id,
      name: name ?? this.name,
      mileage: mileage ?? this.mileage,
      mileageLastUpdated: mileageLastUpdated ?? this.mileageLastUpdated,
      boughtDate: boughtDate ?? this.boughtDate,
      image: clearImage ? null : (image ?? this.image),
      model: model ?? this.model,
      plateNumber: plateNumber ?? this.plateNumber,
      vin: vin ?? this.vin,
      engineNumber: engineNumber ?? this.engineNumber,
      tankCapacity: tankCapacity ?? this.tankCapacity,
    );
  }

  /// Compares this vehicle with another for deep equality.  It does not
  /// compare the [id] field because two otherwise identical records can exist
  /// with different primary keys.
  bool isIdentical(Vehicle other) {
    return id == other.id &&
        name == other.name &&
        mileage == other.mileage &&
        mileageLastUpdated == other.mileageLastUpdated &&
        boughtDate == other.boughtDate &&
        image == other.image &&
        model == other.model &&
        plateNumber == other.plateNumber &&
        vin == other.vin &&
        engineNumber == other.engineNumber &&
        tankCapacity == other.tankCapacity;
  }

  @override
  List<Object?> get props => [
        id,
        name,
        mileage,
        mileageLastUpdated,
        boughtDate,
        image,
        model,
        plateNumber,
        vin,
        engineNumber,
        tankCapacity,
      ];

  @override
  String toString() {
    return 'Vehicle{id: $id, name: $name, tankCapacity: $tankCapacity}';
  }
}