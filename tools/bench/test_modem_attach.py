import os
import tempfile
import unittest

import modem_attach as m


class Allowlist(unittest.TestCase):
    def test_allowed(self):
        for c in ("AT", "AT+CFUN=1", "AT+CFUN=4", "AT+CFUN?", "AT+C5GREG?", "AT+QIACT=1", "AT+CGPADDR=1",
                  'AT+QENG="servingcell"', "AT+QRSRP", 'AT+QPING=1,"10.45.0.1",4,4'):
            self.assertTrue(m.allowed(c), c)

    def test_refused(self):
        for c in ("AT+CFUN=1,1", 'AT+QCFG="usbnet",1', "AT+CRSM=214,28539", "AT+QNWLOCK", "AT+CFUN=1;+QIACT=1",
                  'AT+QPING=1,"x;rm",4,4', "AT+CLCK"):
            self.assertFalse(m.allowed(c), c)
        with self.assertRaises(ValueError):
            m.at("/dev/null", 'AT+QCFG="usbnet",1')

    def test_registered(self):
        self.assertTrue(m.registered("+C5GREG: 0,1 OK"))
        self.assertTrue(m.registered("+C5GREG: 2,5,\"7\" OK"))
        self.assertFalse(m.registered("+C5GREG: 0,2 OK"))
        self.assertFalse(m.registered("+C5GREG: 0,0 OK"))


class QmiDiscovery(unittest.TestCase):
    def test_same_usb_device(self):
        with tempfile.TemporaryDirectory() as d:
            mk = lambda p: os.makedirs(os.path.join(d, p), exist_ok=True)
            # Real RM520N layout on the bench (2026-11-20): class/tty/ttyUSBn/device -> .../2-1.4:1.2/ttyUSBn
            # (usb-serial port level), class/usbmisc/cdc-wdmN/device -> .../2-1.4:1.4 with net/wwanN.
            for usb, tty, wdm, net in (("2-1.4", "ttyUSB2", "cdc-wdm3", "wwan1"), ("1-5", "ttyUSB6", "cdc-wdm0", "wwan0")):
                mk(f"devices/{usb}/{usb}:1.2/{tty}"); mk(f"devices/{usb}/{usb}:1.4/net/{net}")
                mk("class/tty/" + tty); mk("class/usbmisc/" + wdm)
                os.symlink(os.path.join(d, f"devices/{usb}/{usb}:1.2/{tty}"), os.path.join(d, "class/tty", tty, "device"))
                os.symlink(os.path.join(d, f"devices/{usb}/{usb}:1.4"), os.path.join(d, "class/usbmisc", wdm, "device"))
            os.makedirs(os.path.join(d, "dev"))
            link = os.path.join(d, "dev/by-id-A")
            os.symlink("/dev/ttyUSB2", link)
            self.assertEqual(m.qmi_for(link, sysfs=d), ("/dev/cdc-wdm3", "wwan1"))
            link_b = os.path.join(d, "dev/by-id-B")
            os.symlink("/dev/ttyUSB6", link_b)
            self.assertEqual(m.qmi_for(link_b, sysfs=d), ("/dev/cdc-wdm0", "wwan0"))

    def test_usb_device_levels(self):
        self.assertEqual(m.usb_device("/sys/devices/x/usb2/2-1/2-1.4/2-1.4:1.2/ttyUSB4"), "2-1.4")
        self.assertEqual(m.usb_device("/sys/devices/x/usb2/2-1/2-1.4/2-1.4:1.4"), "2-1.4")
        self.assertIsNone(m.usb_device("/sys/devices/virtual/tty/tty0"))

    def test_bad_serial(self):
        with self.assertRaises(SystemExit):
            m.at_port("../../etc")


if __name__ == "__main__":
    unittest.main()
