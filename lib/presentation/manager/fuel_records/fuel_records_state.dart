import 'package:equatable/equatable.dart';
import 'package:carvita/data/models/fuel_record.dart';

class FuelRecordsState extends Equatable {
  final bool loading;
  final List<FuelRecord> records;
  final String? error;

  const FuelRecordsState({
    required this.loading,
    required this.records,
    this.error,
  });

  factory FuelRecordsState.initial() => const FuelRecordsState(
        loading: false,
        records: [],
      );

  FuelRecordsState copyWith({
    bool? loading,
    List<FuelRecord>? records,
    String? error,
  }) {
    return FuelRecordsState(
      loading: loading ?? this.loading,
      records: records ?? this.records,
      error: error,
    );
  }

  @override
  List<Object?> get props => [loading, records, error];
}
