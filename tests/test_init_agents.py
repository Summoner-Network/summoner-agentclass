import pytest
from tooling.kobold import KoboldAgent

def test_kobold():
    success = True
    try:
        agent = KoboldAgent()
    except:
        success = False
    assert success