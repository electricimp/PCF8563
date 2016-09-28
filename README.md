# PCF8563

This class provides a hardware driver for the [NXP PCF8563 real time clock (RTC)](http://www.nxp.com/products/interface-and-connectivity/interface-and-system-management/i2c-bus-portfolio/i2c-real-time-clocks-rtc/real-time-clock-calendar:PCF8563).

This RTC and calendar is optimized for low power consumption. It communicates with the host imp via I&sup2;C at a speed of up to 400Kbps.

This code is currently in development and therefore not yet implemented as an Electric Imp Library. If you wish to try the code in the meantime, please copy the `pcf8563.class.nut` file into your device code.

## Class Usage

### Constructor: PCF8563(*impi2cBus, i2cAddr[, debug]*)

The constructor takes two required parameters: a configured imp I&up2;c bus and the PCF8563’s 8-bit I&sup2;C address (default: 0xA2).

The third parameter is optional: pass in `true` to get extra debugging information in the log (default: `false`).

```squirrel
hardware.i2c89.configure(CLOCK_SPEED_400_KHZ);
rtc <- PCF8563(hardware.i2c89, 0xA2, true);
```

## Class Methods

### sync()

This method sets the PCF8563 to the date and time provided by the imp’s own RTC, which is itself synchronized with the impCloud&trade; when the device connects.

```squirrel
// Sync the PCF8563 and imp RTC
rtc.sync();
```

### getDateAndTime()

This method returns the current date and time provided by the PCF8563. The data is returned as a table with the following keys:

| Key   | Description | Value Range |
| ----- | ---- | ---- |
| *sec*   | Seconds after the minute | 0-59 |
| *min*   | Minutes after the hour | 0-59 |
| *hour*  | Hours since midnight | 0-23 |
| *day*   | Day of the month | 1-31 |
| *month* | Month | 0-11; January = 0 |
| *year*  | The year | 2000-2099 |
| *wday*  | Day of the week | 0-6; Sunday = 0 |

Note that the PCF8563 stores months in the calendar fashion (ie. January = 1, Febraury = 2, etc). Because Squirrel’s *date()* function zero-indexes month values (ie. January = 0, Febraury = 1, etc) the PCF8563 class does the same and modifies the stored/retrieved value automatically.

Additionally, the PCF8563 stores yeas in the form 00-99 whereas *date()* returns the actual year (eg. 2016). Again, the class adapts the hardware value to match the Squirrel function.

### setDateAndTime(*day, month, year, wday, hour, min, sec*)

This method can be used to set the PCF8563 explicitly, should you make use of an alternative source to the imp’s own RTC, or to set the PCF8563 to begin timing from an arbitrary date and time. Again, the parameters match those used by Squirrel’s *date()* function *(see above)*.

### isClockGood()

This method returns a boolean value indicating whether or not the clock’s integrity has been maintained. The value is set by reading the PCF8563’s low-voltage register, which is set when its VDD pin falls below a critical value. This can be used in cases where the RTC is backed up by a cell battery. If host imp powers down, this function can be checked on waking to issue a warning that the back-up battery needs replacing. Under normal imp operating, when the PCF8563 is not running off battery, the low-voltage register will not be set.

The low-voltage register remains set until manually cleared, which can be achieved by calling *clearLV()*.

```squirrel
local integrity = rtc.isClockGood();
local s = "Clock integrity " + (integrity ? "good" : "bad");
server.log(s);

if (!integrity) {
    // Reset clock low-voltage register after warning
    rtc.clearLV();
}
```

### clearLV()

This method clears the PCF8563’s low-voltage register following a low-voltage warning. See *isClockGood()*, above, for an example of *clearLV()*’s use.

## License

The PCF8563 library is copyright 2014-16, Electric Imp, Inc. and licensed under the [MIT License](https://github.com/electricimp/PCF8563/blob/master/LICENSE).
