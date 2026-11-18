## Commons.prewarm()


Build the caches the first question would otherwise pay for.


Usage

``` python
Commons.prewarm()
```


Failures propagate: a direct call is typically warming caches ahead of a deployment, so a cold cache should fail the deploy.
