from summoner.server import SummonerServer
from tooling.your_package import hello_summoner

if __name__ == "__main__":
    hello_summoner()
    srv = SummonerServer(name="test_Server")
    srv.run(config_path="test_server_config.json")
