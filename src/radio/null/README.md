# Null radio backend

Implementation lives in the ProtO-RU fork at `external/proto-ru/lib/radio/null/`
(`device_driver: null`) so it shares the same `radio_factory` / low-PHY path as UHD.

Select with:

```yaml
sdr:
  device_driver: null
  device_args: "tx_dump=/tmp/iq_dump,rx_feed="
```

TX buffers are written as interleaved float32 IQ (`.cf32`) per antenna port plus
`iq_meta.json`. RX is fed from matching files or zeros.

Emulator mode (no `sdr:` block) remains **M0 fronthaul smoke only** and does not
produce golden IQ.
