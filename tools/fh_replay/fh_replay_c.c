// SPDX-License-Identifier: AGPL-3.0-or-later
// Timing-critical OFH pcap replayer: pre-built frames, GPS-slot anchor, busy-wait pacing, per-frame send-error stats.
//
// The Python replayer parses the pcap inside the real-time loop; at 100 MHz (b100) that misses the O-DU timing by
// hundreds of microseconds and the RU correctly drops the late DL grids. This sender preloads the frames and paces
// them on a monotonic clock so the send-time error can be measured directly.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/if_packet.h>
#include <math.h>
#include <linux/if_ether.h>
#include <net/if.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define GPS_EPOCH_OFF_NS ((int64_t)(315964800LL - 18LL) * 1000000000LL)
#define OFH_PERIOD 5120
#define SLOTS_PER_FRAME 20
#define SLOT_NS 500000LL
#define STARTUP_MARGIN_SLOTS 100

typedef struct {
  int64_t  t_ns;
  uint32_t len;
  uint8_t  is_uplane;
  uint8_t* data;
} frame_t;

static int64_t now_ns(clockid_t clk) {
  struct timespec ts;
  clock_gettime(clk, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static uint16_t rd16(const uint8_t* p, int be) { return be ? (uint16_t)((p[0] << 8) | p[1]) : (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t* p, int be) {
  return be ? ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]
            : ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0];
}

static int mac_parse(const char* s, uint8_t out[6]) {
  if (!s || !*s) return -1;
  unsigned v[6];
  if (sscanf(s, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6) return -1;
  for (int i = 0; i < 6; ++i) out[i] = (uint8_t)v[i];
  return 0;
}

static int cplane_slot(const uint8_t* b, uint32_t len) {
  uint32_t off = 12;
  if (len >= 16 && b[12] == 0x81 && b[13] == 0x00) off = 16;
  if (len < off + 14 || b[off] != 0xAE || b[off + 1] != 0xFE) return -1;
  uint32_t ecpri = off + 2;
  if (len < ecpri + 12 || b[ecpri + 1] != 2) return -1;  // C-plane
  uint32_t rap = ecpri + 8;
  if (!(b[rap] & 0x80)) return -1;  // downlink
  unsigned sfn = b[rap + 1];
  unsigned subframe = b[rap + 2] >> 4;
  unsigned slot_id = ((b[rap + 2] & 0x0F) << 2) | (b[rap + 3] >> 6);
  if (subframe > 9 || slot_id >= 2) return -1;
  return (int)((sfn * SLOTS_PER_FRAME + subframe * 2 + slot_id) % OFH_PERIOD);
}

static frame_t* frames;
static size_t   nframes, capframes;

static void add_frame(int64_t t_ns, const uint8_t* data, uint32_t len) {
  if (nframes == capframes) {
    capframes = capframes ? capframes * 2 : 65536;
    frames = realloc(frames, capframes * sizeof(*frames));
    if (!frames) { perror("realloc"); exit(1); }
  }
  frame_t* f = &frames[nframes++];
  f->t_ns = t_ns;
  f->len = len;
  f->data = malloc(len);
  if (!f->data) { perror("malloc"); exit(1); }
  memcpy(f->data, data, len);
  f->is_uplane = (len > 15 && data[12] == 0xAE && data[13] == 0xFE && data[15] == 0) ? 1 : 0;
}

static int load_pcapng(FILE* fp, const uint8_t* only_dst) {
  uint8_t hdr[12];
  if (fread(hdr, 1, 12, fp) != 12) return -1;
  int be;
  if (hdr[8] == 0x4D && hdr[9] == 0x3C && hdr[10] == 0x2B && hdr[11] == 0x1A)
    be = 0;
  else if (hdr[8] == 0x1A && hdr[9] == 0x2B && hdr[10] == 0x3C && hdr[11] == 0x4D)
    be = 1;
  else
    return -1;
  uint32_t len = rd32(hdr + 4, be);
  if (len < 28) return -1;
  fseek(fp, (long)(len - 12), SEEK_CUR);
  long long tsresol = 1000000;
  int      if_tsresol_set = 0;
  uint8_t* body = NULL;
  size_t   bodycap = 0;
  for (;;) {
    uint8_t bh[8];
    if (fread(bh, 1, 8, fp) != 8) break;
    uint32_t btype = rd32(bh, be);
    uint32_t blen = rd32(bh + 4, be);
    if (blen < 12) break;
    size_t bodylen = blen - 12;
    if (bodylen > bodycap) { body = realloc(body, bodylen); bodycap = bodylen; }
    if (fread(body, 1, bodylen, fp) != bodylen) break;
    fseek(fp, 4, SEEK_CUR);  // trailing length
    if (btype == 1) {  // IDB
      uint32_t optlen = bodylen > 8 ? bodylen - 8 : 0;
      size_t   i = 8;
      while (i + 4 <= 8 + optlen) {
        uint16_t code = rd16(body + i, be);
        uint16_t olen = rd16(body + i + 2, be);
        if (code == 0) break;
        if (code == 9 && olen >= 1) {
          uint8_t v = body[i + 4];
          tsresol = 1;
          if (v & 0x80) {
            for (int k = 0; k < (v & 0x7F); ++k) tsresol *= 2;
          } else {
            for (int k = 0; k < (v & 0x7F); ++k) tsresol *= 10;
          }
          if_tsresol_set = 1;
        }
        i += 4 + ((olen + 3) & ~3u);
      }
    } else if (btype == 6) {  // EPB
      if (bodylen < 20) continue;
      uint32_t caplen = rd32(body + 12, be);
      if (20 + caplen > bodylen) continue;
      const uint8_t* pkt = body + 20;
      if (only_dst && memcmp(pkt, only_dst, 6) != 0) continue;
      int64_t tsc = ((int64_t)rd32(body + 4, be) << 32) | rd32(body + 8, be);
      int64_t t_ns = (int64_t)((long double)tsc * 1e9L / (long double)tsresol);
      add_frame(t_ns, pkt, caplen);
    } else if (btype == 3) {  // SPB
      if (bodylen < 4) continue;
      uint32_t origlen = rd32(body, be);
      if (only_dst && bodylen >= 10 && memcmp(body + 4, only_dst, 6) != 0) continue;
      add_frame(0, body + 4, origlen < bodylen - 4 ? origlen : (uint32_t)(bodylen - 4));
    }
  }
  (void)if_tsresol_set;
  free(body);
  return 0;
}

static int load_pcap(FILE* fp, const uint8_t* only_dst, uint32_t magic) {
  int be = (magic == 0xD4C3B2A1 || magic == 0x4D3CB2A1);
  int nano = (magic == 0xA1B23C4D || magic == 0x4D3CB2A1);
  if (fseek(fp, 24, SEEK_SET) != 0) return -1;
  for (;;) {
    uint8_t ph[16];
    if (fread(ph, 1, 16, fp) != 16) break;
    uint32_t tsec = rd32(ph, be), tfrac = rd32(ph + 4, be);
    uint32_t incl = rd32(ph + 8, be);
    uint8_t* buf = malloc(incl);
    if (!buf) { perror("malloc"); exit(1); }
    if (fread(buf, 1, incl, fp) != incl) { free(buf); break; }
    if (only_dst && memcmp(buf, only_dst, 6) != 0) { free(buf); continue; }
    int64_t t_ns = (int64_t)tsec * 1000000000LL + (nano ? (int64_t)tfrac : (int64_t)tfrac * 1000LL);
    frame_t f = {.t_ns = t_ns, .len = incl, .data = buf,
                 .is_uplane = (incl > 15 && buf[12] == 0xAE && buf[13] == 0xFE && buf[15] == 0)};
    if (nframes == capframes) {
      capframes = capframes ? capframes * 2 : 65536;
      frames = realloc(frames, capframes * sizeof(*frames));
    }
    frames[nframes++] = f;
  }
  return 0;
}

static int cmp_i64(const void* a, const void* b) {
  int64_t x = *(const int64_t*)a, y = *(const int64_t*)b;
  return (x > y) - (x < y);
}

int main(int argc, char** argv) {
  const char* pcap = NULL, *iface = NULL, *only_dst_s = NULL, *src_s = NULL, *dst_s = NULL, *marker = NULL;
  double rate = 1.0, lead_us = 0.0, uplane_delay_us = 0.0, align_lead_us = 0.0;
  int vlan = -1, report = 0, count = 0, dry = 0, align_set = 0;
  static struct option opts[] = {
      {"pcap", required_argument, 0, 'p'}, {"iface", required_argument, 0, 'i'},
      {"only-dst-mac", required_argument, 0, 'o'}, {"src-mac", required_argument, 0, 's'},
      {"dst-mac", required_argument, 0, 'd'}, {"vlan", required_argument, 0, 'v'},
      {"rate", required_argument, 0, 'r'}, {"lead-us", required_argument, 0, 'l'},
      {"uplane-delay-us", required_argument, 0, 'u'}, {"align-cplane-lead-us", required_argument, 0, 'a'},
      {"start-marker", required_argument, 0, 'm'}, {"report-send-errors", no_argument, 0, 'R'},
      {"count", required_argument, 0, 'c'}, {"dry-run", no_argument, 0, 'n'}, {0, 0, 0, 0}};
  int c;
  while ((c = getopt_long(argc, argv, "", opts, NULL)) != -1) {
    switch (c) {
      case 'p': pcap = optarg; break;
      case 'i': iface = optarg; break;
      case 'o': only_dst_s = optarg; break;
      case 's': src_s = optarg; break;
      case 'd': dst_s = optarg; break;
      case 'v': vlan = atoi(optarg); break;
      case 'r': rate = atof(optarg); break;
      case 'l': lead_us = atof(optarg); break;
      case 'u': uplane_delay_us = atof(optarg); break;
      case 'a': align_lead_us = atof(optarg); align_set = 1; break;
      case 'm': marker = optarg; break;
      case 'R': report = 1; break;
      case 'c': count = atoi(optarg); break;
      case 'n': dry = 1; break;
      default: return 2;
    }
  }
  if (!pcap || !iface || !align_set) {
    fprintf(stderr, "usage: %s --pcap P --iface I --align-cplane-lead-us US [...]\n"
                    "  --align-cplane-lead-us is required (use the RU profile t2a_min_cp_dl via the window JSON)\n",
            argv[0]);
    return 2;
  }

  FILE* fp = fopen(pcap, "rb");
  if (!fp) { perror(pcap); return 2; }
  uint8_t mg[4];
  if (fread(mg, 1, 4, fp) != 4) { fclose(fp); return 2; }
  uint32_t magic_le = (uint32_t)mg[0] | ((uint32_t)mg[1] << 8) | ((uint32_t)mg[2] << 16) | ((uint32_t)mg[3] << 24);
  fseek(fp, 0, SEEK_SET);
  uint8_t only_dst[6];
  int     have_only = only_dst_s && mac_parse(only_dst_s, only_dst) == 0;
  int     rc;
  if (magic_le == 0x0A0D0D0A)
    rc = load_pcapng(fp, have_only ? only_dst : NULL);
  else
    rc = load_pcap(fp, have_only ? only_dst : NULL, magic_le);
  fclose(fp);
  if (rc || !nframes) { fprintf(stderr, "fh_replay_c: no frames\n"); return 2; }

  // Optional MAC/VLAN rewrite in place (the b100 pcap already carries the DU/RU MACs).
  uint8_t src_b[6], dst_b[6];
  int     have_src = src_s && mac_parse(src_s, src_b) == 0;
  int     have_dst = dst_s && mac_parse(dst_s, dst_b) == 0;
  if (have_src || have_dst || vlan >= 0) {
    for (size_t i = 0; i < nframes; ++i) {
      if (have_dst) memcpy(frames[i].data, dst_b, 6);
      if (have_src) memcpy(frames[i].data + 6, src_b, 6);
      if (vlan >= 0 && frames[i].len >= 14 && frames[i].data[12] == 0x81 && frames[i].data[13] == 0x00)
        frames[i].data[14] = (uint8_t)(vlan >> 8), frames[i].data[15] = (uint8_t)vlan;
    }
  }

  int64_t t_first = frames[0].t_ns, cplane_t = 0;
  int     cplane_slot_v = -1;
  for (size_t i = 0; i < nframes; ++i) {
    int s = cplane_slot(frames[i].data, frames[i].len);
    if (s >= 0) { cplane_t = frames[i].t_ns; cplane_slot_v = s; break; }
  }
  if (cplane_slot_v < 0) { fprintf(stderr, "fh_replay_c: no DL C-plane\n"); return 2; }

  int sock = -1;
  if (!dry) {
    sock = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (sock < 0) { perror("socket"); return 2; }
    struct sockaddr_ll sll;
    memset(&sll, 0, sizeof(sll));
    sll.sll_family = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_ifindex = (int)if_nametoindex(iface);
    if (!sll.sll_ifindex) { perror(iface); return 2; }
    if (bind(sock, (struct sockaddr*)&sll, sizeof(sll)) < 0) { perror("bind"); return 2; }
    // The 40/100 MHz slot bursts (~200-460 KiB) overflow the default AF_PACKET sndbuf (~208 KiB) and block the
    // sender for milliseconds; the blocking frames cross the next C-plane and the RU mislabels them. Enlarge it.
    int sndbuf = 8 * 1024 * 1024;
    if (setsockopt(sock, SOL_SOCKET, 32 /* SO_SNDBUFFORCE */, &sndbuf, sizeof(sndbuf)) < 0) {
      setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    }
  }

  int64_t now_rt = now_ns(CLOCK_REALTIME);
  int64_t now_mono = now_ns(CLOCK_MONOTONIC);
  int64_t now_gps = now_rt - GPS_EPOCH_OFF_NS;
  int64_t now_slot = now_gps / SLOT_NS;
  int64_t delta = (cplane_slot_v - (now_slot % OFH_PERIOD) + OFH_PERIOD) % OFH_PERIOD;
  if (delta < STARTUP_MARGIN_SLOTS) delta += OFH_PERIOD;
  int64_t air_rt = (now_slot + delta) * SLOT_NS + GPS_EPOCH_OFF_NS;
  int64_t cplane_rt = air_rt - (int64_t)llround(align_lead_us * 1000.0);
  int64_t cplane_mono = now_mono + (cplane_rt - now_rt);
  int64_t t0_mono = cplane_mono - (int64_t)llround((double)(cplane_t - t_first) / rate);
  int64_t lead_ns = (int64_t)llround(lead_us * 1000.0);
  int64_t up_ns = (int64_t)llround(uplane_delay_us * 1000.0);

  int64_t* errs = report ? malloc(nframes * sizeof(int64_t)) : NULL;
  size_t   ne = 0, sent = 0;
  for (size_t i = 0; i < nframes; ++i) {
    if (count && sent >= (size_t)count) break;
    frame_t* f = &frames[i];
    int64_t target = t0_mono + (int64_t)llround((double)(f->t_ns - t_first) / rate) - lead_ns;
    if (up_ns && f->is_uplane) target += up_ns;
    for (;;) {
      int64_t t = now_ns(CLOCK_MONOTONIC);
      if (t >= target) break;
    }
    if (marker && sent == 0) {
      int fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (fd >= 0) close(fd);
    }
    if (sock >= 0) {
      ssize_t w = send(sock, f->data, f->len, 0);
      if (w < 0) { perror("send"); return 2; }
    }
    if (errs) errs[ne++] = now_ns(CLOCK_MONOTONIC) - target;
    ++sent;
  }
  if (sock >= 0) close(sock);

  if (errs && ne) {
    qsort(errs, ne, sizeof(int64_t), cmp_i64);
    size_t p50 = (size_t)(0.50 * (ne - 1)), p90 = (size_t)(0.90 * (ne - 1)), p99 = (size_t)(0.99 * (ne - 1));
    size_t late200 = 0, late500 = 0, late1ms = 0;
    for (size_t i = 0; i < ne; ++i) {
      if (errs[i] > 200000) ++late200;
      if (errs[i] > 500000) ++late500;
      if (errs[i] > 1000000) ++late1ms;
    }
    printf("fh_replay_c: send_error_us n=%zu min=%.1f p50=%.1f p90=%.1f p99=%.1f max=%.1f late>200us=%zu late>500us=%zu late>1ms=%zu\n",
           ne, errs[0] / 1e3, errs[p50] / 1e3, errs[p90] / 1e3, errs[p99] / 1e3, errs[ne - 1] / 1e3,
           late200, late500, late1ms);
  }
  printf("fh_replay_c: sent=%zu pcap=%s iface=%s rate=%g lead_us=%g align_slot=%d align_lead_us=%g\n",
         sent, pcap, iface, rate, lead_us, cplane_slot_v, align_lead_us);
  return 0;
}
