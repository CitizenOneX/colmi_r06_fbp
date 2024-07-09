// COLMi R02-R06:
// - RF03 Bluetooth 5.0 LE SoC
// - STK8321 3-axis linear accelerometer
//    - 12 bits per axis, sampling rate configurable between 14Hz->2kHz
//    - motion triggered interrupt signal generation (New data, Any-motion (slope) detection, Significant motion)
// - Vcare VC30F Heart Rate Sensor
// - "Electric Type" Activity Detection (?)

/// BLE Advertised Name matches 'R0n_xxxx'
const advertisedNamePattern = r'^R0\d_[0-9A-Z]{4}$';

/// UUIDs of key custom services and characteristics on the COLMi rings
enum Uuid {
  cmdService ('6e40fff0-b5a3-f393-e0a9-e50e24dcca9e'),
  cmdWriteChar ('6e400002-b5a3-f393-e0a9-e50e24dcca9e'),
  cmdNotifyChar ('6e400003-b5a3-f393-e0a9-e50e24dcca9e'),
  fwService ('de5bf728-d711-4e47-af26-65e3012a5dc7'),
  fwWriteChar ('de5bf72a-d711-4e47-af26-65e3012a5dc7'),
  fwNotifyChar ('de5bf729-d711-4e47-af26-65e3012a5dc7');

  const Uuid(this.str128);

  final String str128;
}

/// Commands we can send to the ring
enum Command {
  setDateTime (hex: '01'), // does this also getDateTime? TODO need to provide datetime bytes here
  enableWaveGesture (hex: '0204'),
  waitingForWaveGesture (hex: '0205'), // confirms back with 0x0200 response
  disableWaveGesture (hex: '0206'),
  getBatteryState (hex: '03'),
  setPhoneName (hex: '04'), // TODO provide string length in data[3] and string data in data[4]+
  keepAlive (hex: '39'), // ?
  reboot (hex: '08'),
  setUnitsMetric (hex: '0a0200'),
  setUnitsImperial (hex: '0a0201'),
  blinkTwice (hex: '10'),
  syncHistoricalHeartRate (hex: '15'), // TODO set data[1-4] uint "from_time"
  setHeartRateMonitoringInterval (hex: '160201'),
  disableSpO2Monitoring (hex: '2c0200'),
  enableSpO2Monitoring (hex: '2c0201'),
  disableStressMonitoring (hex: '360200'),
  enableStressMonitoring (hex: '360201'),
  syncHistoricalStress (hex: '37'),
  syncHistoricalSteps (hex: '43'), // TODO set data[1] number of prev days
  greenLight10Sec (hex: '5055aa'),
  requestHeartRate (hex: '6901'),
  requestSpO2 (hex: '6903'),
  requestStress (hex: '6908'),
  disableAllRawData (hex: 'a102'),
  getAllRawData (hex: 'a103'),
  enableAllRawData (hex: 'a104'),
  syncHistoricalSleep (hex: 'bc27'),
  syncHistoricalSpO2 (hex: 'bc2a'),
  resetDefaults (hex: 'ff');

  const Command({required this.hex});

  final String hex;
  List<int> get bytes => hexStringToCmdBytes(hex);
}

/// 16-byte data notifications we receive back from the ring that are all parsed with custom parsers.
/// When the function is better understood, these names can be improved
enum Notification {
  datetime (0x01),
  waveGesture (0x02), // 0x0200 confirmation, 0x0202 wave detected
  battery (0x03),
  phoneName (0x04),
  unitsPreference (0x0a),
  blinkTwice (0x10),
  heartRateMonitoringInterval (0x16), // TODO 0x160201, 4th byte has interval
  spO2MonitoringPreference (0x2c),
  unknown (0x2f), // (Error?) got this first when doing a "set/get" datetime x01 command, then got a 0x01 message back
  stressMonitoringPreference (0x36),
  greenLight10Sec (0x50),  // 0x5055aa
  heartSpo2Stress (0x69),
  general (0x73),
  rawSensor (0xa1);

  const Notification(this.code);

  final int code;
}

/// Subtype (second byte) of 16-byte '0x73' notifications we receive from the ring
/// without making any particular subscription
enum GeneralSubtype {
  heartRateSyncRequired (0x01),
  singleBpSync (0x02), // TODO better name? What does this do?
  spO2SyncRequired (0x03),
  singleStepDetailSync (0x04),
  temperature (0x05),
  syncTodaySport (0x06),
  sportEnded (0x07),
  targetSettingResponse (0x10),
  battery (0x0c),
  bloodSugar (0x0d),
  stepsCaloriesDistance (0x12);

  const GeneralSubtype(this.code);

  final int code;
}

/// Subtype (second byte) of 16-byte notifications we receive from the ring
/// after making a RawSensor (0xa1) subscription
enum RawSensorSubtype {
  spO2 (0x01), // red led and photodetector; SpO2; oximetry; blood oxygen saturation
  ppg (0x02), // green led and photodetector; photoplethysmography; for pulse rate
  accelerometer (0x03);

  const RawSensorSubtype(this.code);

  final int code;
}

/// Subtype (second byte) of 16-byte notifications we receive from the ring
/// after making a heartSpo2Stress (0x69) request
enum HeartSpO2StressSubtype {
  heartRate (0x01), // then data[2]: 0x00 failed, ring not on finger, or 0x01 running? then data[3]: 0x00 running, or HR result
  spO2 (0x03), // then data[2]: 0x00 failed, ring not on finger, or 0x01 running? then data[3]: 0x00 running, or SpO2 result
  stress (0x08); // then data[2]: 0x00 failed, ring not on finger, or 0x01 running? then data[3]: 0x00 running, or SpO2 result

  const HeartSpO2StressSubtype(this.code);

  final int code;
}

/// Takes a short hex command e.g. 'A102' and packs it (with a checksum) into a well-formed 16-byte command message
List<int> hexStringToCmdBytes(final String hexString) {
  if (hexString.length > 30 || hexString.length % 2 == 1) throw ArgumentError('hex string must be an even number of hex digits [0-f] less than or equal to 30 chars');
  final bytes = List<int>.filled(16, 0);
  for (int i=0; i<hexString.length/2; i++) {
    bytes[i] = int.parse(hexString.substring(2*i, 2*i+2), radix: 16);
  }
  // last byte is a checksum
  bytes[15] = bytes.fold(0, (previous, current) => previous + current) & 0xff;
  return bytes;
}

/// returns the battery level as a percentage and isCharging
/// e.g. [3, 71, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 74]
(int,bool) parseBatteryData(List<int> data) {
  assert(data.length == 16);
  assert(data[0] == 0x03);

  return (data[1],data[2]==1);
}

/// returns the battery level as a percentage and isCharging from the notification
/// e.g. [115, 3, 70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 188]
(int,bool) parseNotifBatteryData(List<int> data) {
  assert(data.length == 16);
  assert(data[0] == 0x73);
  assert(data[1] == 0x0c);

  return (data[2],data[3]==1);
}

/// Returns steps, calories, distance (each uint24 in source data)
/// e.g. [115, 18, 0, 11, 239, 2, 34, 9, 0, 7, 207, 0, 0, 0, 0, 130]
(int, int, int) parseNotifStepsCaloriesDistanceData(List<int> data) {
  assert(data.length == 16);
  assert(data[0] == 0x73);
  assert(data[1] == 0x12);

  int steps = (data[2] << 16) | (data[3] << 8) | data[4];
  int calories = ((data[5] << 16) | (data[6] << 8) | data[7]) ~/ 1000;
  int distance = (data[8] << 16) | (data[9] << 8) | data[10];

  return (steps, calories, distance);
}

/// Blood - raw sensor
/// e.g. [161, 1, 0, 74, 0, 136, 0, 76, 0, 101, 1, 0, 0, 0, 0, 38]
(int, int, int, int) parseRawSpO2SensorData(List<int> data) {
  assert(data.length == 16);
  assert(data[0] == 0xa1);
  assert(data[1] == 0x01);

  int blood = (data[2] << 8) | data[3]; // TODO might just be uint8 too, i.e. data[3]?
  int max1 = data[5];
  int max2 = data[7];
  int max3 = data[9];

  return (blood, max1, max2, max3);
}

/// Photodetector - raw sensor (periodic values range from 10,000 to 13,000, heart beats measured peak to peak)
/// But this is just a snapshot
/// e.g. [161, 2, 50, 94, 50, 118, 49, 30, 1, 88, 1, 0, 0, 0, 0, 132]
(int, int, int, int) parseRawPpgSensorData(List<int> data) {
  assert(data.length == 16);
  assert(data[0] == 0xa1);
  assert(data[1] == 0x02);

  int raw = (data[2] << 8) | data[3];
  int max = (data[4] << 8) | data[5];
  int min = (data[6] << 8) | data[7];
  int diff = (data[8] << 8) | data[9];

  return (raw, max, min, diff);
}

/// Returns IMU/accelerometer data
/// ±4g sensor 12-bit signed, so g value = (rawvalue/2048)*4 in g i.e. raw/512
/// Z is the axis that passes through the centre of the ring
/// Y is tangent to the ring
/// X is vertical when worn on the finger
/// e.g. [161, 3, 0, 12, 31, 6, 251, 3, 0, 0, 0, 0, 0, 0, 0, 211]
(int, int, int) parseRawAccelerometerSensorData(List<int> data) {
  assert(data.length == 16);
  assert(data[0] == 0xa1);
  assert(data[1] == 0x03);

  // raw values are a 12-bit signed value (±2048) reflecting the range ±4g
  // so 1g (gravity) shows up as ±512 in rawZ when the ring is laying flat
  // (positive or negative depending on which side is face up)
  int rawY = ((data[2] << 4) | (data[3] & 0xf)).toSigned(12);
  int rawZ = ((data[4] << 4) | (data[5] & 0xf)).toSigned(12);
  int rawX = ((data[6] << 4) | (data[7] & 0xf)).toSigned(12);

  return (rawX, rawY, rawZ);
}