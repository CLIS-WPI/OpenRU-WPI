// uhd_one_tone: one-channel CW tone for bench port identification (received on HackRFs, receive-only).
//   uhd_one_tone <device-args> <channel 0..3> <tx_gain_dB <=30> <seconds <=10>
// LO 3420.48 MHz, tone +1.000 MHz (3421.48 MHz), TX/RX port, internal clock/time.
// Hard limits are enforced here, not only by the caller. Sends one bounded burst and exits.
#include <uhd/usrp/multi_usrp.hpp>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>
#include <exception>

static int run(int argc, char** argv)
{
  if (argc != 5) {
    std::fprintf(stderr, "usage: uhd_one_tone <args> <channel 0..3> <gain<=30> <seconds<=10>\n");
    return 2;
  }
  const std::string args = argv[1];
  const int         ch   = std::atoi(argv[2]);
  const double      gain = std::atof(argv[3]);
  const double      secs = std::atof(argv[4]);
  if (ch < 0 || ch > 3 || gain < 0 || gain > 30.0 || secs <= 0 || secs > 10.0) {
    std::fprintf(stderr, "refused: channel must be 0..3, gain 0..30 dB, seconds 0..10\n");
    return 2;
  }
  const double lo = 3420.48e6, offset = 1.0e6, rate = 7.68e6, ampl = 0.3;

  auto usrp = uhd::usrp::multi_usrp::make(args + ",clock_source=internal,time_source=internal,master_clock_rate=122.88e6");
  usrp->set_tx_rate(rate, ch);
  usrp->set_tx_antenna("TX/RX", ch);
  usrp->set_tx_gain(gain, ch);
  usrp->set_tx_freq(uhd::tune_request_t(lo), ch);
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  const double g_rb = usrp->get_tx_gain(ch), f_rb = usrp->get_tx_freq(ch), r_rb = usrp->get_tx_rate(ch);
  std::printf("tone: ch=%d lo=%.3f MHz tone=%.3f MHz gain=%.1f dB rate=%.3f Msps ant=%s secs=%.1f\n", ch, f_rb / 1e6,
              (f_rb + offset) / 1e6, g_rb, r_rb / 1e6, usrp->get_tx_antenna(ch).c_str(), secs);
  if (g_rb > 30.0 + 1e-6) {
    std::fprintf(stderr, "refused: readback gain %.1f > 30\n", g_rb);
    return 3;
  }

  uhd::stream_args_t sa("fc32", "sc16");
  sa.channels = {static_cast<size_t>(ch)};
  auto tx = usrp->get_tx_stream(sa);

  const size_t spb = tx->get_max_num_samps();
  std::vector<std::complex<float>> buf(spb);
  const size_t total = static_cast<size_t>(secs * r_rb);
  double       ph = 0, dph = 2 * M_PI * offset / r_rb;
  uhd::tx_metadata_t md;
  md.start_of_burst = true;
  md.has_time_spec  = false;
  size_t sent       = 0;
  while (sent < total) {
    const size_t n = std::min(spb, total - sent);
    for (size_t i = 0; i < n; ++i, ph += dph) {
      buf[i] = std::complex<float>(ampl * std::cos(ph), ampl * std::sin(ph));
    }
    ph = std::fmod(ph, 2 * M_PI);
    md.end_of_burst = (sent + n == total);
    sent += tx->send(&buf.front(), n, md, 1.0);
    if (md.start_of_burst) {
      std::printf("tone: streaming\n");  // first buffer accepted: the tone is on air from here
      std::fflush(stdout);
    }
    md.start_of_burst = false;
  }
  if (!md.end_of_burst) {
    md.end_of_burst = true;
    tx->send("", 0, md);
  }
  std::printf("tone: done, %zu samples (%.2f s)\n", sent, sent / r_rb);
  return 0;
}

int main(int argc, char** argv)
{
  try {
    return run(argc, argv);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "tone: ERROR %s\n", e.what());
    return 4;
  }
}
