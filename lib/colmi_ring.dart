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

/// 16-byte data notifications we receive back from the ring that are all parsed with custom parsers.
/// When the function is better understood, these names can be improved
enum Notification {
  notification (0x73),
  battery (0x03),
  blinkTwice (0x10),
  rawSensor (0xa1),
  heartRate (0x69),
  waveGesture (0x02);

  const Notification(this.code);

  final int code;
}

/// Subtype (second byte) of 16-byte '0x73' notifications we receive from the ring
/// without making any particular subscription
enum NotificationSubtype {
  syncTodayHrs (0x01),
  syncSingleBp (0x02),
  syncTodaySpo2 (0x03),
  syncStepDetailSingle (0x04),
  temperature (0x05),
  syncTodaySport (0x06),
  sportEnded (0x07),
  targetSettingResponse (0x10),
  battery (0x0c),
  bloodSugar (0x0d),
  stepsCaloriesDistance (0x12);

  const NotificationSubtype(this.code);

  final int code;
}

/// Subtype (second byte) of 16-byte notifications we receive from the ring
/// after making a RawSensor subscription
enum NotificationRawSensor {
  blood (0x01),
  heartrate (0x02),
  accelerometer (0x03);

  const NotificationRawSensor(this.code);

  final int code;
}

/// Commands we can send to the ring
enum Command {
  getBatteryState (hex: '03'),
  requestHeartRate (hex: '690101'),
  allRawDataOff (hex: 'a102'),
  getAllRawData (hex: 'a103'),
  allRawDataOn (hex: 'a10404'),
  waveGestureOn (hex: '0204'),
  waveGestureOff (hex: '0206'),
  blinkTwice (hex: '10'),
  reboot (hex: '08'),
  resetDefault (hex: 'ff');

  const Command({required this.hex});

  final String hex;
  List<int> get bytes => hexStringToCmdBytes(hex);
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
(int,bool,) parseBatteryData(List<int> data) {
  assert(data.length == 16);
  assert(data[0] == 0x03);

  return (data[1],data[2]==1);
}

/// returns the battery level as a percentage and isCharging from the notification
/// e.g. [115, 3, 70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 188]
(int,bool,) parseNotifBatteryData(List<int> data) {
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
(int, int, int, int) parseRawBloodSensorData(List<int> data) {
  assert(data.length == 16);
  assert(data[0] == 0xa1);
  assert(data[1] == 0x01);

  int blood = (data[2] << 8) | data[3];
  int max1 = data[5];
  int max2 = data[7];
  int max3 = data[9];

  return (blood, max1, max2, max3);
}

/// HRS - raw sensor
/// e.g. [161, 2, 50, 94, 50, 118, 49, 30, 1, 88, 1, 0, 0, 0, 0, 132]
(int, int, int, int) parseRawHeartRateSensorData(List<int> data) {
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
(int, int, int,) parseRawAccelerometerSensorData(List<int> data) {
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