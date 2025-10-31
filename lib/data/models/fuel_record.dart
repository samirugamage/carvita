import 'package:equatable/equatable.dart';

/// Represents a single fuel record for a vehicle.
///
/// Each record captures the odometer reading, date of refuelling, the volume
/// of fuel filled and the cost information.  It also records whether the
/// vehicle's tank was filled completely.  An optional notes field allows
/// additional information (e.g. gas station, payment method, etc.).
class FuelRecord extends Equatable {
  final int? id;
  final int vehicleId;
  final DateTime date;
  final double odometer;
  final double volume;
  final double? pricePerL;
  final double? totalCost;
  final bool isFullTank;
  final String? notes;

  const FuelRecord({
    this.id,
    required this.vehicleId,
    required this.date,
    required this.odometer,
    required this.volume,
    this.pricePerL,
    this.totalCost,
    this.isFullTank = false,
    this.notes,
  });

  /// Create a [FuelRecord] from a database row.  Date strings are expected to
  /// be ISO‐8601 formatted.  Integer flags are converted to booleans.
  factory FuelRecord.fromMap(Map<String, dynamic> map) {
    return FuelRecord(
      id: map['id'] as int?,
      vehicleId: map['vehicleId'] as int,
      date: DateTime.parse(map['date'] as String),
      odometer: (map['odometer'] as num).toDouble(),
      volume: (map['volume'] as num).toDouble(),
      pricePerL: map['pricePerL'] == null
          ? null
          : (map['pricePerL'] as num).toDouble(),
      totalCost: map['totalCost'] == null
          ? null
          : (map['totalCost'] as num).toDouble(),
      isFullTank: (map['isFullTank'] as int) == 1,
      notes: map['notes'] as String?,
    );
  }

  /// Convert this record into a map for database insertion.  Booleans are
  /// stored as integers (1 for true, 0 for false).
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'vehicleId': vehicleId,
      'date': date.toIso8601String(),
      'odometer': odometer,
      'volume': volume,
      'pricePerL': pricePerL,
      'totalCost': totalCost,
      'isFullTank': isFullTank ? 1 : 0,
      'notes': notes,
    };
  }

  /// Creates a copy of this record with optionally replaced fields.
  FuelRecord copyWith({
    int? id,
    int? vehicleId,
    DateTime? date,
    double? odometer,
    double? volume,
    double? pricePerL,
    double? totalCost,
    bool? isFullTank,
    String? notes,
  }) {
    return FuelRecord(
      id: id ?? this.id,
      vehicleId: vehicleId ?? this.vehicleId,
      date: date ?? this.date,
      odometer: odometer ?? this.odometer,
      volume: volume ?? this.volume,
      pricePerL: pricePerL ?? this.pricePerL,
      totalCost: totalCost ?? this.totalCost,
      isFullTank: isFullTank ?? this.isFullTank,
      notes: notes ?? this.notes,
    );
  }

  @override
  List<Object?> get props => [
        id,
        vehicleId,
        date,
        odometer,
        volume,
        pricePerL,
        totalCost,
        isFullTank,
        notes,
      ];

  @override
  String toString() {
    return 'FuelRecord{id: $id, vehicleId: $vehicleId, date: $date, volume: $volume}';
  }
}