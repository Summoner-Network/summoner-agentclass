import inspect
import asyncio

# Setup path
import sys, os
target_path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if target_path not in sys.path:
    sys.path.insert(0, target_path)

from summoner.client import SummonerClient
from summoner.protocol.process import Receiver

from typing import Callable, Union, Hashable, Any, Optional


class AsyncKeyedMutex:
    def __init__(self):
        self._locks: dict[Hashable, asyncio.Lock] = {}
        self._refs: dict[Hashable, int] = {}
        self._guard = asyncio.Lock()

    def lock(self, key: Hashable):
        mutex = self
        class _Guard:
            async def __aenter__(self_nonlocal):
                async with mutex._guard:
                    lock = mutex._locks.get(key)
                    if lock is None:
                        lock = asyncio.Lock()
                        mutex._locks[key] = lock
                        mutex._refs[key] = 0
                    mutex._refs[key] += 1
                    self_nonlocal._lock = lock
                await self_nonlocal._lock.acquire()
            async def __aexit__(self_nonlocal, exc_type, exc, tb):
                self_nonlocal._lock.release()
                async with mutex._guard:
                    mutex._refs[key] -= 1
                    if mutex._refs[key] == 0:
                        del mutex._locks[key]
                        del mutex._refs[key]
        return _Guard()

class SummonerAgent(SummonerClient):
    
    release_name = "aurora"
    release_version = "0.0.1"

    def __init__(self, name: Optional[str] = None):
        super().__init__(name)         
        self._key_mutex: Optional[AsyncKeyedMutex] = None  

    # identities:
    # identity = agent.identity()
    # identity.use(file)
    # use SummonerClient.initialize() to set up ID (variables, etc)

    # hooks:
    # - added aurora version
    # - validation could have reputation       

    def mutex_receive(
        self,
        route: str,
        *,
        priority: Union[int, tuple[int, ...]] = (),
        key_by: Union[str, Callable[[Any], Hashable]] = None,
    ):
        route = route.strip()
        def decorator(fn):
            if not inspect.iscoroutinefunction(fn):
                raise TypeError(f"@mutex_receive handler '{fn.__name__}' must be async")

            # Normalize priority like base class
            tuple_priority = (priority,) if isinstance(priority, int) else tuple(priority)

            # DNA capture (match base format)
            self._dna_receivers.append({
                "fn": fn,
                "route": route,
                "priority": tuple_priority,
                "source": inspect.getsource(fn),
                "module": fn.__module__,
                "fn_name": fn.__name__,
            })

            async def register():
                nonlocal key_by
                if self._key_mutex is None:
                    self._key_mutex = AsyncKeyedMutex()

                if key_by is None:
                    raise ValueError("@mutex_receive requires key_by")

                if isinstance(key_by, str):
                    def _key(payload):
                        return payload[key_by] if isinstance(payload, dict) else getattr(payload, key_by)
                else:
                    _key = key_by

                raw_fn = fn
                async def wrapped(payload):
                    k = _key(payload)
                    async with self._key_mutex.lock(k):
                        return await raw_fn(payload)

                receiver = Receiver(fn=wrapped, priority=tuple_priority)

                if self._flow.in_use:
                    parsed_route = self._flow.parse_route(route)
                    normalized_route = str(parsed_route)
                    async with self.routes_lock:
                        self.receiver_parsed_routes[normalized_route] = parsed_route
                        self.receiver_index[normalized_route] = receiver
                else:
                    async with self.routes_lock:
                        self.receiver_index[route] = receiver

            self._schedule_registration(register())
            return fn
        return decorator
