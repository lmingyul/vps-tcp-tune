"""TCP tuning and generated PTM automation, using disposable files and command stubs."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "net-tcp-tune.sh").read_text()


def function(name, source=SOURCE):
    return re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", source, re.M | re.S)[0]


class TcpTuningTests(unittest.TestCase):
    def run_bash(self, code, **env):
        environment = dict(os.environ, **env)
        environment.pop("BASH_ENV", None)
        return subprocess.run(["bash", "--noprofile", "--norc", "-c", code],
                              env=environment, capture_output=True, text=True, timeout=10)

    def test_tcp_memory_ratios_use_actual_page_size_including_small_machines(self):
        for memory in (64, 958, 1964):
            for page_size in (4096, 16384, 65536):
                with self.subTest(memory=memory, page_size=page_size):
                    result = self.run_bash(function("calculate_tcp_mem") + r'''
getconf() { printf '%s\n' "$TEST_PAGE_SIZE"; }
calculate_tcp_mem "$TEST_MEMORY"
''', TEST_PAGE_SIZE=str(page_size), TEST_MEMORY=str(memory))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    pages = [int(value) for value in result.stdout.split()]
                    self.assertEqual(len(pages), 3)
                    for count, divisor in zip(pages, (16, 8, 4)):
                        self.assertLessEqual(count * page_size, memory * 1048576 / divisor)
                        self.assertLess(memory * 1048576 / divisor - count * page_size, page_size)

    def generate_automation(self, root):
        generator = SOURCE.split("ptm_install_cron() {", 1)[1].split("\nptm_remove_cron()", 1)[0]
        code = "ptm_install_cron() {" + generator + r'''
crontab() { [ "$1" != -l ]; }
systemctl() { :; }
snell_bj_to_local_time() { printf '%s %s\n' "$1" "$2"; }
ptm_install_cron
'''
        variables = {name: str(root / name) for name in (
            "PTM_DAILY_SCRIPT", "PTM_RESET_SCRIPT", "PTM_BOOT_RESTORE_SCRIPT",
            "PTM_BOOT_RESTORE_SERVICE", "PTM_CONFIG_FILE", "PTM_CONFIG_DIR",
            "PTM_RESET_HISTORY_LOG", "PTM_NOTIFICATION_LOG", "PTM_TRAFFIC_SNAPSHOT")}
        result = self.run_bash(code, **variables)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in ("PTM_DAILY_SCRIPT", "PTM_RESET_SCRIPT", "PTM_BOOT_RESTORE_SCRIPT"):
            path = root / name
            self.assertTrue(path.stat().st_size)
            result = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        return (root / "PTM_DAILY_SCRIPT").read_text()

    def test_daily_cleanup_removes_only_own_empty_htb_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            daily = self.generate_automation(root)
            for queue, classes, should_remove in (
                ("htb 1:", "class htb 1:1 root rate 1Gbit", True),
                ("htb 1:", "class htb 1:1 root rate 1Gbit\nclass htb 1:1010 parent 1:1 rate 10Mbit", False),
                ("htb 2:", "class htb 2:1 root rate 1Gbit", False),
                ("cake 1:", "", False),
            ):
                with self.subTest(queue=queue, classes=classes):
                    calls = root / "calls"
                    calls.write_text("")
                    result = self.run_bash(function("cleanup_expired", daily) + r'''
log() { :; }
jq() { :; }
nft() { :; }
ip() { printf 'default via 192.0.2.1 dev eth0\n'; }
update_json() { :; }
group_ports() { :; }
tc() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$1 $2" in
        'qdisc show') printf 'qdisc %s root default 30\n' "$TEST_QUEUE" ;;
        'class show') printf '%s\n' "$TEST_CLASSES" ;;
    esac
}
cleanup_expired 8881
''', CALLS=str(calls), TEST_QUEUE=queue, TEST_CLASSES=classes)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual("qdisc del dev eth0 root\n" in calls.read_text(), should_remove)

    def test_ptm_menu_can_refresh_existing_automation_without_adding_port(self):
        result = self.run_bash(function("ptm_menu") + r'''
ptm_init_config() { :; }
clear() { :; }
ptm_get_active_ports() { printf '8881\n'; }
ptm_get_daily_total_traffic() { printf '0\n'; }
ptm_format_bytes() { printf '0 B\n'; }
ptm_render_port_table() { :; }
ptm_install_cron() { printf 'AUTOMATION_REFRESHED\n'; }
break_end() { :; }
sleep() { exit 93; }
ptm_menu <<'INPUT'
6
0
INPUT
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("AUTOMATION_REFRESHED"), 1)


if __name__ == "__main__":
    unittest.main()
