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


class PolicyRouting(unittest.TestCase):
    def test_two_modems_get_separate_tables(self):
        with tempfile.TemporaryDirectory() as d:
            for name, idx in (("wwan0", 7), ("wwan1", 9)):
                os.makedirs(f"{d}/class/net/{name}")
                with open(f"{d}/class/net/{name}/ifindex", "w") as f:
                    f.write(f"{idx}\n")
            old, m.SYSFS = m.SYSFS, d
            try:
                ta, tb = m.route_table("wwan0"), m.route_table("wwan1")
            finally:
                m.SYSFS = old
        self.assertEqual((ta, tb), (1007, 1009))
        a = m.policy_cmds("wwan0", "10.45.0.2", "10.45.0.1", ta)
        b = m.policy_cmds("wwan1", "10.45.0.3", "10.45.0.1", tb)
        self.assertEqual(a[0], ["ip", "route", "replace", "10.45.0.1/32", "dev", "wwan0", "src", "10.45.0.2", "table", "1007"])
        self.assertEqual(b[1], ["ip", "rule", "add", "from", "10.45.0.3/32", "lookup", "1009", "priority", "1009"])
        self.assertNotEqual(a[0][-1], b[0][-1])


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


class PolicyState(unittest.TestCase):
    """Cleanup from the recorded state, independent of the wwan interface still existing."""

    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.calls = []
        self._run, self._state, self._sysfs = m.subprocess.run, m.STATE_DIR, m.SYSFS
        m.STATE_DIR, m.SYSFS = f"{self.d.name}/state", f"{self.d.name}/sys"
        fake = type("R", (), {"returncode": 1, "stdout": "", "stderr": ""})  # "no more rules"
        m.subprocess.run = lambda cmd, **kw: (self.calls.append(cmd[2:] if cmd[:2] == ["sudo", "-n"] else cmd), fake)[1]

    def tearDown(self):
        m.subprocess.run, m.STATE_DIR, m.SYSFS = self._run, self._state, self._sysfs
        self.d.cleanup()

    def iface(self, name, idx):
        os.makedirs(f"{m.SYSFS}/class/net/{name}", exist_ok=True)
        with open(f"{m.SYSFS}/class/net/{name}/ifindex", "w") as f:
            f.write(f"{idx}\n")

    def test_down_with_interface_gone(self):
        m.write_state("c24c59be", {"serial": "c24c59be", "iface": "wwan1", "table": 1009, "ue": "10.45.0.3",
                                   "server": "10.45.0.1"})
        self.assertFalse(os.path.exists(f"{m.SYSFS}/class/net/wwan1"))  # interface gone
        st = m.drop_recorded("c24c59be")
        self.assertEqual(st["table"], 1009)
        self.assertIn(["ip", "rule", "del", "from", "10.45.0.3/32", "lookup", "1009"], self.calls)
        self.assertIn(["ip", "rule", "del", "lookup", "1009"], self.calls)
        self.assertIn(["ip", "route", "flush", "table", "1009"], self.calls)
        self.assertIsNone(m.read_state("c24c59be"))
        self.assertIsNone(m.drop_recorded("c24c59be"))  # idempotent

    def test_reenumeration_clears_old_table(self):
        # first attach as wwan1 (ifindex 9): recorded table 1009
        m.write_state("c24c59be", {"serial": "c24c59be", "iface": "wwan1", "table": 1009, "ue": "10.45.0.3",
                                   "server": "10.45.0.1"})
        # modem re-enumerates as wwan2 (ifindex 12): up must drop 1009 before installing 1012
        self.iface("wwan2", 12)
        new = m.route_table("wwan2")
        old = m.drop_recorded("c24c59be")
        m.policy_down(new)
        self.assertEqual((old["table"], new), (1009, 1012))
        flushed = [c[-1] for c in self.calls if c[:3] == ["ip", "route", "flush"]]
        self.assertEqual(flushed, ["1009", "1012"])
        self.assertIn(["ip", "rule", "del", "from", "10.45.0.3/32", "lookup", "1009"], self.calls)
        m.write_state("c24c59be", {"serial": "c24c59be", "iface": "wwan2", "table": new, "ue": "10.45.0.4",
                                   "server": "10.45.0.1"})
        self.assertEqual(m.read_state("c24c59be")["table"], 1012)

    def test_down_modem_unplugged(self):
        import argparse, contextlib, io
        m.write_state("c24c59be", {"serial": "c24c59be", "iface": "wwan1", "table": 1009, "ue": "10.45.0.3"})
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as e:
            m.down(argparse.Namespace(serial="c24c59be"))
        self.assertIn("AT+CFUN=4 NOT sent", str(e.exception))
        self.assertIn(["ip", "route", "flush", "table", "1009"], self.calls)
        self.assertIsNone(m.read_state("c24c59be"))

    def test_two_modems_keep_separate_state(self):
        m.write_state("aaaaaaaa", {"serial": "aaaaaaaa", "iface": "wwan0", "table": 1007, "ue": "10.45.0.2"})
        m.write_state("c24c59be", {"serial": "c24c59be", "iface": "wwan1", "table": 1009, "ue": "10.45.0.3"})
        m.drop_recorded("aaaaaaaa")
        self.assertIsNone(m.read_state("aaaaaaaa"))
        self.assertEqual(m.read_state("c24c59be")["table"], 1009)
        self.assertNotIn(["ip", "route", "flush", "table", "1009"], self.calls)


if __name__ == "__main__":
    unittest.main()
