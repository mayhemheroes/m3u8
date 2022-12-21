#! /usr/bin/env python3
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
