"""Fork contracts using extracted functions and disposable files only."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "net-tcp-tune.sh").read_text()
BASH = shutil.which("bash")


def function(name, source=SCRIPT):
    return re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", source, re.M | re.S)[0]


class TemporaryShellTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.calls = self.root / "calls"

    def run_bash(self, code, **env):
        environment = dict(os.environ, CALLS=str(self.calls), **env)
        environment.pop("BASH_ENV", None)
        return subprocess.run([BASH, "--noprofile", "--norc", "-c", code],
                              env=environment, text=True, capture_output=True, timeout=10)


class ForkDownloadTests(TemporaryShellTests):
    def project_urls(self, filename):
        urls = re.findall(r"https://raw\.githubusercontent\.com/([^/\s]+)/vps-tcp-tune/([^\s\"')]+)",
                          (ROOT / filename).read_text())
        self.assertTrue(urls, filename)
        for owner, path in urls:
            self.assertEqual(owner, "lmingyul", filename)
            self.assertTrue(path.startswith("refs/heads/main/"), (filename, path))
        return urls

    def test_readme_downloads_use_fork_and_keep_curl_config_guard(self):
        urls = self.project_urls("README.md")
        filenames = {path.split("?")[0].rsplit("/", 1)[1] for _, path in urls}
        self.assertTrue({"install-alias.sh", "net-tcp-tune.sh"} <= filenames)
        for line in (ROOT / "README.md").read_text().splitlines():
            if "curl " in line and "/vps-tcp-tune/" in line:
                self.assertRegex(line, r"curl\s+-q\s+-fsSL\b")

    def test_alias_download_uses_fork_and_keeps_curl_config_guard(self):
        self.project_urls("install-alias.sh")
        source = (ROOT / "install-alias.sh").read_text()
        harness = function("append_alias_block", source) + r'''
date() { echo unexpected-date >> "$CALLS"; echo already-expanded; }
append_alias_block > "$FIXTURE_RC"
source "$FIXTURE_RC"
alias bbr
'''
        result = self.run_bash(harness, FIXTURE_RC=str(self.root / "shellrc"))
        self.assertEqual(result.returncode, 0, result.stderr)
        alias = result.stdout
        self.assertRegex(alias, r"curl\s+-q\s+-fsSL\b")
        self.assertIn("https://raw.githubusercontent.com/lmingyul/vps-tcp-tune/refs/heads/main/net-tcp-tune.sh", alias)
        self.assertIn("$(date +%s)", alias)
        self.assertFalse(self.calls.exists(), "Timestamp must expand when using the alias, not when installing it")

    def test_patch_example_uses_fork(self):
        self.project_urls("snell-upgrade-patch.sh")


class ClearTests(TemporaryShellTests):
    def check_clear(self, *, term, infocmp_rc=0, clear_rc=0):
        bindir = self.root / "bin"
        bindir.mkdir()
        if infocmp_rc is not None:
            info = bindir / "infocmp"
            info.write_text("#!/bin/sh\nprintf 'infocmp:%s\\n' \"$1\" >> \"$CALLS\"\n"
                            "echo terminfo-warning >&2\nexit \"$INFOCMP_RC\"\n")
            info.chmod(0o755)
        clear = bindir / "clear"
        clear.write_text("#!/bin/sh\nprintf 'clear:%s:%s\\n' \"$TERM\" \"$*\" >> \"$CALLS\"\n"
                         "echo clear-warning >&2\n[ \"$CLEAR_RC\" -eq 0 ] || exit \"$CLEAR_RC\"\n"
                         "printf 'clear-output\\n'\n")
        clear.chmod(0o755)
        result = self.run_bash(function("clear") + '\nclear --test\nprintf "after:%s\\n" "$TERM" >> "$CALLS"',
                               PATH=str(bindir), TERM=term, INFOCMP_RC=str(infocmp_rc), CLEAR_RC=str(clear_rc))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn(f"after:{term}\n", self.calls.read_text())
        self.assertEqual(result.stdout, "clear-output\n" if clear_rc == 0 else "\x1b[H\x1b[2J")
        return self.calls.read_text()

    def test_supported_term_is_forwarded_without_changing_caller(self):
        self.assertIn("clear:screen-256color:--test\n", self.check_clear(term="screen-256color"))

    def test_missing_ghostty_terminfo_uses_xterm(self):
        calls = self.check_clear(term="xterm-ghostty", infocmp_rc=1)
        self.assertIn("infocmp:xterm-ghostty\n", calls)
        self.assertIn("clear:xterm-256color:--test\n", calls)

    def test_missing_infocmp_uses_xterm(self):
        self.assertIn("clear:xterm-256color:--test\n", self.check_clear(term="xterm-ghostty", infocmp_rc=None))

    def test_external_clear_failure_emits_ansi_fallback(self):
        self.check_clear(term="xterm-ghostty", infocmp_rc=1, clear_rc=9)


class OneClickLogTests(TemporaryShellTests):
    def run_stage_one(self, install_rc, *, tee=True):
        log = self.root / "install.log"
        log.write_text("existing-log\n")
        harness = function("one_click_optimize") + r'''
clear() { :; }
uname() { printf '6.1.0-stock\n'; }
date() { printf '2026-10-17 00:00:00\n'; }
install_xanmod_kernel() {
    printf 'kernel-install-stdout\n'
    printf 'kernel-install-stderr\n' >&2
    return "$INSTALL_RC"
}
server_reboot() { printf 'reboot\n' >> "$CALLS"; }
check_bbr_status() { printf 'status\n' >> "$CALLS"; }
break_end() { printf 'pause\n' >> "$CALLS"; }
'''
        if not tee:
            harness += r'''
command() {
    if [ "$1" = -v ] && [ "$2" = tee ]; then return 1; fi
    builtin command "$@"
}
'''
        result = self.run_bash(harness + "\none_click_optimize", INSTALL_RC=str(install_rc), LOG_FILE=str(log))
        self.assertEqual(result.returncode, install_rc, result.stdout + result.stderr)
        self.assertIn("kernel-install-stdout\n", result.stdout)
        self.assertIn("kernel-install-stderr\n", result.stdout if tee else result.stderr)
        calls = self.calls.read_text()
        if install_rc:
            self.assertNotIn("reboot", calls)
            self.assertIn("status\npause\n", calls)
            self.assertIn("阶段 1 失败", result.stdout)
        else:
            self.assertEqual(calls, "reboot\n")
        self.assertTrue(log.read_text().startswith("existing-log\n"))
        self.assertIn("one_click_optimize stage1 install kernel", log.read_text())
        return result, log.read_text()

    def test_success_appends_stdout_and_stderr_before_reboot(self):
        result, log = self.run_stage_one(0)
        self.assertEqual(result.stderr, "")
        self.assertIn("kernel-install-stdout\nkernel-install-stderr\n", log)

    def test_failure_logs_both_streams_preserves_status_and_skips_reboot(self):
        result, log = self.run_stage_one(37)
        self.assertEqual(result.stderr, "")
        self.assertIn("kernel-install-stdout\nkernel-install-stderr\n", log)

    def test_missing_tee_preserves_success_output(self):
        self.run_stage_one(0, tee=False)

    def test_missing_tee_preserves_failure_output_and_status_without_reboot(self):
        self.run_stage_one(37, tee=False)


class XanmodPackageTests(TemporaryShellTests):
    def select(self, version, available, expected):
        harness = function("xanmod_select_kernel_package") + r'''
apt-cache() {
    case " $AVAILABLE_PACKAGES " in
        *" $2 "*) return 0;;
        *) return 100;;
    esac
}
'''
        result = self.run_bash(harness + "\nxanmod_select_kernel_package " + shlex.quote(str(version)),
                               AVAILABLE_PACKAGES=" ".join(available))
        self.assertEqual(result.returncode, 0 if expected else 1, result.stderr)
        self.assertEqual(result.stdout, expected + "\n" if expected else "")

    def test_same_level_main_is_preferred(self):
        for version in (2, 3):
            with self.subTest(version=version):
                main = f"linux-xanmod-x64v{version}"
                self.select(version, [main, f"linux-xanmod-lts-x64v{version}", "linux-xanmod-lts-x64v1"], main)

    def test_same_level_lts_is_used_when_main_is_missing(self):
        for version in (1, 2, 3):
            with self.subTest(version=version):
                lts = f"linux-xanmod-lts-x64v{version}"
                self.select(version, [lts, "linux-xanmod-lts-x64v1"], lts)

    def test_v3_falls_back_to_lts_v2_before_lts_v1(self):
        self.select(3, ["linux-xanmod-lts-x64v1", "linux-xanmod-lts-x64v2"], "linux-xanmod-lts-x64v2")

    def test_v2_and_v3_can_fall_back_to_lts_v1(self):
        for version in (2, 3):
            with self.subTest(version=version):
                self.select(version, ["linux-xanmod-x64v2", "linux-xanmod-lts-x64v1"] if version == 3
                            else ["linux-xanmod-lts-x64v1"], "linux-xanmod-lts-x64v1")

    def test_v4_uses_v3_main_or_lts(self):
        for package in ("linux-xanmod-x64v3", "linux-xanmod-lts-x64v3", "linux-xanmod-lts-x64v2"):
            with self.subTest(package=package):
                self.select(4, ["linux-xanmod-x64v4", package], package)

    def test_no_available_package_returns_failure(self):
        for version in (1, 2, 3, 4):
            with self.subTest(version=version):
                self.select(version, [], None)


# PERSIST_SERVICE fixture published by the fork at f579a07; never executed.
LEGACY_DNS_UNIT = """[Unit]
Description=DNS Purify - Restore DNS Configuration on Boot
Documentation=https://github.com/lmingyul/vps-tcp-tune
After=systemd-resolved.service network-online.target
Wants=network-online.target
Wants=systemd-resolved.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/dns-purify-apply.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
"""


class LegacyDnsOwnershipTests(TemporaryShellTests):
    def matches(self, content):
        unit = self.root / "legacy.service"
        unit.write_text(content)
        return self.run_bash(function("boot_recovery_legacy_dns_unit_matches") +
                             "\nboot_recovery_legacy_dns_unit_matches " + shlex.quote(str(unit)))

    def test_exact_fork_and_upstream_units_are_accepted(self):
        for owner in ("lmingyul", "Eric86777"):
            with self.subTest(owner=owner):
                result = self.matches(LEGACY_DNS_UNIT.replace("lmingyul", owner))
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_third_party_documentation_and_custom_fields_are_refused(self):
        variants = [LEGACY_DNS_UNIT.replace("lmingyul", "third-party"),
                    LEGACY_DNS_UNIT.replace("RemainAfterExit=yes", "RemainAfterExit=yes\nEnvironment=KEEP_ME=1")]
        for content in variants:
            with self.subTest(content=content):
                self.assertNotEqual(self.matches(content).returncode, 0)


if __name__ == "__main__":
    unittest.main()
