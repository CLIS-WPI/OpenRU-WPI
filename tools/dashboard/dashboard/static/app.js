(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const root = document.documentElement;
  const params = new URLSearchParams(window.location.search);
  const storedTheme = window.localStorage.getItem("openru.theme");
  const theme = params.get("theme") === "light" || params.get("theme") === "dark"
    ? params.get("theme")
    : (storedTheme === "light" || storedTheme === "dark" ? storedTheme : "dark");
  root.dataset.theme = theme;

  const cssVar = (name) => getComputedStyle(root).getPropertyValue(name).trim();

  const intFmt = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 });
  const decFmt = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 });

  const fmtInt = (value) => {
    const n = Number(value);
    return Number.isFinite(n) ? intFmt.format(Math.round(n)) : "—";
  };
  const fmtDec = (value, digits = 1) => {
    const n = Number(value);
    return Number.isFinite(n) ? n.toFixed(digits) : "—";
  };
  const fmtPct = (part, total) => {
    const a = Number(part);
    const b = Number(total);
    return Number.isFinite(a) && Number.isFinite(b) && b > 0 ? (100 * a / b).toFixed(1) : "—";
  };
  const fmtUs = (value) => {
    const n = Number(value);
    if (!Number.isFinite(n)) return "—";
    if (Math.abs(n) >= 1000) return (n / 1000).toFixed(2) + " ms";
    return Math.round(n) + " µs";
  };
  const fmtBps = (value) => {
    const n = Number(value);
    if (!Number.isFinite(n)) return "—";
    if (n >= 1e9) return (n / 1e9).toFixed(2) + " Gbps";
    if (n >= 1e6) return (n / 1e6).toFixed(2) + " Mbps";
    if (n >= 1e3) return (n / 1e3).toFixed(1) + " kbps";
    return Math.round(n) + " bps";
  };
  const fmtBytes = (value) => {
    const n = Number(value);
    if (!Number.isFinite(n)) return "—";
    const units = ["B", "KiB", "MiB", "GiB", "TiB"];
    let x = n;
    let i = 0;
    while (x >= 1024 && i < units.length - 1) { x /= 1024; i += 1; }
    return (i === 0 ? Math.round(x) : x.toFixed(1)) + " " + units[i];
  };
  const fmtDuration = (seconds) => {
    const s = Number(seconds);
    if (!Number.isFinite(s) || s < 0) return "—";
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    if (m) return `${m}m ${Math.floor(s % 60)}s`;
    return `${Math.round(s)}s`;
  };
  const fmtClock = (ts) => {
    if (!Number.isFinite(Number(ts))) return "—";
    return new Date(Number(ts) * 1000).toLocaleTimeString([], {
      hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
    });
  };
  const fmtCpu = (list) => Array.isArray(list) && list.length ? list.join(",") : "—";

  class LineChart {
    constructor(canvas, opts) {
      this.canvas = canvas;
      this.ctx = canvas.getContext("2d");
      this.opts = Object.assign({ window: 180, zero: true, yFormat: fmtInt, tipFormat: null }, opts);
      this.series = this.opts.series.map((s) => Object.assign({}, s, { color: cssVar(s.colorVar || "--chart-1") }));
      this.points = [];
      this.hover = null;
      this.geometry = null;
      this.wrap = canvas.parentElement;
      this.tip = document.createElement("div");
      this.tip.className = "chart-tip";
      this.wrap.appendChild(this.tip);
      this.resize();
      const ro = new ResizeObserver(() => this.resize());
      ro.observe(this.wrap);
      canvas.addEventListener("mousemove", (event) => this.onMove(event));
      canvas.addEventListener("mouseleave", () => { this.hover = null; this.tip.classList.remove("visible"); this.draw(); });
    }

    refreshColors() {
      this.series = this.opts.series.map((s) => Object.assign({}, s, { color: cssVar(s.colorVar || "--chart-1") }));
      this.draw();
    }

    resize() {
      const rect = this.canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
      this.width = Math.max(1, Math.floor(rect.width));
      this.height = Math.max(1, Math.floor(rect.height));
      this.canvas.width = Math.floor(this.width * dpr);
      this.canvas.height = Math.floor(this.height * dpr);
      this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      this.draw();
    }

    setData(points) {
      this.points = Array.isArray(points) ? points.filter((p) => p && Number.isFinite(Number(p.ts))) : [];
      this.points.sort((a, b) => Number(a.ts) - Number(b.ts));
      this.draw();
    }

    onMove(event) {
      if (!this.geometry || this.points.length < 2) return;
      const rect = this.canvas.getBoundingClientRect();
      const x = event.clientX - rect.left;
      const g = this.geometry;
      if (x < g.left || x > g.right) { this.tip.classList.remove("visible"); return; }
      const ts = g.xmin + (x - g.left) / Math.max(1, g.right - g.left) * (g.xmax - g.xmin);
      let best = this.points[0];
      let bestDelta = Infinity;
      for (const point of this.points) {
        const delta = Math.abs(Number(point.ts) - ts);
        if (delta < bestDelta) { bestDelta = delta; best = point; }
      }
      this.hover = best;
      const values = this.series.map((s) => {
        const value = best[s.key];
        const text = this.opts.tipFormat ? this.opts.tipFormat(value, s) : this.opts.yFormat(value);
        return `${s.label} ${text}`;
      });
      this.tip.textContent = `${fmtClock(best.ts)} · ${values.join(" · ")}`;
      const px = g.left + (Number(best.ts) - g.xmin) / Math.max(1e-9, g.xmax - g.xmin) * (g.right - g.left);
      this.tip.style.left = `${Math.max(70, Math.min(this.width - 70, px))}px`;
      this.tip.style.top = `${Math.max(30, g.top + 16)}px`;
      this.tip.classList.add("visible");
      this.draw();
    }

    draw() {
      const ctx = this.ctx;
      const w = this.width;
      const h = this.height;
      if (!w || !h) return;
      ctx.clearRect(0, 0, w, h);

      const windowS = Number(this.opts.window) || 180;
      const lastTs = this.points.length ? Number(this.points[this.points.length - 1].ts) : 0;
      const cutoff = lastTs - windowS;
      const points = this.points.filter((p) => Number(p.ts) >= cutoff);
      if (!points.length) {
        ctx.fillStyle = cssVar("--faint");
        ctx.font = "11px ui-monospace, monospace";
        ctx.textAlign = "center";
        ctx.fillText("waiting for samples…", w / 2, h / 2);
        this.geometry = null;
        return;
      }

      let xmax = Math.max(...points.map((p) => Number(p.ts)));
      let xmin = Math.max(Math.min(...points.map((p) => Number(p.ts))), xmax - windowS);
      if (!(xmax > xmin)) { xmin = xmax - 60; }
      const values = [];
      for (const s of this.series) {
        for (const p of points) {
          const v = Number(p[s.key]);
          if (Number.isFinite(v)) values.push(v);
        }
      }
      let ymin = this.opts.yMin !== undefined ? Number(this.opts.yMin) : (this.opts.zero ? 0 : Math.min(...values));
      let ymax = this.opts.yMax !== undefined ? Number(this.opts.yMax) : Math.max(...values);
      if (!Number.isFinite(ymin)) ymin = 0;
      if (!Number.isFinite(ymax)) ymax = 1;
      if (!this.opts.zero && this.opts.yMin === undefined) {
        const pad = Math.max(0.5, (ymax - ymin) * 0.12);
        ymin -= pad;
        ymax += pad;
      }
      if (ymax <= ymin) ymax = ymin + 1;
      if (this.opts.zero) ymax = Math.max(ymax * 1.12, ymin + 1);

      const left = 46;
      const right = w - 8;
      const top = 8;
      const bottom = h - 21;
      const plotW = Math.max(1, right - left);
      const plotH = Math.max(1, bottom - top);
      const xScale = (ts) => left + (Number(ts) - xmin) / (xmax - xmin) * plotW;
      const yScale = (value) => bottom - (Number(value) - ymin) / (ymax - ymin) * plotH;

      ctx.font = "9.5px ui-monospace, monospace";
      ctx.textAlign = "right";
      ctx.textBaseline = "middle";
      for (let i = 0; i <= 4; i += 1) {
        const value = ymin + (ymax - ymin) * i / 4;
        const y = yScale(value);
        ctx.strokeStyle = cssVar("--grid");
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(left, y + 0.5);
        ctx.lineTo(right, y + 0.5);
        ctx.stroke();
        ctx.fillStyle = cssVar("--faint");
        ctx.fillText(this.opts.yFormat(value), left - 6, y);
      }

      ctx.textAlign = "center";
      ctx.textBaseline = "top";
      for (let i = 0; i <= 3; i += 1) {
        const ts = xmin + (xmax - xmin) * i / 3;
        const x = xScale(ts);
        ctx.strokeStyle = cssVar("--grid");
        ctx.beginPath();
        ctx.moveTo(x + 0.5, top);
        ctx.lineTo(x + 0.5, bottom);
        ctx.stroke();
        ctx.fillStyle = cssVar("--faint");
        ctx.fillText(fmtClock(ts), x, bottom + 5);
      }

      for (const s of this.series) {
        const segments = [];
        let current = [];
        for (const p of points) {
          const raw = p[s.key];
          const v = Number(raw);
          if (raw === null || raw === undefined || !Number.isFinite(v)) {
            if (current.length) segments.push(current);
            current = [];
          } else {
            current.push([xScale(p.ts), yScale(v)]);
          }
        }
        if (current.length) segments.push(current);
        ctx.strokeStyle = s.color;
        ctx.lineWidth = 1.7;
        ctx.lineJoin = "round";
        ctx.lineCap = "round";
        for (const segment of segments) {
          if (segment.length === 1) {
            ctx.fillStyle = s.color;
            ctx.beginPath();
            ctx.arc(segment[0][0], segment[0][1], 2, 0, Math.PI * 2);
            ctx.fill();
            continue;
          }
          ctx.beginPath();
          segment.forEach(([x, y], index) => { if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y); });
          ctx.stroke();
          if (s.fill && segment.length > 1) {
            const gradient = ctx.createLinearGradient(0, top, 0, bottom);
            gradient.addColorStop(0, s.color + "33");
            gradient.addColorStop(1, s.color + "00");
            ctx.fillStyle = gradient;
            ctx.beginPath();
            ctx.moveTo(segment[0][0], bottom);
            segment.forEach(([x, y]) => ctx.lineTo(x, y));
            ctx.lineTo(segment[segment.length - 1][0], bottom);
            ctx.closePath();
            ctx.fill();
          }
        }
      }

      if (this.hover) {
        const hx = xScale(this.hover.ts);
        ctx.strokeStyle = cssVar("--border-strong");
        ctx.lineWidth = 1;
        ctx.setLineDash([3, 3]);
        ctx.beginPath();
        ctx.moveTo(hx, top);
        ctx.lineTo(hx, bottom);
        ctx.stroke();
        ctx.setLineDash([]);
        for (const s of this.series) {
          const v = Number(this.hover[s.key]);
          if (!Number.isFinite(v)) continue;
          ctx.fillStyle = s.color;
          ctx.beginPath();
          ctx.arc(hx, yScale(v), 2.6, 0, Math.PI * 2);
          ctx.fill();
        }
      }

      this.geometry = { left, right, top, bottom, xmin, xmax, ymin, ymax };
    }
  }

  const charts = {
    ofh: new LineChart($("chart-ofh"), {
      window: 180, zero: true, yFormat: fmtInt,
      series: [
        { key: "rx_total", label: "RX", colorVar: "--chart-1", fill: true },
        { key: "tx_total", label: "TX", colorVar: "--chart-2" },
        { key: "rx_on_time", label: "on time", colorVar: "--chart-3" },
      ],
    }),
    latency: new LineChart($("chart-latency"), {
      window: 180, zero: true, yFormat: fmtUs,
      series: [
        { key: "wall_avg_us", label: "wall avg", colorVar: "--chart-3" },
        { key: "wall_max_us", label: "wall max", colorVar: "--chart-4" },
        { key: "sched_max_us", label: "sched max", colorVar: "--chart-2" },
      ],
    }),
    errors: new LineChart($("chart-errors"), {
      window: 180, zero: true, yFormat: fmtInt,
      series: [
        { key: "seq_past", label: "seq past", colorVar: "--chart-5" },
        { key: "missed_prach", label: "missed PRACH", colorVar: "--chart-4" },
        { key: "late_prach", label: "late PRACH", colorVar: "--chart-2" },
      ],
    }),
    rsrp: new LineChart($("chart-rsrp"), {
      window: 600, zero: false, yFormat: (v) => `${fmtDec(v, 0)} dBm`,
      series: [
        { key: "a", label: "modem A", colorVar: "--chart-1" },
        { key: "b", label: "modem B", colorVar: "--chart-3" },
      ],
    }),
  };

  const legends = {
    ofh: ["ofh", charts.ofh.series],
    latency: ["latency", charts.latency.series],
    errors: ["errors", charts.errors.series],
    rsrp: ["rsrp", charts.rsrp.series],
  };

  function renderLegends() {
    for (const [id, [legendId, series]] of Object.entries(legends)) {
      const el = $(`legend-${legendId}`);
      if (!el) continue;
      el.textContent = "";
      for (const s of series) {
        const key = document.createElement("span");
        key.className = "key";
        const swatch = document.createElement("span");
        swatch.className = "swatch";
        swatch.style.background = cssVar(s.colorVar);
        key.appendChild(swatch);
        key.appendChild(document.createTextNode(s.label));
        el.appendChild(key);
      }
      void id;
    }
  }

  function setBadge(id, text, state) {
    const el = $(id);
    if (!el) return;
    el.textContent = text;
    el.dataset.state = state || "idle";
  }

  function setText(id, value) {
    const el = $(id);
    if (el) el.textContent = value;
  }

  function statusItem(title, value, detail, state, dot) {
    const item = document.createElement("div");
    item.className = "status-item";
    item.dataset.state = state;
    const titleEl = document.createElement("div");
    titleEl.className = "status-title";
    titleEl.textContent = title;
    const valueEl = document.createElement("div");
    valueEl.className = "status-value";
    if (dot) {
      const d = document.createElement("span");
      d.className = "dot";
      valueEl.appendChild(d);
    }
    valueEl.appendChild(document.createTextNode(value));
    const detailEl = document.createElement("div");
    detailEl.className = "status-detail";
    detailEl.textContent = detail || "";
    item.append(titleEl, valueEl, detailEl);
    return item;
  }

  function modemState(m) {
    if (!m) return { state: "idle", label: "absent" };
    if (m.registered) return { state: "ok", label: "registered" };
    if (m.cfun === 4) return { state: "warn", label: "airplane" };
    if (m.error) return { state: m.present ? "bad" : "idle", label: "error" };
    if (m.present && m.connected) return { state: "warn", label: "searching" };
    if (m.present) return { state: "warn", label: "no response" };
    return { state: "idle", label: "absent" };
  }

  function renderStatus(s) {
    const stack = s.stack || {};
    const du = s.du || {};
    const core = s.core || {};
    const host = s.host || {};
    const modems = s.modems || {};
    const cell = du.cell || {};
    const stackState = stack.status === "up" ? "ok" : stack.status === "partial" ? "warn" : stack.status === "down" ? "bad" : "idle";
    const stackValue = stack.status ? stack.status.toUpperCase() : "UNKNOWN";
    const stackDetail = stack.expected
      ? `${(stack.required_running || stack.running || []).length}/${(stack.required || stack.expected).length} required · ${stack.uptime_s != null ? fmtDuration(stack.uptime_s) : "—"}`
      : "docker not reachable";
    const cellState = du.cell_up ? "ok" : (du.last_mac || du.mac) ? "bad" : "idle";
    const cellValue = du.cell_up ? "CELL UP" : ((du.mac || du.last_mac) ? "CELL DOWN" : "UNKNOWN");
    const cellDetail = `PCI ${cell.pci ?? "—"} · n${cell.band ?? "—"} · ${cell.dl_arfcn ?? "—"}`;
    const gnbCount = Number(core.gnb_count || 0);
    const gnbState = gnbCount > 0 ? "ok" : (stack.services && stack.services.core && stack.services.core.running ? "warn" : "idle");
    const gnbValue = gnbCount > 0 ? `${gnbCount} attached` : "NO N2";
    const gnbDetail = (core.gnbs || []).map((g) => g.addr).join(", ") || "waiting for NG setup";
    const hostHw = host.hwlat || {};
    const hwState = !hostHw.available ? "idle" : (hostHw.max_us < 100 ? "ok" : hostHw.max_us < 500 ? "warn" : "bad");
    const hwValue = hostHw.available ? `${fmtInt(hostHw.max_us)} µs` : "NOT SAMPLED";
    const hwDetail = `isolcpus ${fmtCpu((host.isolation || {}).isolcpus)}`;
    const diskPct = Number((host.disk_root || {}).used_pct);
    const diskState = !Number.isFinite(diskPct) ? "idle" : diskPct < 80 ? "ok" : diskPct < 90 ? "warn" : "bad";
    const diskValue = Number.isFinite(diskPct) ? `${diskPct.toFixed(0)}%` : "—";
    const diskDetail = `${fmtBytes((host.disk_root || {}).free_bytes)} free`;

    const items = [
      statusItem("Stack", stackValue, stackDetail, stackState, true),
      statusItem("Cell", cellValue, cellDetail, cellState, true),
      statusItem("gNB", gnbValue, gnbDetail, gnbState, true),
    ];
    for (const label of ["A", "B"]) {
      const m = modems[label] || {};
      const st = modemState(m);
      const rsrp = m.serving && m.serving.rsrp_dbm != null ? `${fmtDec(m.serving.rsrp_dbm, 0)} dBm` : "no signal";
      const ip = m.pdn && m.pdn.address ? m.pdn.address : "no PDU";
      items.push(statusItem(`Modem ${label}`, st.label.toUpperCase(), `${m.port || "no port"} · ${rsrp} · ${ip}`, st.state, true));
    }
    items.push(statusItem("Host hwlat", hwValue, hwDetail, hwState, true));
    items.push(statusItem("Disk", diskValue, diskDetail, diskState, true));

    const strip = $("status-strip");
    strip.textContent = "";
    for (const item of items) strip.appendChild(item);
  }

  function applyRelease(release) {
    if (!release) return;
    setText("chip-tag", release.tag || "tag —");
    setText("chip-commit", release.commit || "commit —");
    setText("chip-profile", release.profile || "profile —");
    const tx = release.tx_gain;
    const rx = release.rx_gain;
    setText("chip-gain", Number.isFinite(Number(tx)) || Number.isFinite(Number(rx))
      ? `TX ${tx ?? "—"} / RX ${rx ?? "—"} dB`
      : "gain n/a");
    const commitChip = $("chip-commit");
    if (commitChip) commitChip.title = `proto-ru ${release.submodule || "unknown"}`;
    setText("footer-release", `${release.tag || "?"} · ${release.commit || "?"} · ${release.profile || "?"}`);
  }

  function applyRu(ru, du) {
    const latest = ru && ru.latest;
    if (!latest) {
      setBadge("ru-badge", "waiting", "idle");
      for (const id of ["kpi-rx", "kpi-tx", "kpi-ontime", "kpi-late", "kpi-early", "kpi-seq"]) setText(id, "—");
      return;
    }
    const age = Number(ru.latest.ts) ? Date.now() / 1000 - Number(ru.latest.ts) : 0;
    setBadge("ru-badge", age < 6 ? "live" : "stale", age < 6 ? "ok" : "warn");
    setText("kpi-rx", fmtInt(latest.rx_total));
    setText("kpi-tx", fmtInt(latest.tx_total));
    setText("kpi-ontime", fmtPct(latest.rx_on_time, latest.rx_total));
    setText("kpi-late", fmtInt(latest.rx_late));
    setText("kpi-early", fmtInt(latest.rx_early));
    setText("kpi-seq", fmtInt(latest.rx_seq_err));
    void du;
  }

  function applyDu(du) {
    const cell = (du && du.cell) || {};
    const mac = (du && du.mac) || {};
    setText("du-sub", `PCI ${cell.pci ?? "—"} · band ${cell.band ?? "—"} · ARFCN ${cell.dl_arfcn ?? "—"} · ${cell.channel_bandwidth_MHz ?? "—"} MHz`);
    setBadge("du-badge", du && du.cell_up ? "cell up" : (mac.nof_slots ? "cell down" : "unknown"), du && du.cell_up ? "ok" : (mac.nof_slots ? "bad" : "idle"));
    setText("du-wall-avg", fmtUs(mac.wall_avg_us));
    setText("du-wall-max", fmtUs(mac.wall_max_us));
    setText("du-slots", mac.nof_slots != null ? fmtInt(mac.nof_slots) : "—");
    setText("du-cs", mac.involuntary_context_switches != null ? fmtInt(mac.involuntary_context_switches) : "—");
    const sched = (du && du.sched) || {};
    setText("du-ues", sched.nof_ues != null ? fmtInt(sched.nof_ues) : "—");
    const ofh = (du && du.ofh) || {};
    setText("du-ofh-rx", ofh.rx_total != null ? fmtInt(ofh.rx_total) : "—");
  }

  function rollingErrors(series, windowSeconds = 60) {
    const points = Array.isArray(series) ? series : [];
    const keys = ["seq_past", "missed_prach", "late_prach"];
    return points.map((p) => {
      const out = { ts: p.ts, seq_past: 0, missed_prach: 0, late_prach: 0 };
      for (const q of points) {
        if (q.ts <= p.ts && q.ts > p.ts - windowSeconds) {
          for (const key of keys) out[key] += Number(q[key] || 0);
        }
      }
      return out;
    });
  }

  function applyErrors(du) {
    const errors = (du && du.errors) || {};
    const seq = errors.seq_past || {};
    const prach = errors.missed_prach || {};
    const late = errors.late_prach || {};
    const total = Number(seq.per_min || 0) + Number(prach.per_min || 0) + Number(late.per_min || 0);
    setBadge("err-badge", total ? `${fmtInt(total)} / min` : "clean", total === 0 ? "ok" : total < 60 ? "warn" : "bad");
    setText("err-seq", fmtInt(seq.per_min));
    setText("err-prach", fmtInt(prach.per_min));
    setText("err-late", fmtInt(late.per_min));
    setText("err-seq-total", `total ${fmtInt(seq.total)}`);
    setText("err-prach-total", `total ${fmtInt(prach.total)}`);
    setText("err-late-total", `total ${fmtInt(late.total)}`);
  }

  function modemCard(label, m) {
    const st = modemState(m);
    const card = document.createElement("div");
    card.className = "modem";
    card.dataset.state = st.state;

    const head = document.createElement("div");
    head.className = "modem-head";
    const name = document.createElement("div");
    name.className = "modem-name";
    name.textContent = `Modem ${label}`;
    const port = document.createElement("span");
    port.textContent = m && m.port ? m.port : "no port";
    name.appendChild(port);
    const pill = document.createElement("span");
    pill.className = `pill ${st.state}`;
    pill.textContent = st.label;
    head.append(name, pill);

    const serving = (m && m.serving) || {};
    const reg = (m && m.registration) || {};
    const fivegs = reg.fivegs || {};
    const eps = reg.eps || {};
    const pdn = (m && m.pdn) || {};
    const operator = (m && m.operator) || {};
    const signal = (m && m.signal) || {};
    const fields = [
      ["CFUN", m && m.cfun_name ? `${m.cfun_name}${m.cfun != null ? ` (${m.cfun})` : ""}` : "—"],
      ["5G reg", fivegs.stat_name || "—"],
      ["LTE reg", eps.stat_name || "—"],
      ["PLMN", operator.mcc && operator.mnc ? `${operator.mcc}/${operator.mnc}` : (serving.mcc && serving.mnc ? `${serving.mcc}/${serving.mnc}` : "—")],
      ["RSRP", serving.rsrp_dbm != null ? `${fmtDec(serving.rsrp_dbm, 1)} dBm` : (signal.dbm != null ? `${fmtDec(signal.dbm, 1)} dBm` : "—")],
      ["RSRQ", serving.rsrq_db != null ? `${fmtDec(serving.rsrq_db, 1)} dB` : "—"],
      ["SINR", serving.sinr_db != null ? `${fmtDec(serving.sinr_db, 1)} dB` : "—"],
      ["Band", serving.band || "—"],
      ["ARFCN", serving.arfcn != null ? serving.arfcn : "—"],
      ["PCI", serving.pci != null ? serving.pci : "—"],
      ["IMSI", (m && m.sim && m.sim.imsi) || "—"],
      ["PDU", pdn.address || "—"],
    ];
    const grid = document.createElement("div");
    grid.className = "modem-grid";
    for (const [key, value] of fields) {
      const cell = document.createElement("div");
      const k = document.createElement("label");
      k.textContent = key;
      const v = document.createElement("b");
      v.textContent = String(value);
      v.title = String(value);
      cell.append(k, v);
      grid.appendChild(cell);
    }
    card.append(head, grid);
    if (m && m.error) {
      const err = document.createElement("div");
      err.className = "modem-error";
      err.textContent = m.error;
      card.appendChild(err);
    }
    return card;
  }

  function applyModems(modems) {
    const host = $("modem-cards");
    host.textContent = "";
    host.appendChild(modemCard("A", (modems || {}).A));
    host.appendChild(modemCard("B", (modems || {}).B));
    const states = ["A", "B"].map((label) => modemState((modems || {})[label]));
    const ok = states.filter((s) => s.state === "ok").length;
    const bad = states.filter((s) => s.state === "bad").length;
    setBadge("modem-badge", ok ? `${ok} registered` : bad ? "error" : "not registered", ok ? "ok" : bad ? "bad" : "idle");
  }

  function applyCore(core) {
    core = core || {};
    const counts = core.counts || {};
    setText("core-gnb", fmtInt(core.gnb_count));
    setText("core-ues", fmtInt(core.ue_count));
    setText("core-accepted", fmtInt(counts.reg_accepted));
    setText("core-rejected", fmtInt(counts.reg_rejected));
    setText("core-authfail", fmtInt(counts.auth_failure));
    setText("core-pdu", fmtInt(counts.pdu_established));
    setBadge("core-badge", core.gnb_up ? "N2 up" : "no n2", core.gnb_up ? "ok" : "warn");
    const body = $("ue-table").querySelector("tbody");
    body.textContent = "";
    const ues = core.ues || [];
    if (!ues.length) {
      const row = document.createElement("tr");
      const cell = document.createElement("td");
      cell.colSpan = 4;
      cell.textContent = "no UE sessions seen at this log level";
      row.appendChild(cell);
      body.appendChild(row);
    } else {
      for (const ue of ues.slice(0, 8)) {
        const row = document.createElement("tr");
        const stateClass = ue.state === "pdu" || ue.state === "registered" ? "ok" : ue.state === "auth_ok" || ue.state === "requesting" ? "warn" : "";
        for (const [text, cls] of [
          [ue.supi || "—", ""],
          [ue.state || "—", `state ${stateClass}`],
          [ue.dnn || "—", ""],
          [ue.ipv4 || ue.ipv6 || "—", ""],
        ]) {
          const td = document.createElement("td");
          if (cls) td.className = cls;
          td.textContent = text;
          td.title = text;
          row.appendChild(td);
        }
        body.appendChild(row);
      }
    }
    const rejects = $("reject-list");
    rejects.textContent = "";
    const auth = core.auth || {};
    if (auth.last_cause) {
      const item = document.createElement("div");
      item.className = "reject";
      item.textContent = `auth: ${auth.last_cause}`;
      rejects.appendChild(item);
    }
    for (const reject of (core.rejects || []).slice(-4)) {
      const item = document.createElement("div");
      item.className = "reject";
      item.textContent = `${reject.supi || "UE"} · ${reject.cause_name || "reject"}${reject.pdu ? " (PDU)" : ""}`;
      rejects.appendChild(item);
    }
  }

  function applyHost(host, stack) {
    host = host || {};
    const isolation = host.isolation || {};
    const hwlat = host.hwlat || {};
    const memory = host.memory || {};
    const disk = host.disk_root || {};
    setText("host-sub", `${host.hostname || "—"} · ${host.kernel || "—"} · ${host.cpu_count ?? "—"} CPUs`);
    setBadge("host-badge", hwlat.available ? (hwlat.max_us < 100 ? "quiet" : hwlat.max_us < 500 ? "jitter" : "noisy") : "hwlat n/a", hwlat.available ? (hwlat.max_us < 100 ? "ok" : hwlat.max_us < 500 ? "warn" : "bad") : "idle");
    setText("host-load", host.load ? fmtDec(host.load["1m"], 2) : "—");
    setText("host-mem", memory.used_pct != null ? `${fmtDec(memory.used_pct, 0)}%` : "—");
    setText("host-disk", disk.used_pct != null ? `${fmtDec(disk.used_pct, 0)}%` : "—");
    setText("host-hwlat", hwlat.available ? `${fmtInt(hwlat.max_us)} µs` : "—");

    const iso = $("host-iso");
    iso.textContent = "";
    const chips = [
      ["isolcpus", fmtCpu(isolation.isolcpus)],
      ["nohz_full", fmtCpu(isolation.nohz_full)],
      ["rcu_nocbs", fmtCpu(isolation.rcu_nocbs)],
      ["irqaffinity", isolation.irqaffinity || "—"],
      ["cstates", `${(isolation.cstate_limit || {})["intel_idle.max_cstate"] ?? "—"} / ${(isolation.cstate_limit || {})["processor.max_cstate"] ?? "—"}`],
    ];
    for (const [key, value] of chips) {
      const chip = document.createElement("span");
      chip.className = "iso";
      const b = document.createElement("b");
      b.textContent = `${key} `;
      chip.appendChild(b);
      chip.appendChild(document.createTextNode(value));
      iso.appendChild(chip);
    }

    const nics = $("host-nics");
    nics.textContent = "";
    for (const nic of host.nic || []) {
      const row = document.createElement("div");
      row.className = "nic";
      const values = [
        nic.name,
        `mtu ${nic.mtu ?? "—"}`,
        nic.speed_mbps && nic.speed_mbps > 0 ? `${nic.speed_mbps} Mb/s` : "speed —",
        `rx err ${nic.rx_errors ?? "—"}`,
        `tx err ${nic.tx_errors ?? "—"}`,
      ];
      values.forEach((value, index) => {
        const span = document.createElement("span");
        if (index === 0) span.className = "nic-name";
        span.textContent = value;
        span.title = `${value} · rx_dropped ${nic.rx_dropped ?? "—"} · tx_dropped ${nic.tx_dropped ?? "—"}`;
        row.appendChild(span);
      });
      nics.appendChild(row);
    }

    const stackList = $("stack-list");
    stackList.textContent = "";
    const services = (stack && stack.services) || {};
    for (const name of Object.keys(services).sort()) {
      const service = services[name];
      const row = document.createElement("div");
      row.className = "stack-row";
      const label = document.createElement("span");
      label.className = "name";
      label.textContent = `${name} · ${service.name || ""}`;
      const state = document.createElement("span");
      state.className = "state";
      const running = service.running;
      const health = service.health;
      if (running && (!health || health === "healthy")) state.classList.add("ok");
      else if (running || health === "starting") state.classList.add("warn");
      else state.classList.add("bad");
      state.textContent = health && health !== "healthy" ? `${service.state || "?"} / ${health}` : (service.state || "?");
      row.append(label, state);
      stackList.appendChild(row);
    }
  }

  const logState = {
    all: [],
    renderedSeq: 0,
    clearSeq: 0,
    signature: "",
    paused: false,
    stick: true,
  };

  const LEVEL_RANK = { debug: 0, info: 1, warn: 2, error: 3, critical: 4 };
  const SOURCE_LABEL = { ru: "RU", du: "DU", core: "CORE" };

  function logFilter() {
    return {
      source: $("log-source").value,
      level: $("log-level").value,
      search: $("log-search").value.trim().toLowerCase(),
    };
  }

  function filteredLogs() {
    const filter = logFilter();
    const minRank = filter.level === "all" ? -1 : LEVEL_RANK[filter.level] ?? 0;
    return logState.all.filter((line) => {
      if (Number(line.seq) <= logState.clearSeq) return false;
      if (filter.source !== "all" && line.source !== filter.source) return false;
      if (minRank >= 0 && (LEVEL_RANK[line.level] ?? 1) < minRank) return false;
      if (filter.search && !String(line.text || "").toLowerCase().includes(filter.search)) return false;
      return true;
    });
  }

  function makeLogLine(line) {
    const row = document.createElement("div");
    row.className = `log-line level-${line.level || "info"}`;
    const time = document.createElement("span");
    time.className = "log-time";
    time.textContent = fmtClock(line.ts);
    const source = document.createElement("span");
    source.className = `log-src src-${line.source || "core"}`;
    source.textContent = SOURCE_LABEL[line.source] || String(line.source || "").toUpperCase();
    const text = document.createElement("span");
    text.className = "log-text";
    text.textContent = line.text || "";
    row.append(time, source, text);
    return row;
  }

  function rebuildLogs(lines) {
    const list = $("log-list");
    list.textContent = "";
    const slice = lines.slice(-600);
    const fragment = document.createDocumentFragment();
    for (const line of slice) fragment.appendChild(makeLogLine(line));
    list.appendChild(fragment);
    logState.renderedSeq = lines.length ? Math.max(...lines.map((line) => Number(line.seq))) : logState.renderedSeq;
    logState.stick = true;
    if (!logState.paused) list.scrollTop = list.scrollHeight;
  }

  function updateLogs(snapshot, force = false) {
    const logs = Array.isArray(snapshot.logs) ? snapshot.logs : [];
    const maxSeq = logs.length ? Number(logs[logs.length - 1].seq) : 0;
    if (maxSeq < logState.renderedSeq - 10) {
      logState.renderedSeq = 0;
      logState.clearSeq = 0;
      force = true;
    }
    logState.all = logs;
    const lines = filteredLogs();
    setText("log-count", `${lines.length}${lines.length !== logs.length ? ` / ${logs.length}` : ""}`);
    $("log-empty").classList.toggle("visible", lines.length === 0);
    if (logState.paused) return;

    const signature = JSON.stringify(logFilter());
    if (force || signature !== logState.signature) {
      logState.signature = signature;
      rebuildLogs(lines);
      return;
    }

    const list = $("log-list");
    const nearBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 48;
    const fresh = lines.filter((line) => Number(line.seq) > logState.renderedSeq);
    if (!fresh.length) return;
    const fragment = document.createDocumentFragment();
    for (const line of fresh) fragment.appendChild(makeLogLine(line));
    list.appendChild(fragment);
    while (list.children.length > 600) list.removeChild(list.firstChild);
    logState.renderedSeq = Math.max(logState.renderedSeq, ...fresh.map((line) => Number(line.seq)));
    if (nearBottom || logState.stick) {
      list.scrollTop = list.scrollHeight;
      logState.stick = true;
    }
  }

  function updateConnection(snapshot) {
    const now = Date.now();
    if (!snapshot) return;
    const age = now - lastMessageAt;
    if (lastMessageAt && age < 5000) setConn("live", "live");
    else if (lastMessageAt && age < 20000) setConn("stale", "stale");
    else setConn("down", "reconnecting");
    const footer = $("footer-release");
    if (footer && snapshot.release) footer.title = `${snapshot.release.submodule || ""}`;
  }

  let lastMessageAt = 0;
  let current = null;

  function setConn(state, text) {
    const el = $("conn");
    if (!el) return;
    el.dataset.state = state;
    setText("conn-text", text);
  }

  function updateReplay(snapshot) {
    const replay = Boolean(snapshot && snapshot.replay);
    const chip = $("chip-replay");
    const banner = $("replay-banner");
    if (chip) chip.hidden = !replay;
    if (banner) banner.hidden = !replay;
  }

  function updateAuthBanner(snapshot) {
    const banner = $("auth-banner");
    const disabled = Boolean(snapshot && snapshot.auth_disabled);
    const replay = Boolean(snapshot && snapshot.replay);
    banner.hidden = !disabled || replay;
    const logout = $("logout-form");
    if (logout) logout.style.display = disabled ? "none" : "";
  }

  function applySnapshot(snapshot) {
    if (!snapshot || typeof snapshot !== "object") return;
    current = snapshot;
    applyRelease(snapshot.release);
    renderStatus(snapshot);
    applyRu(snapshot.ru, snapshot.du);
    applyDu(snapshot.du);
    applyErrors(snapshot.du);
    applyModems(snapshot.modems);
    applyCore(snapshot.core);
    applyHost(snapshot.host, snapshot.stack);
    updateAuthBanner(snapshot);
    updateReplay(snapshot);
    charts.ofh.setData((snapshot.ru || {}).history || []);
    charts.latency.setData(snapshot.du_history || []);
    charts.errors.setData(rollingErrors((snapshot.du || {}).error_series || [], 60));
    const modemHistory = new Map();
    for (const label of ["A", "B"]) {
      for (const point of ((snapshot.modem_history || {})[label] || [])) {
        const ts = Number(point.ts);
        if (!Number.isFinite(ts)) continue;
        const entry = modemHistory.get(ts) || { ts };
        entry[label.toLowerCase()] = point.rsrp_dbm;
        modemHistory.set(ts, entry);
      }
    }
    charts.rsrp.setData([...modemHistory.values()].sort((a, b) => a.ts - b.ts));
    updateLogs(snapshot);
    updateConnection(snapshot);
  }

  function connectEvents() {
    if (!window.EventSource) { setConn("down", "no SSE"); return; }
    let source;
    try {
      source = new EventSource("/api/events");
    } catch (err) {
      setConn("down", "no SSE");
      return;
    }
    source.addEventListener("state", (event) => {
      lastMessageAt = Date.now();
      try {
        applySnapshot(JSON.parse(event.data));
        setConn("live", "live");
      } catch (err) {
        setConn("stale", "bad payload");
      }
    });
    source.onopen = () => {
      lastMessageAt = Date.now();
      setConn("live", "live");
    };
    source.onerror = () => {
      setConn("stale", "reconnecting");
      window.setTimeout(async () => {
        try {
          const response = await fetch("/api/state", { cache: "no-store" });
          if (response.status === 401) window.location.href = "/login";
        } catch (err) {
          /* EventSource will retry. */
        }
      }, 1500);
    };
    window.addEventListener("beforeunload", () => source.close());
  }

  document.addEventListener("DOMContentLoaded", () => {
    renderLegends();
    charts.ofh.refreshColors();
    charts.latency.refreshColors();
    charts.errors.refreshColors();
    charts.rsrp.refreshColors();

    for (const id of ["log-source", "log-level"]) {
      $(id).addEventListener("change", () => updateLogs(current || {}, true));
    }
    $("log-search").addEventListener("input", () => updateLogs(current || {}, true));
    $("log-pause").addEventListener("change", (event) => {
      logState.paused = event.target.checked;
      $("log-list").classList.toggle("paused", logState.paused);
      if (!logState.paused) updateLogs(current || {}, true);
    });
    $("log-clear").addEventListener("click", () => {
      logState.clearSeq = logState.all.length ? Math.max(...logState.all.map((line) => Number(line.seq))) : logState.renderedSeq;
      logState.renderedSeq = logState.clearSeq;
      logState.signature = "";
      $("log-list").textContent = "";
      $("log-empty").classList.add("visible");
      updateLogs(current || {}, true);
    });
    $("log-list").addEventListener("scroll", () => {
      const list = $("log-list");
      logState.stick = list.scrollHeight - list.scrollTop - list.clientHeight < 48;
    });

    const themeButton = $("theme-toggle");
    themeButton.addEventListener("click", () => {
      const next = root.dataset.theme === "light" ? "dark" : "light";
      root.dataset.theme = next;
      window.localStorage.setItem("openru.theme", next);
      renderLegends();
      charts.ofh.refreshColors();
      charts.latency.refreshColors();
      charts.errors.refreshColors();
      charts.rsrp.refreshColors();
    });

    let initial = null;
    try {
      const node = $("bootstrap");
      if (node && node.textContent.trim()) initial = JSON.parse(node.textContent);
    } catch (err) {
      initial = null;
    }
    if (initial) {
      lastMessageAt = 0;
      applySnapshot(initial);
      setConn("stale", "connecting");
    } else {
      setConn("down", "no data");
    }
    connectEvents();
    window.setInterval(() => updateConnection(current), 1000);
  });
})();
