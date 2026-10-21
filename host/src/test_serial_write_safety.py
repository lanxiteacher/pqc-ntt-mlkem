"""Offline guards for finite writes, no flush, and no partial-frame retries."""
import sys
import types
from unittest.mock import patch

import link


def main():
    class Sink:
        def __init__(self):
            self.is_open = True
            self.calls = []
            self.error = None
            self.short = False

        def write(self, data):
            self.calls.append(data)
            if self.error:
                raise self.error
            return len(data) - 1 if self.short else len(data)

        def flush(self):
            raise AssertionError('unbounded flush must not be called')

        def close(self):
            self.is_open = False

    sink = Sink()
    opened = {}

    def factory(port, **kwargs):
        opened.update(port=port, **kwargs)
        return sink

    serial = types.SimpleNamespace(serial_for_url=factory, PARITY_NONE='N',
                                   STOPBITS_ONE=1, SerialException=OSError)
    with patch.dict(sys.modules, serial=serial):
        transport = link.SerialLink(port='test-only')
    assert opened['write_timeout'] == 5.0 and opened['timeout'] > 0
    for payload in (b'x\n', b'123\n' * 256, b'123\n' * 512):
        before = len(sink.calls)
        transport.write(payload)
        assert sink.calls[before:] == [payload]
    sink.short = True
    before = len(sink.calls)
    try:
        transport.write(b'abc\n')
    except OSError as exc:
        assert 'short write' in str(exc)
    else:
        raise AssertionError('short write accepted')
    assert len(sink.calls) == before + 1
    sink.short = False
    for error in (TimeoutError('driver write timed out'), OSError('disconnected')):
        sink.error = error
        before = len(sink.calls)
        try:
            transport.write(b'abc\n')
        except OSError as exc:
            assert exc is error
        else:
            raise AssertionError('driver failure swallowed')
        assert len(sink.calls) == before + 1
    transport.close()
    assert not sink.is_open
    print('PASS: finite driver timeout; 3 complete writes; no flush; short write, timeout and disconnect fail without retries.')
    print('Scope: mocked serial driver; real CH340 soak still required.')


if __name__ == '__main__':
    main()
