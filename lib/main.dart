import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'data/sqlite_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SplitTogetherApp(repository: SqliteSplitRepository()));
}
