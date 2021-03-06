/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2019, 2020 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

class Device {
  String deviceId;
  String displayName;
  String lastSeenIp;
  DateTime lastSeenTs;

  Device.fromJson(Map<String, dynamic> json) {
    deviceId = json['device_id'];
    displayName = json['display_name'];
    lastSeenIp = json['last_seen_ip'];
    lastSeenTs = DateTime.fromMillisecondsSinceEpoch(json['last_seen_ts'] ?? 0);
  }

  Map<String, dynamic> toJson() {
    final data = <String, dynamic>{};
    data['device_id'] = deviceId;
    if (displayName != null) {
      data['display_name'] = displayName;
    }
    if (lastSeenIp != null) {
      data['last_seen_ip'] = lastSeenIp;
    }
    if (lastSeenTs != null) {
      data['last_seen_ts'] = lastSeenTs.millisecondsSinceEpoch;
    }
    return data;
  }
}
