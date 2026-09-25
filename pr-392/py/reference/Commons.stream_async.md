## Commons.stream_async()


Ask a question and stream the answer as it arrives.


Usage

``` python
Commons.stream_async(
    *args,
    content="text",
    echo="none",
    data_model=None,
    kwargs=None,
    controller=None
)
```


The signature is identical to chatlas's, so a chat UI can drive this agent directly and needs the attachment content, the mode, and the controller its stop button cancels through.

The Commons agent does not accept `data_model`. If you pass it, this method raises NotImplementedError. In chatlas, using `data_model` means the chunks are JSON that the caller parses as one document. Commons adds provenance markers and citations to the stream that are not compatible with `data_model`, so it is explicitly forbidden.
