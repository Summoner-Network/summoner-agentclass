import pytest

import sys, os
target_path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if target_path not in sys.path:
    sys.path.insert(0, target_path)

from tooling.kobold import KoboldAgent


def test_kobold_agent():
    success = True
    try:
        agent = KoboldAgent()
    except:
        success = False
    assert success