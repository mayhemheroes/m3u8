#! /usr/bin/env python3
"""Atheris fuzz harness for the m3u8 HLS playlist parser.

Feeds arbitrary text to m3u8's public parse API (m3u8.loads) and round-trips
the resulting model back to text via .dumps(). Atheris instruments the imported
m3u8 modules so libFuzzer drives the parser toward new code paths.

Run modes (driven by the compiled launcher `m3u8_fuzzer` / `-standalone`):
  * fuzzing      — `python3 fuzz_load.py [libFuzzer args]`
  * single input — `python3 fuzz_load.py <file>` (libFuzzer runs it once)
"""
from decimal import InvalidOperation

import atheris
import sys
import fuzz_helpers

with atheris.instrument_imports(include=["m3u8"]):
    import m3u8


def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        playlist = m3u8.loads(fdp.ConsumeRemainingString())
        playlist.dumps()
    except ValueError as e:
        if 'not enough' in str(e) or 'could not convert' in str(e):
            return -1
        raise
    except TypeError as e:
        if '__init__' in str(e):
            return -1
        raise


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
