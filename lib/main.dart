import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

const String obstacleDeviceName = "ESP32_Obstacle_2";
const String obstacleOnCommand = "B12";
const String obstacleOffCommand = "B11";
const String obstacleAutoCommand = "B10";

// true로 바꾸면 장애물 명령 뒤에 줄바꿈(\n)을 붙여 전송합니다.
const bool appendNewlineToObstacleCommands = false;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TrafficLightApp());
}

class TrafficLightApp extends StatelessWidget {
  const TrafficLightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '트랙 장치 제어',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        scaffoldBackgroundColor: Colors.grey.shade100,
        useMaterial3: true,
      ),
      home: const TrafficLightPage(),
    );
  }
}

class TrafficLightPage extends StatefulWidget {
  const TrafficLightPage({super.key});

  @override
  State<TrafficLightPage> createState() => _TrafficLightPageState();
}

class _TrafficLightPageState extends State<TrafficLightPage>
    with WidgetsBindingObserver {
  static const String _trafficDeviceName = 'Traffic Light + 2';

  // 신호등 제어 상태 및 Bluetooth 연결
  final List<BluetoothDevice> _trafficDevices = [];
  BluetoothDevice? _selectedTrafficDevice;
  BluetoothConnection? _trafficConnection;
  StreamSubscription<BluetoothDiscoveryResult>? _trafficDiscoverySubscription;
  StreamSubscription<Uint8List>? _trafficInputSubscription;
  bool _isTrafficDiscovering = false;
  bool _isTrafficConnecting = false;
  String _currentSignal = '대기 중';
  String _trafficReceiveBuffer = '';

  // 장애물 제어 상태 및 Bluetooth 연결
  BluetoothConnection? _obstacleConnection;
  StreamSubscription<Uint8List>? _obstacleInputSubscription;
  bool _isObstacleConnecting = false;
  String _lastObstacleCommand = '없음';
  String _obstacleStatus = '연결 대기';
  String _obstacleReceiveBuffer = '';
  bool _obstacleV2 = false;
  bool _obstacleReady = false;
  bool _obstacleStopped = false;
  int? _obstacleSpeed;
  bool _obstacleAuto = false;
  Timer? _obstacleHeartbeat;
  Timer? _obstacleHoldTimer;
  String? _heldObstacleCommand;
  int? _obstaclePointer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _stopObstacle();
      _obstacleHeartbeat?.cancel();
    } else if (_isObstacleConnected) {
      _startObstacleHeartbeat();
    }
  }

  bool get _isTrafficConnected => _trafficConnection?.isConnected ?? false;
  bool get _isObstacleConnected => _obstacleConnection?.isConnected ?? false;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _obstacleHeartbeat?.cancel();
    _obstacleHoldTimer?.cancel();
    if (_obstacleV2 && _isObstacleConnected) {
      _obstacleConnection!.output.add(Uint8List.fromList(utf8.encode('B22')));
    }
    _trafficDiscoverySubscription?.cancel();
    _trafficInputSubscription?.cancel();
    _trafficConnection?.dispose();
    _obstacleInputSubscription?.cancel();
    _obstacleConnection?.dispose();
    super.dispose();
  }

  Future<bool> _prepareBluetooth() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final bluetoothBlocked =
        [
          statuses[Permission.bluetoothScan],
          statuses[Permission.bluetoothConnect],
        ].whereType<PermissionStatus>().any(
          (status) => status.isPermanentlyDenied || status.isRestricted,
        );

    if (bluetoothBlocked) {
      _showMessage('블루투스 권한을 허용해야 합니다.');
      await openAppSettings();
      return false;
    }

    final isEnabled = await FlutterBluetoothSerial.instance.isEnabled;
    if (isEnabled == true) {
      return true;
    }

    final enabled = await FlutterBluetoothSerial.instance.requestEnable();
    if (enabled == true) {
      return true;
    }

    _showMessage('블루투스를 켜야 장치를 검색하거나 연결할 수 있습니다.');
    return false;
  }

  // 신호등 제어: 기존 Traffic Light + 2 장치 검색/선택 흐름
  Future<void> _searchTrafficDevices() async {
    if (!await _prepareBluetooth()) {
      return;
    }

    await _trafficDiscoverySubscription?.cancel();

    setState(() {
      _trafficDevices.clear();
      _selectedTrafficDevice = null;
      _isTrafficDiscovering = true;
    });

    try {
      final bondedDevices = await FlutterBluetoothSerial.instance
          .getBondedDevices();
      for (final device in bondedDevices) {
        _addTrafficDevice(device);
      }

      _trafficDiscoverySubscription = FlutterBluetoothSerial.instance
          .startDiscovery()
          .listen(
            (result) {
              _addTrafficDevice(result.device);
            },
            onError: (Object error) {
              if (!mounted) {
                return;
              }
              setState(() {
                _isTrafficDiscovering = false;
              });
              _showMessage('신호등 장치 검색 실패: $error');
            },
            onDone: () {
              if (!mounted) {
                return;
              }
              setState(() {
                _isTrafficDiscovering = false;
              });
            },
          );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isTrafficDiscovering = false;
      });
      _showMessage('신호등 장치 검색 실패: $error');
    }
  }

  void _addTrafficDevice(BluetoothDevice device) {
    if (device.name != _trafficDeviceName || !mounted) {
      return;
    }

    setState(() {
      final index = _trafficDevices.indexWhere(
        (savedDevice) => savedDevice.address == device.address,
      );

      if (index >= 0) {
        _trafficDevices[index] = device;
      } else {
        _trafficDevices.add(device);
      }

      _selectedTrafficDevice ??= device;
    });
  }

  Future<void> _connectSelectedTrafficDevice() async {
    final device = _selectedTrafficDevice;
    if (device == null) {
      _showMessage('연결할 신호등 장치를 선택하세요.');
      return;
    }

    if (!await _prepareBluetooth()) {
      return;
    }

    await FlutterBluetoothSerial.instance.cancelDiscovery();
    await _trafficInputSubscription?.cancel();
    _trafficConnection?.dispose();

    setState(() {
      _isTrafficConnecting = true;
    });

    try {
      final connection = await BluetoothConnection.toAddress(device.address);
      if (!mounted) {
        connection.dispose();
        return;
      }

      _trafficConnection = connection;
      _trafficInputSubscription = connection.input?.listen(
        _handleTrafficIncomingData,
        onError: (Object error) {
          if (!mounted) {
            return;
          }
          _setTrafficDisconnected();
          _showMessage('신호등 수신 오류: $error');
        },
        onDone: () {
          if (!mounted) {
            return;
          }
          _setTrafficDisconnected();
          _showMessage('신호등 Bluetooth 연결이 종료되었습니다.');
        },
      );

      setState(() {
        _isTrafficConnecting = false;
      });
      _showMessage('신호등 장치에 연결되었습니다.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isTrafficConnecting = false;
      });
      _setTrafficDisconnected();
      _showMessage('신호등 연결 실패: $error');
    }
  }

  void _handleTrafficIncomingData(Uint8List data) {
    _trafficReceiveBuffer += utf8.decode(data, allowMalformed: true);

    final lines = _trafficReceiveBuffer.split('\n');
    _trafficReceiveBuffer = lines.removeLast();

    for (final line in lines) {
      _handleTrafficMessage(line.trim());
    }
  }

  void _handleTrafficMessage(String message) {
    if (!message.startsWith('CURRENT:')) {
      return;
    }

    final signal = message.substring('CURRENT:'.length).trim().toUpperCase();
    setState(() {
      _currentSignal = _signalLabel(signal);
    });
  }

  String _signalLabel(String signal) {
    switch (signal) {
      case 'GREEN':
        return '초록불';
      case 'YELLOW':
        return '노란불';
      case 'RED':
        return '빨간불';
      case 'LEFT':
        return '좌회전';
      case 'RED_LEFT':
        return '빨간불 + 좌회전';
      case 'OFF':
        return '끄기';
      default:
        return signal;
    }
  }

  Future<void> _sendTrafficCommand(String command) async {
    final connection = _trafficConnection;
    if (connection == null || !connection.isConnected) {
      _showMessage('먼저 신호등 장치를 연결하세요.');
      return;
    }

    try {
      connection.output.add(Uint8List.fromList(utf8.encode('$command\n')));
      await connection.output.allSent;
    } catch (error) {
      _setTrafficDisconnected();
      _showMessage('신호등 명령 전송 실패: $error');
    }
  }

  void _setTrafficDisconnected() {
    _trafficInputSubscription?.cancel();
    _trafficConnection?.dispose();
    if (!mounted) {
      return;
    }
    setState(() {
      _trafficConnection = null;
      _isTrafficConnecting = false;
    });
  }

  // 장애물 제어: ESP32_Obstacle_2에 독립적으로 연결하고 B10/B11/B12 전송
  Future<void> _connectObstacleDevice() async {
    if (_isObstacleConnected) {
      _showMessage('장애물 장치가 이미 연결되어 있습니다.');
      return;
    }

    if (!await _prepareBluetooth()) {
      return;
    }

    await _trafficDiscoverySubscription?.cancel();
    await FlutterBluetoothSerial.instance.cancelDiscovery();
    if (mounted && _isTrafficDiscovering) {
      setState(() {
        _isTrafficDiscovering = false;
      });
    }

    await _obstacleInputSubscription?.cancel();
    _obstacleConnection?.dispose();

    setState(() {
      _isObstacleConnecting = true;
    });

    try {
      final device = await _findDeviceByName(obstacleDeviceName);
      if (!mounted) {
        return;
      }

      if (device == null) {
        setState(() {
          _isObstacleConnecting = false;
        });
        _showMessage('$obstacleDeviceName 장치를 찾을 수 없습니다.');
        return;
      }

      final connection = await BluetoothConnection.toAddress(device.address);
      if (!mounted) {
        connection.dispose();
        return;
      }

      _obstacleConnection = connection;
      _obstacleInputSubscription = connection.input?.listen(
        _handleObstacleIncomingData,
        onError: (Object error) {
          if (!mounted) {
            return;
          }
          _setObstacleDisconnected();
          _showMessage('장애물 수신 오류: $error');
        },
        onDone: () {
          if (!mounted) {
            return;
          }
          _setObstacleDisconnected();
          _showMessage('장애물 Bluetooth 연결이 종료되었습니다.');
        },
      );

      setState(() {
        _isObstacleConnecting = false;
      });
      _startObstacleHeartbeat();
      _showMessage('장애물 장치에 연결되었습니다.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isObstacleConnecting = false;
      });
      _setObstacleDisconnected();
      _showMessage('장애물 연결 실패: $error');
    }
  }

  Future<BluetoothDevice?> _findDeviceByName(String deviceName) async {
    final bondedDevices = await FlutterBluetoothSerial.instance
        .getBondedDevices();

    for (final device in bondedDevices) {
      if (device.name == deviceName) {
        return device;
      }
    }

    final completer = Completer<BluetoothDevice?>();
    StreamSubscription<BluetoothDiscoveryResult>? subscription;
    Timer? timeoutTimer;

    subscription = FlutterBluetoothSerial.instance.startDiscovery().listen(
      (result) {
        if (result.device.name == deviceName && !completer.isCompleted) {
          completer.complete(result.device);
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      },
    );

    timeoutTimer = Timer(const Duration(seconds: 12), () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });

    try {
      return await completer.future;
    } finally {
      timeoutTimer.cancel();
      await subscription.cancel();
      await FlutterBluetoothSerial.instance.cancelDiscovery();
    }
  }

  Future<void> _disconnectObstacleDevice() async {
    await _stopObstacle();
    _setObstacleDisconnected();
    _showMessage('장애물 연결을 해제했습니다.');
  }

  void _handleObstacleIncomingData(Uint8List data) {
    _obstacleReceiveBuffer += utf8.decode(data, allowMalformed: true);
    final lines = _obstacleReceiveBuffer.split('\n');
    _obstacleReceiveBuffer = lines.removeLast();
    if (_obstacleReceiveBuffer.length > 2048) _obstacleReceiveBuffer = '';
    for (final raw in lines) {
      final line = raw.trim();
      if (!mounted) return;
      if (line == 'FW:OBSTACLE_V2') {
        setState(() => _obstacleV2 = true);
      } else if (line.startsWith('SPEED:')) {
        final speed = int.tryParse(line.substring(6));
        if (speed != null && speed >= 0 && speed <= 2) {
          setState(() => _obstacleSpeed = speed);
        }
      } else if (line.startsWith('STATE:')) {
        setState(() {
          _obstacleReady = line.contains('READY:1');
          _obstacleStopped = line.startsWith('STATE:STOP ');
          _obstacleAuto = line.startsWith('STATE:AUTO ');
          _obstacleStatus = _obstacleStateLabel(line);
        });
        if (line.startsWith('STATE:FAULT ')) _cancelObstacleHold();
      }
    }
  }

  String _obstacleStateLabel(String line) {
    final left = line.contains('LEFT:1') ? '눌림' : '해제';
    final right = line.contains('RIGHT:1') ? '눌림' : '해제';
    if (line.contains('READY:0')) return '모터 방향 확인 필요 · 왼쪽 $left / 오른쪽 $right';
    final state = line.split(' ').first.substring(6);
    final label = switch (state) {
      'AUTO' => '끝–중간 왕복',
      'MANUAL' => '수동 이동',
      'CALIBRATION' => '방향 확인 중',
      'FAULT' => '보호 정지',
      _ => '정지',
    };
    final reason = line.split('REASON:').last;
    final detail = switch (reason) {
      'travel_timeout' => '이동 한도 초과',
      'both_limits' => '양쪽 스위치 동시 감지',
      'home_not_released' => '출발 스위치 해제 안됨',
      'link_lost' || 'disconnected' => '연결 끊김',
      'hold_expired' => '수동 명령 만료',
      'end_limit' => '끝 위치 도착',
      _ => '',
    };
    return '$label${detail.isEmpty ? '' : ' · $detail'} · 왼쪽 $left / 오른쪽 $right';
  }

  void _startObstacleHeartbeat() {
    _obstacleHeartbeat?.cancel();
    _obstacleHeartbeat = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_obstacleV2 && _isObstacleConnected) _writeObstacle('B25');
    });
  }

  Future<void> _writeObstacle(String command) async {
    final connection = _obstacleConnection;
    if (!_obstacleV2 || connection == null || !connection.isConnected) return;
    try {
      connection.output.add(Uint8List.fromList(utf8.encode(command)));
      await connection.output.allSent;
    } catch (error) {
      _setObstacleDisconnected();
      _showMessage('장애물 전송 실패: $error');
    }
  }

  void _cancelObstacleHold() {
    _obstacleHoldTimer?.cancel();
    _obstacleHoldTimer = null;
    _heldObstacleCommand = null;
    _obstaclePointer = null;
  }

  void _beginObstacleHold(String command, int pointer) {
    if (!_obstacleV2 || !_obstacleReady || !_isObstacleConnected) return;
    if (_heldObstacleCommand != null) return;
    _heldObstacleCommand = command;
    _obstaclePointer = pointer;
    _writeObstacle(command);
    setState(() => _lastObstacleCommand = command);
    _obstacleHoldTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_heldObstacleCommand == command) _writeObstacle(command);
    });
  }

  void _endObstacleHold(int pointer) {
    if (_obstaclePointer == pointer) _stopObstacle();
  }

  Future<void> _stopObstacle() async {
    _cancelObstacleHold();
    if (mounted) setState(() => _obstacleAuto = false);
    await _writeObstacle('B22');
  }

  Future<void> _toggleObstacleAuto() async {
    _cancelObstacleHold();
    if (_obstacleAuto) {
      await _stopObstacle();
    } else {
      if (mounted) {
        setState(() {
          _lastObstacleCommand = 'B10';
          _obstacleAuto = true;
        });
      }
      await _writeObstacle('B10');
    }
  }

  Widget _obstacleSpeedSelector() {
    final enabled =
        _isObstacleConnected &&
        _obstacleV2 &&
        _obstacleSpeed != null &&
        _obstacleStopped &&
        !_obstacleAuto &&
        _heldObstacleCommand == null;
    const labels = ['저속', '중속', '고속'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '이동 속도: ${_obstacleSpeed == null ? '확인 대기' : labels[_obstacleSpeed!]}',
        ),
        Wrap(
          spacing: 8,
          children: List.generate(
            3,
            (index) => ChoiceChip(
              label: Text(labels[index]),
              selected: _obstacleSpeed == index,
              onSelected: enabled ? (_) => _writeObstacle('B3$index') : null,
            ),
          ),
        ),
        const Text('정지한 상태에서 속도를 변경할 수 있습니다.'),
      ],
    );
  }

  Widget _obstacleDirectionButton(String label, String command) {
    final enabled = _isObstacleConnected && _obstacleV2 && _obstacleReady;
    return Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) => Listener(
          onPointerDown: enabled
              ? (event) => _beginObstacleHold(command, event.pointer)
              : null,
          onPointerUp: (event) => _endObstacleHold(event.pointer),
          onPointerCancel: (event) => _endObstacleHold(event.pointer),
          onPointerMove: (event) {
            if (_obstaclePointer != event.pointer) return;
            final box = event.localPosition;
            if (box.dx < 0 ||
                box.dx > constraints.maxWidth ||
                box.dy < 0 ||
                box.dy > 64) {
              _stopObstacle();
            }
          },
          child: SizedBox(
            height: 64,
            child: FilledButton(
              onPressed: enabled ? () {} : null,
              child: Text(label, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }

  void _setObstacleDisconnected() {
    _obstacleHeartbeat?.cancel();
    _cancelObstacleHold();
    _obstacleInputSubscription?.cancel();
    _obstacleConnection?.dispose();
    if (!mounted) return;
    setState(() {
      _obstacleConnection = null;
      _isObstacleConnecting = false;
      _obstacleV2 = false;
      _obstacleReady = false;
      _obstacleStopped = false;
      _obstacleSpeed = null;
      _obstacleAuto = false;
      _obstacleStatus = '연결 안됨';
      _obstacleReceiveBuffer = '';
    });
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('트랙 장치 제어'),
        centerTitle: true,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionTitle('신호등 제어'),
              const SizedBox(height: 10),
              _TrafficStatusCard(
                isConnected: _isTrafficConnected,
                currentSignal: _currentSignal,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _isTrafficDiscovering ? null : _searchTrafficDevices,
                icon: _isTrafficDiscovering
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                label: Text(
                  _isTrafficDiscovering ? '검색 중' : '신호등 Bluetooth 장치 검색',
                ),
              ),
              const SizedBox(height: 12),
              _DeviceList(
                devices: _trafficDevices,
                selectedDevice: _selectedTrafficDevice,
                isDiscovering: _isTrafficDiscovering,
                targetDeviceName: _trafficDeviceName,
                onSelected: (device) {
                  setState(() {
                    _selectedTrafficDevice = device;
                  });
                },
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isTrafficConnecting
                    ? null
                    : _connectSelectedTrafficDevice,
                icon: _isTrafficConnecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_connected),
                label: Text(_isTrafficConnecting ? '연결 중' : '선택한 신호등 장치 연결'),
              ),
              const SizedBox(height: 24),
              const _SectionTitle('수동 제어'),
              const SizedBox(height: 10),
              _CommandGrid(
                buttons: [
                  _CommandButtonData(
                    label: '초록불',
                    color: Colors.green,
                    command: 'GREEN',
                  ),
                  _CommandButtonData(
                    label: '노란불',
                    color: Colors.amber,
                    foregroundColor: Colors.black,
                    command: 'YELLOW',
                  ),
                  _CommandButtonData(
                    label: '빨간불',
                    color: Colors.red,
                    command: 'RED',
                  ),
                  _CommandButtonData(
                    label: '빨간불 + 좌회전',
                    color: Colors.deepOrange,
                    command: 'RED_LEFT',
                  ),
                  _CommandButtonData(
                    label: '끄기',
                    color: Colors.grey,
                    command: 'OFF',
                    fullWidth: true,
                  ),
                ],
                onPressed: _sendTrafficCommand,
              ),
              const SizedBox(height: 24),
              const _SectionTitle('모드'),
              const SizedBox(height: 10),
              _CommandGrid(
                buttons: [
                  _CommandButtonData(
                    label: '자동 모드',
                    color: Colors.blue,
                    command: 'AUTO',
                  ),
                  _CommandButtonData(
                    label: '수동 모드',
                    color: Colors.indigo,
                    command: 'MANUAL',
                  ),
                ],
                onPressed: _sendTrafficCommand,
              ),
              const SizedBox(height: 28),
              const Divider(),
              const SizedBox(height: 16),
              const _SectionTitle('장애물 제어'),
              const SizedBox(height: 10),
              _ObstacleStatusCard(
                isConnected: _isObstacleConnected,
                lastCommand: _lastObstacleCommand,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isObstacleConnecting
                    ? null
                    : _connectObstacleDevice,
                icon: _isObstacleConnecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_connected),
                label: Text(_isObstacleConnecting ? '연결 중' : '장애물 연결'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _isObstacleConnected
                    ? _disconnectObstacleDevice
                    : null,
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('장애물 연결 해제'),
              ),
              const SizedBox(height: 16),
              Text(_obstacleStatus),
              const SizedBox(height: 12),
              _obstacleSpeedSelector(),
              if (_isObstacleConnected && !_obstacleV2)
                const Text('새 장애물 펌웨어 확인을 기다리는 중입니다.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isObstacleConnected && _obstacleV2 && _obstacleReady
                    ? _toggleObstacleAuto
                    : null,
                icon: Icon(_obstacleAuto ? Icons.pause : Icons.repeat),
                label: Text(
                  _obstacleAuto ? 'AUTO 끄기 · 정지' : 'AUTO 켜기 · 끝–중간 왕복',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _obstacleDirectionButton('← 왼쪽\n보드 반대쪽', 'B21'),
                  const SizedBox(width: 10),
                  _obstacleDirectionButton('오른쪽 →\n보드 쪽', 'B20'),
                ],
              ),
              const SizedBox(height: 8),
              const Text('좌우 버튼은 누르는 동안 이동하고, 손을 떼면 정지합니다.'),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrafficStatusCard extends StatelessWidget {
  const _TrafficStatusCard({
    required this.isConnected,
    required this.currentSignal,
  });

  final bool isConnected;
  final String currentSignal;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      children: [
        const Text(
          '신호등 연결 상태',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 14),
        _StatusRow(
          label: '상태',
          value: isConnected ? '연결됨' : '연결 안됨',
          valueColor: isConnected ? Colors.green : Colors.grey.shade700,
        ),
        const SizedBox(height: 12),
        _StatusRow(
          label: '장치명',
          value: _TrafficLightPageState._trafficDeviceName,
          valueColor: Colors.black87,
        ),
        const SizedBox(height: 12),
        _StatusRow(
          label: '현재 신호',
          value: currentSignal,
          valueColor: Colors.black87,
        ),
      ],
    );
  }
}

class _ObstacleStatusCard extends StatelessWidget {
  const _ObstacleStatusCard({
    required this.isConnected,
    required this.lastCommand,
  });

  final bool isConnected;
  final String lastCommand;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      children: [
        const Text(
          '장애물 연결 상태',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 14),
        _StatusRow(
          label: '상태',
          value: isConnected ? '연결됨' : '연결 안됨',
          valueColor: isConnected ? Colors.green : Colors.grey.shade700,
        ),
        const SizedBox(height: 12),
        const _StatusRow(
          label: '장치명',
          value: obstacleDeviceName,
          valueColor: Colors.black87,
        ),
        const SizedBox(height: 12),
        _StatusRow(
          label: '마지막 명령',
          value: lastCommand,
          valueColor: Colors.black87,
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 16,
              color: valueColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.devices,
    required this.selectedDevice,
    required this.isDiscovering,
    required this.targetDeviceName,
    required this.onSelected,
  });

  final List<BluetoothDevice> devices;
  final BluetoothDevice? selectedDevice;
  final bool isDiscovering;
  final String targetDeviceName;
  final ValueChanged<BluetoothDevice> onSelected;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: devices.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  isDiscovering
                      ? '$targetDeviceName 장치를 찾는 중입니다.'
                      : '검색된 $targetDeviceName 장치가 없습니다.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              )
            : Column(
                children: [
                  for (final device in devices)
                    ListTile(
                      onTap: () => onSelected(device),
                      leading: Icon(
                        selectedDevice?.address == device.address
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: selectedDevice?.address == device.address
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                      ),
                      title: Text(device.name ?? '이름 없는 장치'),
                      subtitle: Text(device.address),
                    ),
                ],
              ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
    );
  }
}

class _CommandGrid extends StatelessWidget {
  const _CommandGrid({required this.buttons, required this.onPressed});

  static const double _spacing = 10;
  static const double _buttonHeight = 58;

  final List<_CommandButtonData> buttons;
  final ValueChanged<String> onPressed;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width - 32;
        final halfWidth = (availableWidth - _spacing) / 2;

        return Wrap(
          spacing: _spacing,
          runSpacing: _spacing,
          children: [
            for (final button in buttons)
              SizedBox(
                width: button.fullWidth ? availableWidth : halfWidth,
                height: _buttonHeight,
                child: ElevatedButton(
                  onPressed: () => onPressed(button.command),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: button.color,
                    foregroundColor: button.foregroundColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  child: Text(
                    button.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CommandButtonData {
  const _CommandButtonData({
    required this.label,
    required this.color,
    required this.command,
    this.foregroundColor = Colors.white,
    this.fullWidth = false,
  });

  final String label;
  final Color color;
  final Color foregroundColor;
  final String command;
  final bool fullWidth;
}
