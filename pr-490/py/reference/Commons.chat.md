## Commons.chat()


Ask a question and wait for the whole answer.


Usage

``` python
Commons.chat(
    *args,
    echo="output",
    stream=True,
    kwargs=None,
)
```


A reminder queued with [queue_restore_reminder()](Commons.queue_restore_reminder.md#commons.Commons.queue_restore_reminder) rides this turn, and a turn that fails leaves it queued for the next one.
