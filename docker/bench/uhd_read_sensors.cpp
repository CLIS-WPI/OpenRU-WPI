// uhd_read_sensors: read-only UHD sensor dump: no tuning, no gain, no streaming.
//   uhd_read_sensors <device-args>
#include <uhd/usrp/multi_usrp.hpp>
#include <cstdio>
#include <exception>
#include <string>

static void dump_info(const char* what, const uhd::dict<std::string, std::string>& d)
{
  for (const auto& k : d.keys()) {
    std::printf("  %s %s = %s\n", what, k.c_str(), d[k].c_str());
  }
}

int main(int argc, char** argv)
{
  if (argc != 2) {
    std::fprintf(stderr, "usage: uhd_read_sensors <args>\n");
    return 2;
  }
  try {
    auto usrp = uhd::usrp::multi_usrp::make(std::string(argv[1]));
    std::printf("mboard: %s\n", usrp->get_mboard_name(0).c_str());
    for (const auto& s : usrp->get_mboard_sensor_names(0)) {
      try {
        std::printf("  mboard sensor %s = %s\n", s.c_str(), usrp->get_mboard_sensor(s, 0).to_pp_string().c_str());
      } catch (const std::exception& e) {
        std::printf("  mboard sensor %s = <error %s>\n", s.c_str(), e.what());
      }
    }
    for (size_t ch = 0; ch < usrp->get_tx_num_channels(); ++ch) {
      std::printf("TX channel %zu: subdev %s antennas", ch, usrp->get_tx_subdev_name(ch).c_str());
      for (const auto& a : usrp->get_tx_antennas(ch)) {
        std::printf(" %s", a.c_str());
      }
      std::printf("\n");
      dump_info("tx_info", usrp->get_usrp_tx_info(ch));
      for (const auto& s : usrp->get_tx_sensor_names(ch)) {
        try {
          std::printf("  tx sensor %s = %s\n", s.c_str(), usrp->get_tx_sensor(s, ch).to_pp_string().c_str());
        } catch (const std::exception& e) {
          std::printf("  tx sensor %s = <error %s>\n", s.c_str(), e.what());
        }
      }
    }
    for (size_t ch = 0; ch < usrp->get_rx_num_channels(); ++ch) {
      std::printf("RX channel %zu: subdev %s\n", ch, usrp->get_rx_subdev_name(ch).c_str());
      for (const auto& s : usrp->get_rx_sensor_names(ch)) {
        try {
          std::printf("  rx sensor %s = %s\n", s.c_str(), usrp->get_rx_sensor(s, ch).to_pp_string().c_str());
        } catch (const std::exception& e) {
          std::printf("  rx sensor %s = <error %s>\n", s.c_str(), e.what());
        }
      }
    }
  } catch (const std::exception& e) {
    std::fprintf(stderr, "uhd_read_sensors: ERROR %s\n", e.what());
    return 4;
  }
  return 0;
}
