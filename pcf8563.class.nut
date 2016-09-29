class PCF8563 {

    // Squirrel class for the NXP PCF8563 real time clock
	// http://www.nxp.com/documents/data_sheet/PCF8563.pdf
	//
	// Bus: I2C
	//
	// Written by Tom Byrne and Tony Smith
	// Copyright Electric Imp, Inc. 2014-16

    // PCF8563 Register Constants
    static CTRL_REG_1        = 0x00;
    static CTRL_REG_2        = 0x01;
    static VL_SEC_REG        = 0x02;
    static MINS_REG          = 0x03;
    static HOURS_REG         = 0x04;
    static DAYS_REG          = 0x05;
    static WKDAY_REG         = 0x06;
    static CNTRY_MONTHS_REG  = 0x07;
    static YEARS_REG         = 0x08;
    static MINS_ALARM_REG    = 0x09;
    static HOURS_ALARM_REG   = 0x0A;
    static DAY_ALARM_REG     = 0x0B;
    static WKDAY_ALARM_REG   = 0x0C;
    static CLKOUT_CTRL_REG   = 0x0D;
    static TIMER_CTRL_REG    = 0x0E;
    static TIMER_REG         = 0x0F;

    static version = [1,0,0];

    // Properties
    _i2c = null;
    _addr = null;
    _alarmData = null;
    _alarmPin = null;
    _alarmCB = null;
    _alarmFlag = false;
    _debug = false;

    constructor(impi2c = null, addr = 0xA2, debug = false) {
        if (impi2c == null) {
            server.error("PCF8563 requires a non-null imp I2C bus");
            return null;
        }

        _i2c = impi2c;
        _addr = addr;
        _debug = debug;
    }

    function sync() {
        // Set the RTC to match the imp's own RTC.
        // The imp's RTC is re-synced on server connect, so syncing right after a
        // server connect is recommended. The imp’s RTC is not battery connected
        local now = date();
        _writeDate(now.day, now.month, now.year - 2000, now.wday, now.hour, now.min, now.sec);
    }

    function getDateAndTime() {
		// Read all seven bytes of date data in one go,
		// as per page 13 of the PCF8563 data sheet
		local data = _i2c.read(_addr, format("%c", VL_SEC_REG), 7);

		if (data == null) {
            if (_debug) server.log(format("I2C Read Failure. Device: 0x%02x Register: 0x%02x", _addr, VL_SEC_REG));
            return null;
        }

        local dateData = {};
        dateData.sec <- _BCDtoInteger(data[0] & 0x7F);
        dateData.min <- _BCDtoInteger(data[1] & 0x7F);
        dateData.hour <- _BCDtoInteger(data[2] & 0x3F);
        dateData.day <- _BCDtoInteger(data[3] & 0x3F);
        dateData.wday <- data[4] & 0x07;
        dateData.month <- _BCDtoInteger(data[5] & 0x1F) - 1;
        dateData.year <- 2000 + _BCDtoInteger(data[6]);
        return dateData;
	}

    function setDateAndTime(day, month, year, wday, hour, min, sec) {
		// Manually set the RTC's initial values - all parameters are integers
		if (day < 1 || day > 31) {
		    server.error("PCF8563.setDateAndTime() passed out-of-range date");
		    return;
		}

		if (month < 0 || month > 11) {
		    server.error("PCF8563.setDateAndTime() passed out-of-range month (0-11)");
		    return;
		}

		// Make sure 'year' is in two-digit form
		year = format("%04d", year).slice(2, 4).tointeger();

        if (year < 0 || year > 99) {
		    server.error("PCF8563.setDateAndTime() passed out-of-range year (0-99)");
		    return;
		}

		if (wday < 0 || wday > 6) {
		    server.error("PCF8563.setDateAndTime() passed out-of-range day of the week (0-6");
		    return;
		}

		if (sec < 0 || sec > 59) {
		    server.error("PCF8563.setDateAndTime() passed out-of-range seconds value (0-59)");
		    return;
		}

		if (min < 0 || min > 59) {
		    server.error("PCF8563.setDateAndTime() passed out-of-range minutes value (0-59)");
		    return;
		}

		if (hour < 0 || hour > 23) {
		    server.error("PCF8563.setDateAndTime() passed out-of-range hour value (0-23)");
		    return;
		}

        _writeDate(day, month, year, wday, hour, min, sec);
	}

    function checkClock() {
        // If bit 7 of VL_SEC_REG is set, the internal voltage detector has detected a
        // low-voltage event and the clock integrity is not guaranteed.
        // The flag remains set until it is manually cleared.
        // This is provided because the RTC is often run on a battery
        if (_readReg(VL_SEC_REG) & 0x80) return false;
        return true;
    }

    function clearClockCheck() {
        // Clear the low-voltage flag
        local r = _readReg(VL_SEC_REG) & 0x7F;
        _writeReg(VL_SEC_REG, r);
    }

    function configureAlarm(alarmPin = null, callback = null) {
        if (alarmPin == null) {
            server.error("PCF8563.configureAlarm() requires a non-null imp pin object");
            return;
        }

        if (callback == null) {
            server.error("PCF8563.configureAlarm() requires as non-null alarm callback");
            return;
        }

        _alarmCB = callback;
        _alarmPin = alarmPin;
        _alarmPin.configure(DIGITAL_IN_PULLUP, _interrupt.bindenv(this));
        _alarmData = [0x80, 0x80, 0x80, 0x80];
    }

    function setAlarm(alarm = null) {
        if (alarm != null) {
            // Set the alarm time using the passed table, 'alarm'
            local params = ["min", "hour", "day", "wday"];
            local andValue = [0x7F, 0x3F, 0x3F, 0x03];
            local alarmBlob = blob(4);
            local value = 0;

            foreach (i, param in params) {
                if (param in alarm && alarm[param] != null) {
                    // Set the alarm parameter
                    if (_debug) server.log("Setting alarm " + param + " to " + alarm[param]);
                    value = _integerToBCD(alarm[param] & andValue[i]);
                } else {
                    // Set bit 7 to disable the alarm parameter
                    if (_alarmData[i] != 0x80) {
                        value = _alarmData[i] | 0x80;
                    } else {
                        value = 0x80;
                    }
                }

                alarmBlob[i] = value;
                _alarmData[i] = value;
            }

            local err = _writeAlarm(alarmBlob);
            if (_debug && err == 0) {
                server.log("Alarm set (weekday:day:hour:mins) to " + format("0x%02X:0x%02X:0x%02X:0x%02X", _alarmData[3], _alarmData[2], _alarmData[1], _alarmData[0]));
            }
        } else {
            local alarmSet = false;
            foreach (param in _alarmData) {
                if (param != 0x80) {
                    alarmSet = true;
                    break;
                }
            }

            if (!alarmSet) {
                server.error("PCF8563.setAlarm() requires an initial alarm time setting");
                return;
            }
        }


        // Set AIE (bit 1) of CTRL_REG_2 to activate the alarm
        // Also clear TIE (bit 0)
        local r = _readReg(CTRL_REG_2);
        r = (r | 0x02) & 0xFE;
        _writeReg(CTRL_REG_2, r);
        _alarmFlag = true;
        if (_debug) server.log("Alarm enabled");
    }

    function unsetAlarm() {
        // To stop the alarm from being triggered,
        // just clear AIE (bit 1) of CTRL_REG_2
        local r = _readReg(CTRL_REG_2) & 0xFD;
        _writeReg(CTRL_REG_2, r);
        _alarmFlag = false;
        if (_debug) server.log("Alarm disabled");
    }

    function silenceAlarm() {
        // To stop the alarm from 'ringing' clear the
        // AF bit (3) of CTRL_REG_2
        local r = _readReg(CTRL_REG_2) & 0xF7;
        _writeReg(CTRL_REG_2, r);
        if (_debug) server.log("Alarm silenced");
    }

    function clearAlarm() {
        // Clear the AIE (bit 1) of CTRL_REG_2 to stop the alarm
        // Also clear AF (bit 3) and TIE (bit 0)
        local r = _readReg(CTRL_REG_2) & 0xF4;
        _writeReg(CTRL_REG_2, r);
        _alarmFlag = false;

        local alarmBlob = blob(4);
        for (local i = 0 ; i < 4 ; ++i) {
            alarmBlob[i] = 0x80;
            _alarmData[i] = 0x80;
        }

        local err = _writeAlarm(alarmBlob);
        if (_debug && err == 0) server.log("Alarm cleared and disabled");
    }

    // ********** Private Functions - Do Not Call **********

    function _readReg(register) {
        // Read the specified register
        local data = _i2c.read(_addr, format("%c", register), 1);
        if (data == null) {
            server.error(format("I2C Read Failure. Device: 0x%02x Register: 0x%02x", _addr, register));
            return -1;
        }

        return data[0];
    }

    function _writeReg(register, databyte) {
        // Write 'databyte' to the specified register
        local err = _i2c.write(_addr, format("%c%c", register, databyte));
        if (err != 0) {
            server.error(format("I2C Write Failure. Device: 0x%02x Register: 0x%02x Error: %d", _addr, register, err));
        }
    }

    function _writeDate(day, month, year, wday, hour, min, sec) {
        // Write to all seven date registers at once,
        // as per page 13 of the PCF8563 data sheet
        local data = blob(7);
        data.writen(_integerToBCD(sec), 'b');
        data.writen(_integerToBCD(min), 'b');
        data.writen(_integerToBCD(hour), 'b');
        data.writen(_integerToBCD(day), 'b');
        data.writen(wday, 'b');
        data.writen(_integerToBCD(month + 1), 'b');
        data.writen(_integerToBCD(year), 'b');

        local err = _i2c.write(_addr, format("%c", VL_SEC_REG) + data.tostring());
        if (err != 0) {
            server.error(format("I2C Write Failure. Device: 0x%02x Error: %d", _addr, err));
        } else {
            if (_debug) server.log("RTC set");
        }
    }

    function _writeAlarm(alarmBlob) {
        local err = _i2c.write(_addr, format("%c", MINS_ALARM_REG) + alarmBlob.tostring());
        if (err != 0) {
            server.error(format("I2C Write Failure. Device: 0x%02x Error: %d", _addr, err));
        }

        return err;
    }

    function _integerToBCD(value) {
		// Writes must be converted from integer to BCD
		local a = value / 10;
		local b = value - (a * 10);
		return (a << 4) + b;
	}

	function _BCDtoInteger(value) {
		// Reads must be converted to integer from BCD
		local a = (value & 0xF0) >> 4;
		local b = value & 0x0F;
		return (a * 10) + b;
	}

	function _interrupt() {
	    // Only want to trigger callback when INT pin goes low,
	    // so use '_alarmFlag' to ensure callback isn't triggered
	    // when INT floats again (when AF set to 0)
	    if (_alarmFlag) _alarmCB();
	    _alarmFlag = false;
	}
}
