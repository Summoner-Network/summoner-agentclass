import os
import sys
from typing import Callable, Union
import inspect
import asyncio

# Setup path
target_path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if target_path not in sys.path:
    sys.path.insert(0, target_path)

from summoner.client import SummonerClient

class KoboldAgent(SummonerClient):
    
    release_name = "kobold"
    release_version = "1.0.0"

    # identities:
        # identity = agent.identity()
        # identity.use(file)
        # use SummonerClient.initialize() to set up ID (variables, etc)

    # hooks:
    # - added kobold version
    # - validation could have reputation
    
    

