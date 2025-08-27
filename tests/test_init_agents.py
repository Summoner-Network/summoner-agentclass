import pytest

import sys, os
target_path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if target_path not in sys.path:
    sys.path.insert(0, target_path)

from tooling.aurora import SummonerAgent


def test_kobold_agent():
    success = True
    try:
        agent = SummonerAgent()
    except:
        success = False
    assert success