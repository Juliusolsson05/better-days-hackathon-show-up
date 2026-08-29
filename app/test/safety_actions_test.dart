import 'package:flutter_test/flutter_test.dart';
import 'package:showup/data/mock_repository.dart';
import 'package:showup/models/models.dart';
import 'package:showup/state/app_state.dart';

void main() {
  test(
    'leaving clears local private group state only after repository success',
    () async {
      final repo = MockRepository()..formGroup();
      final state = AppState(
        repo,
        requestNotificationPermission: () async => false,
      );
      await state.enterGroup();
      repo.dispose();
      expect(state.group, isNotNull);

      await state.leaveCurrentGroup();

      expect(state.group, isNull);
      expect(state.assignment, isNull);
      expect(state.phase, Phase.waiting);
      expect(await repo.currentGroup(), isNull);
    },
  );
}
