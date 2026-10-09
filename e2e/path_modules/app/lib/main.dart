import 'package:feature/feature.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  static final Future<String> _probe = probeVersion();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: FutureBuilder<String>(
            future: _probe,
            builder: (context, snapshot) =>
                Text('ffo_probe: ${snapshot.data ?? '...'}'),
          ),
        ),
      ),
    );
  }
}
