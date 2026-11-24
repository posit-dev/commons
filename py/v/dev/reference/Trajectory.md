## Trajectory


One logged conversation.


Usage

``` python
Trajectory(
    turns,
    last_active,
    user,
    exchanges,
)
```


`turns` are its chatlas turns as of its latest chat activity, and `last_active` is the time of that activity, in UTC. `user` is the authenticated user of the session, from the conversation's earliest recorded chat, or None when none was recorded. `exchanges` splits `turns` at each question the user asked, with the provenance recorded for each answer. Turns before the first question, such as the system prompt, are in no exchange.


## Parameter Attributes


`turns: list[Turn]`  

`last_active: datetime`  

`user: str | None`  

`exchanges: list[Exchange]`
