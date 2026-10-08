import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_light_controller/main.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final writes = <String>[];
  const codec = StandardMethodCodec();

  setUp(() {
    writes.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async => call.method == 'requestPermissions'
          ? {for (final int id in call.arguments as List) id: 1}
          : 1,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_bluetooth_serial/methods'),
      (call) async {
        if (call.method == 'isEnabled') return true;
        if (call.method == 'getBondedDevices') {
          return [
            {'name': 'ESP32_Obstacle_2', 'address': '58:BF:25:93:8E:54'},
          ];
        }
        if (call.method == 'connect') return 1;
        if (call.method == 'write') {
          writes.add(utf8.decode(call.arguments['bytes'] as Uint8List));
        }
        return null;
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_bluetooth_serial/read/1'),
      (_) async => null,
    );
  });

  Future<void> incoming(WidgetTester tester, String text) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter_bluetooth_serial/read/1',
      codec.encodeSuccessEnvelope(Uint8List.fromList(utf8.encode(text))),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> connect(WidgetTester tester) async {
    await tester.pumpWidget(const TrafficLightApp());
    await tester.ensureVisible(find.text('장애물 연결'));
    await tester.tap(find.text('장애물 연결'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets('old or uncalibrated firmware cannot receive motion commands', (
    tester,
  ) async {
    await connect(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(writes, isEmpty);
    await incoming(tester, 'FW:OBSTACLE_');
    await incoming(
      tester,
      'V2\nSTATE:STOP LEFT:0 RIGHT:0 READY:0 REASON:boot\n',
    );
    await tester.ensureVisible(find.text('← 왼쪽\n보드 쪽'));
    await tester.tap(find.text('← 왼쪽\n보드 쪽'));
    await tester.pump();
    expect(writes.where((s) => s == 'B20' || s == 'B10'), isEmpty);
    await dispose(tester);
  });

  testWidgets('held movement refreshes, release stops, AUTO off stops', (
    tester,
  ) async {
    await connect(tester);
    await incoming(
      tester,
      'FW:OBSTACLE_V2\nSTATE:STOP LEFT:0 RIGHT:0 READY:1 REASON:boot\n',
    );
    await tester.ensureVisible(find.text('← 왼쪽\n보드 쪽'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('← 왼쪽\n보드 쪽')),
    );
    await tester.pump(const Duration(milliseconds: 450));
    expect(writes.where((s) => s == 'B20').length, greaterThanOrEqualTo(3));
    await gesture.up();
    await tester.pump();
    expect(writes.last, 'B22');
    final count = writes.where((s) => s == 'B20').length;
    await tester.pump(const Duration(milliseconds: 400));
    expect(writes.where((s) => s == 'B20').length, count);
    await tester.ensureVisible(find.text('AUTO 켜기 · 끝–중간 왕복'));
    await tester.tap(find.text('AUTO 켜기 · 끝–중간 왕복'));
    await tester.pump();
    expect(writes.last, 'B10');
    await tester.tap(find.text('AUTO 끄기 · 정지'));
    await tester.pump();
    expect(writes.last, 'B22');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(writes.last, 'B22');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await dispose(tester);
  });

  testWidgets(
    'speed needs firmware support and stopped status, uses device acknowledgement',
    (tester) async {
      await connect(tester);
      await incoming(
        tester,
        'FW:OBSTACLE_V2\nSTATE:STOP LEFT:0 RIGHT:0 READY:1 REASON:boot\n',
      );
      ChoiceChip chip(String label) =>
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));
      expect(chip('저속').onSelected, isNull);
      await incoming(tester, 'SPEED:1\n');
      expect(chip('중속').selected, isTrue);
      await tester.ensureVisible(find.text('저속'));
      await tester.tap(find.text('저속'));
      await tester.pump();
      expect(writes.last, 'B30');
      expect(chip('중속').selected, isTrue);
      await incoming(tester, 'SPEED:0\n');
      expect(chip('저속').selected, isTrue);
      await incoming(
        tester,
        'STATE:AUTO LEFT:0 RIGHT:0 READY:1 REASON:moving\n',
      );
      expect(chip('고속').onSelected, isNull);
      await incoming(
        tester,
        'STATE:FAULT LEFT:0 RIGHT:0 READY:1 REASON:travel_timeout\n',
      );
      expect(chip('고속').onSelected, isNull);
      await dispose(tester);
    },
  );
}
