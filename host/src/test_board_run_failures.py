"""CLI lifetime and evidence checks; mocked driver, no physical port opened."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
from unittest.mock import patch

import board_run
import link


def main():
    checks = 0
    with tempfile.TemporaryDirectory(prefix="pqc_cli_failure_") as tmp:
        result = Path(tmp) / "result.json"
        for command in ("#PING", "#NTT 1"):
            for fault in ("short", "timeout", "disconnect", "read", "close"):
                class Sink:
                    is_open = True
                    writes = 0
                    closes = 0

                    def write(self, data):
                        self.writes += 1
                        if fault == "short":
                            return len(data) - 1
                        if fault == "timeout":
                            raise TimeoutError("controlled write timeout")
                        if fault == "disconnect":
                            raise OSError("controlled disconnect")
                        return len(data)

                    def read(self, size):
                        raise OSError("controlled receive failure")

                    def close(self):
                        self.closes += 1
                        if fault == "close":
                            raise OSError("controlled close failure")
                        self.is_open = False

                sink = Sink()
                serial = types.SimpleNamespace(
                    serial_for_url=lambda *a, **k: sink, PARITY_NONE="N",
                    STOPBITS_ONE=1, SerialException=OSError)
                err = io.StringIO()
                with patch.dict(sys.modules, serial=serial), \
                     patch.object(board_run.host.Host, "handshake", return_value=False), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                    rc = board_run.main(["--port", "mock-only", "--result-json", str(result), command])
                evidence = json.loads(result.read_text(encoding="utf-8"))
                assert rc == 1 and evidence["status"] == "fail", (command, fault)
                assert sink.closes == 1 and evidence["close_attempted"]
                assert evidence["closed"] == (fault != "close")
                assert sink.writes == 1, "interrupted frame must not be retried"
                assert evidence["stage"] == ("probe" if command == "#PING" else "transaction")
                assert "BOARD_RUN_RESULT " in err.getvalue() and "Traceback" not in err.getvalue()
                assert evidence["error_type"] == ("TimeoutError" if fault == "timeout" else "OSError")
                checks += 1
        # Exercise real CLI subprocess success/argument behavior and saved evidence.
        for command in ("#PING", "#NTT 1", "#PMUL FULL 1"):
            p = subprocess.run([sys.executable, str(Path(board_run.__file__)), "--loopback",
                                "--physical-order", "--check", "--result-json", str(result), command],
                               capture_output=True, timeout=30)
            evidence = json.loads(result.read_text(encoding="utf-8"))
            assert p.returncode == 0, p.stderr
            assert evidence["status"] == "pass" and evidence["closed"]
            checks += 1
        p = subprocess.run([sys.executable, str(Path(board_run.__file__)), "--help"],
                           capture_output=True, timeout=10)
        assert p.returncode == 0 and b"BOARD_RUN_RESULT" not in p.stderr
        checks += 1
        with patch.object(link, "open_link", side_effect=SystemExit("controlled open failure")), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            assert board_run.main(["--result-json", str(result), "#NTT 1"]) == 1
        evidence = json.loads(result.read_text(encoding="utf-8"))
        assert not evidence["close_attempted"] and evidence["stage"] == "open"
        checks += 1
    print(f"PASS: {checks} CLI failure/success checks; no board accessed")


if __name__ == "__main__":
    main()
