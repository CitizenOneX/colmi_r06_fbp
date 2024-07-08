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
  Timer? _rawDataTimer;
  bool _waveGestureOn = false;

  int? _batteryLevel;
  bool? _batteryIsCharging;
  int? _steps;
  int? _calories;
  int? _distance;
  int? _blood;
  int? _bloodMax1;
  int? _bloodMax2;
  int? _bloodMax3;
  int? _hrRaw;
  int? _hrMax;
  int? _hrMin;
  int? _hrDiff;
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
    if (data[0] == ring.Notification.rawSensor.code && data[1] == ring.NotificationRawSensor.accelerometer.code) {
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
    else if (data[0] == ring.Notification.notification.code) {
      if (kDebugMode) debugPrint('Notification message');

      // check second byte and dispatch to specific parsing function
      if (data[1] == ring.NotificationSubtype.stepsCaloriesDistance.code) {
          var (steps, calories, distance) = ring.parseNotifStepsCaloriesDistanceData(data);
          _steps = steps;
          _calories = calories;
          _distance = distance;
      }
      else if (data[1] == ring.NotificationSubtype.battery.code) {
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
      if (data[1] == ring.NotificationRawSensor.accelerometer.code) {
          var (rawX, rawY, rawZ) = ring.parseRawAccelerometerSensorData(data);
          _rawX = rawX;
          _rawY = rawY;
          _rawZ = rawZ;

          // calculate absolute "scroll" position when rotated around the finger
          // range -pi .. pi
          _scroll = atan2(rawY, rawX);

          // how much acceleration other than gravity?
          // range > 0, in g (squared, actually)
          _impact = ((rawX * rawX + rawY * rawY + rawZ * rawZ)/(512*512) - 1.0).abs();
      }
      else if (data[1] == ring.NotificationRawSensor.blood.code) {
        var (blood, max1, max2, max3) = ring.parseRawBloodSensorData(data);
          _blood = blood;
          _bloodMax1 = max1;
          _bloodMax2 = max2;
          _bloodMax3 = max3;
      }
      else if (data[1] == ring.NotificationRawSensor.heartrate.code) {
        var (raw, max, min, diff) = ring.parseRawHeartRateSensorData(data);
          _hrRaw = raw;
          _hrMax = max;
          _hrMin = min;
          _hrDiff = diff;
      }
      else {
          debugPrint('Unknown Raw Sensor subtype: ${data[1]}');
      }
    }
    else if (data[0] == ring.Notification.heartRate.code) {
      debugPrint('Heart Rate message');
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
    else {
      debugPrint('Unknown message type: ${data[0]}');
    }

    _receivedData = data.toString();

    // update the UI
    setState(() {});
  }

  /// Polls the ring periodically for a snapshot of HR, SPO2 and Accelerometer data
  /// Originally used the "a10404" subscription but it only provides updates about once per second
  /// So this implementation periodically polls "a103" while the _rawDataOn flag is toggled on.
  /// TODO it would be nice to be able to turn on the raw data selectively, for e.g. HR or accelerometer etc
  /// TODO it would also be nice to be able to get "MAX" accelerometer values over a given period
  /// or since the last request, to help with tap detection
  Future<void> _toggleAllRawData() async {
    if (!_rawDataOn) {
      _rawDataTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
        if (_rawDataOn) {
          _sendCommand(ring.Command.getAllRawData.bytes);
        }
      });
    }
    else {
      _rawDataTimer?.cancel();
      _rawDataTimer = null;
    }
    _rawDataOn = !_rawDataOn;
  }

  Future<void> _toggleWaveGesture() async {
    await _sendCommand(_waveGestureOn ? ring.Command.waveGestureOff.bytes : ring.Command.waveGestureOn.bytes);
    _waveGestureOn = !_waveGestureOn;
  }

  Future<void> _getBatteryState() async {
    await _sendCommand(ring.Command.getBatteryState.bytes);
  }

  Future<void> _getAllRawData() async {
    await _sendCommand(ring.Command.getAllRawData.bytes);
  }

  Future<void> _allRawDataOff() async {
    await _sendCommand(ring.Command.allRawDataOff.bytes);
  }

  Future<void> _reboot() async {
    await _sendCommand(ring.Command.reboot.bytes);
  }

  Future<void> _resetDefault() async {
    await _sendCommand(ring.Command.resetDefault.bytes);
  }

  Future<void> _blinkTwice() async {
    await _sendCommand(ring.Command.blinkTwice.bytes);
  }

  /// kicks off the measurement start, then (if the ring is being worn) it seems like you wait about 20 seconds
  /// then get 10 notification callbacks (looks like 5 pairs - duplicates with the same data) in rapid succession
  /// If the ring is not being worn you get a message back after about 1 second instead
  Future<void> _measureHeartRate() async {
    await _sendCommand(ring.Command.requestHeartRate.bytes);
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
            SizedBox(height: 140,
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
                Text('Blood: ${_blood ?? ''}',),
                const SizedBox(height: 10),
                Text('BloodMax1: ${_bloodMax1 ?? ''}',),
                const SizedBox(height: 10),
                Text('BloodMax2: ${_bloodMax2 ?? ''}',),
                const SizedBox(height: 10),
                Text('BloodMax3: ${_bloodMax3 ?? ''}',),
                const SizedBox(height: 10),
                Text('HR Raw: ${_hrRaw ?? ''}',),
                const SizedBox(height: 10),
                Text('HR Max: ${_hrMax ?? ''}',),
                const SizedBox(height: 10),
                Text('HR Min: ${_hrMin ?? ''}',),
                const SizedBox(height: 10),
                Text('HR Diff: ${_hrDiff ?? ''}',),
                const SizedBox(height: 10),
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
                  onPressed: _toggleWaveGesture,
                  child: const Text("Toggle Wave Gesture Detection"),
                ),
                ElevatedButton(
                  onPressed: _getBatteryState,
                  child: const Text("Get Battery State"),
                ),
                ElevatedButton(
                  onPressed: _measureHeartRate,
                  child: const Text("Start Measuring Heart Rate"),
                ),
                ElevatedButton(
                  onPressed: _getAllRawData,
                  child: const Text("Get Raw Data"),
                ),
                ElevatedButton(
                  onPressed: _allRawDataOff,
                  child: const Text("Raw Data Subscription Off"),
                ),
                ElevatedButton(
                  onPressed: _resetDefault,
                  child: const Text("Reset Default"),
                ),
                ElevatedButton(
                  onPressed: _reboot,
                  child: const Text("Reboot"),
                ),
                ElevatedButton(
                  onPressed: _blinkTwice,
                  child: const Text("Blink Twice"),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
