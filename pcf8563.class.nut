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
    _alarm = null;
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

    function isClockGood() {
        // The first bit of the VL_SEC_REG is a Voltage Low flag (VL)
        // If this flag is set, the internal voltage detector has detected a
        // low-voltage event and the clock integrity is not guaranteed.
        // The flag remains set until it is manually cleared.
        // This is provided because the RTC is often run on a battery
        if (0x80 & _readReg(VL_SEC_REG)) return false;
        return true;
    }

    function clearLV() {
        // Clear the Voltage Low flag.
        local data = 0x7F & _readReg(VL_SEC_REG);
        _writeReg(VL_SEC_REG, data);
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

        if (_alarmPin == _getWakepin()) {
            // User has selected the wakeup pin
            _alarmPin.configure(DIGITAL_IN_WAKEUP, _interrupt.bindenv(this));
        } else {
            _alarmPin.configure(DIGITAL_IN, _interrupt.bindenv(this));
        }

        _alarm = [-1, -1, -1, -1];
    }

    function setAlarm(time) {
        local ps = ["min", "hour", "day", "wday"];
        local ad = [0x7F, 0x3F, 0x3F, 0x03];
        local ast = blob();

        foreach (i, pa in ps) {
            if (pa in time && time[pa] != null) {
                // Set the alarm component
                local t = _integerToBCD(time[pa] & ad[i]);

                // Set bit 7 to enable the alarm
                t = t + 0x80;
                ast.writen(t, 'b');
               _alarm[i] = t;
            } else {
                // Clear bit 7 to disable the alarm
                if (_alarm[i] != -1) {
                    local t = _alarm[i] & 0x7F;
                    ast.writen(t, 'b');
                    _alarm[i] = t;
                } else {
                    ast.writen(0, 'b');
                }
            }
        }

        local err = _writeAlarm(ast);
         if (_debug && err == 0) server.log("Alarm set");
         if (_debug) server.log(_alarm[0] + " : " + _alarm[1] + " : " + _alarm[2] + " : " + _alarm[3]);
    }

    function clearAlarm() {
        local ast = "\x00\x00\x00\x00";
        local err = _writeAlarm(ast);
        if (_debug && err == 0) server.log("Alarm cleared");
        _alarm = [-1, -1, -1, -1];
    }

    function unsetAlarm() {
        local ast = blob();
        foreach (i, c in _alarm) {
            if (c != -1) {
                c = c & 0x7F;
                _alarm[i] = c;
                ast.write(c, 'b');
            } else {
                ast.write(0, 'b');
            }
        }

        local err = _writeAlarm(ast);
        if (_debug && err == 0) server.log("Alarm cleared");
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

    function _writeReg(register, byte) {
        // Write data 'byte' to the specified register
        local err = _i2c.write(_addr, format("%c%c", register, byte));
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

    function _writeAlarm(aTime) {
        local err = _i2c.write(_addr, format("%c", MINS_ALARM_REG) + aTime.tostring());
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
	    if (_debug) server.log("Alarm!");
	    _alarmCB();
	}

	function _getWakepin() {
	    // imp001/2
	    if ("pin1" in hardware) return hardware.pin1;
	    return hardware.pinW;
	}
}
