# Low-PHY Architecture Map: ProtO-RU (O-RU, split 7.2)

Status: working draft, code-derived. Read-only analysis of
`external/proto-ru` on branch `feat/null-radio`, submodule HEAD
`5277e051b5c566652f6f3d02ef85d806b36aee2b`
("feat(radio): null radio realtime pace, async TX dump, clock only on RX").
No builds, containers, GPUs or radios were used.

The submodule had two uncommitted files when read:
`lib/radio/null/radio_null_session.h` and
`lib/radio/null/radio_null_session.cpp`. The null-radio description below
reflects that working tree; it is `[UNVERIFIED]` against the clean commit.

Evidence convention (per `docs/BRIEF_PHASE1.md`): every statement below is
`[DERIVED]` from the cited source unless it carries another tag.
`[UNVERIFIED]` marks behavior that could not be confirmed from the checked-out
tree (for example because the submodule has uncommitted local changes).

Traceability caveat: the submodule working tree was dirty while this map was
written. Line numbers are valid for the working tree at the time of reading,
not necessarily for a clean `git checkout` of `feat/null-radio`.

---

## 1. What this document maps

ProtO-RU implements the O-RU side of O-RAN split 7.2: it receives downlink
User-Plane and Control-Plane Ethernet/eCPRI frames from an O-DU, turns them
into baseband IQ, and drives a radio; on the uplink it receives baseband IQ
from the radio, demodulates it into a resource grid and/or PRACH buffer, and
sends User-Plane replies back over Ethernet.

The map covers two complete paths:

- **Downlink (DL):** fronthaul wire -> resource grid -> OFDM modulation ->
  baseband gateway -> radio.
- **Uplink (UL):** radio -> baseband gateway -> per-symbol demux ->
  PUxCH/PRACH -> resource grid / PRACH buffer -> U-plane encode ->
  fronthaul wire.

It also records the data types and memory layouts, the thread/executor
boundaries, the per-symbol versus per-slot granularity, and the parts that are
natural candidates for a CUDA replacement.

The pipeline architecture in one line:

```
O-DU --Ethernet/eCPRI--> [ru_message_receiver] -> C-plane -> scheduling handler
                                             \-> U-plane -> grid repo (cbf16)
                                                              |
                                              [ru_emulator_sdr_upper_phy]
                                                              |
                                        [ru_sdr] -> lower_phy -> PDxCH/OFDM
                                                              |
                                                        baseband gateway
                                                              |
                                                            radio

radio -> baseband gateway -> lower_phy uplink processor (per symbol)
      -> PUxCH demod -> resource grid     -> ru_uplink_iq_sink
      -> PRACH proc  -> PRACH buffer      -> ru_uplink_iq_sink
                                              |
                                   [ru_uplink_symbol_responder]
                                              |
                                   data_flow_uplane_data (BFP + OFH)
                                              |
                                          Ethernet TX
```

---

## 2. Composition and entry points

### 2.1 Application-level assembly

The example application builds one sector per RU emulator instance:

- Ethernet TX/RX pair: `apps/examples/ofh/ru_emulator.cpp:438-441`.
- Upper PHY choice: SDR mode uses `ru_emulator_sdr_upper_phy`; otherwise the
  loopback/test-IQ `ru_emulator_upper_phy` is used
  (`apps/examples/ofh/ru_emulator.cpp:443-454`).
- OFH sector: `create_ru_sector(sec_cfg, sec_deps)` with
  `sec_deps.upper_phy = upper_phy.get()` and
  `sec_deps.uplink_encode_executor = &ofh_tx_executor`
  (`apps/examples/ofh/ru_emulator.cpp:456-461`).
- SDR-only objects: radio, TTI orchestrator, GPS slot aligner and received
  symbol adapter (`apps/examples/ofh/ru_emulator.cpp:463-523`). The uplink IQ
  sink is obtained from the sector at `:470`, wrapped by
  `ru_emulator_rx_symbol_adapter` at `:473`, and the radio is created at
  `:516`. Completed DL grids are connected to the radio at `:522`.

The sector configuration is built at `apps/examples/ofh/ru_emulator.cpp:380-404`:

- `ul_eaxc`, `prach_eaxc`, `mtu_size = ETHERNET_FRAME_SIZE`,
  `nof_frames_per_symbol = 2`.
- `tx_window_start_symbols = timing.sym_up_ul_start`,
  `tx_window_end_symbols = timing.sym_up_ul_end` (Ta3 window).
- `rx_window = {sym_up_dl_end, sym_up_dl_start}`.
- `uplink_response_mode = store_and_respond` in SDR mode, `immediate` in
  loopback mode (`:392-395`).
- `dl_finalize_lead_symbols` is a local value,
  `(nof_slots_per_subframe(scs) + 1) * nsym_per_slot`; it is assigned to
  `dl_grid_finalize_offset_symbols` as `-dl_finalize_lead_symbols` in SDR mode,
  or `+nsym_per_slot` in loopback mode (`:396-405`).

### 2.2 SDR RU composition

`ru_sdr_impl` holds the radio-facing pipeline:

- Dependencies: `rx_symbol_handler`, `timing_handler`, `logger`,
  `radio_logger`, `error_notifier`
  (`lib/ru/sdr/ru_sdr_impl.h:30-36`).
- Constructor wires `error_adapter`, `rx_adapter`, `timing_adapter`,
  `radio_unit_controller`, `ru_downlink_hdlr`,
  `ru_uplink_request_hdlr` (`lib/ru/sdr/ru_sdr_impl.cpp:9-22`).
- `set_lower_phy_sectors` registers the lower-PHY sector facade
  (`lib/ru/sdr/ru_sdr_impl.cpp:24-40`).

`ru_lower_phy_downlink_handler_impl::handle_dl_data` forwards a completed grid
to the sector's `handle_resource_grid` (`lib/ru/sdr/ru_lower_phy_downlink_handler_impl.cpp:11-17`).
`ru_lower_phy_uplink_request_handler_impl::handle_prach_occasion` forwards to
the per-sector handler (`lib/ru/sdr/ru_lower_phy_uplink_request_handler_impl.cpp:13-17`).

The lower-PHY facade exposes the individual controls
(`lib/ru/sdr/lower_phy/lower_phy_sector.cpp:9-46`): uplink/downlink request
handlers, controller, Tx/Rx CFO, Tx/Rx center frequency, and Tx time offset.

---

## 3. Execution model and timing

### 3.1 Executors and threads

Each emulator instance gets a receive executor and a worker executor:

- `ru_rx_#i`: lock-free SPSC queue depth 2, 1 us, RT priority max-1, pinned to
  `ofh_cpus` (`apps/examples/ofh/ru_emulator.cpp:559-573`).
- `ru_emu_#i`: lock-free SPSC queue depth `task_worker_queue_size` (1024),
  1 us, RT max-1, pinned to `ofh_cpus`
  (`apps/examples/ofh/ru_emulator.cpp:575-588`).
- `ru_ofh_tx_#i`: lock-free MPMC queue for decoupled UL User-Plane build and
  compression, 10 us, pinned to `ofh_cpus`
  (`apps/examples/ofh/ru_emulator.cpp:590-604`).
- SDR mode adds radio and baseband workers via `create_sdr_executors`
  (`apps/examples/ofh/ru_emulator.cpp:606-609`).
- A shared `ru_timing` executor with SPSC depth 4, 1 us, RT max exists at
  `apps/examples/ofh/ru_emulator.cpp:612-620`.

The SDR sector executor mapper exposes separate executors per role
`{dl, ul, prach, tx, rx}` (`lib/ru/sdr/ru_sdr_executor_mapper.cpp:13-38`).
They are wired into the lower PHY in `ru_emulator.cpp:507-514`:
`rx_task_executor`, `tx_task_executor`, `dl_task_executor`,
`ul_task_executor`, `prach_async_executor`.

### 3.2 Baseband pull/push loop

`lower_phy_baseband_processor` owns the sample-clock loop
(`lib/phy/lower/lower_phy_baseband_processor.cpp`):

- Constructor computes
  `nof_samples_in_all_hyper_frames = srate.to_kHz() * NOF_HYPER_SFNS * NOF_SFNS * NOF_SUBFRAMES_PER_FRAME`
  and `slot_duration = 1000 / 2^numerology`
  (`:12-30`). It preallocates `nof_rx_buffers` dynamic gateway buffers at
  `:42-45`.
- `start()` defers the first uplink and downlink tasks
  (`:48-60`).
- `dl_process(timestamp)` waits until the receive clock is close enough,
  applies optional system-time throttling, calls
  `downlink_processor.process(apply_timestamp_sfn0_ref(timestamp))`,
  sets `result.metadata.ts = timestamp + tx_time_offset`, and transmits
  (`:70-137`).
- `ul_process()` pops an RX buffer, calls `receiver.receive`, updates
  `last_rx_timestamp`, and defers UL processing to `uplink_executor`
  (`:139-173`).

The DL timestamp offset and max delay are computed in the factory:
`tx_time_offset = get_tx_time_offset(...)` and
`rx_to_tx_max_delay = srate.to_kHz() + tx_time_offset`
(`lib/phy/lower/lower_phy_factory.cpp:96-100`). The baseband processor uses
that delay to bound how far TX may run ahead of RX (`:89-93`).

### 3.3 Granularity

- **Fronthaul control:** per slot and per eAxC request (`resource_request_pool`
  is indexed by slot; see `lib/phy/lower/processors/resource_request_pool.h:14-39`).
- **Fronthaul data:** one OFH section per symbol, possibly fragmented by PRB
  count (`lib/ofh/transmitter/ofh_data_flow_uplane_data_impl.cpp:195-263`).
- **Resource grid:** one grid per slot, dimensions
  `(nof_subc, nof_symbols, nof_ports)`.
- **Modulation/demodulation:** one DFT per symbol per port
  (`lib/phy/lower/modulation/ofdm_modulator_impl.cpp:39-90`,
  `lib/phy/lower/modulation/ofdm_demodulator_impl.cpp:77-129`).
- **Baseband gateway:** the radio chooses the buffer size. The lower PHY can
  request `slot`, `half_slot`, `single_packet` or `optimal_slot`
  (`lib/phy/lower/lower_phy_factory.cpp:79-94`). TX output is therefore a
  variable-length run of samples with a timestamp, not necessarily one slot.
- **OFH transmit window:** per symbol, gated by `[T - Ta3_max, T - Ta3_min]`
  (`lib/ofh/ru/ofh_ru_message_transmitter.cpp:29-35`).

---

## 4. Data types and memory layout

### 4.1 Complex sample types

`include/ocudu/adt/complex.h:22-44`:

- `cf_t = std::complex<float>` (8 bytes, 4-byte aligned).
- `ci8_t = std::complex<int8_t>` (2 bytes).
- `ci16_t = std::complex<int16_t>` (4 bytes).
- `cbf16_t { bf16_t real; bf16_t imag; }` (4 bytes). `bf16_t` is a
  `strong_type<uint16_t>` (`include/ocudu/adt/bf16.h:13-17`), so the pair is
  two 16-bit words with no padding.
- `cbf16_t` is explicitly "meant for storage purposes only, no operations
  other than equality comparison are allowed" (`include/ocudu/adt/complex.h:29-30`),
  but in practice conversion helpers materialize `cf_t` for DSP.

### 4.2 Resource grid

`resource_grid_impl` stores a dynamic 3-D tensor
(`lib/phy/support/resource_grid_impl.h:28-32`):

```
dynamic_tensor<resource_grid_dimensions::all, cbf16_t, resource_grid_dimensions>
```

with dimension order **subcarrier -> symbol -> port**
(`resource_grid_dimensions.h`: `subc = 0`, `symbol = 1`, `port = 2`,
`all = 3`). Element type is `cbf16_t`; therefore the grid is a dense
`nof_subc * nof_symbols * nof_ports` array of 4-byte complex BF16.

The grid exposes a reader (`resource_grid_reader_impl`) and a writer
(`resource_grid_writer_impl`). The writer API used in the DSP path is
`put(port, symbol, k_init, symbols)` (`lib/phy/support/resource_grid_writer_impl.h:13-39`).

### 4.3 Baseband gateway buffers

`baseband_gateway_buffer_dynamic` is a tensor with dimensions
**sample -> channel** and element `ci16_t`
(`include/ocudu/gateways/baseband/buffer/baseband_gateway_buffer_dynamic.h:15-26`).
It is the host-side radio interface. The corresponding reader/writer views
(`baseband_gateway_buffer_reader`, `_writer`) are used by the lower PHY.

### 4.4 PRACH buffer

`prach_buffer` stores **frequency-domain** PRACH sequences, not time-domain
samples. It exposes `get_symbol(port, td_occasion, fd_occasion, symbol)`
returning `span<cbf16_t>` (`include/ocudu/phy/support/prach_buffer.h:12-58`).
Long preambles use `L_RA = 839` with up to 4 symbols; short preambles use
`L_RA = 129` with up to 12 symbols (`:16-18`). The lower-PHY PRACH worker
collects time-domain `ci16_t` samples into `temp_baseband` and demodulates into
this buffer (`lib/phy/lower/processors/uplink/prach/prach_processor_worker.h:63-78`).

### 4.5 OFH frame pool

Uplink User-Plane frames are rented from `ether::frame_pool`. A `frame_buffer`
has a state `{free, reserved, pending}`
(`include/ocudu/ofh/ethernet/ethernet_frame_pool.h:25-45`). Each slot+symbol
maps to one or more frames, and the transmitter drains the pool by a symbol
interval. The pool decouples "build/compress" from "put on the wire".

---

## 5. Downlink path: wire -> resource grid -> radio

### 5.1 Ethernet/eCPRI receive and dispatch

`ru_message_receiver::process_frame` is the single frame entry:

- Pads short frames to 64 bytes before the eCPRI decoder
  (`lib/ofh/ru/ofh_ru_message_receiver.cpp:43-52`).
- Decodes Ethernet/VLAN (`:54-58`) and eCPRI (`:60-64`).
- Optionally updates RX window statistics from the U-plane slot peeker
  (`:66-72`).
- On eCPRI IQ data (`message_type::iq_data`): validates the eAxC against the
  configured DL eAxC list, checks sequence ID, then calls
  `uplane_handler.decode_message(pc_id, ofh_pdu)` (`:74-96`).
- On real-time control data (`rt_control_data`): determines direction from the
  MSB of the OFH radio header, checks the direction-specific sequence counter,
  then calls `cplane_handler.decode_message(rtc_id, ofh_pdu)` (`:98-115`).

The direction-specific debug logs are at `:100-113`.

### 5.2 C-plane -> schedule and allocate a grid

`ru_rx_cplane_data_flow::decode_message` decodes the C-plane and calls
`notifier.on_cplane_message_received(eaxc, results)`
(`lib/ofh/receiver/ofh_ru_rx_cplane_data_flow.cpp:17-25`).

`ru_cplane_scheduling_dispatcher::on_cplane_message_received` dispatches by
section type and direction (`lib/ofh/receiver/ofh_ru_cplane_scheduling_dispatcher.cpp:20-49`):

- PRACH section type 3 -> `ul_handler.handle_prach_scheduling`
  (`:23-31`).
- Uplink direction -> `ul_handler.handle_uplink_scheduling`
  (`:33-41`).
- Otherwise (downlink) -> `dl_handler.handle_downlink_scheduling`
  (`:43-48`).

`ul_handler` is mode-dependent
(`lib/ofh/ru/ofh_ru_sector.cpp:141-165`):

- In `immediate` mode it is `ru_cplane_scheduling_handler`, which answers
  uplink/PRACH from the upper PHY's transmit grid/buffer.
- In `store_and_respond` mode (SDR) it is
  `ru_uplink_scheduling_recorder`, which only records the request into
  `ru_uplink_request_repository` (`lib/ofh/ru/ofh_ru_uplink_scheduling_recorder.cpp:41-86`);
  the reply is built later from captured radio IQ.

The DL handler is always `ru_cplane_scheduling_handler`
(`lib/ofh/ru/ofh_ru_cplane_scheduling_handler.cpp:11-35`). Its constructor
holds the upper PHY, grid repository, uplink data flow, PRACH data flow and
sector ID. `handle_downlink_scheduling` reuses an existing grid for the slot
via `grid_repo->find_grid(slot)` and only asks the upper PHY for a new one if
none exists (`:34-42`); it then registers the context with
`grid_repo->add(context, grid, symbol_range, logger)` (`:49-52`). Reusing the
slot grid is what allows one C-plane command per eAxC to fill different ports
of the same grid.

### 5.3 U-plane -> grid

`ru_rx_uplane_data_flow::decode_message` decodes the U-plane and calls
`rx_symbol_writer.write_to_resource_grid(eaxc, results)`
(`lib/ofh/receiver/ofh_ru_rx_uplane_data_flow.cpp:20-30`).

`uplane_message_decoder_impl::decode` parses the 4-byte U-plane header
(`lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp:22-37`), validates
direction/payload version/filter index/symbol range (`:39-84`), then for each
section decodes IQ data (`:339-355`):

- `prb_iq_data_size_bits = 12 * 2 * data_width`, plus 8 bits for the
  compression parameter when present (`:343-348`).
- Advances the deserializer by
  `nof_prbs * prb_iq_data_size_bits.round_up_to_bytes()` (`:349-351`).
- Resizes `results.iq_samples` to `nof_prbs * 12` and calls
  `decompressor->decompress(...)` (`:352-355`).

The destination grid is looked up by slot+symbol from `rx_grid_context` in
`ofh_uplane_rx_symbol_data_flow_writer`
(`lib/ofh/receiver/ofh_uplane_rx_symbol_data_flow_writer.cpp:12-35`,
lookup at `:17-30`). The repository is `rx_grid_context_repository`:

- `process_pending_contexts()` drains queued context additions
  (`lib/ofh/support/rx_grid_context_repository.h:200-207`).
- `find_grid(slot)` scans symbols for a matching grid and returns a copy
  (`:209-222`).
- `write_grid(slot, port, symbol, start_re, iq)` locks and writes
  (`:224-229`).
- `try_popping_complete_resource_grid_symbol(slot, symbol)` returns and clears
  a symbol grid only when all PRBs/ports are present (`:238-253`).
- `pop_resource_grid_symbol(...)` unconditionally pops and clears (`:255-271`).

The context object is
`rx_grid_context { resource_grid_context context, shared_resource_grid grid }`
(`lib/ofh/support/rx_grid_context_repository.h:27-47` region).

### 5.4 Finalize and hand to the radio

`ru_downlink_rx_window_handler::on_new_symbol`
(`lib/ofh/ru/ofh_ru_downlink_rx_window_handler.cpp:9-33`):

1. Calls `grid_repo->process_pending_contexts()`.
2. Finalizes the grid at
   `symbol_point - finalize_offset_symbols`, where the configured offset is
   propagated from the sector's `dl_grid_finalize_offset_symbols`
   (`lib/ofh/ru/ofh_ru_sector.cpp:214`) into
   `ru_downlink_rx_window_handler_config::finalize_offset_symbols`
   (`lib/ofh/ru/ofh_ru_downlink_rx_window_handler.h:15-26`).

In SDR mode the upper PHY is `ru_emulator_sdr_upper_phy`:

- It allocates a grid from its own pool and zeroes it if non-empty
  (`apps/examples/ofh/ru_emulator_sdr_upper_phy.cpp:33-40`).
- `on_downlink_rx_grid_completed` de-duplicates completion notifications so the
  whole-slot grid is pushed once (`:42-51`).
- It drops the grid if the radio handler is not connected or the GPS offset is
  not established (`:53-59`).
- It translates the wire (GPS) slot to radio slot numbering using the GPS
  offset and the current radio slot (`:61-72`), builds a
  `resource_grid_context` and calls `handler->handle_dl_data(context, grid)`
  (`:74-78`).
- Pool size is 16 grids, each `(nof_dl_ports, nsymb, nof_prb*12)`
  (`:21-22`, `:92-99`).

The documented contract is that pushing happens at the reception-window
finalize point, ahead of the lower PHY baseband pull, so the deadline is the
slot's air time minus one millisecond
(`apps/examples/ofh/ru_emulator_sdr_upper_phy.h:29-38`).

### 5.5 Lower-PHY request path

`processor_handler_adaptor::handle_resource_grid` calls
`pdxch_handler.handle_request(grid, context)`
(`lib/phy/lower/processors/adaptors/processor_handler_adaptor.cpp:10-28`).

`pdxch_processor_impl::handle_request`:

- Ignores stopped processor (`lib/phy/lower/processors/downlink/pdxch/pdxch_processor_impl.cpp:33-36`).
- Asserts a notifier is connected (`:38`).
- Ignores an empty grid (`:40-43`).
- Gets a baseband buffer from `bb_buffers` (`:45-50`); on exhaustion logs
  "Insufficient number of buffers." and drops the request.
- Calls the per-slot modulator `handle_request(buffer, grid, context)`
  (`:52-53`).
- On modulator busy, logs and emits a critical trace event (`:55-60`).

`pdxch_baseband_modulator::handle_request`
(`lib/phy/lower/processors/downlink/pdxch/pdxch_baseband_modulator.h:100-194`):

- Rejects a null buffer (`:103-106`); port count must match (`:108-109`).
- Uses an atomic state `idle -> modulate_mask + symbols*ports` so only one
  transmission is in flight (`:111-116`).
- Copies the context and grid, moves the buffer into `current_result`
  (`:118-121`).
- Computes symbol indices and slot sample count, then resizes the buffer to
  the slot length (`:123-132`).
- Defers one task per (symbol, port) (`:137-174`), each task:
  - takes a `ci16_t` view of the output at the symbol offset and a `cf_t`
    scratch view (`:147-150`),
  - calls `modulator.modulate(cf_buf, grid_reader, port, symbol_index)`
    (`:155-156`),
  - applies amplitude control (`:158-159`),
  - computes average power, peak and clipping metrics (`:161-165`),
  - converts `cf_t -> ci16_t` into the output (`:167-168`),
  - completes the task (`:172-173`).
- If task submission fails, zeroes that symbol/port region and still completes
  (`:176-185`).

Failure to submit all tasks is therefore contained per symbol/port; the
buffer remains valid and is zeroed where modulation did not run.

### 5.6 OFDM modulation kernel

`ofdm_symbol_modulator_impl::modulate`
(`lib/phy/lower/modulation/ofdm_modulator_impl.cpp:39-90`):

- Input grid is `cbf16_t`; the DFT input/output is `cf_t` (`:73-80`).
- Copies lower half of the grid into `dft_input.last(rg_size/2)` and upper half
  into `dft_input.first(rg_size/2)` (`:73-77`). This is the standard
  DC-centered mapping: the grid spans `[-rg_size/2, +rg_size/2)`.
- Runs the DFT (`:79-80`).
- Applies per-symbol phase compensation and scale
  (`:82-86`).
- Copies the cyclic prefix from the tail of the symbol (`:88-89`).
- If the grid is empty for the port, zeroes the whole output and returns
  (`:67-71`).

Constructor invariants: `dft_size > rg_size`, `rg_size = bw_rb * 12`, and the
DFT input is zeroed (`lib/phy/lower/modulation/ofdm_modulator_impl.cpp:14-37`).

`downlink_processor_baseband_impl` then assembles the symbol stream into
slot-aligned gateway buffers:

- Computes the subframe/symbol position from the sample timestamp
  (`lib/phy/lower/processors/downlink/downlink_processor_baseband_impl.cpp:89-124`).
- Notifies the TTI boundary when the slot changes and calls
  `pdxch_proc_baseband.process_slot(...)`
  (`:126-142`).
- Applies CFO to the whole slot buffer by converting `ci16_t -> cf_t`,
  processing, then converting back (`:144-158`).
- If the next sample is not slot-aligned or no PDxCH buffer exists, returns a
  zero/partially filled buffer trimmed to the next slot boundary
  (`:165-188`).
- Otherwise returns the PDxCH slot buffer directly (`:190-192`).

The per-slot PDxCH request buffer is produced asynchronously by
`pdxch_baseband_modulator`; `process_slot` exchanges the stored request with
an empty one and reports late/mismatched slots
(`lib/phy/lower/processors/downlink/pdxch/pdxch_processor_impl.cpp:63-102`).

### 5.7 DL summary

```
frame -> eth/ecpri decode -> [C-plane: allocate grid] -> [U-plane: decompress + write grid]
      -> finalize (ahead of air) -> handle_dl_data -> PDxCH request
      -> per (symbol, port): grid[port,symbol,:] -> iFFT -> CP -> scale/phase
      -> ci16 slot buffer -> CFO -> gateway TS -> radio.transmit
```

Key DL properties:

- Wire data is `cbf16_t`; DSP is `cf_t`; radio is `ci16_t`.
- The grid is slot-sized and dense; each symbol/port is independent.
- The modulation request is per slot; the compute is per symbol/port.
- In SDR mode the finalize point is intentionally early, so the radio pull is
  the real deadline.

---

## 6. Uplink path: radio -> resource grid/PRACH -> wire

### 6.1 Radio notification

The SDR RU registers `ru_lower_phy_rx_symbol_adapter` as the lower-PHY RX
symbol notifier (`lib/ru/sdr/rx_symbol_adapter.h:14-40`):

- `on_rx_symbol` calls
  `rx_symbol_handler.on_new_uplink_symbol({.slot, .sector, .symbol_id}, grid, is_valid)`
  (`:23-31` region).
- `on_rx_prach_window` calls `on_new_prach_window_data` (`:33-39` region).

In the emulator, `ru_emulator_rx_symbol_adapter` wraps the sector's
`ofh::ru_uplink_iq_sink` and translates radio slot numbering to GPS/OFH slot
numbering (`apps/examples/ofh/ru_emulator_rx_symbol_adapter.h:16-58`):

- `on_new_uplink_symbol` -> `sink.handle_uplink_symbol(to_ofh_slot(context.slot), context.symbol_id, grid)`
  (`:36-43`).
- `on_new_prach_window_data` -> `sink.handle_prach_window(to_ofh_slot(context.slot), *buffer)`
  (`:46-51`).
- `to_ofh_slot` applies the GPS slot offset (`:54-58`).

### 6.2 Baseband receive and per-symbol demux

`lower_phy_baseband_processor::ul_process`
(`lib/phy/lower/lower_phy_baseband_processor.cpp:139-173`):

- Pops an RX buffer, calls `receiver.receive(rx_buffer->get_writer())`
  (`:147-151`).
- Updates `last_rx_timestamp = rx_metadata.ts + nof_samples` (`:155`).
- Defers processing to `uplink_executor` (`:158-169`); the buffer returns to
  the RX pool after processing (`:165`).

`lower_phy_uplink_processor_impl::process` runs a small FSM
(`lib/phy/lower/processors/uplink/uplink_processor_impl.cpp:83-94`):

- `alignment`: find the next subframe boundary within the buffer
  (`:96-118`).
- `collecting`: accumulate samples until a complete OFDM symbol is available
  (`:166-272`).

On a symbol boundary (`:120-164`):

- Computes slot/symbol from the sample timestamp (`:123-148`).
- Stores `current_slot`, `current_symbol_index`, `current_symbol_size`,
  resets the write index, and resizes the temp buffer (`:150-156`).
- At symbol 0, advances the CFO command (`:158-160`).

While collecting (`:166-272`):

- Validates the timestamp and channel count (`:169-177`); on mismatch returns
  to alignment.
- Copies `ci16_t` samples per port into `temp_buffer` (`:179-198`).
- When the symbol is complete, converts to `cf_t`, applies CFO, converts back
  (`:206-220`).
- Calls PRACH `process_symbol` first (`:222-225`), then PUxCH `process_symbol`
  (`:227-230`).
- If PUxCH processed, computes average/peak/clipping metrics and notifies
  (`:232-255`).
- Emits half-slot and full-slot notifications
  (`:257-267`).
- Recurses on the remainder of the buffer (`:269-271`).

### 6.3 PUxCH demodulation

`puxch_processor_impl::process_symbol`
(`lib/phy/lower/processors/uplink/puxch/puxch_processor_impl.cpp:13-73`):

- On slot change, exchanges the current request grid from the
  `resource_request_pool`; invalid or mismatched slot releases the grid and
  notifies a late request (`:18-39`).
- Returns early if no grid is available (`:41-44`).
- Computes `symbol_index_subframe = context.nof_symbols + slot.subframe_slot_index() * nof_symbols_per_slot`
  (`:46-47`).
- For each RX port: `ci16_t -> cf_t`, then
  `demodulator->demodulate(grid_writer, cf_buffer, port, symbol_index)`
  (`:54-62`).
- Notifies `on_rx_symbol` (`:64-65`).
- Releases the grid after the last symbol (`:67-70`).

`ofdm_symbol_demodulator_impl::demodulate`
(`lib/phy/lower/modulation/ofdm_demodulator_impl.cpp:77-129`):

- Recomputes phase compensation if the center frequency changed
  (`:82-87`).
- Requires input size `cp_len + dft_size` (`:89-103`).
- Copies the DFT window, skipping the CP and applying the configured window
  offset (`:105-106`).
- Runs the DFT (`:108-109`).
- Applies phase compensation and scale (`:111-115`), plus window-offset phase
  compensation when configured (`:117-120`).
- Maps the DC-centered DFT output back into the grid: upper half to
  `[dft_size - rg_size/2, ...)` -> grid start, lower half to grid
  `[rg_size/2, ...)` (`:122-128`).

Constructor invariants mirror the modulator: `dft_size > rg_size`, nonzero
scale, DFT input zeroed (`lib/phy/lower/modulation/ofdm_demodulator_impl.cpp:16-61`).

The PUxCH processor factory sets the OFDM demodulator scale to
`1/sqrt(bw_rb * 12)` and computes the DFT window offset from the CP length
(`lib/phy/lower/processors/uplink/puxch/puxch_processor_factories.cpp:21-46`).

### 6.4 PRACH capture and demodulation

`prach_processor_impl` is a fixed-size worker pool
(`lib/phy/lower/processors/uplink/prach/prach_processor_impl.h:16-98`):

- `handle_request` picks the first idle worker and hands it the PRACH buffer
  and context; if all workers are busy, calls `on_prach_request_overflow`
  (`:27-51`).
- `process_symbol` fans the same baseband symbol out to every worker
  (`:53-61`).

Each `prach_processor_worker` is a four-state FSM
`{idle, wait, collecting, processing}` and assumes `handle_request`/
`is_available` run on one thread while `process_symbol` runs on another
(`lib/phy/lower/processors/uplink/prach/prach_processor_worker.h:24-50`,
`:128-135`). Its buffers are sized to `prach_constants::MAX_WINDOW_LENGTH`
(`:100-112`):

- `temp_baseband(max_nof_ports, MAX_WINDOW_LENGTH_samples)`.
- `temp_cf_baseband({MAX_WINDOW_LENGTH_samples, max_nof_ports})`.

The worker accumulates `ci16_t` time-domain samples, converts to `cf_t`, then
calls the `ofdm_prach_demodulator` into a `prach_buffer`
(`include/ocudu/phy/lower/modulation/ofdm_prach_demodulator.h:45-60`).
The demodulator handles long preambles (CP + `N_u`) and short preambles
(one slot at PUSCH SCS) (`:45-55`).

The PRACH worker factory creates `max_nof_concurrent_requests` workers, each
with its own demodulator, all sharing the same `async_task_executor` and
sampling rate (`lib/phy/lower/processors/uplink/prach/prach_processor_factories.cpp:39-49`).

### 6.5 Uplink reply: grid -> OFH U-plane

In `store_and_respond` mode the reply path is: C-plane recorder stores the
request (`lib/ofh/ru/ofh_ru_uplink_scheduling_recorder.cpp:41-86`), the radio
captures IQ and pushes it into the sector's uplink IQ sink
(`apps/examples/ofh/ru_emulator_rx_symbol_adapter.h:36-51`), and the
responders match the captured slot/symbol against the stored request before
encoding.

The OFH sector's uplink sink is driven by the radio adapter. The responder
`ru_uplink_symbol_responder::handle_uplink_symbol`
(`lib/ofh/ru/ofh_ru_uplink_symbol_responder.cpp:24-62`):

- Reads `grid.get_reader()` and iterates
  `min(nof_ports, ul_eaxc.size())` ports (`:28-31`).
- Looks up the recorded request for `(slot, eaxc)` from
  `ru_uplink_request_repository` (`:32-33`).
- Skips symbols outside `[start_symbol, start_symbol + nof_symbols)`
  (`:35-39`).
- Builds a `data_flow_uplane_resource_grid_context` with
  `{slot, sector, port, eaxc, symbol_range = [symbol, symbol+1), section_id}`
  (`:41-47`).
- Calls `ul_data_flow.enqueue_section_type_1_message(df_context, grid)`
  (`:54`).
- Clears the request after the last symbol (`:56-60`).

PRACH is analogous: `ru_prach_window_responder::handle_prach_window`
(`lib/ofh/ru/ofh_ru_prach_window_responder.cpp:24-61`):

- Iterates ports up to `min(buffer.get_max_nof_ports(), prach_eaxc.size())`
  (`:26-29`).
- Looks up the PRACH request and builds
  `data_flow_uplane_prach_context` with PRB start/count, symbol range, filter
  index, PRACH SCS and section ID (`:37-48`).
- Calls `enqueue_prach_message` and clears the request (`:55-59`).

`data_flow_uplane_data_impl::enqueue_section_type_1_message` builds and
compresses the U-plane message (`lib/ofh/transmitter/ofh_data_flow_uplane_data_impl.cpp:85-92`).

`enqueue_section_type_1_message_symbol_burst`
(`:178-264`):

- Reads `iq_data = reader.get_view(port, symbol_id)` when the RU bandwidth
  matches the grid; otherwise copies into a temp buffer and zero-pads
  (`:202-209`).
- Splits into fragments with `ofh_uplane_fragment_size_calculator` based on
  frame capacity minus headers (`:211-233`).
- Reserves a frame per fragment from `frame_pool` (`:217-229`).
- Builds `uplane_message_params` with direction, standard channel filter,
  slot, symbol, fragment start PRB, fragment PRB count, compression and
  section ID (`:247-254`).
- Calls `enqueue_section_type_1_message_symbol(...)` with the IQ subspan
  (`:256-260`).

`enqueue_section_type_1_message_symbol`
(`:266-303`):

- Builds the OFH message (Ethernet header space excluded) with
  `up_builder->build_message(...)` (`:271-276`).
- Builds the eCPRI IQ-data header with a sequence ID from
  `up_seq_gen.generate(eaxc)` (`:278-281`).
- Builds the Ethernet frame (`:286-288`).
- Returns the total frame size (`:302`).

`generate_ofh_user_parameters` sets `section_type::type_1`, compression, and
`section_id` (`:22-44`). `generate_ecpri_data_parameters` maps eAxC to
`pc_id`, sets the sequence ID, sets the E bit to 1 (no fragmentation), and
uses subsequence ID 0 (`:46-61`).

### 6.6 U-plane header encoding

`ofh_uplane_message_builder_impl`:

- `encode_data_direction`: bit 7 = direction, bits 4-6 = payload version,
  bits 0-3 = filter index (`lib/ofh/serdes/ofh_uplane_message_builder_impl.cpp:15-28`).
- `encode_subframe_and_slot`: high nibble = subframe index, low nibble = four
  MSBs of subframe slot index (`:30-40`).
- `encode_slot_lsb_and_symbol`: bits 6-7 = two LSBs of slot index, bits 0-3 =
  symbol ID (`:42-50`).
- Section header: section ID, RB/symbol flags, start PRB, PRB count
  (`:80-94`).
- Compression header and IQ serialization: header, optional `udCompLen` for
  selective compression, then `compressor.compress(...)`
  (`:96-127`).

### 6.7 BFP compression/decompression

Generic BFP (`lib/ofh/compression/iq_compression_bfp_impl.cpp`):

- Quantize `bf16_t` pairs to `int16_t` (`:13-31`).
- Per PRB: find max absolute sample, derive exponent, shift right, store
  exponent byte, bit-pack `12 * 2` values at `data_width` (`:33-59`).
- `compress` converts the whole `cbf16_t` span, then compresses each PRB
  independently (`:61-87`).
- Decompress: read exponent, reconstruct scale, unpack, sign-extend, scale
  (`:89-113`), loop over PRBs (`:115-140`).

AVX2 BFP (`lib/ofh/compression/iq_compression_bfp_avx2.cpp`):

- Falls back to generic for unsupported widths (`:19-23`).
- Processes two PRBs per iteration using three `__m256i` registers
  (`:48-58`).
- Computes two exponents, arithmetic-shifts, permutes halves, writes exponent
  bytes, and pack two PRBs big-endian (`:60-85`).
- Handles a trailing odd PRB with the generic kernel (`:88-96`).
- Decompress uses AVX2 unpack plus a scaling vector, then converts to `cf_t`
  (`:99-153`).

---

## 7. Granularity, ownership and synchronization summary

| Object | Granularity | Producer | Consumer | Sync |
| --- | --- | --- | --- | --- |
| C-plane request | slot + eAxC | OFH RX thread | scheduler / grid repo | repo mutex |
| Grid request | one slot | C-plane handler | U-plane writer | grid repo mutex |
| DL grid | one slot, dense | U-plane writer | PDxCH | `shared_resource_grid` refcount |
| DL modulation | symbol x port | executor task | gateway buffer | atomic state + task count |
| DL baseband | sample run, slot-aligned | downlink processor | gateway transmitter | TX executor + clock |
| UL baseband | sample run | gateway receiver | uplink processor | RX/UL executors |
| UL symbol | one OFDM symbol | uplink FSM | PUxCH/PRACH | single UL executor |
| PUxCH grid | one slot | request handler | per-symbol demod | `resource_request_pool` (16 slots) |
| PRACH occasion | request window | scheduler | worker pool | worker FSM |
| UL reply message | symbol x eAxC (fragmented by PRB) | data flow | frame pool | frame states |
| OFH TX | symbol window `Ta3` | message transmitter | Ethernet TX | frame pool + executor |

The request pool is fixed at 16 entries and indexed by `system_slot() % 16`
(`lib/phy/lower/processors/resource_request_pool.h:24-39`), so requests more
than 16 slots apart alias.

---

## 8. CUDA replacement surface

This section identifies where a GPU kernel can replace CPU code without
changing the wire format or the surrounding scheduling. It is a surface map,
not a performance claim.

### 8.1 High-value kernels

1. **OFDM modulator (iFFT + CP + phase/scale).**
   `ofdm_symbol_modulator_impl::modulate`
   (`lib/phy/lower/modulation/ofdm_modulator_impl.cpp:39-90`) is a per
   (symbol, port) transform over `dft_size` complex samples. Natural
   deployment: one block per (symbol, port), or batched over all symbols of a
   slot. The input grid symbol is `cbf16_t`; conversion to `cf_t` is required
   before cuFFT. The output is `cf_t`, then converted to `ci16_t` by the
   caller (`pdxch_baseband_modulator.h:167-168`).

2. **OFDM demodulator (DFT + CP removal + grid remap).**
   `ofdm_symbol_demodulator_impl::demodulate`
   (`lib/phy/lower/modulation/ofdm_demodulator_impl.cpp:77-129`) is the
   inverse per (symbol, port). Deployment can mirror the modulator. The grid
   write is DC-centered and split into two halves (`:122-128`), which is easy
   to express as two strided writes but must match the CPU mapping exactly.

3. **BFP quantize/compress.**
   The CPU path quantizes `cbf16_t` -> `int16_t`, finds a per-PRB max, shifts
   and bit-packs (`lib/ofh/compression/iq_compression_bfp_impl.cpp:33-87`).
   A GPU kernel can process one block per PRB or per group of PRBs. The bit
   packing is the awkward part for GPU; the AVX2 implementation shows the
   intended two-PRB batching and big-endian packing
   (`lib/ofh/compression/iq_compression_bfp_avx2.cpp:48-96`).

4. **BFP decompress.**
   `iq_compression_bfp_impl::decompress` (`:115-140`) and the AVX2 variant
   (`:99-153`) are the inverse. Decompression is more GPU-friendly than
   compression because it is a scatter-free expand-and-scale.

5. **CFO compensation.**
   DL applies CFO to the whole slot buffer
   (`lib/phy/lower/processors/downlink/downlink_processor_baseband_impl.cpp:144-158`);
   UL applies CFO per symbol
   (`lib/phy/lower/processors/uplink/uplink_processor_impl.cpp:206-220`).
   Both are element-wise complex multiplies over `ci16_t`, with conversion to
   and from `cf_t`.

6. **Amplitude control and power metrics.**
   DL amplitude control plus avg/peak/clipping is inside the same per-symbol
   task (`pdxch_baseband_modulator.h:158-165`). This is a reduction over the
   symbol and can be fused with the modulator epilogue.

7. **PRACH demodulation.**
   `ofdm_prach_demodulator` receives a window of `cf_t` and writes a
   frequency-domain `prach_buffer` (`include/ocudu/phy/lower/modulation/ofdm_prach_demodulator.h:45-60`).
   It is a separate DFT-like workload, naturally batched per occasion/port.

### 8.2 What should stay on the host

- Ethernet/eCPRI parsing and validation, sequence-ID checks, VLAN/MAC
  filtering (`lib/ofh/ru/ofh_ru_message_receiver.cpp:41-166`).
- OFH header construction, fragmentation, frame-pool management and TX
  window selection (`lib/ofh/transmitter/ofh_data_flow_uplane_data_impl.cpp:178-303`,
  `lib/ofh/ru/ofh_ru_message_transmitter.cpp:25-47`).
- Request repository, schedule lookup, late-request detection and
  `shared_resource_grid` refcounting. These are small control operations with
  strict ordering.
- Slot/TTI scheduling and the baseband pull loop
  (`lib/phy/lower/lower_phy_baseband_processor.cpp:70-173`).

### 8.3 Layout constraints for a GPU port

- Resource grid is dense `cbf16_t` in `subcarrier -> symbol -> port` order
  (`lib/phy/support/resource_grid_impl.h:28-32`). A kernel that wants
  symbol-major or port-major access must either transpose or use strided
  access consciously.
- Gateway buffers are dense `ci16_t` in `sample -> channel` order
  (`include/ocudu/gateways/baseband/buffer/baseband_gateway_buffer_dynamic.h:15-26`).
- `cbf16_t` is 4 bytes (two BF16 words), `ci16_t` is 4 bytes, `cf_t` is
  8 bytes (`include/ocudu/adt/complex.h:22-44`). A 100 MHz carrier at 30 kHz
  SCS runs at 122.88 Msps with a 4096-point FFT: 122,880 samples per port
  per millisecond, or 61,440 per 0.5 ms slot. A 4T4R grid at 273 PRB is
  `14 symbols * 12 * 273 * 4 ports * 4 bytes` = 733,824 bytes (~0.73 MB) per
  slot; the matching `ci16_t` baseband is 245,760 bytes per port per slot
  (~0.98 MB for 4 ports).
- Soft radios (null/zmq) force a **slot**-sized baseband RX buffer while UHD
  uses **single_packet** (`apps/examples/ofh/ru_emulator_sdr.cpp:152-154`).
  The GPU path will therefore see a different buffer size and pull cadence
  on replay/offline runs than on UHD; do not size staging from null-radio
  runs alone.
- The CPU path is per symbol/port and uses a shared scratch buffer sized
  `2 * dft_size` (`pdxch_baseband_modulator.h:63`,
  `lib/phy/lower/processors/uplink/uplink_processor_impl.cpp:33-37`). A GPU
  port needs explicit staging buffers and a completion signal back into the
  executor model.

### 8.4 Recommended boundary

Keep the OFH and scheduling control plane unchanged. Replace these three
compute islands, each with an explicit host-device contract:

1. grid + CFO in -> modulated `ci16_t` slot out (DL);
2. `ci16_t` slot in -> grid + PRACH out (UL);
3. `cbf16_t` grid/PRACH in -> compressed OFH payload out, and the inverse
   (UL encode / DL decode).

This preserves the existing `shared_resource_grid`, request-pool, frame-pool
and executor semantics, which are the parts most sensitive to timing and
ownership.

---

## 9. Null radio integration

The null radio is a software radio backend intended for replay/offline runs
and for validating the pipeline without hardware.

### 9.1 Backend registration

- `lib/radio/radio_factory.cpp:15` includes the null factory; `:39` registers
  it as `"null"`.
- `lib/radio/CMakeLists.txt:26-29` always builds `ocudu_radio_null`.
- `lib/radio/null/radio_factory_null_impl.cpp:11-37` validates
  `sampling_rate_Hz > 0` and non-empty TX/RX streams, then returns a
  `radio_session_null_impl`.
- The CLI exposes `--device_driver` with values `uhd`, `zmq`, `null`
  (`apps/examples/ofh/ru_emulator_cli11_schema.cpp:99`).

### 9.2 Behavior

`radio_session_null_impl` implements both `radio_session` and
`radio_management_plane` (`lib/radio/null/radio_null_session.h:22-39`):

- It has a `pace_mode { realtime, free }`.
- TX IQ is dumped to `.cf32`; RX is read from files or filled with zeros.
- The radio clock advances only in `receive()`
  (`lib/radio/null/radio_null_session.cpp:69-71`, `:105-121`).

Gateway (`lib/radio/null/radio_null_session.cpp:40-103`):

- `transmit` converts `ci16_t` to interleaved float pairs, zeroes samples
  outside `[tx_start, tx_end)` and zeroes the whole block when `is_empty`
  (`:69-103`).
- `receive` reads per-port `portN.cf32` files if present, else zeros; on EOF
  it zero-fills and marks EOF (`:105-140` region).

Realtime pacing sleeps until the wall-clock time corresponding to the end of
the buffer, using the same `system_clock` family as SDR start-time alignment
(`lib/radio/null/radio_null_session.cpp:110-121`).

### 9.3 IQ dump and metadata

`start()` records `start_ts`, initializes `tx_file_cursor`, and writes the
sidecar (`lib/radio/null/radio_null_session.cpp:357-365`). `stop()` joins the
writer and rewrites the sidecar (`:367-379`).

`write_sidecar_json()` writes `iq_meta.json` with
`sample_rate_Hz`, `start_timestamp`, `nof_tx_ports`, `nof_rx_ports`,
`format = "cf32"`, `backend = "null"`, `pace`, and a `slot_grid` object with
`scs_kHz`, `samples_per_slot`, `slots_per_frame`, and
`"symbol0_sample_offset_basis": "ts - start_timestamp"`
(`lib/radio/null/radio_null_session.cpp:381-406`).

The writer thread:

- Waits on `tx_cv` and pops a block from the ring
  (`lib/radio/null/radio_null_session.cpp:238-250`).
- Gap-fills zeros so the file sample offset equals `ts - start_ts`
  (`:256-267`).
- Writes one JSONL line per block to `tx_index.jsonl`:
  `{"ts", "nof_samples", "is_empty", "sfn", "slot", "symbol0_sample_offset"}`
  (`:269-275`).
- Writes per-channel floats, zero-filling empty blocks (`:277-295`).

### 9.4 How it plugs into the emulator

- `apps/examples/ofh/ru_emulator_sdr.cpp:152` and `:170-171` classify
  `device_driver == "zmq" || "null"` as "soft radio": no hardware PPS clock,
  free-running time.
- Soft radios also force `baseband_rx_buffer_size_policy::slot`, whereas UHD
  uses `single_packet` (`apps/examples/ofh/ru_emulator_sdr.cpp:152-154`).
  The null radio hands the lower PHY one slot-sized buffer per `receive()`
  call; UHD hands it radio-native single packets. Timing or buffer-cadence
  numbers measured with the null radio are therefore **not representative of
  UHD hardware**.
- The rest of the SDR RU stack is unchanged: the null backend presents the
  same `baseband_gateway` transmitter/receiver interface as a real radio, so
  `ru_sdr_impl`, the lower PHY, the OFH sector and the uplink responder all
  run normally.

### 9.5 Caveats

- The null radio is a radio backend, not an OFH replay source. To drive the
  DL path you still need eCPRI frames into the Ethernet RX path; the null
  backend only replaces the RF side.
- The RX feed is per-port `portN.cf32` with no metadata; alignment is by
  sample count from `start_ts`, not by timestamp markers.
- `pace=free` runs as fast as possible and is explicitly not a timing claim;
  the code logs "[OFFLINE THROUGHPUT — not a timing claim]"
  (`lib/radio/null/radio_null_session.cpp:328-338`).

---

## 10. Naming inversion and other gotchas

### 10.1 OFH `ul`/`dl` names are from the O-DU perspective

In the O-RU receiver, symbols named `ul_*` often refer to **downlink** data
received from the O-DU, and `dl_*` can refer to uplink directions. Concrete
examples:

- `ru_message_receiver_config.dl_eaxc` is the list of eAxCs accepted for
  received User-Plane IQ (`lib/ofh/ru/ofh_ru_message_receiver.cpp:30`, used at
  `:77`).
- The log message "no uplink slot context" is emitted by the writer when the
  repository has no context for the received slot/symbol
  (`lib/ofh/receiver/ofh_uplane_rx_symbol_data_flow_writer.cpp:17-30`). The
  writer is assembling the RU **downlink** grid from received U-plane data,
  despite the `ul_context`/`ul_eaxc` names and the "uplink" wording.
- `ru_uplink_symbol_responder` is the O-RU **uplink reply** builder; the grid
  it reads is the RU uplink grid.

When reading the code, treat direction names as "relative to the O-DU unless
the file is clearly in the O-RU uplink reply path".

### 10.2 One-word names inside the UL processor

`lower_phy_rx_symbol_context` has a field `nof_symbols` that actually carries
the **symbol index** in the PUxCH path
(`lib/phy/lower/processors/uplink/puxch/puxch_processor_impl.cpp:46-47`).
Do not read it as a count.

### 10.3 DL finalize lead

`dl_grid_finalize_offset_symbols =
(if SDR) -(nof_slots_per_subframe + 1) * nsym_per_slot, else +nsym_per_slot`
(`apps/examples/ofh/ru_emulator.cpp:396-405`) is applied by
`ru_downlink_rx_window_handler` (`lib/ofh/ru/ofh_ru_downlink_rx_window_handler.cpp:9-33`).
In SDR mode this is what allows the grid to be pushed to the radio before the
lower PHY pulls it, at the cost of holding the grid one extra slot [DERIVED
from the configuration and the documented contract in
`apps/examples/ofh/ru_emulator_sdr_upper_phy.h:29-38`].

### 10.4 Grid aliasing

`resource_request_pool` has 16 slots
(`lib/phy/lower/processors/resource_request_pool.h:24-39`). A delayed request
more than 16 slots behind aliases onto a newer request and is reported as
late. The code handles this by releasing the stale grid and notifying
`on_*_request_late` (`puxch_processor_impl.cpp:18-39`,
`pdxch_processor_impl.cpp:63-102`).

### 10.5 Short Ethernet frames

The O-RU receives C-plane requests that are shorter than the 64-byte wire
minimum. `ru_message_receiver::process_frame` pads them before decoding
(`lib/ofh/ru/ofh_ru_message_receiver.cpp:43-52`). Do not add a length filter
that rejects short frames.

---

## 11. Verification status

### 11.1 Verified by source reading

- All `file:line` claims in sections 2-9 were read directly from the working
  tree.
- The SDR DL handoff, the null-radio backend registration, the resource grid
  layout, the OFDM modulator/demodulator mapping, the BFP kernels and the
  UL responder/PRACH responder paths were each inspected at the cited lines.

### 11.2 Unverified or tree-dependent

- Exact behavior of uncommitted local changes in the submodule. The tree is on
  `feat/null-radio` and was dirty during this analysis. Any line that shifted
  since the read is not guaranteed.
- Runtime equivalence of AVX2 BFP and generic BFP for all data widths. The
  fallback condition is visible (`iq_compression_bfp_avx2.cpp:19-23`,
  `:103-107`), but no bit-exactness test was run.
- Any timing, throughput or latency number. No builds or measurements were
  performed.
- GPU behavior. This document only maps the replacement surface; no CUDA code
  exists in this tree and no performance claim is made.

### 11.3 Not in scope of this map

- DU-side code, scheduler, FAPI, M-plane, C-plane policy, PTP stack.
- RF front end, DPD, precoding, beamforming.
- Docker/build system details.

---

## 12. Key file index

Downlink:

- `apps/examples/ofh/ru_emulator.cpp` (assembly, sector config, executors)
- `apps/examples/ofh/ru_emulator_sdr_upper_phy.{h,cpp}` (SDR DL grid handoff)
- `lib/ofh/ru/ofh_ru_message_receiver.cpp` (Ethernet/eCPRI decode + dispatch)
- `lib/ofh/receiver/ofh_ru_rx_cplane_data_flow.cpp` (C-plane decode)
- `lib/ofh/receiver/ofh_ru_cplane_scheduling_dispatcher.cpp` (C-plane routing)
- `lib/ofh/ru/ofh_ru_cplane_scheduling_handler.cpp` (per-slot grid allocation)
- `lib/ofh/receiver/ofh_ru_rx_uplane_data_flow.cpp` (U-plane decode)
- `lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp` (U-plane header/IQ decode)
- `lib/ofh/receiver/ofh_uplane_rx_symbol_data_flow_writer.cpp` (grid write)
- `lib/ofh/support/rx_grid_context_repository.h` (grid contexts)
- `lib/ofh/ru/ofh_ru_downlink_rx_window_handler.cpp` (grid finalize)
- `lib/ru/sdr/ru_lower_phy_downlink_handler_impl.cpp` (DL handoff)
- `lib/phy/lower/processors/adaptors/processor_handler_adaptor.cpp` (adapter)
- `lib/phy/lower/processors/downlink/pdxch/pdxch_processor_impl.cpp` (request)
- `lib/phy/lower/processors/downlink/pdxch/pdxch_baseband_modulator.h` (per-symbol tasks)
- `lib/phy/lower/modulation/ofdm_modulator_impl.cpp` (iFFT/CP)
- `lib/phy/lower/processors/downlink/downlink_processor_baseband_impl.cpp` (slot assembly/CFO)
- `lib/phy/lower/lower_phy_baseband_processor.cpp` (TX/RX loop)

Uplink:

- `lib/ru/sdr/rx_symbol_adapter.h` (lower-PHY -> RU RX adapter)
- `apps/examples/ofh/ru_emulator_rx_symbol_adapter.h` (radio -> OFH sink)
- `lib/phy/lower/processors/uplink/uplink_processor_impl.cpp` (UL FSM/CFO)
- `lib/phy/lower/processors/uplink/puxch/puxch_processor_impl.cpp` (PUxCH demod)
- `lib/phy/lower/modulation/ofdm_demodulator_impl.cpp` (DFT/grid remap)
- `lib/phy/lower/processors/uplink/prach/prach_processor_impl.h` (worker pool)
- `lib/phy/lower/processors/uplink/prach/prach_processor_worker.h` (PRACH FSM)
- `lib/phy/lower/processors/uplink/prach/prach_processor_factories.cpp` (worker creation)
- `lib/ofh/ru/ofh_ru_uplink_symbol_responder.cpp` (grid -> U-plane)
- `lib/ofh/ru/ofh_ru_prach_window_responder.cpp` (PRACH -> U-plane)
- `lib/ofh/transmitter/ofh_data_flow_uplane_data_impl.cpp` (OFH encode/fragment)
- `lib/ofh/serdes/ofh_uplane_message_builder_impl.cpp` (header encode)
- `lib/ofh/compression/iq_compression_bfp_impl.cpp` (generic BFP)
- `lib/ofh/compression/iq_compression_bfp_avx2.cpp` (AVX2 BFP)
- `lib/ofh/ru/ofh_ru_message_transmitter.cpp` (Ta3 window TX)
- `lib/ofh/ru/ofh_ru_ota_symbol_task_dispatcher.h` (defer TX drain)
- `lib/ofh/ru/ofh_ru_uplink_task_dispatcher.h` (defer UL encode)

Data types:

- `include/ocudu/adt/complex.h`
- `include/ocudu/adt/bf16.h`
- `lib/phy/support/resource_grid_impl.h`
- `include/ocudu/phy/support/resource_grid_dimensions.h`
- `include/ocudu/gateways/baseband/buffer/baseband_gateway_buffer_dynamic.h`
- `include/ocudu/phy/support/prach_buffer.h`
- `include/ocudu/phy/support/prach_buffer_context.h`
- `include/ocudu/phy/support/shared_resource_grid.h`
- `lib/phy/lower/processors/resource_request_pool.h`
- `include/ocudu/ofh/ethernet/ethernet_frame_pool.h`

Null radio:

- `lib/radio/null/radio_null_session.h`
- `lib/radio/null/radio_null_session.cpp`
- `lib/radio/null/radio_factory_null_impl.cpp`
- `lib/radio/radio_factory.cpp`
- `lib/radio/CMakeLists.txt`
- `apps/examples/ofh/ru_emulator_cli11_schema.cpp`
- `apps/examples/ofh/ru_emulator_sdr.cpp`

SDR composition:

- `lib/ru/sdr/ru_sdr_impl.{h,cpp}`
- `lib/ru/sdr/ru_controller_sdr_impl.cpp`
- `lib/ru/sdr/lower_phy/lower_phy_sector.cpp`
- `lib/ru/sdr/lower_phy/lower_phy_factory.cpp`
- `lib/ru/sdr/ru_sdr_executor_mapper.cpp`
- `lib/phy/lower/lower_phy_impl.cpp`
- `lib/phy/lower/lower_phy_factory.cpp`
