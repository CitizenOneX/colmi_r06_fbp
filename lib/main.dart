import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'colmi_ring.dart' as ring;

void main() {
  FlutterBluePlus.setLogLevel(LogLevel.info);
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'COLMi Smart Ring Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<List<ScanResult>>? _scanResultSubs; // device scan subscription
  BluetoothDevice? _device;
  BluetoothCharacteristic? _charWrite; // custom write
  BluetoothCharacteristic? _charNotify; // custom notify
  StreamSubscription<List<int>>? _charNotifySubs; // custom notify stream subscription
  StreamSubscription<BluetoothConnectionState>? _connStateSubs; // device connection state subscription

  String? _sentData;
  String? _receivedData;
  int _prevReceivedTime = DateTime.now().millisecondsSinceEpoch;
  String? _error;
  bool _rawDataOn = false;
  bool _pollRawDataOn = false;
  Timer? _rawDataTimer;
  bool _waveGestureOn = false;

  int? _batteryLevel;
  bool? _batteryIsCharging;
  int? _steps;
  int? _calories;
  int? _distance;
  int? _heartRate;
  int? _spO2Percentage;
  int? _stress;
  int? _spO2raw;
  int? _spO2a;
  int? _spO2b;
  int? _spO2c;
  int? _ppgRaw;
  int? _ppgMax;
  int? _ppgMin;
  int? _ppgDiff;
  int? _rawX;
  int? _rawY;
  int? _rawZ;
  int? _accelMillis;
  int _waves = 0;
  double? _scroll;
  double? _impact;

  /// Connect to the ring then discover its services/characteristics
  /// The ring only seems to put a name in the Advertised Data, not services, manufacturer data or anything else identifiable
  /// TODO although the flutter_blue_plus_example program somehow does get 2 bytes of manufacturer data and 6-ish bytes of Service data before connecting...
  Future<void> _connect() async {
    // if we've previously connected, just reconnect, don't scan
    if (_device != null) {
      _device!.cancelWhenDisconnected(_connStateSubs!, delayed:true, next:true);
      await _device!.connect();
      await _discoverServices();
      // update UI after ring is connected
      setState(() {});
      return;
    }

    // Otherwise Start scanning
    try {
      // Wait for Bluetooth enabled & permission granted
      await FlutterBluePlus.adapterState.where((val) => val == BluetoothAdapterState.on).first;

      // guessing that all the rings advertise a name of R0* based on my R06
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 5),
        withKeywords: ['R0']);
    } catch (e) {
      debugPrint(e.toString());
    }

    // Listen to scan results
    // if there's already a subscription, remember to cancel it first if we can
    // Connects to the first one; if you have several rings in range then tweak this
    await _scanResultSubs?.cancel();
    _scanResultSubs = FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        // not quite sure if all the rings follow 'R0n_xxxx' but my R06 does
        if (r.advertisementData.advName.startsWith(RegExp(ring.advertisedNamePattern))) {
          FlutterBluePlus.stopScan();
          _device = r.device;
          try {
            // firstly set up a subscription to track connections/disconnections from the ring
            _connStateSubs = _device!.connectionState.listen((BluetoothConnectionState state) async {
                debugPrint('device connection state change: $state');
                if (state == BluetoothConnectionState.disconnected) {
                  DisconnectReason? reason = _device!.disconnectReason;
                  _error = null;

                  if (reason != null) {
                    debugPrint('device disconnection reason: ${_device!.disconnectReason}');
                    if (reason.platform == ErrorPlatform.android && reason.code == 133) {
                      _error = 'ANDROID_SPECIFIC_ERROR occurred. Multiple attempts to reconnect (3+) usually solve it.';
                    }
                  }
                }
                // update UI to show or clear Error
                setState(() {});
            });

            _device!.cancelWhenDisconnected(_connStateSubs!, delayed:true, next:true);
            await _device!.connect();
            await _discoverServices();

            // update UI after ring is connected
            setState(() {});
          }
          catch (e) {
            debugPrint(e.toString());
          }
          break;
        }
      }
    });
  }

  /// Disconnect from the ring and cancel the notification subscription
  Future<void> _disconnect() async {
    await _charNotifySubs?.cancel();
    await _device?.disconnect();
    _charWrite = null;
    _charNotify = null;
    setState(() {});
  }

  /// Find and keep references to the custom write and notify characteristics
  Future<void> _discoverServices() async {
    if (_device != null && _device!.isConnected) {
      List<BluetoothService> services = await _device!.discoverServices();
      for (BluetoothService service in services) {
        if (service.uuid.str128 == ring.Uuid.cmdService.str128) {
          for (BluetoothCharacteristic c in service.characteristics) {
            // Find the Char for writing 16-byte commands to the ring
            if (c.uuid.str128 == ring.Uuid.cmdWriteChar.str128) {
              _charWrite = c;
            }
            // Find the Char for receiving 16-byte notifications from the ring and subscribe
            else if (c.uuid.str128 == ring.Uuid.cmdNotifyChar.str128) {
              _charNotify = c;
              // if there's already a subscription, remember to cancel the old one first if we can
              await _charNotifySubs?.cancel();
              _charNotifySubs = _charNotify!.onValueReceived.listen(_onNotificationData);
              await _charNotify!.setNotifyValue(true);
            }
          }
        }
      }
    }
  }

  /// Callback for handling all 16-byte data notifications from the custom notification characteristic
  void _onNotificationData(List<int> data) {
    if (kDebugMode) debugPrint('_onNotificationData called: $data');

    // track the time between accelerometer updates
    if (data[0] == ring.Notification.rawSensor.code && data[1] == ring.RawSensorSubtype.accelerometer.code) {
      var receivedTime = DateTime.now().millisecondsSinceEpoch;
      _accelMillis = receivedTime - _prevReceivedTime;
      _prevReceivedTime = receivedTime;
    }

    if (data.length != 16) {
      _error = 'Invalid message length: ${data.length}';
      debugPrint(_error);
      setState(() {});
      return;
    }

    // switch over all the different kinds of 16-byte data messages
    // You'd think this could be a switch statement,
    // but no: https://github.com/dart-lang/language/issues/2780
    if (data[0] == ring.Notification.battery.code) {
      debugPrint('Battery message');
      var (level, isCharging) = ring.parseBatteryData(data);
      _batteryLevel = level;
      _batteryIsCharging = isCharging;
    }
    else if (data[0] == ring.Notification.general.code) {
      if (kDebugMode) debugPrint('Notification message');

      // check second byte and dispatch to specific parsing function
      if (data[1] == ring.GeneralSubtype.stepsCaloriesDistance.code) {
          var (steps, calories, distance) = ring.parseNotifStepsCaloriesDistanceData(data);
          _steps = steps;
          _calories = calories;
          _distance = distance;
      }
      else if (data[1] == ring.GeneralSubtype.battery.code) {
          var (level, isCharging) = ring.parseNotifBatteryData(data);
          _batteryLevel = level;
          _batteryIsCharging = isCharging;
      }
      else {
        // other subtype cases
          debugPrint('Unknown Notification subtype: ${data[1]}');
      }
    }
    else if (data[0] == ring.Notification.rawSensor.code) {
      // check second byte and dispatch to specific parsing function
      if (data[1] == ring.RawSensorSubtype.accelerometer.code) {
          var (rawX, rawY, rawZ) = ring.parseRawAccelerometerSensorData(data);
          _rawX = rawX;
          _rawY = rawY;
          _rawZ = rawZ;

          // how much acceleration other than gravity?
          var netGforce = (sqrt(rawX * rawX + rawY * rawY + rawZ * rawZ)/512 - 1.0).abs();

          // if this is just close to g, then the ring is at rest or perhaps gentle scrolling
          if (netGforce < 0.1) {
            // calculate absolute "scroll" position when rotated around the finger
            // range -pi .. pi
            _scroll = atan2(rawY, rawX);
            _impact = 0.0;
          }
          else if (netGforce > 0.2) {
            // if values are large, this is a flick or tap, don't update _scroll
            // range > 0, in g
            _impact = netGforce;
          }
      }
      else if (data[1] == ring.RawSensorSubtype.spO2.code) {
        var (raw, a, b, c) = ring.parseRawSpO2SensorData(data);
          _spO2raw = raw;
          _spO2a = a;
          _spO2b = b;
          _spO2c = c;
      }
      else if (data[1] == ring.RawSensorSubtype.ppg.code) {
        var (raw, max, min, diff) = ring.parseRawPpgSensorData(data);
          _ppgRaw = raw;
          _ppgMax = max;
          _ppgMin = min;
          _ppgDiff = diff;
      }
      else {
          debugPrint('Unknown Raw Sensor subtype: ${data[1]}');
      }
    }
    else if (data[0] == ring.Notification.heartSpo2Stress.code) {
      if (data[1] == ring.HeartSpO2StressSubtype.heartRate.code) {
        debugPrint('Heart Rate message');
        if (data[3] != 0) _heartRate = data[3];
      }
      else if (data[1] == ring.HeartSpO2StressSubtype.spO2.code) {
        debugPrint('SpO2 message');
        if (data[3] != 0) _spO2Percentage = data[3];
      }
      else if (data[1] == ring.HeartSpO2StressSubtype.stress.code) {
        debugPrint('Stress message');
        if (data[3] != 0) _stress = data[3];
      }
      else {
        debugPrint('Unknown Heart Rate/SpO2/Stress subtype');
      }
    }
    else if (data[0] == ring.Notification.waveGesture.code) {
      debugPrint('Wave Gesture message');
      if (data[1] == 2) {
        _waves++;
      }
    }
    else if (data[0] == ring.Notification.blinkTwice.code) {
      debugPrint('Blink Twice message');
    }
    else if (data[0] == ring.Notification.greenLight10Sec.code) {
      debugPrint('Green Light 10s message');
    }
    else {
      debugPrint('Unknown message type: ${data[0]}');
    }

    _receivedData = data.toString();

    // update the UI
    setState(() {});
  }

  /// Polls the ring periodically for a snapshot of SpO2, PPG and Accelerometer data
  /// Originally used the 0xa104 subscription but it only provides updates about once per second
  /// So this implementation periodically polls "a103" while the _pollRawDataOn flag is toggled on.
  /// NOTE: the LEDs don't flash and the SpO2 and PPG data doesn't change over time which suggests
  /// that only the accelerometer data is being polled, as opposed to the 0xa104 subscription
  /// TODO it would be nice to be able to turn on the raw data selectively, for e.g. HR or accelerometer etc
  /// TODO it would also be nice to be able to get "MAX" accelerometer values over a given period
  /// or since the last request, to help with tap detection
  Future<void> _pollAllRawData() async {
    if (!_pollRawDataOn) {
      _rawDataTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
        if (_pollRawDataOn) {
          _sendCommand(ring.Command.getAllRawData.bytes);
        }
      });
    }
    else {
      _rawDataTimer?.cancel();
      _rawDataTimer = null;
    }
    _pollRawDataOn = !_pollRawDataOn;
  }

  /// Uses the 0xa104 subscription that provides updates about once per second
  Future<void> _toggleAllRawData() async {
    await _sendCommand(_rawDataOn ? ring.Command.disableAllRawData.bytes : ring.Command.enableAllRawData.bytes);
    _rawDataOn = !_rawDataOn;
  }

  Future<void> _toggleWaveGesture() async {
    await _sendCommand(_waveGestureOn ? ring.Command.disableWaveGesture.bytes : ring.Command.enableWaveGesture.bytes);
    _waveGestureOn = !_waveGestureOn;
  }

  Future<void> _getBatteryState() async {
    await _sendCommand(ring.Command.getBatteryState.bytes);
  }

  Future<void> _getAllRawData() async {
    await _sendCommand(ring.Command.getAllRawData.bytes);
  }

  Future<void> _reboot() async {
    await _sendCommand(ring.Command.reboot.bytes);
  }

  Future<void> _resetDefaults() async {
    await _sendCommand(ring.Command.resetDefaults.bytes);
  }

  Future<void> _blinkTwice() async {
    await _sendCommand(ring.Command.blinkTwice.bytes);
  }

  Future<void> _greenLight() async {
    await _sendCommand(ring.Command.greenLight10Sec.bytes);
  }

  /// kicks off the measurement start, then (if the ring is being worn) you wait about 25 seconds
  /// then get 10 notification callbacks (looks like 5 pairs - duplicates with the same data) in rapid succession
  /// If the ring is not being worn you get a message back after about 1 second instead
  Future<void> _measureHeartRate() async {
    await _sendCommand(ring.Command.requestHeartRate.bytes);
  }
  Future<void> _measureSpO2() async {
    await _sendCommand(ring.Command.requestSpO2.bytes);
  }
  Future<void> _measureStress() async {
    await _sendCommand(ring.Command.requestStress.bytes);
  }

  /// Actually send the 16-byte command message to the custom Write characteristic
  Future<void> _sendCommand(List<int> cmd) async {
    if (_device != null && _device!.isConnected && _charWrite != null) {
      try {
        _sentData = cmd.toString();
        _error = null;
        await _charWrite!.write(cmd);
      }
      catch (e) {
        _error = e.toString();
        debugPrint(_error);
      }

      // update the UI too
      setState(() {});

      if (kDebugMode) debugPrint('Sent data: $_sentData');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("COLMi Smart Ring Demo"),
      ),
      body: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            Text(
              _device != null ? "Device: ${_device!.platformName}" : "No Device Found",
            ),
            const SizedBox(height: 10),
            Text('Sent Command: ${_sentData ?? 'No Data'}',),
            const SizedBox(height: 10),
            Text('Response: ${_receivedData ?? 'No Data'}',),
            const SizedBox(height: 10),
            Text('Error: ${_error ?? 'None'}',),
            const Divider(),
            ElevatedButton(
              onPressed: (_device == null || _device!.isDisconnected) ? _connect : _disconnect,
              child: Text((_device == null || _device!.isDisconnected) ? "Connect" : "Disconnect"),
            ),
            const Divider(),

            // put it in a SizedBox to control vertical number of elements
            SizedBox(height: 60,
              child: Wrap(direction: Axis.vertical, runSpacing: 30.0, children: [
                Text('Battery Level: ${_batteryLevel != null ? '$_batteryLevel%' : ''}',),
                const SizedBox(height: 10),
                Text('Is Charging: ${_batteryIsCharging ?? ''}',),
                const SizedBox(height: 10),
                Text('Steps: ${_steps ?? ''}',),
                const SizedBox(height: 10),
                Text('Calories: ${_calories ?? ''}',),
                const SizedBox(height: 10),
                Text('Distance: ${_distance ?? ''}',),
                const SizedBox(height: 10),
                Text('Heart Rate: ${_heartRate ?? ''}',),
                const SizedBox(height: 10),
                Text('SpO2: ${_spO2Percentage != null ? '$_spO2Percentage%' : ''}',),
                const SizedBox(height: 10),
                Text('Stress: ${_stress ?? ''}',),
                const SizedBox(height: 10),
              ])),
              const Divider(),

              // SpO2, PPG raw data
              SizedBox(height: 20,
              child: Wrap(direction: Axis.vertical, runSpacing: 30.0, children: [
                Text('SpO2 Raw: [${_spO2raw ?? ''}, ${_spO2a ?? ''}, ${_spO2b ?? ''}, ${_spO2c ?? ''}]',),
                Text('PPG Raw: [${_ppgRaw ?? ''}, ${_ppgMax ?? ''}, ${_ppgMin ?? ''}, ${_ppgDiff ?? ''}]',),
              ])),
              const Divider(),

              // accelerometer data
              SizedBox(height: 140,
                child: Wrap(direction: Axis.vertical, runSpacing: 30.0, children: [
                Text('Accel Millis: ${_accelMillis ?? ''}',),
                const SizedBox(height: 10),
                Text('Raw X: ${_rawX ?? ''}',),
                const SizedBox(height: 10),
                Text('Raw Y: ${_rawY ?? ''}',),
                const SizedBox(height: 10),
                Text('Raw Z: ${_rawZ ?? ''}',),
                const SizedBox(height: 10),
                Text('Waves: $_waves',),
                const SizedBox(height: 10),
                Column(children: [
                  Row(children:[
                    Text('Scroll: ${_scroll?.toStringAsFixed(2) ?? ''}',),
                    Slider(value: _scroll ?? 0, min:-pi, max:pi, onChanged: (val)=>{},),
                  ]),
                  Row(children:[
                    Text('Impact: ${_impact?.toStringAsFixed(2) ?? ''}',),
                    Slider(value: _impact?.clamp(0, 1) ?? 0, min:0, max:1, onChanged: (val)=>{},),
                  ])
                ]),
              ]),
            ),
            const Divider(),

            // buttons for sending commands to the ring
            if (_device != null && _device!.isConnected) ...[
              Wrap(spacing: 8.0, runSpacing: 4.0, children: [
                ElevatedButton(
                  onPressed: _toggleAllRawData,
                  child: const Text("Toggle Raw Data Stream"),
                ),
                ElevatedButton(
                  onPressed: _pollAllRawData,
                  child: const Text("Toggle Poll Raw Data"),
                ),
                ElevatedButton(
                  onPressed: _toggleWaveGesture,
                  child: const Text("Toggle Wave Gesture Detection"),
                ),
                ElevatedButton(
                  onPressed: _getBatteryState,
                  child: const Text("Get Battery State"),
                ),
                ElevatedButton(
                  onPressed: _measureHeartRate,
                  child: const Text("Measure Heart Rate"),
                ),
                ElevatedButton(
                  onPressed: _measureSpO2,
                  child: const Text("Measure SpO2"),
                ),
                ElevatedButton(
                  onPressed: _measureStress,
                  child: const Text("Measure Stress"),
                ),
                ElevatedButton(
                  onPressed: _getAllRawData,
                  child: const Text("Get Raw Data"),
                ),
                ElevatedButton(
                  onPressed: _blinkTwice,
                  child: const Text("Blink Twice"),
                ),
                ElevatedButton(
                  onPressed: _greenLight,
                  child: const Text("Green Light 10s"),
                ),
                ElevatedButton(
                  onPressed: _resetDefaults,
                  child: const Text("Reset Defaults"),
                ),
                ElevatedButton(
                  onPressed: _reboot,
                  child: const Text("Reboot"),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
