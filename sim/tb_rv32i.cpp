#include <verilated.h>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "Vrv32i_core.h"

#if VM_TRACE
#include <verilated_vcd_c.h>
#endif

namespace {

constexpr uint32_t kExitAddr = 0xfffffff0u;
constexpr size_t kMemBytes = 256 * 1024;

struct Args {
    std::string program;
    std::string trace_path = "build/waves/rv32i_core.vcd";
    uint64_t max_cycles = 1000;
    bool trace = false;
};

bool starts_with(const std::string &value, const std::string &prefix) {
    return value.rfind(prefix, 0) == 0;
}

Args parse_args(int argc, char **argv) {
    Args args;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (starts_with(arg, "+program=")) {
            args.program = arg.substr(std::string("+program=").size());
        } else if (starts_with(arg, "+max-cycles=")) {
            args.max_cycles = std::stoull(arg.substr(std::string("+max-cycles=").size()));
        } else if (arg == "+trace") {
            args.trace = true;
        } else if (starts_with(arg, "+trace=")) {
            args.trace = true;
            args.trace_path = arg.substr(std::string("+trace=").size());
        }
    }
    if (args.program.empty()) {
        throw std::runtime_error("missing +program=<hex file>");
    }
    return args;
}

std::string strip_hex_line(std::string line) {
    const auto comment = line.find_first_of("#;");
    if (comment != std::string::npos) {
        line.resize(comment);
    }
    const auto first = line.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        return "";
    }
    const auto last = line.find_last_not_of(" \t\r\n");
    return line.substr(first, last - first + 1);
}

std::vector<uint32_t> load_hex(const std::string &path) {
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("cannot open program hex: " + path);
    }

    std::vector<uint32_t> words;
    std::string line;
    size_t lineno = 0;
    while (std::getline(input, line)) {
        ++lineno;
        line = strip_hex_line(line);
        if (line.empty()) {
            continue;
        }
        try {
            words.push_back(static_cast<uint32_t>(std::stoul(line, nullptr, 16)));
        } catch (const std::exception &) {
            std::ostringstream oss;
            oss << path << ":" << lineno << ": invalid hex word '" << line << "'";
            throw std::runtime_error(oss.str());
        }
    }
    if (words.empty()) {
        throw std::runtime_error("program hex is empty: " + path);
    }
    return words;
}

class Memory {
  public:
    explicit Memory(size_t bytes) : bytes_(bytes, 0) {}

    uint32_t read_word(uint32_t addr) const {
        const uint32_t base = addr & ~uint32_t{3};
        if (base + 3 >= bytes_.size()) {
            return 0;
        }
        return uint32_t{bytes_[base]} | (uint32_t{bytes_[base + 1]} << 8) |
               (uint32_t{bytes_[base + 2]} << 16) | (uint32_t{bytes_[base + 3]} << 24);
    }

    uint64_t read_dword(uint32_t addr) const {
        return uint64_t{read_word(addr)} | (uint64_t{read_word(addr + 4)} << 32);
    }

    bool write_word(uint32_t addr, uint32_t data, uint8_t strobe) {
        const uint32_t base = addr & ~uint32_t{3};
        if (base + 3 >= bytes_.size()) {
            return false;
        }
        for (int lane = 0; lane < 4; ++lane) {
            if (strobe & (uint8_t{1} << lane)) {
                bytes_[base + lane] = static_cast<uint8_t>((data >> (lane * 8)) & 0xffu);
            }
        }
        return true;
    }

  private:
    std::vector<uint8_t> bytes_;
};

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    Args args;
    try {
        args = parse_args(argc, argv);
    } catch (const std::exception &exc) {
        std::cerr << "tb_rv32i: " << exc.what() << "\n";
        return 2;
    }

    std::vector<uint32_t> imem;
    try {
        imem = load_hex(args.program);
    } catch (const std::exception &exc) {
        std::cerr << "tb_rv32i: " << exc.what() << "\n";
        return 2;
    }

    Memory mem(kMemBytes);
    for (size_t i = 0; i < imem.size(); ++i) {
        mem.write_word(static_cast<uint32_t>(i * 4), imem[i], 0xF);
    }
    Vrv32i_core top;
    vluint64_t sim_time = 0;

#if VM_TRACE
    VerilatedVcdC *trace = nullptr;
    if (args.trace) {
        Verilated::traceEverOn(true);
        trace = new VerilatedVcdC;
        top.trace(trace, 99);
        trace->open(args.trace_path.c_str());
    }
#else
    void *trace = nullptr;
    if (args.trace) {
        std::cerr << "tb_rv32i: binary was built without trace support\n";
    }
#endif

    auto dump = [&]() {
#if VM_TRACE
        if (trace != nullptr) {
            trace->dump(sim_time);
        }
#endif
        ++sim_time;
    };

    auto settle = [&]() {
        top.imem_rdata_i = mem.read_dword(top.imem_addr_o);
        top.dmem_rdata_i = mem.read_word(top.dmem_addr_o);
        top.eval();
        top.imem_rdata_i = mem.read_dword(top.imem_addr_o);
        top.dmem_rdata_i = mem.read_word(top.dmem_addr_o);
        top.eval();
    };

    top.clk = 0;
    top.rst_n = 0;
    top.imem_rdata_i = 0;
    top.dmem_rdata_i = 0;

    for (int i = 0; i < 2; ++i) {
        settle();
        dump();
        top.clk = 1;
        top.eval();
        dump();
        top.clk = 0;
        top.eval();
        dump();
    }
    top.rst_n = 1;

    bool exit_seen = false;
    uint32_t exit_code = 0;
    std::string fail_reason;
    uint64_t cycle = 0;

    for (; cycle < args.max_cycles && !Verilated::gotFinish(); ++cycle) {
        settle();

        if (top.dmem_wstrb_o != 0) {
            const uint32_t addr = top.dmem_addr_o;
            const uint32_t data = top.dmem_wdata_o;
            const uint8_t strobe = static_cast<uint8_t>(top.dmem_wstrb_o);

            if ((addr & ~uint32_t{3}) == kExitAddr) {
                exit_seen = true;
                exit_code = data;
            } else {
                mem.write_word(addr, data, strobe);
            }
        }

        top.clk = 1;
        top.eval();
        dump();
        top.clk = 0;
        top.eval();
        dump();

        if (!fail_reason.empty()) {
            break;
        }
        if (top.trap_o) {
            std::ostringstream oss;
            oss << "core trap pc=0x" << std::hex << std::setw(8) << std::setfill('0') << top.pc_o;
            fail_reason = oss.str();
            break;
        }
        if (exit_seen) {
            break;
        }
        if (top.halt_o) {
            if (!exit_seen)
                fail_reason = "halted before writing exit code";
            break;
        }
    }

#if VM_TRACE
    if (trace != nullptr) {
        trace->close();
        delete trace;
    }
#endif

    if (cycle >= args.max_cycles && !exit_seen && fail_reason.empty()) {
        fail_reason = "max cycles reached";
    }

    if (exit_seen && exit_code == 1 && fail_reason.empty()) {
        std::cout << "RESULT pass program=" << args.program << " cycles=" << (cycle + 1)
                  << " exit_code=" << exit_code << "\n";
        return 0;
    }

    std::cout << "RESULT fail program=" << args.program << " cycles=" << (cycle + 1);
    if (exit_seen) {
        std::cout << " exit_code=" << exit_code;
    }
    if (!fail_reason.empty()) {
        std::cout << " reason=\"" << fail_reason << "\"";
    }
    std::cout << "\n";
    return 1;
}
