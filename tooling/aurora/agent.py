import inspect
import asyncio

from summoner.client import SummonerClient
from summoner.protocol.process import Receiver

from tooling.your_package import hello_summoner

hello_summoner()

from .utils.async_keyed_mutex import AsyncKeyedMutex

from typing import Callable, Union, Hashable, Any, Optional


class SummonerAgent(SummonerClient):
    
    release_name = "aurora"
    release_version = "beta.1.1.0"

    def __init__(self, name: Optional[str] = None):
        super().__init__(name)         
        self._key_mutex: Optional[AsyncKeyedMutex] = None
        self._seq_seen: dict[tuple[str, Hashable], int] = {}   # (route,key) -> last seq 

    # identities:
    # identity = agent.identity()
    # identity.use(file)
    # use SummonerClient.initialize() to set up ID (variables, etc)

    # hooks:
    # - added aurora version
    # - validation could have reputation       

    def keyed_receive(
        self,
        route: str,
        key_by: Union[str, Callable[[Any], Hashable]],
        priority: Union[int, tuple[int, ...]] = (),
        seq_by: Union[None, str, Callable[[Any], int]] = None,   # optional dedupe
    ):
        """
        Register a receiver that enforces per-key mutual exclusion and optional replay
        protection, while preserving high concurrency across different keys.

        This decorator wraps the async handler so that, for a given (route, key),
        only one invocation runs at a time. Messages for different keys execute
        concurrently. If `seq_by` is provided, the decorator also drops stale or
        duplicate messages whose sequence is less than or equal to the last seen
        for that (route, key).

        Parameters:
            route (str):
                Route pattern, same semantics as `@receive`. If Flow is enabled,
                the route is parsed and normalized before registration.
            key_by (str | Callable[[Any], Hashable]):
                How to extract the per-entity key from the payload. If a string,
                it is treated as a dict key or attribute name. If a callable, it
                must return a hashable key. Composite keys may be returned as tuples.
            priority (int | tuple[int, ...], optional):
                Handler priority, identical to `@receive`. Default is `()`.
            seq_by (None | str | Callable[[Any], int], optional):
                Optional monotonic sequence extractor used for replay protection.
                If provided, any message with `seq <= last_seen_seq[(route, key)]`
                is ignored. If a string, treated as a dict key or attribute name;
                if a callable, it must return an integer sequence.

        Handler signature:
            async def fn(payload) -> Optional[Event]

        Returns:
            Callable: A decorator that registers the wrapped handler.

        Behavior:
            - Lock granularity is (route, key). Different routes do not share locks,
              even for the same key.
            - The lock covers the handler body; keep work inside the critical section
              short and offload slow I/O if possible.
            - Sequence state is kept in-memory in `self._seq_seen` and resets on process
              restart. It is not persisted or shared across processes.

        Limitations:
            - Fairness: `asyncio.Lock` is not strictly FIFO. If strict per-key FIFO is
              required, prefer a per-key mailbox/queue worker.
            - Scope: Mutual exclusion is per Python process and event loop. It does not
              serialize work across different machines or processes.
            - Assumption: `self._key_mutex` must be an instance of `AsyncKeyedMutex`
              before use.

        Examples:

            @agent.keyed_receive("game:move", key_by="player_id")
            async def on_move(payload):
                # payload is a dict like {"player_id": "...", "dx": ..., "dy": ...}
                # This critical section is serialized *only* for this player_id.
                # Keep it tight: update in-memory state, enqueue work, emit events, etc.
                # If you use Flow, you can return an Event; otherwise return None.
                ...

            @agent.keyed_receive("account:update", key_by="account_id", seq_by="seq")
            async def on_account_update(payload):
                # payload: {"account_id": "A123", "seq": 41, "delta": {...}}
                # For each account_id:
                #   - messages run under a per-key lock
                #   - any message with seq <= last_seen_seq will be ignored
                ...

            @agent.keyed_receive("player:event",
                                 key_by=lambda p: (p["zone_id"], p["player"]["id"]),
                                 seq_by=lambda p: int(p["meta"]["ts_ns"]))
            async def on_player_event(payload): ...
        """
        route = route.strip()

        # --- Build extractors once (no duplication) ---
        if key_by is None:
            raise ValueError("@keyed_receive requires key_by")

        if isinstance(key_by, str):
            def _key(payload): 
                return payload[key_by] if isinstance(payload, dict) else getattr(payload, key_by)
        else:
            _key = key_by

        if seq_by is None:
            def _seq(_): return None
        elif isinstance(seq_by, str):
            def _seq(payload): 
                return payload[seq_by] if isinstance(payload, dict) else getattr(payload, seq_by)
        else:
            _seq = seq_by

        def decorator(fn):
            if not inspect.iscoroutinefunction(fn):
                raise TypeError(f"@keyed_receive handler '{fn.__name__}' must be async")

            tuple_priority = (priority,) if isinstance(priority, int) else tuple(priority)

            # DNA capture (same shape as base class)
            self._dna_receivers.append({
                "fn": fn,
                "route": route,
                "priority": tuple_priority,
                "source": inspect.getsource(fn),
                "module": fn.__module__,
                "fn_name": fn.__name__,
            })

            async def register():
                # lazy init
                if self._key_mutex is None:
                    self._key_mutex = AsyncKeyedMutex()

                raw_fn = fn
                key_fn = _key         # freeze closures
                seq_fn = _seq

                async def wrapped(payload):
                    k = key_fn(payload)
                    async with self._key_mutex.lock((route, k)):
                        s = seq_fn(payload)
                        if s is not None:
                            last = self._seq_seen.get((route, k))
                            if last is not None and s <= last:   # drop stale/replay
                                return None
                            self._seq_seen[(route, k)] = s
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
