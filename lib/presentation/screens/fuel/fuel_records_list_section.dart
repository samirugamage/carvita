import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';

import 'package:carvita/data/models/fuel_record.dart';
import 'package:carvita/data/repositories/fuel_repository.dart';
import 'package:carvita/data/sources/local/database_helper.dart';

import 'package:carvita/presentation/manager/fuel_records/fuel_records_cubit.dart';
import 'package:carvita/presentation/manager/fuel_records/fuel_records_state.dart';

import 'fuel_record_edit_screen.dart';

/// A shrink-wrapped section intended to be embedded inside an existing
/// SingleChildScrollView (for example, the Service History tab).
class FuelRecordsListSection extends StatelessWidget {
  final int vehicleId;

  const FuelRecordsListSection({super.key, required this.vehicleId});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => FuelRecordsCubit(
        repo: FuelRepository(dbHelper: DatabaseHelper()),
        vehicleId: vehicleId,
      )..load(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: const [
          // Buttons row (Import CSV, Add)
          _FuelRecordsActionsRow(),
          SizedBox(height: 8),
          // List of records
          _FuelRecordsListView(),
        ],
      ),
    );
  }
}

class _FuelRecordsListView extends StatelessWidget {
  const _FuelRecordsListView();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<FuelRecordsCubit, FuelRecordsState>(
      builder: (context, state) {
        if (state.loading) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12.0),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (state.error != null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: Text(
              'Error: ${state.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        }
        if (state.records.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: Text(
              'No fuel records yet',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: state.records.length,
          separatorBuilder: (_, __) => const Divider(height: 0),
          itemBuilder: (context, i) {
            final r = state.records[i];
            return ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 0.0),
              title: Text(
                '${DateFormat('yyyy-MM-dd HH:mm').format(r.date)}  •  ${r.volume.toStringAsFixed(2)} L',
              ),
              subtitle: Text(
                'Odo ${r.odometer.toStringAsFixed(0)}'
                '${r.pricePerL != null ? '  •  Rs ${r.pricePerL!.toStringAsFixed(2)}/L' : ''}'
                '${r.totalCost != null ? '  •  Total Rs ${r.totalCost!.toStringAsFixed(2)}' : ''}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FuelRecordEditScreen(
                            vehicleId: context.read<FuelRecordsCubit>().vehicleId,
                            initial: r,
                            onSave: (updated) async {
                              await context.read<FuelRecordsCubit>().update(updated);
                              if (Navigator.of(context).canPop()) {
                                Navigator.of(context).pop();
                              }
                            },
                          ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_forever),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Delete fuel record'),
                          content: const Text('This cannot be undone'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await context.read<FuelRecordsCubit>().remove(r.id!);
                      }
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Action row with Import CSV and Add buttons.
class _FuelRecordsActionsRow extends StatelessWidget {
  const _FuelRecordsActionsRow();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<FuelRecordsCubit>();

    return Row(
      children: [
        FilledButton.icon(
          onPressed: () async {
            final picked = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['csv'],
            );
            if (picked == null || picked.files.isEmpty) return;
            final path = picked.files.first.path;
            if (path == null) return;

            final imported = await cubit.importCsv(path);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Imported $imported record(s)')),
              );
            }
          },
          icon: const Icon(Icons.upload_file),
          label: const Text('Import CSV'),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => FuelRecordEditScreen(
                  vehicleId: cubit.vehicleId,
                  onSave: (rec) async {
                    await cubit.add(rec);
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ),
            );
          },
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
      ],
    );
  }
}
