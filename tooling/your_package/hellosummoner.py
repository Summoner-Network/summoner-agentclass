import sys, os
target_path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if target_path not in sys.path:
    sys.path.insert(0, target_path)

# from summoner.client import SummonerClient

def hello_summoner():
    print("Hello Summoner!")