// Read the N310 reference-lock sensor through the UHD API.
//
//   uhd_ref_check <device_args>   # exit 0 locked, 1 unlocked, 2 error
//   uhd_ref_check --self-test     # no radio; checks the real sensor formats
//
// The sensor value string for this board is "locked"/"unlocked" (the boolean
// unit pair), not "true"/"false". uhd_usrp_probe may also print only sensor
// names, so text parsing is not reliable.
#include <uhd/types/sensors.hpp>
#include <uhd/usrp/multi_usrp.hpp>

#include <iostream>
#include <string>

static int self_test()
{
    int errors = 0;

    uhd::sensor_value_t locked("ref_locked", true, "locked", "unlocked");
    uhd::sensor_value_t unlocked("ref_locked", false, "locked", "unlocked");

    if (!locked.to_bool()) {
        std::cerr << "self-test: locked.to_bool() returned false\n";
        ++errors;
    }
    if (unlocked.to_bool()) {
        std::cerr << "self-test: unlocked.to_bool() returned true\n";
        ++errors;
    }
    if (locked.to_pp_string().find(": locked") == std::string::npos) {
        std::cerr << "self-test: locked.pp='" << locked.to_pp_string() << "'\n";
        ++errors;
    }
    if (unlocked.to_pp_string().find(": unlocked") == std::string::npos) {
        std::cerr << "self-test: unlocked.pp='" << unlocked.to_pp_string() << "'\n";
        ++errors;
    }

    std::cout << "locked  : " << locked.to_pp_string() << "\n";
    std::cout << "unlocked: " << unlocked.to_pp_string() << "\n";
    std::cout << "uhd_ref_check self-test: " << (errors == 0 ? "PASS" : "FAIL") << "\n";
    return errors == 0 ? 0 : 1;
}

int main(int argc, char** argv)
{
    if (argc == 2 && std::string(argv[1]) == "--self-test") {
        return self_test();
    }
    if (argc != 2) {
        std::cerr << "usage: " << argv[0] << " <device_args>\n"
                  << "       " << argv[0] << " --self-test\n";
        return 2;
    }

    try {
        auto usrp = uhd::usrp::multi_usrp::make(argv[1]);
        auto sensor = usrp->get_mboard_sensor("ref_locked");
        const bool locked = sensor.to_bool();
        std::cout << sensor.to_pp_string() << "\n";
        std::cout << "ref_locked=" << (locked ? "locked" : "unlocked") << "\n";
        return locked ? 0 : 1;
    } catch (const std::exception& e) {
        std::cerr << "uhd_ref_check: " << e.what() << "\n";
        return 2;
    }
}
