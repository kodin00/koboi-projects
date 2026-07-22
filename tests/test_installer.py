"""quickstart installer regression pack (Layer-1, no Docker).

Guards the proven installer bugs so they can't return: the `--project`-no-value
hang (P0-1), dead `--no-color`/`--no-utf8` flags (P0-3), `--yes`-without-`--project`,
and the `bash -n` + shellcheck syntax gates. Runs the script's own subcommands
(`--list`) so the assertions exercise real code paths.
"""
from __future__ import annotations

import os
import shlex
import shutil
import subprocess

import pytest

from conftest import REPO_ROOT

QS = REPO_ROOT / "quickstart.sh"
PS1 = REPO_ROOT / "quickstart.ps1"


def _run(args, env=None, timeout=15):
    e = os.environ.copy()
    if env:
        e.update(env)
    return subprocess.run(["bash", str(QS), *args], capture_output=True, text=True,
                          env=e, timeout=timeout, cwd=str(REPO_ROOT))


def test_bash_syntax_clean():
    r = subprocess.run(["bash", "-n", str(QS)], capture_output=True, text=True)
    assert r.returncode == 0, f"bash -n failed:\n{r.stderr}"


def test_shellcheck_clean_if_available():
    if not shutil.which("shellcheck"):
        pytest.skip("shellcheck not installed")
    r = subprocess.run(["shellcheck", "-S", "warning", str(QS)], capture_output=True, text=True)
    assert r.returncode == 0, f"shellcheck found issues:\n{r.stdout}\n{r.stderr}"


def test_project_with_no_value_does_not_hang():
    """P0-1: `--project` with no value must die cleanly, not spin forever."""
    try:
        r = _run(["--project"], env={"KOBOI_UC_HOME": "/tmp/qs-nonexistent"}, timeout=8)
    except subprocess.TimeoutExpired:
        pytest.fail("--project with no value hung (infinite loop) -- P0-1 regressed")
    assert r.returncode != 0
    assert "requires a project name" in r.stderr, f"unexpected stderr: {r.stderr}"


def test_yes_without_project_dies_cleanly():
    try:
        r = _run(["--yes"], env={"KOBOI_UC_HOME": "/tmp/qs-nonexistent"}, timeout=8)
    except subprocess.TimeoutExpired:
        pytest.fail("--yes without --project hung")
    assert r.returncode != 0
    assert "requires --project" in r.stderr


def test_no_color_flag_emits_no_ansi():
    """P0-3: --no-color must actually disable color.

    Under pytest's piped stdout `[ -t 1 ]` is false, so colors are off REGARDLESS
    of the pre-scan fix -- a plain subprocess call can't catch a regression. Run
    under a pseudo-terminal so `[ -t 1 ]` is true; then ONLY the --no-color
    pre-scan (exporting NO_COLOR before the color-init block) disables ANSI."""
    try:
        import pty
    except ImportError:
        pytest.skip("pty not available (non-Unix)")

    def run_pty(argv):
        pid, fd = pty.fork()
        if pid == 0:  # child: stdin/stdout/stderr = the pty slave ([ -t 1 ] is true)
            os.execvp(argv[0], argv)
        out = b""
        try:
            while True:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                out += chunk
        except OSError:
            pass
        os.waitpid(pid, 0)
        return out

    out = run_pty(["bash", str(QS), "--no-color", "--list"]).decode(errors="replace")
    assert "\x1b[" not in out, "ANSI escapes present despite --no-color (pre-scan regressed)"


def test_no_utf8_flag_emits_no_raw_unicode():
    """P0-3/B: --no-utf8 must not emit raw UTF-8 glyphs (banner/mojibake)."""
    r = _run(["--no-utf8", "--list"])
    # No raw non-ASCII bytes should reach stdout under --no-utf8.
    non_ascii = [b for b in r.stdout.encode() if b >= 0x80]
    assert not non_ascii, f"raw non-ASCII bytes under --no-utf8: {non_ascii[:20]}"


def test_list_shows_all_ten_projects_and_ports():
    r = _run(["--list"])
    out = r.stdout
    for name in ["ecommerce-support", "hr-screening", "finance-reconciliation",
                 "healthcare-intake", "legal-contract-review", "real-estate",
                 "insurance-claims", "market-intel", "employee-concierge", "customer-success"]:
        assert name in out, f"{name} missing from --list"
    # Port table: every port 8001-8010 must appear (not just the endpoints).
    for port in range(8001, 8011):
        assert f":{port}" in out, f"port :{port} missing from --list"


def test_unknown_project_rejected():
    r = _run(["--project", "no-such-project"], env={"KOBOI_UC_HOME": "/tmp/qs-nonexistent"}, timeout=8)
    assert r.returncode != 0
    assert "unknown project" in r.stderr


def test_ps1_daemon_check_uses_lastexitcode():
    """P0-2: the .ps1 must test $LASTEXITCODE, not rely on try/catch (which never
    fires for a native exe returning nonzero)."""
    src = PS1.read_text()
    assert "$LASTEXITCODE" in src, "ps1 daemon check doesn't test $LASTEXITCODE (P0-2)"
    # And the broken try/catch on docker info should be gone.
    assert "try { docker info" not in src, "ps1 still uses try/catch around docker info"


def _fake_docker_env(tmp_path, info_line):
    """Put a fake `docker` on PATH so preflight's daemon check can be exercised
    without a real daemon. `docker compose ...` -> ok; `docker info` -> print
    `info_line` to stderr and exit 1 (mirroring how docker reports the reason).
    Scoped to the subprocess via PATH; does not touch the real docker."""
    shim = tmp_path / "docker"
    shim.write_text(
        "#!/usr/bin/env bash\n"
        'case "$1" in\n'
        "  compose) exit 0 ;;\n"
        f"  info) echo {shlex.quote(info_line)} >&2; exit 1 ;;\n"
        "esac\n"
        "exit 0\n"
    )
    shim.chmod(0o755)
    return {"PATH": f"{tmp_path}:{os.environ['PATH']}", "KOBOI_UC_HOME": str(tmp_path / "home")}


def test_preflight_permission_denied_guides_docker_group(tmp_path):
    """Linux first-run #1 (the reported bug): the daemon IS running, but this
    user isn't in the docker group, so `docker info` exits 1 with 'permission
    denied'. quickstart must NOT claim the daemon is down -- it must point at
    `usermod -aG docker` (the actual fix)."""
    env = _fake_docker_env(
        tmp_path,
        "Got permission denied while trying to connect to the Docker daemon socket "
        "at unix:///var/run/docker.sock",
    )
    r = _run(["--project", "hr-screening", "--yes"], env=env, timeout=10)
    assert r.returncode != 0
    assert "usermod -aG docker" in r.stderr, f"missing docker-group guidance:\n{r.stderr}"
    # The old misleading "daemon is not running" message must be gone on this path.
    assert "daemon is not running" not in r.stderr, f"old wrong message still present:\n{r.stderr}"


def test_preflight_daemon_down_guides_systemctl(tmp_path):
    """Linux first-run #2: the daemon is genuinely not running. quickstart must
    advise `systemctl start docker`."""
    env = _fake_docker_env(
        tmp_path,
        "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. "
        "Is the docker daemon running?",
    )
    r = _run(["--project", "hr-screening", "--yes"], env=env, timeout=10)
    assert r.returncode != 0
    assert "systemctl start docker" in r.stderr, f"missing systemctl guidance:\n{r.stderr}"


def test_wizard_without_tty_guides_instead_of_garbled_error(tmp_path):
    """The `curl ... | bash` over a broken SSH/web-console case: the wizard's
    menu shows but /dev/tty can't deliver keystrokes, so the choice comes back
    empty. Must print actionable guidance -- NOT the old garbled cascade of
    'invalid choice' followed by 'unknown project <entire menu>'."""
    bin_ = tmp_path / "bin"
    bin_.mkdir()
    shim = bin_ / "docker"
    # Fake docker that satisfies preflight (compose ok, info ok, ps -> empty).
    shim.write_text('#!/usr/bin/env bash\ncase "$1" in compose|info) exit 0;; esac\nexit 0\n')
    shim.chmod(0o755)
    r = _run([], env={"PATH": f"{bin_}:{os.environ['PATH']}"}, timeout=15)  # wizard, no args; piped stdout -> no tty
    assert r.returncode != 0
    assert "Can't read keyboard input" in r.stderr
    assert "--project" in r.stderr
    # The old garbled double-error must be gone.
    assert "unknown project" not in r.stderr, f"garbled 'unknown project' still present:\n{r.stderr}"
    assert "invalid choice" not in r.stderr, f"'invalid choice' still present:\n{r.stderr}"


def test_preflight_dial_unix_down_guides_systemctl_not_usermod(tmp_path):
    """Regression: a daemon-DOWN error reported in the raw Go form
    `dial unix /var/run/docker.sock: connect: connection refused` used to match
    the permission-denied arm (via a bare *"dial unix"* pattern) and wrongly
    tell the user to run `usermod -aG docker`. It must route to the daemon-down
    remedy (`systemctl start docker`)."""
    env = _fake_docker_env(
        tmp_path,
        "dial unix /var/run/docker.sock: connect: connection refused",
    )
    r = _run(["--project", "hr-screening", "--yes"], env=env, timeout=10)
    assert r.returncode != 0
    assert "systemctl start docker" in r.stderr, f"missing systemctl guidance:\n{r.stderr}"
    assert "usermod -aG docker" not in r.stderr, (
        f"misclassified daemon-down (dial unix ... connection refused) as "
        f"permission-denied:\n{r.stderr}"
    )


def test_preflight_unrecognized_error_hits_catchall(tmp_path):
    """An unrecognized `docker info` failure must hit the catch-all: exit
    non-zero AND surface the captured message so the user is never left with a
    blank reason."""
    env = _fake_docker_env(tmp_path, "docker: something totally novel went wrong")
    r = _run(["--project", "hr-screening", "--yes"], env=env, timeout=10)
    assert r.returncode != 0
    assert "unexpected error" in r.stderr, f"catch-all die not hit:\n{r.stderr}"
    assert "something totally novel went wrong" in r.stderr, (
        f"captured docker message not surfaced in the catch-all:\n{r.stderr}"
    )
