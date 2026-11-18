## Trajectory


One logged conversation.


Usage

``` python
Trajectory(
    turns,
    last_active,
    user,
    provenance,
)
```


`turns` are its chatlas turns as of its latest chat activity, and `last_active` is the time of that activity, in UTC. `user` is the authenticated user of the session, from the conversation's earliest recorded chat, or None when none was recorded. `provenance` has one record per exchange, in order.


## Parameter Attributes


`turns: list[Turn]`  

`last_active: datetime`  

`user: str | None`  

`provenance: list[ExchangeProvenance]`
