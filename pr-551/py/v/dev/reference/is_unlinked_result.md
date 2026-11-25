## is_unlinked_result()


Whether a tool result from [trajectory_read()](trajectory_read.md#commons.trajectory_read) has no recorded tool call.


Usage

``` python
is_unlinked_result(result)
```


A conversation's spans can record a tool result without the tool call it answers. Such a result has a placeholder `request`, with the result's recorded id, an empty name, and no arguments, so that chatlas can print it. This returns True for a result with that placeholder or with no request at all, and False for a result linked to a recorded tool call, even one that recorded no name.


## Parameters


`result: ContentToolResult`  
A tool result from the turns of a [Trajectory](Trajectory.md#commons.Trajectory) or an [Exchange](Exchange.md#commons.Exchange).
