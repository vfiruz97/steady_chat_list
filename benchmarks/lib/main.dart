import 'package:flutter/widgets.dart';

/// Host app for the integration tests in `integration_test/`. It shows
/// nothing by itself; the tests pump their own widgets.
void main() => runApp(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: Text('steady_chat_list benchmarks')),
      ),
    );
