# OPENRU_TRACE — compute-time slot probes

Off by default. Set `OPENRU_TRACE=/path/to/trace.csv` in the ProtO-RU container environment to enable.

## CSV columns

`unix_ns,sfn,slot,stage,label`

## Stages (compute path only — not a fronthaul delay profile)

| stage | Where |
| --- | --- |
| `uplane_rx` | DL U-plane message accepted (`ofh_ru_rx_uplane_data_flow.cpp`) |
| `decompress_done` | After BFP/IQ decompress in the same decode |
| `ifft_done` | After OFDM slot modulate (iFFT + CP) (`ofdm_modulator_impl.cpp`) |
| `radio_handoff` | Grid handed to radio (`ru_emulator_sdr_upper_phy.cpp`) |

Header: `include/ocudu/support/openru_trace.h`.
